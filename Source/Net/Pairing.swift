import Foundation
import Network
import CryptoKit
import SystemConfiguration

// Nearby pairing: the Mac where the user clicks Add (the client) finds the
// other Mac's pairing service over Bonjour, both sides run an ephemeral X25519
// key agreement and show the same six-digit code, and only an explicit
// "Allow" on the other Mac (the server) sends its device key (encrypted)
// across. Since 0.7.1 the client then answers with its own card under the
// same agreement, so either Mac can dial the other. A 0.7.0 server closes
// right after sending; the client's card then follows over the first link.
// Since 0.8.0 every Mac that is on runs the server, whatever its role.
// Nothing is trusted silently; Apple's Continuity trust is not readable by apps.

func localComputerName() -> String { DeviceIdentity.localName }

func localBonjourHost() -> String {
    let host = (SCDynamicStoreCopyLocalHostName(nil) as String?) ?? ProcessInfo.processInfo.hostName
    return host.hasSuffix(".local") ? host : host + ".local"
}

struct PairFrame: Codable {
    static let version = "micbridge-pair-2"
    var v = PairFrame.version
    var kind: String
    var pub: Data? = nil
    var name: String? = nil
    var box: Data? = nil
    /// 0.9.0+, all optional (older Macs ignore them): the sender's device ID
    /// and model, and in a request the device ID of the Mac being asked.
    /// They only route and label; the card's key fingerprint is what counts.
    var id: String? = nil
    var model: String? = nil
    var to: String? = nil
}

/// Who asked this Mac to pair, as the request said (not yet verified).
struct PairRequest: Equatable {
    var name: String
    var model: String?
    var device: String?
    var code: String
}

/// Which `_micbridge2-pair._tcp` service is the Mac the user picked. Two Macs
/// may share a computer name, so a 0.9.0+ service is matched by the device ID
/// in its TXT record; only a service without one (0.7.1 / 0.8.0) falls back
/// to its exact name. The client still checks the key it receives.
enum PairingTarget {
    static let deviceKey = "d"
    struct Candidate: Equatable {
        var name: String
        var device: String?
    }
    static func pick(_ candidates: [Candidate], device: String, name: String) -> Int? {
        if let index = candidates.firstIndex(where: { $0.device == device }) { return index }
        return candidates.firstIndex { $0.device == nil && $0.name == name }
    }
    static let wrongMac = { tr("对方不是所选的 Mac，已取消配对。", "That isn’t the Mac you chose, so pairing was cancelled.") }
}

enum PairingCrypto {
    static let info = Data("MicBridge nearby pairing v2".utf8)
    static func agree(_ mine: Curve25519.KeyAgreement.PrivateKey, peer: Data, client: Data, server: Data) throws -> (code: String, key: SymmetricKey) {
        let secret = try mine.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: peer))
        let transcript = client + server
        let key = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: transcript, sharedInfo: info + Data("key".utf8), outputByteCount: 32)
        let codeBytes = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: transcript, sharedInfo: info + Data("code".utf8), outputByteCount: 4)
        let value = codeBytes.withUnsafeBytes { $0.reduce(UInt32(0)) { $0 << 8 | UInt32($1) } } % 1_000_000
        return (String(format: "%06d", value), key)
    }
    static func seal(_ pairing: Pairing, key: SymmetricKey) throws -> Data {
        try AES.GCM.seal(JSONEncoder().encode(pairing), using: key).combined!
    }
    static func open(_ box: Data, key: SymmetricKey) throws -> Pairing {
        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: box), using: key)
        return try JSONDecoder().decode(Pairing.self, from: plain).validated()
    }
}

