import CoreAudio
import Foundation
import Network
import CryptoKit

func runConnectionTests() throws {
    var count = 0
    func check(_ condition: Bool, _ description: String) throws {
        guard condition else { throw BridgeError("FAIL: \(description)") }
        count += 1; print("PASS: \(description)")
    }
    let key = Keys.generate()
    let name = BridgeDiscovery.serviceName(for: key)
    try check(name == BridgeDiscovery.serviceName(for: key) && name != BridgeDiscovery.serviceName(for: Keys.generate()), "discovery matches only the previously paired random key")
    try check(!name.contains(key.base64EncodedString()), "Bonjour never advertises the pairing key")
    // Service types: DNS-SD labels of at most 15 lowercase letters, digits
    // and hyphens; not 0.9's, so 1.0 and 0.9 never see each other; and the
    // same two the app declares for Local Network access.
    let types = [BridgeDiscovery.serviceType, NearbyPairingServer.serviceType]
    try check(types.allSatisfy { type in
        guard type.hasPrefix("_"), type.hasSuffix("._tcp") else { return false }
        let label = type.dropFirst().dropLast(5)
        return (1...15).contains(label.count) && label.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
            && label.first != "-" && label.last != "-" && label.contains { ("a"..."z").contains($0) }
    } && Set(types).count == 2, "both Bonjour service types follow the DNS-SD naming rules")
    try check(Set(types).isDisjoint(with: ["_micbridge._tcp", "_micbridge-pair._tcp"]), "1.0 doesn't use 0.9's service types, so neither lists the other")
    if let declared = Bundle.main.object(forInfoDictionaryKey: "NSBonjourServices") as? [String] {
        try check(Set(declared) == Set(types), "Info.plist declares exactly these service types")
    }
    try check(Wire.isLocalNetworkDenied(.dns(-65570), path: nil), "Local Network privacy denial is recognised")
    let routed = try JSONDecoder().decode(Message.self, from: JSONEncoder().encode(Message(kind: "helloOK", hosts: ["192.168.1.2"])))
    try check(routed.hosts == ["192.168.1.2"] && (try JSONDecoder().decode(Message.self, from: Data(#"{"version":2,"id":"x","date":0,"kind":"helloOK","session":"","text":""}"#.utf8))).hosts == nil, "wired-route hint round-trips and is optional for older peers")
    try check(LocalAddresses.wiredIPv4().allSatisfy { !$0.hasPrefix("127.") && !$0.hasPrefix("169.254.") }, "wired-route hint never offers loopback or link-local addresses")
    try check(!Wire.isLocalNetworkDenied(.dns(-65554), path: nil) && !Wire.isLocalNetworkDenied(nil, path: nil), "ordinary DNS failures are not reported as a privacy denial")
    let legacy = Message(kind: "hello", text: "legacy")
    let legacyData = try JSONEncoder().encode(legacy)
    try check(try JSONDecoder().decode(Message.self, from: legacyData).clientVersion == nil, "legacy version-2 handshake remains readable")
    let modern = Message(kind: "hello", clientVersion: bridgeVersion)
    try check(try JSONDecoder().decode(Message.self, from: JSONEncoder().encode(modern)).clientVersion == bridgeVersion, "authenticated handshake carries the displayed version")
    // Presentation: the footer never claims the remote microphone state
    // while disconnected, and app / peer names read naturally.
    let peer = "MacBook"
    try check(!StatusCopy.micCaption(role: .borrower, peer: peer, enabled: true, connected: false, micActive: false).contains("已关闭"),
              "a disconnected borrower does not claim to know the remote microphone state")
    try check(StatusCopy.micCaption(role: .borrower, peer: peer, enabled: true, connected: true, micActive: false).contains("已关闭"),
              "a connected idle borrower clearly reports no capture")
    try check(StatusCopy.micCaption(role: .borrower, peer: peer, enabled: true, connected: true, micActive: true).contains("使用中"),
              "active capture cannot be presented as idle")
    try check(StatusCopy.micCaption(role: .provider, peer: peer, enabled: true, connected: true, micActive: true).contains("使用中"),
              "the provider shows its own microphone in use")
    let incoming = PanelSnapshot(status: .incomingPairing(peer: peer, code: "482193"), role: .borrower, peerName: peer)
    try check(incoming.formattedCode == "482 193" && incoming.title.contains("允许") && incoming.title.contains(peer) && incoming.subtitle.isEmpty,
              "the approving Mac shows who asks and the code, in one sentence")
    let asking = PanelSnapshot(status: .pairing(code: "482193", message: ""), role: .provider, peerName: "工作室")
    try check(asking.subtitle.contains("工作室"), "the asking Mac names the Mac that must approve")
    let recording = PanelSnapshot(status: .inUse(.live), role: .borrower, micActive: true, peerName: peer, client: "备忘录")
    try check(recording.subtitle.contains("备忘录") && recording.title.contains(peer), "the borrower names the app and whose microphone it uses")
    try check(appLead("Safari") == "Safari " && appLead("备忘录") == "备忘录" && appLead("") == "应用", "app names read naturally in Chinese sentences")
    try check(cjkSpaced("已连接Studio的麦克风") == "已连接 Studio 的麦克风" && cjkSpaced("已连接 Studio 的麦克风") == "已连接 Studio 的麦克风",
              "Chinese and Latin runs are spaced exactly once")

    // Nearby pairing crypto: same code and key on both sides; MITM changes the code.
    let client = Curve25519.KeyAgreement.PrivateKey(), server = Curve25519.KeyAgreement.PrivateKey()
    let cPub = client.publicKey.rawRepresentation, sPub = server.publicKey.rawRepresentation
    let a = try PairingCrypto.agree(client, peer: sPub, client: cPub, server: sPub)
    let b = try PairingCrypto.agree(server, peer: cPub, client: cPub, server: sPub)
    try check(a.code == b.code && a.code.count == 6 && a.key == b.key, "both Macs derive the same pairing code and key")
    let attacker = Curve25519.KeyAgreement.PrivateKey(), mPub = attacker.publicKey.rawRepresentation
    let toClient = try PairingCrypto.agree(client, peer: mPub, client: cPub, server: mPub)
    let toServer = try PairingCrypto.agree(server, peer: mPub, client: mPub, server: sPub)
    try check(toClient.code != b.code || toServer.code != a.code, "a man in the middle cannot show matching codes on both Macs")
    let pairing = Pairing(host: "studio.local", key: key.base64EncodedString())
    var box = try PairingCrypto.seal(pairing, key: a.key)
    try check(try PairingCrypto.open(box, key: b.key).key == pairing.key, "pairing key travels encrypted and intact")
    box[box.count - 1] ^= 1
    try check((try? PairingCrypto.open(box, key: b.key)) == nil, "tampered pairing box is rejected")
    try check((try? PairingCrypto.open(PairingCrypto.seal(pairing, key: toClient.key), key: b.key)) == nil, "pairing box from a different agreement is rejected")
    try check((try? Pairing(host: "x.local", key: Data(count: 8).base64EncodedString()).validated()) == nil, "short pairing key is rejected")

    print("\(count) connection, pairing and presentation checks passed.")
}

// Real Bonjour advertisement with a TXT presence record, an in-place TXT
// update, resolution and the encrypted handshake, using a fresh test key and
// an ephemeral port (the installed app may hold 45874). No stored
// credentials or audio are accessed.
func runDiscoveryProbe() throws {
    let key = Keys.generate(), challenge = Keys.generate().base64EncodedString()
    let name = BridgeDiscovery.serviceName(for: key)
    let listener = try NWListener(using: .tcp, on: .any)
    var advert = PresenceAdvert(mode: .borrower, version: bridgeVersion, name: "MicBridge probe", model: DeviceIdentity.model)
    listener.service = NWListener.Service(name: name, type: BridgeDiscovery.serviceType, txtRecord: NWTXTRecord(advert.txt))
    let browser = NearbyBrowser()
    var client: Wire?, server: Wire?
    var complete = false, sawIdle = false, sawBusy = false
    var failure: String?
    listener.newConnectionHandler = { connection in
        let wire = Wire(connection: connection, key: key); server = wire
        wire.onReady = {
            wire.send(Message(kind: "challenge", text: challenge))
            do { try wire.useChallenge(challenge) } catch { failure = error.localizedDescription }
        }
        wire.onMessage = { message in
            if message.kind == "hello", message.text == challenge {
                wire.send(Message(kind: "helloOK", clientVersion: bridgeVersion))
            } else { failure = "unexpected discovery handshake" }
        }
        wire.start()
    }
    listener.stateUpdateHandler = { state in
        print("Bonjour listener: \(state)")
        if case .failed(let error) = state { failure = error.localizedDescription }
    }
    listener.serviceRegistrationUpdateHandler = { print("Bonjour registration: \($0)") }
    browser.onChange = { services in
        guard let found = services.first(where: { $0.serviceName == name }) else { return }
        print("Found \(found.serviceName): \(found.advert.map { "\($0.mode.rawValue) busy=\($0.busy) name=\($0.name)" } ?? "no TXT")")
        if found.advert?.busy == false, !sawIdle {
            sawIdle = true
            // Update the TXT record in place, as a Mac does when it links up.
            advert.busy = true
            listener.service = NWListener.Service(name: name, type: BridgeDiscovery.serviceType, txtRecord: NWTXTRecord(advert.txt))
        }
        guard found.advert?.busy == true, client == nil else { return }
        sawBusy = true
        let wire = Wire(connection: NWConnection(to: found.endpoint, using: .tcp), key: key); client = wire
        wire.onMessage = { message in
            if message.kind == "challenge" {
                do { try wire.useChallenge(message.text); wire.send(Message(kind: "hello", text: message.text, clientVersion: bridgeVersion)) }
                catch { failure = error.localizedDescription }
            } else if message.kind == "helloOK" { complete = message.clientVersion == bridgeVersion }
        }
        wire.onClose = { failure = $0.message }; wire.start()
    }
    listener.start(queue: .main); browser.start()
    defer {
        client?.onClose = nil; client?.onMessage = nil; server?.onMessage = nil; server?.onReady = nil
        client?.close(.local("test complete")); server?.close(.local("test complete")); browser.stop(); listener.cancel()
    }
    let deadline = Date().addingTimeInterval(15)
    while !complete && failure == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    guard complete, failure == nil else { throw BridgeError("Bonjour discovery probe: \(failure ?? "timeout") (TXT seen: \(sawIdle), update seen: \(sawBusy))") }
    print("PASS: real Bonjour discovery with TXT presence, in-place TXT update, resolution and encrypted handshake.")
    print("No microphone opened. No pairing keys read or saved.")
}
