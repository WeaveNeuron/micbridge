import Foundation
import Network

/// Two (or more) real `LinkManager`s in one process over 127.0.0.1: no
/// Bonjour, no firewall prompt, no keychain, no audio.
func runLinkTests() throws {
    var count = 0
    func check(_ condition: Bool, _ description: String) throws {
        guard condition else { throw BridgeError("FAIL: \(description)") }
        count += 1; print("PASS: \(description)")
    }
    func spin(_ seconds: TimeInterval = 3, until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }
    func settle(_ seconds: TimeInterval = 0.4) { spin(seconds) { false } }

    final class Node {
        let link = LinkManager(), key = Keys.generate(), name: String, mode: PeerMode
        var events: [ConnectionEvent] = [], messages: [Message] = [], hellos: [PeerHello] = [], results: [CloseReason?] = []
        var replaced = 0
        var id: String { DeviceKey.id(for: key) }
        var closes: Int { events.filter { if case .closed = $0 { return true }; return false }.count }
        init(_ name: String, _ mode: PeerMode, wired: WiredAddresses) {
            self.name = name; self.mode = mode
            link.loopbackOnly = true; link.wired = wired
            let local = LocalHello(name: name, model: "Test Mac", device: DeviceKey.id(for: key), mode: mode)
            link.local = { local }
            link.onEvent = { [unowned self] in self.events.append($0) }
            link.onMessage = { [unowned self] in self.messages.append($0) }
            link.onHello = { [unowned self] in self.hellos.append($0) }
            link.onReplaced = { [unowned self] in self.replaced += 1 }
            link.onDialResult = { [unowned self] _, reason in self.results.append(reason) }
        }
        func target(_ other: Node) -> DialTarget {
            DialTarget(id: other.id, key: other.key, host: "127.0.0.1", port: other.link.listeningPort ?? 0)
        }
    }
    func listening(_ nodes: Node...) throws {
        for node in nodes { try node.link.listen(key: node.key) }
        spin { nodes.allSatisfy { $0.link.listeningPort != nil } }
        guard nodes.allSatisfy({ $0.link.listeningPort != nil }) else { throw BridgeError("FAIL: loopback listeners did not start") }
    }
    // Every Mac's wired-address lookup takes a full second here, as it can
    // on a Mac with many interfaces. No handshake may wait for it.
    var lookedUpOnMain = false
    let wired = WiredAddresses {
        if Thread.isMainThread { lookedUpOnMain = true }
        Thread.sleep(forTimeInterval: 1)
        return ["192.0.2.7"]
    }
    let refreshStarted = Date()
    wired.refresh()
    try check(Date().timeIntervalSince(refreshStarted) < 0.2 && wired.current.isEmpty, "looking up the wired addresses never blocks the main thread")
    spin(5) { !wired.current.isEmpty }
    try check(wired.current == ["192.0.2.7"] && !lookedUpOnMain, "the wired addresses arrive from a background lookup")

    var everyone: [Node] = []
    defer { for node in everyone { node.link.closeAll("test complete") } }

    // A borrower dials its provider; both learn who the other is.
    let provider = Node("提供方 Mac", .provider, wired: wired), borrower = Node("使用方 Mac", .borrower, wired: wired)
    everyone += [provider, borrower]
    try listening(provider, borrower)
    let dialStarted = Date()
    borrower.link.setTarget(borrower.target(provider)); borrower.link.dial()
    spin { provider.link.handshaken && borrower.link.handshaken }
    try check(provider.link.handshaken && borrower.link.handshaken && borrower.link.peerDialedByUs && !provider.link.peerDialedByUs,
              "a borrower dials its provider over the encrypted handshake")
    try check(Date().timeIntervalSince(dialStarted) < 0.5 && provider.link.peerInfo?.hosts == ["192.0.2.7"] && borrower.link.wiredHosts == ["192.0.2.7"],
              "the handshake carries the wired addresses both ways without waiting for a lookup")
    try check(provider.link.peerInfo?.device == borrower.id && provider.link.peerInfo?.mode == .borrower &&
              provider.link.peerInfo?.name == "使用方 Mac" && provider.link.peerInfo?.supports(ProtocolFeature.peerKey) == true,
              "the provider learns the borrower's device ID, mode, name and features")
    try check(borrower.link.peerInfo?.device == provider.id && borrower.link.peerInfo?.name == "提供方 Mac" && borrower.results.last! == nil,
              "the borrower learns the same about the provider, and the dial is reported as working")
    try check(provider.events.contains(.handshakeOK) && borrower.events.contains(.handshakeOK) && provider.closes + borrower.closes == 0,
              "both report the link exactly as up")
    borrower.link.send(Message(kind: "peerKey", text: borrower.key.base64EncodedString()))
    spin { provider.messages.contains { $0.kind == "peerKey" } }
    try check(provider.messages.first { $0.kind == "peerKey" }?.text == borrower.key.base64EncodedString(), "post-handshake messages reach the other Mac")

    // A second borrower is told the provider is busy; the first link stays.
    let second = Node("第二台使用方", .borrower, wired: wired); everyone.append(second)
    try listening(second)
    second.link.setTarget(second.target(provider)); second.link.dial()
    spin { second.closes > 0 }
    try check(second.events.last == .closed(.busy) && provider.link.peerInfo?.device == borrower.id && provider.closes == 0,
              "a provider serves one borrower; another one is told it is busy")

    // Goodbye: the other Mac learns why before the link closes.
    provider.link.disconnect("test", bye: .paused)
    spin { borrower.closes > 0 }
    try check(borrower.messages.last?.kind == "bye" && borrower.messages.last?.text == "paused" && borrower.closes == 1 && provider.closes == 0,
              "a pausing Mac says goodbye with the reason, and only the other side reports the close")

    // While paused the listener stays up (the advert says paused) but turns links away.
    provider.link.acceptsConnections = { false }
    let before = borrower.closes
    // Forget the learned (fake) wired address, so this dial reaches the provider.
    borrower.link.setTarget(nil); borrower.link.setTarget(borrower.target(provider)); borrower.link.dial()
    spin { borrower.closes > before }
    try check(borrower.closes == before + 1 && !borrower.link.handshaken && borrower.events.last == .closed(.peerClosed),
              "a paused Mac turns links away")
    provider.link.acceptsConnections = { true }

    // Both Macs dial each other at once: both keep the link the borrower
    // dialed. Each round adds random latency to every frame (in order per
    // connection) and starts the dials together or at a random offset, so
    // the two handshakes interleave differently every time.
    // MICBRIDGE_DIAL_ROUNDS=500 runs a longer stress.
    let rounds = max(1, Int(ProcessInfo.processInfo.environment["MICBRIDGE_DIAL_ROUNDS"] ?? "") ?? 40)
    defer { Wire.testLatency = nil }
    for round in 1...rounds {
        let maxLatency = [0, 0.002, 0.01, 0.025][round % 4]
        Wire.testLatency = maxLatency == 0 ? nil : { Double.random(in: 0...maxLatency) }
        let p = Node("提供方 \(round)", .provider, wired: wired), b = Node("使用方 \(round)", .borrower, wired: wired)
        try listening(p, b)
        p.link.setTarget(p.target(b)); b.link.setTarget(b.target(p))
        let (first, other) = Bool.random() ? (p, b) : (b, p)
        let offset = round % 3 == 0 ? 0 : Double.random(in: 0...(maxLatency * 4 + 0.01))
        first.link.dial()
        if offset > 0 { settle(offset) }
        other.link.dial()
        spin { p.link.handshaken && b.link.handshaken && !p.link.isDialing && !b.link.isDialing }
        settle(0.15)
        // A link that was up before the other dial started is simply kept:
        // that dial never goes out.
        let bothDialed = [p, b].allSatisfy { $0.events.contains(.dialStarted) }
        let settled = p.link.handshaken && b.link.handshaken && b.link.peerDialedByUs != p.link.peerDialedByUs &&
            (b.link.peerDialedByUs || !bothDialed) && p.closes + b.closes == 0
        if !settled {
            print("  latency up to \(Int(maxLatency * 1000)) ms; \(first.name) dialed \(Int(offset * 1000)) ms before \(other.name)")
            for node in [p, b] {
                print("  \(node.name): handshaken \(node.link.handshaken), dialed by it \(node.link.peerDialedByUs), " +
                      "dialing \(node.link.isDialing), replaced \(node.replaced), events \(node.events), dial results \(node.results)")
            }
        }
        try check(settled, "simultaneous dials settle on one link, the borrower's, on both Macs, with no close reported (round \(round))")
        p.link.send(Message(kind: "ready"))
        spin { b.messages.contains { $0.kind == "ready" } }
        try check(b.messages.contains { $0.kind == "ready" }, "the surviving link carries messages (round \(round))")
        p.link.closeAll("round complete"); b.link.closeAll("round complete")
    }
    Wire.testLatency = nil

    // A 0.6.0 provider (no device ID, no features) still connects, and a second
    // copy of it supersedes the first, as 0.6.0 expects.
    let host = Node("新版使用方", .borrower, wired: wired); everyone.append(host)
    try listening(host)
    func legacyDial(_ received: @escaping (Message) -> Void) -> Wire {
        let wire = Wire(connection: NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: host.link.listeningPort!)!, using: .tcp), key: host.key)
        wire.onMessage = { m in
            if m.kind == "challenge" { try? wire.useChallenge(m.text); wire.send(Message(kind: "hello", text: m.text, clientVersion: "0.6.0")) }
            else { received(m) }
        }
        wire.start()
        return wire
    }
    var firstGot: [Message] = [], secondGot: [Message] = []
    let first = legacyDial { firstGot.append($0) }
    spin { firstGot.contains { $0.kind == "helloOK" } }
    try check(host.link.peerInfo?.device == nil && host.link.peerInfo?.version == "0.6.0" && host.link.peerInfo?.features.isEmpty == true,
              "a 0.6.0 provider connects without any 0.7.1 fields")
    let next = legacyDial { secondGot.append($0) }
    spin { secondGot.contains { $0.kind == "helloOK" } && firstGot.contains { $0.kind == "superseded" } }
    try check(firstGot.contains { $0.kind == "superseded" } && secondGot.contains { $0.kind == "helloOK" } && host.replaced == 1,
              "a reconnecting 0.6.0 provider replaces its stale link as before")
    for wire in [first, next] { wire.onMessage = nil; wire.onClose = nil; wire.close(.local("test complete")) }

    print("\(count) two-instance link checks passed. Loopback only; no Bonjour, keychain or audio.")
}
