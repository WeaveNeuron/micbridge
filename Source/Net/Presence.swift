import Foundation
import Network
import CryptoKit

/// A Mac's stable identity on the network: a fingerprint of its device key
/// (the key it listens with). It is also the tail of its Bonjour service
/// name, so 0.6.0 / 0.7.0 Macs keep finding the same service.
enum DeviceKey {
    static func id(for key: Data) -> String {
        SHA256.hash(data: key).prefix(10).map { String(format: "%02x", $0) }.joined()
    }
    static let servicePrefix = "MicBridge-"
    static func id(fromServiceName name: String) -> String? {
        guard name.hasPrefix(servicePrefix) else { return nil }
        let id = String(name.dropFirst(servicePrefix.count))
        return isID(id) ? id : nil
    }
    /// 20 hex digits, as `id(for:)` makes.
    static func isID(_ text: String) -> Bool {
        text.count == 20 && text.allSatisfy(\.isHexDigit)
    }
}

/// What a Mac is doing right now, as it tells others.
enum PeerMode: String, Codable, Equatable {
    case provider, borrower, paused
    init(role: Role, enabled: Bool) { self = enabled ? (role == .provider ? .provider : .borrower) : .paused }
    var role: Role? { self == .provider ? .provider : self == .borrower ? .borrower : nil }
}

/// The Bonjour TXT record every 0.7.1+ Mac publishes with its service.
/// Coarse on purpose: mode, version, name, model and a busy flag. Whether a
/// microphone is in use only travels over the encrypted link.
/// 0.6.0 / 0.7.0 Macs publish no TXT record at all.
struct PresenceAdvert: Equatable {
    var mode: PeerMode
    var version: String
    var name: String
    var model: String
    /// Linked to another Mac already (a provider serves one borrower).
    var busy = false

    var txt: [String: String] {
        var fields = ["m": mode.rawValue, "v": version, "n": Self.clip(name), "h": Self.clip(model)]
        if busy { fields["b"] = "1" }
        return fields
    }
    init(mode: PeerMode, version: String, name: String, model: String, busy: Bool = false) {
        self.mode = mode; self.version = version; self.name = name; self.model = model; self.busy = busy
    }
    /// Nil for a record without a known mode (older or foreign services).
    init?(txt: [String: String]) {
        guard let raw = txt["m"], let mode = PeerMode(rawValue: raw), let version = txt["v"], !version.isEmpty else { return nil }
        self.init(mode: mode, version: version, name: txt["n"] ?? "", model: txt["h"] ?? "", busy: txt["b"] == "1")
    }
    /// TXT entries are limited to 255 bytes; names are cut on a character
    /// boundary well below that.
    static func clip(_ text: String, bytes: Int = 120) -> String {
        var result = ""
        for character in text {
            if result.utf8.count + String(character).utf8.count > bytes { break }
            result.append(character)
        }
        return result
    }
}

/// One `_micbridge2._tcp` service seen on the network.
struct NearbyService: Equatable {
    var serviceName: String
    var deviceID: String?
    var endpoint: NWEndpoint
    /// Nil for 0.6.0 / 0.7.0 Macs, which only listen as borrowers.
    var advert: PresenceAdvert?
}

/// Browses every MicBridge service nearby, with TXT records. Replaces 0.7.0's
/// browser that only looked for one key.
final class NearbyBrowser {
    private var browser: NWBrowser?
    private(set) var services: [NearbyService] = []
    var onChange: (([NearbyService]) -> Void)?
    var isRunning: Bool { browser != nil }

    /// Starts, or restarts (a browser started before Local Network access was
    /// granted does not recover by itself). Last results stay until new ones.
    func start() {
        browser?.cancel(); browser = nil
        let parameters = NWParameters.tcp; parameters.includePeerToPeer = true
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: BridgeDiscovery.serviceType, domain: "local."), using: parameters)
        b.browseResultsChangedHandler = { [weak self, weak b] results, _ in
            guard let self, self.browser === b else { return }
            self.services = results.compactMap(Self.service).sorted { $0.serviceName < $1.serviceName }
            self.onChange?(self.services)
        }
        browser = b
        b.start(queue: .main)
    }
    func stop() {
        browser?.cancel(); browser = nil
        if !services.isEmpty { services = []; onChange?([]) }
    }
    static func service(_ result: NWBrowser.Result) -> NearbyService? {
        guard case .service(let name, _, _, _) = result.endpoint else { return nil }
        var advert: PresenceAdvert?
        if case .bonjour(let record) = result.metadata { advert = PresenceAdvert(txt: record.dictionary) }
        return NearbyService(serviceName: name, deviceID: DeviceKey.id(fromServiceName: name), endpoint: result.endpoint, advert: advert)
    }
}

/// Post-handshake message kinds a 0.7.1+ peer understands. Sent in hello /
/// helloOK; nothing new is sent to a peer that did not list it.
enum ProtocolFeature {
    static let peerKey = "peerKey", bye = "bye"
    static let all = [peerKey, bye]
}

/// Why a peer said goodbye before closing the link.
enum ByeReason: String, Equatable {
    case quit, paused, sleep, mode
}