/// Length-prefixed JSON frames for the short, pre-trust pairing exchange.
final class PairLink {
    let connection: NWConnection
    private var buffer = FrameBuffer()
    var onReady: (() -> Void)?
    var onFrame: ((PairFrame) -> Void)?
    var onClose: ((String) -> Void)?
    private(set) var closed = false
    init(_ connection: NWConnection) { self.connection = connection }
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.closed else { return }
            switch state {
            case .ready: self.onReady?(); self.receive()
            case .failed(let error), .waiting(let error): self.close(tr("连接失败：\(error.localizedDescription)", "Couldn’t connect: \(error.localizedDescription)"))
            case .cancelled: self.close(tr("连接已关闭。", "The connection closed."))
            default: break
            }
        }
        connection.start(queue: .main)
    }
    func send(_ frame: PairFrame, then: (() -> Void)? = nil) {
        guard !closed, let body = try? JSONEncoder().encode(frame) else { return }
        var size = UInt32(body.count).bigEndian
        var data = withUnsafeBytes(of: &size) { Data($0) }
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { _ in DispatchQueue.main.async { then?() } })
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, done, error in
            guard let self, !self.closed else { return }
            do {
                if let data {
                    for raw in try self.buffer.append(data) {
                        let frame = try JSONDecoder().decode(PairFrame.self, from: raw)
                        guard frame.v == PairFrame.version else { throw BridgeError(tr("配对版本不兼容。", "Incompatible pairing version.")) }
                        self.onFrame?(frame)
                        if self.closed { return }
                    }
                }
                if done || error != nil { self.close(tr("对方已断开。", "The other Mac disconnected.")) } else { self.receive() }
            } catch { self.close(tr("配对数据无效。", "Invalid pairing data.")) }
        }
    }
    func close(_ reason: String) {
        guard !closed else { return }
        closed = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        onClose?(reason)
    }
}

/// Advertises this Mac's pairing service and waits for the user's decision.
final class NearbyPairingServer {
    static let serviceType = "_micbridge2-pair._tcp"
    private(set) var listener: NWListener?
    private var pending: PairLink?
    private var pendingKey: SymmetricKey?
    /// The device ID of the Mac that asked, if it said (0.9.0+).
    private var pendingRequester: String?
    private var cooldownUntil = Date.distantPast
    var payload: (() throws -> Pairing)?
    /// The name the service is advertised under (0.8.0 clients pick it by it).
    var name: () -> String = localComputerName
    /// This Mac's device ID, advertised in TXT and sent in the offer. Empty:
    /// not known (tests of older servers).
    var deviceID: () -> String = { "" }
    var requestTimeout: TimeInterval = 120
    var rejectCooldown: TimeInterval = 30
    /// The client's own card, sent back after the approval (0.7.1+).
    var onPairedBack: ((Pairing) -> Void)?
    var onRequest: ((PairRequest) -> Void)?
    var onCancelled: (() -> Void)?
    var hasRequest: Bool { pendingKey != nil }

