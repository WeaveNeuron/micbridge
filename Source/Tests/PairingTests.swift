import Foundation
import Network

/// Nearby pairing over real loopback TCP (127.0.0.1 only: no Bonjour, no
/// firewall prompt, no keychain), through the same server and client classes
/// the app uses. The Mac that clicks Add is the client; the Mac that checks
/// the six digits and clicks Allow is the server.
func runPairingTests() throws {
    var count = 0
    func check(_ condition: Bool, _ description: String) throws {
        guard condition else { throw BridgeError("FAIL: \(description)") }
        count += 1; print("PASS: \(description)")
    }

    // Choosing the service: by device ID, never by a shared name.
    let idA = String(repeating: "a", count: 20), idB = String(repeating: "b", count: 20)
    let twins = [PairingTarget.Candidate(name: "Studio", device: idA), PairingTarget.Candidate(name: "Studio (2)", device: idB)]
    try check(PairingTarget.pick(twins, device: idB, name: "Studio") == 1, "of two Macs named alike, the one with the picked device ID is asked")
    try check(PairingTarget.pick([.init(name: "Studio", device: idA)], device: idB, name: "Studio") == nil,
              "a same-name Mac that says it is someone else is never asked")
    try check(PairingTarget.pick([.init(name: "MacBook", device: nil), .init(name: "Studio", device: nil)], device: idB, name: "Studio") == 1,
              "an older pairing service without TXT is found by its exact name")
    try check(PairingTarget.pick([.init(name: "Studio (2)", device: nil)], device: idB, name: "Studio") == nil, "no match, no request")
    try check(DeviceKey.isID(idA) && !DeviceKey.isID("Studio") && !DeviceKey.isID(idA + "0"), "device IDs are 20 hex digits")
    let frame = try JSONEncoder().encode(PairFrame(kind: "request", pub: Data([1]), name: "MacBook"))
    let text = String(decoding: frame, as: UTF8.self)
    try check(!text.contains("\"to\"") && !text.contains("\"id\"") && !text.contains("\"model\""), "a request without the new fields encodes as 0.8.0 sent it")
    let old = try JSONDecoder().decode(PairFrame.self, from: Data(#"{"v":"micbridge-pair-2","kind":"offer","name":"Studio"}"#.utf8))
    try check(old.id == nil && old.to == nil && old.v == PairFrame.version, "a frame without the optional fields decodes")

    let studio = Keys.generate(), macBook = Keys.generate(), twin = Keys.generate()
    let studioID = DeviceKey.id(for: studio), macBookID = DeviceKey.id(for: macBook), twinID = DeviceKey.id(for: twin)
    let studioCard = Pairing(host: "studio.local", key: studio.base64EncodedString(), name: "Studio", model: "Mac Studio")
    let twinCard = Pairing(host: "studio-2.local", key: twin.base64EncodedString(), name: "Studio", model: "Mac Studio")
    let macBookCard = Pairing(host: "macbook.local", key: macBook.base64EncodedString(), name: "MacBook", model: "MacBook Air")

    // 1. Approved: same six digits on both Macs, cards cross both ways.
    var r = try pairOnce(server: .init(card: studioCard, id: studioID), client: .init(cards: [macBookCard], target: studioID))
    try check(r.failure == nil && r.received?.key == studioCard.key && r.received?.name == "Studio" && r.serverCode.count == 6 && r.serverCode == r.clientCode,
              "approved pairing delivers the other Mac's card and both show the same code")
    try check(r.returned?.key == macBookCard.key, "the asking Mac's own card goes back, so either Mac can dial")
    try check(r.request?.name == "MacBook" && r.request?.model == "MacBook Air" && r.request?.device == macBookID,
              "the approving Mac sees the asking Mac's name, model and device ID")

    // 2. Declined: nothing either way, and a cooldown follows.
    r = try pairOnce(server: .init(card: studioCard, id: studioID, approve: false), client: .init(cards: [macBookCard], target: studioID), followUp: true)
    try check(r.received == nil && r.returned == nil && r.failure != nil && !r.serverPending, "a declined pairing delivers nothing either way")
    try check(r.followUpRequests == 0 && r.followUpFailed, "asking again right after a decline is turned away")

    // 3. Same name, other device ID: the server says so, nobody is asked.
    r = try pairOnce(server: .init(card: twinCard, id: twinID), client: .init(cards: [macBookCard], target: studioID))
    try check(r.request == nil && r.received == nil && r.returned == nil && r.failure == PairingTarget.wrongMac(),
              "a request meant for another Mac of the same name is refused without asking anyone")

    // 4. Same name, older server (no ID in the offer): the key check stops it.
    r = try pairOnce(server: .init(card: twinCard, id: ""), client: .init(cards: [macBookCard], target: studioID))
    try check(r.request != nil && r.received == nil && r.failure == PairingTarget.wrongMac(),
              "a card from the wrong Mac is rejected by its key fingerprint, even from an older server")

    // 5. An older client (no to / id / model, no card back) still pairs.
    r = try pairOnce(server: .init(card: studioCard, id: studioID), client: .init(cards: [], target: nil))
    try check(r.received?.key == studioCard.key && r.returned == nil && r.request?.device == nil && r.request?.name == localComputerName(),
              "a 0.8.0-style request still pairs")

    // 6. The returned card must be the key of the Mac that asked.
    r = try pairOnce(server: .init(card: studioCard, id: studioID), client: .init(cards: [macBookCard, twinCard], target: studioID))
    try check(r.received?.key == studioCard.key && r.returned == nil, "a returned card that is not the asking Mac's key is dropped")

    // 7. One request at a time; 8. a cancelled request clears on both Macs.
    try check(try secondClientRefused(studioCard, studioID), "while one request waits, a second Mac is turned away")
    try check(try cancelClears(studioCard, studioID), "cancelling on the asking Mac clears the request on the other")

    print("\(count) pairing checks passed. Loopback only; no Bonjour or keychain.")
}

private struct ServerSide {
    var card: Pairing
    var id: String
    var approve = true
}
private struct ClientSide {
    /// Successive answers of the client's payload (the second, if any, is
    /// the card sent back after approval). Empty: an older client.
    var cards: [Pairing]
    var target: String?
}
private struct PairOutcome {
    var request: PairRequest?
    var serverCode = "", clientCode = ""
    var received: Pairing?, returned: Pairing?
    var failure: String?
    var serverPending = false
    var followUpRequests = 0
    var followUpFailed = false
}

private func spin(until done: () -> Bool, seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while !done() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
}

private func pairOnce(server s: ServerSide, client c: ClientSide, followUp: Bool = false) throws -> PairOutcome {
    let server = NearbyPairingServer(), client = NearbyPairingClient()
    var out = PairOutcome()
    var finished = false
    server.deviceID = { s.id }
    server.payload = { s.card }
    server.onPairedBack = { out.returned = $0 }
    server.onRequest = { request in
        out.request = request; out.serverCode = request.code
        if s.approve { try? server.approve() } else { server.reject() }
    }
    var calls = 0
    if !c.cards.isEmpty {
        client.payload = { defer { calls += 1 }; return c.cards[min(calls, c.cards.count - 1)] }
    }
    client.onStatus = { _, code, _ in if !code.isEmpty { out.clientCode = code } }
    client.onFailed = { out.failure = $0; finished = true }
    client.onPaired = { out.received = $0; finished = true }
    var port: NWEndpoint.Port?
    try server.start(loopbackOnly: true) { p in port = p; client.connect(to: .hostPort(host: "127.0.0.1", port: p), peer: "Studio", deviceID: c.target) }
    defer { client.stop(); server.stop(); server.onRequest = nil; server.payload = nil; server.onPairedBack = nil }
    spin(until: { finished }, seconds: 5)
    // The card going back arrives a moment after.
    if out.received != nil, !c.cards.isEmpty { spin(until: { out.returned != nil }, seconds: c.cards.count > 1 ? 1 : 3) }
    out.serverPending = server.hasRequest
    if followUp, let port {
        let again = NearbyPairingClient()
        var done = false
        again.onFailed = { _ in done = true }
        again.onPaired = { _ in done = true }
        let before = out.request
        out.request = nil
        again.connect(to: .hostPort(host: "127.0.0.1", port: port), peer: "Studio", deviceID: c.target)
        spin(until: { done }, seconds: 3)
        out.followUpRequests = out.request == nil ? 0 : 1
        out.followUpFailed = done
        out.request = before
        again.stop()
    }
    return out
}

private func secondClientRefused(_ card: Pairing, _ id: String) throws -> Bool {
    let server = NearbyPairingServer(), first = NearbyPairingClient(), second = NearbyPairingClient()
    server.deviceID = { id }; server.payload = { card }
    var requests = 0, secondFailed = false
    server.onRequest = { _ in requests += 1 }
    second.onFailed = { _ in secondFailed = true }
    try server.start(loopbackOnly: true) { p in
        first.connect(to: .hostPort(host: "127.0.0.1", port: p), peer: "Studio", deviceID: id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { second.connect(to: .hostPort(host: "127.0.0.1", port: p), peer: "Studio", deviceID: id) }
    }
    defer { first.stop(); second.stop(); server.stop(); server.onRequest = nil; server.payload = nil }
    spin(until: { secondFailed }, seconds: 5)
    return secondFailed && requests == 1 && server.hasRequest
}

private func cancelClears(_ card: Pairing, _ id: String) throws -> Bool {
    let server = NearbyPairingServer(), client = NearbyPairingClient()
    server.deviceID = { id }; server.payload = { card }
    var asked = false, cancelled = false
    server.onRequest = { _ in asked = true }
    server.onCancelled = { cancelled = true }
    try server.start(loopbackOnly: true) { p in client.connect(to: .hostPort(host: "127.0.0.1", port: p), peer: "Studio", deviceID: id) }
    defer { client.stop(); server.stop(); server.onRequest = nil; server.onCancelled = nil; server.payload = nil }
    spin(until: { asked }, seconds: 5)
    client.stop()
    spin(until: { cancelled }, seconds: 5)
    return asked && cancelled && !server.hasRequest
}