    func start(loopbackOnly: Bool = false, ready: ((NWEndpoint.Port) -> Void)? = nil) throws {
        stop()
        let parameters = NWParameters.tcp; parameters.includePeerToPeer = !loopbackOnly
        if loopbackOnly { parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any) }
        let l = try NWListener(using: parameters)
        if !loopbackOnly {
            let id = deviceID()
            l.service = id.isEmpty ? NWListener.Service(name: name(), type: Self.serviceType)
                                   : NWListener.Service(name: name(), type: Self.serviceType, txtRecord: NWTXTRecord([PairingTarget.deviceKey: id]))
        }
        l.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        l.stateUpdateHandler = { [weak self, weak l] state in
            guard let self, let l, self.listener === l else { return }
            if case .ready = state, let port = l.port { ready?(port) }
            if case .failed = state { self.listener = nil }
        }
        listener = l
        l.start(queue: .main)
    }
    private func accept(_ connection: NWConnection) {
        guard pending == nil, Date() >= cooldownUntil else { connection.cancel(); return }
        let link = PairLink(connection); pending = link
        let mine = Curve25519.KeyAgreement.PrivateKey()
        link.onFrame = { [weak self, weak link] frame in
            guard let self, let link, self.pending === link else { return }
            guard frame.kind == "request", self.pendingKey == nil, let pub = frame.pub,
                  frame.id.map(DeviceKey.isID) ?? true else { link.close(tr("配对请求无效。", "Invalid pairing request.")); return }
            let own = self.deviceID()
            // Meant for another Mac (one with the same name): say so and
            // close, without asking the user here or starting a cooldown.
            if let to = frame.to, !own.isEmpty, to != own {
                link.send(PairFrame(kind: "notMe")) { link.close("not this Mac") }
                return
            }
            let serverPub = mine.publicKey.rawRepresentation
            guard let agreed = try? PairingCrypto.agree(mine, peer: pub, client: pub, server: serverPub) else { link.close(tr("配对请求无效。", "Invalid pairing request.")); return }
            self.pendingKey = agreed.key
            self.pendingRequester = frame.id
            link.send(PairFrame(kind: "offer", pub: serverPub, name: self.name(), id: own.isEmpty ? nil : own))
            self.onRequest?(PairRequest(name: String((frame.name ?? PairedDevice.fallbackName).prefix(40)),
                                        model: frame.model.map { String($0.prefix(60)) }, device: frame.id, code: agreed.code))
        }
        link.onClose = { [weak self, weak link] _ in
            guard let self, let link, self.pending === link else { return }
            let announced = self.pendingKey != nil
            self.clear()
            if announced { self.onCancelled?() }
        }
        link.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + requestTimeout) { [weak self, weak link] in
            if let self, let link, self.pending === link { link.close(tr("配对超时。", "Pairing timed out.")) }
        }
    }
    func approve() throws {
        guard let link = pending, let key = pendingKey, let payload else { return }
        let box = try PairingCrypto.seal(payload(), key: key)
        let requester = pendingRequester
        clear()
        // Wait briefly for the client's card; a 0.7.0 client just closes.
        // A card must be the key of the Mac that said it was asking.
        link.onClose = nil
        link.onFrame = { [weak self, weak link] frame in
            if frame.kind == "key", let box = frame.box, let card = try? PairingCrypto.open(box, key: key),
               let cardKey = card.keyData, requester.map({ $0 == DeviceKey.id(for: cardKey) }) ?? true {
                self?.onPairedBack?(card)
            }
            link?.close("done")
        }
        link.send(PairFrame(kind: "key", box: box))
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { link.close("done") }
    }
    func reject() {
        guard let link = pending else { return }
        clear(); cooldownUntil = Date().addingTimeInterval(rejectCooldown)
        link.send(PairFrame(kind: "reject")) { link.close(tr("已拒绝", "Declined")) }
    }
    private func clear() { pending = nil; pendingKey = nil; pendingRequester = nil }
    func stop() {
        pending?.onClose = nil; pending?.close("stopped"); clear()
        listener?.cancel(); listener = nil
    }
}

/// Asks one nearby Mac, by its pairing service name, to pair, and waits for
/// the user there to approve.
final class NearbyPairingClient {
    private var browser: NWBrowser?
    private var link: PairLink?
    private var timeout: DispatchWorkItem?
    /// The Mac being asked (its pairing service name), while pairing.
    private(set) var target: String?
    /// Its device ID: the key that comes back must have this fingerprint.
    private(set) var targetID: String?
    var isActive: Bool { target != nil }
    /// This Mac's own card, returned to the other Mac after its approval.
    var payload: (() throws -> Pairing?)?
    var onStatus: ((_ message: String, _ code: String, _ peer: String) -> Void)?
    var onPaired: ((Pairing) -> Void)?
    /// Pairing ended without a card: declined, timed out or failed.
    var onFailed: ((String) -> Void)?

    /// Browses for the Mac with device ID `deviceID` (advertised as `name`)
    /// and asks it.
    func start(deviceID: String, name: String, within seconds: TimeInterval = 15) {
        stop()
        target = name; targetID = deviceID
        let parameters = NWParameters.tcp; parameters.includePeerToPeer = true
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: NearbyPairingServer.serviceType, domain: "local."), using: parameters)
        b.browseResultsChangedHandler = { [weak self, weak b] results, _ in
            guard let self, self.browser === b, self.link == nil else { return }
            let list = Array(results)
            let candidates = list.map { result -> PairingTarget.Candidate in
                var serviceName = ""
                if case .service(let n, _, _, _) = result.endpoint { serviceName = n }
                var device: String?
                if case .bonjour(let record) = result.metadata { device = record.dictionary[PairingTarget.deviceKey].flatMap { DeviceKey.isID($0) ? $0 : nil } }
                return PairingTarget.Candidate(name: serviceName, device: device)
            }
            guard let index = PairingTarget.pick(candidates, device: deviceID, name: name) else { return }
            self.browser?.cancel(); self.browser = nil
            self.connect(to: list[index].endpoint, peer: name, deviceID: deviceID)
        }
        browser = b
        b.start(queue: .main)
        onStatus?(tr("正在连接\(name)…", "Connecting to \(name)…"), "", name)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.target == name, self.link == nil else { return }
            self.fail(tr("找不到\(name)，请确认它已打开 MicBridge。",
                         "Couldn’t reach \(name). Make sure MicBridge is open there."))
        }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
    /// Asks the pairing service at `endpoint` (tests: a loopback port). With
    /// a `deviceID`, only that Mac's key is accepted.
    func connect(to endpoint: NWEndpoint, peer: String, deviceID: String?) {
        if target == nil { target = peer }
        targetID = deviceID
        let mine = Curve25519.KeyAgreement.PrivateKey(), clientPub = mine.publicKey.rawRepresentation
        let parameters = NWParameters.tcp; parameters.includePeerToPeer = true
        let link = PairLink(NWConnection(to: endpoint, using: parameters)); self.link = link
        var key: SymmetricKey?
        link.onReady = { [weak self, weak link] in
            // Say who is asking (from this Mac's own card) and whom.
            let own = (try? self?.payload?()) ?? nil
            link?.send(PairFrame(kind: "request", pub: clientPub, name: own?.name ?? localComputerName(),
                                 id: own?.keyData.map(DeviceKey.id(for:)), model: own?.model, to: deviceID))
        }
        link.onFrame = { [weak self, weak link] frame in
            guard let self, let link, self.link === link else { return }
            switch frame.kind {
            case "notMe":
                link.close(PairingTarget.wrongMac())
            case "offer" where key == nil:
                if let deviceID, let id = frame.id, id != deviceID { link.close(PairingTarget.wrongMac()); return }
                guard let pub = frame.pub, let agreed = try? PairingCrypto.agree(mine, peer: pub, client: clientPub, server: pub) else {
                    link.close(tr("配对失败。", "Pairing failed.")); return
                }
                key = agreed.key
                self.timeout?.cancel()
                self.onStatus?(tr("在\(peer)上点“允许”", "Click Allow on \(peer)"), agreed.code, peer)
            case "key":
                guard let k = key, let box = frame.box, let pairing = try? PairingCrypto.open(box, key: k), let cardKey = pairing.keyData else {
                    link.close(tr("配对数据校验失败。", "The pairing data failed verification.")); return
                }
                // The final check, for every server version: the key must be
                // the one whose fingerprint the user picked.
                if let deviceID, DeviceKey.id(for: cardKey) != deviceID { link.close(PairingTarget.wrongMac()); return }
                link.onClose = nil; link.onFrame = nil
                self.link = nil
                self.stop()
                if let mine = try? self.payload?(), let back = try? PairingCrypto.seal(mine, key: k) {
                    link.send(PairFrame(kind: "key", box: back)) { link.close("done") }
                } else { link.close("done") }
                self.onPaired?(pairing)
            case "reject":
                link.close(tr("\(peer)拒绝了配对。", "\(peer) declined to pair."))
            default: link.close(tr("配对失败。", "Pairing failed."))
            }
        }
        link.onClose = { [weak self, weak link] reason in
            guard let self, let link, self.link === link else { return }
            self.link = nil
            self.fail(reason)
        }
        link.start()
    }
    private func fail(_ reason: String) {
        stop()
        onFailed?(reason)
    }
    func stop() {
        timeout?.cancel(); timeout = nil
        link?.onClose = nil; link?.close("stopped"); link = nil
        browser?.cancel(); browser = nil
        target = nil; targetID = nil
    }
}
