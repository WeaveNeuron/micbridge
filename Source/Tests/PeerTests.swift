import Foundation
import Network

/// 0.7.1 peer-to-peer pieces that need no network: device identity, the TXT
/// presence advert and protocol compatibility with 0.6.0 / 0.7.0.
func runPeerTests() throws {
    var count = 0
    func check(_ condition: Bool, _ description: String) throws {
        guard condition else { throw BridgeError("FAIL: \(description)") }
        count += 1; print("PASS: \(description)")
    }

    // Device identity: the key fingerprint, shared with the Bonjour name.
    let key = Keys.generate()
    let id = DeviceKey.id(for: key)
    try check(id.count == 20 && BridgeDiscovery.serviceName(for: key) == "MicBridge-" + id && DeviceKey.id(fromServiceName: "MicBridge-" + id) == id,
              "a Mac's device ID is the fingerprint already in its 0.6.0 service name")
    try check(DeviceKey.id(fromServiceName: "MacBook") == nil && DeviceKey.id(fromServiceName: "MicBridge-xyz") == nil,
              "foreign service names are not mistaken for devices")

    // TXT presence advert.
    let advert = PresenceAdvert(mode: .borrower, version: "0.7.1", name: "Studio", model: "Mac Studio (M5 Ultra)", busy: true)
    try check(PresenceAdvert(txt: advert.txt) == advert && advert.txt["b"] == "1", "the presence advert round-trips through TXT")
    try check(PresenceAdvert(txt: PresenceAdvert(mode: .provider, version: "0.7.1", name: "a", model: "").txt)?.busy == false,
              "an idle Mac advertises no busy flag")
    try check(PresenceAdvert(txt: [:]) == nil && PresenceAdvert(txt: ["m": "dj", "v": "1"]) == nil, "a service without a known mode reads as an older MicBridge")
    let long = String(repeating: "工作室", count: 60)
    let clipped = PresenceAdvert.clip(long)
    try check(clipped.utf8.count <= 120 && long.hasPrefix(clipped) && !clipped.isEmpty, "long names are cut on a character boundary within the TXT limit")
    try check(!advert.txt.values.contains(where: { $0.contains(key.base64EncodedString()) }) && advert.txt.keys.sorted() == ["b", "h", "m", "n", "v"],
              "the advert carries only mode, version, name, model and busy")
    try check(PeerMode(role: .borrower, enabled: false) == .paused && PeerMode(role: .provider, enabled: true) == .provider, "a paused Mac advertises paused, whatever its role")

    // Protocol compatibility.
    let legacyHello = Data(#"{"version":2,"id":"x","date":0,"kind":"hello","session":"","text":"c","clientVersion":"0.6.0"}"#.utf8)
    let legacy = try JSONDecoder().decode(Message.self, from: legacyHello)
    try check(legacy.device == nil && legacy.features == nil && legacy.mode == nil, "a 0.6.0 hello decodes with no 0.7.1 fields")
    let plain = String(decoding: try JSONEncoder().encode(Message(kind: "pcm")), as: UTF8.self)
    try check(!plain.contains("device") && !plain.contains("features") && !plain.contains("\"mode\""), "audio frames carry no new keys")
    let hello = try JSONDecoder().decode(Message.self, from: JSONEncoder().encode(
        Message(kind: "hello", device: id, mode: "borrower", features: ProtocolFeature.all)))
    try check(hello.device == id && hello.mode == "borrower" && hello.features == ProtocolFeature.all && hello.version == 2,
              "0.7.1 hello carries device, mode and features on wire version 2")
    let card = Pairing(host: "studio.local", key: key.base64EncodedString(), name: "Studio", model: "Mac Studio")
    let parsed = try Pairing.parse(card.encoded)
    try check(parsed.name == "Studio" && parsed.model == "Mac Studio", "a pairing card carries the Mac's own name")
    let oldCard = "micbridge://" + Data(#"{"version":2,"host":"old.local","key":"\#(key.base64EncodedString())"}"#.utf8).base64EncodedString()
    try check((try Pairing.parse(oldCard)).name == nil, "a 0.7.0 pairing card without a name still parses")

    // Presence: TXT, goodbyes and dial results, in that order of trust.
    var presence = PeerPresence()
    try check(presence.availability == .unknown, "nothing is claimed about a Mac never seen")
    presence.dialed(.refused)
    try check(presence.availability == .appClosed, "a refused dial means the Mac is awake but MicBridge is not running")
    presence.dialed(.timeout)
    try check(presence.availability == .unreachable, "a dial timeout means asleep, off or elsewhere")
    presence.seen(PresenceAdvert(mode: .provider, version: "0.7.1", name: "a", model: ""))
    try check(presence.availability == .online(.provider) && presence.lastDial == nil, "seeing its advert replaces the guess")
    presence.seen(PresenceAdvert(mode: .paused, version: "0.7.1", name: "a", model: ""))
    try check(presence.availability == .paused, "a paused Mac says so in its advert")
    presence.said(.sleep); presence.vanished()
    try check(presence.availability == .asleep, "a Mac that said it is going to sleep is shown asleep")
    presence.said(.quit)
    try check(presence.availability == .appClosed, "a Mac whose MicBridge quit is shown so")
    presence.seen(nil)
    try check(presence.availability == .online(.borrower) && presence.bye == nil, "an older MicBridge seen without TXT is a listening borrower")
    presence.linked(true)
    try check(presence.availability == .connected, "connected wins over everything")

    // Who dials whom.
    let p1 = PairedDevice(id: "p1", mode: .provider, lastConnected: Date()), p2 = PairedDevice(id: "p2", mode: .provider)
    func seen(_ mode: PeerMode, busy: Bool = false) -> PeerPresence {
        var p = PeerPresence(); p.seen(PresenceAdvert(mode: mode, version: "0.7.1", name: "", model: "", busy: busy)); return p
    }
    try check(DialPlanner.target(role: .borrower, devices: [p1, p2], keys: ["p1", "p2"], presence: ["p1": seen(.provider), "p2": seen(.provider)], preferred: "p2", idleFor: 0) == "p2",
              "a borrower dials the provider it chose")
    try check(DialPlanner.target(role: .borrower, devices: [p1, p2], keys: ["p1", "p2"], presence: ["p1": seen(.provider, busy: true), "p2": seen(.paused)], preferred: nil, idleFor: 0) == nil,
              "a borrower does not dial a busy or paused provider")
    try check(DialPlanner.target(role: .borrower, devices: [p1], keys: ["p1"], presence: ["p1": seen(.provider, busy: true)], preferred: "p1", idleFor: 0) == "p1",
              "a borrower redials its own provider even while a stale link makes it look busy")
    try check(DialPlanner.target(role: .borrower, devices: [p1], keys: [], presence: ["p1": seen(.provider)], preferred: nil, idleFor: 0) == nil,
              "a borrower without the provider's key waits for it to dial")
    let b1 = PairedDevice(id: "b1", host: "b1.local", mode: .borrower, hasOurKey: true)
    try check(DialPlanner.target(role: .provider, devices: [b1], keys: ["b1"], presence: ["b1": seen(.borrower)], preferred: nil, idleFor: 3) == nil &&
              DialPlanner.target(role: .provider, devices: [b1], keys: ["b1"], presence: ["b1": seen(.borrower)], preferred: nil, idleFor: 10) == "b1",
              "a provider lets a 0.7.1 borrower dial first, then dials as a fallback")
    var fresh = b1; fresh.hasOurKey = false
    try check(DialPlanner.target(role: .provider, devices: [fresh], keys: ["b1"], presence: ["b1": seen(.borrower)], preferred: nil, idleFor: 0) == "b1",
              "a provider dials at once a borrower that does not have its key yet")
    var legacySeen = PeerPresence(); legacySeen.seen(nil)
    try check(DialPlanner.target(role: .provider, devices: [b1], keys: ["b1"], presence: ["b1": legacySeen], preferred: nil, idleFor: 0) == "b1" &&
              DialPlanner.target(role: .provider, devices: [b1], keys: ["b1"], presence: [:], preferred: nil, idleFor: 0) == "b1",
              "a provider dials 0.6.0 / 0.7.0 borrowers and unseen borrowers by address, as before")
    try check(DialPlanner.target(role: .provider, devices: [b1], keys: ["b1"], presence: ["b1": seen(.provider)], preferred: nil, idleFor: 99) == nil,
              "nobody dials a Mac in the same role")

    // Duplicate links: both Macs keep the same one.
    let keepAtBorrower = LinkArbiter.keepsIncoming(localID: "aa", localMode: .borrower, remoteID: "bb", remoteMode: .provider)
    let keepAtProvider = LinkArbiter.keepsIncoming(localID: "bb", localMode: .provider, remoteID: "aa", remoteMode: .borrower)
    try check(!keepAtBorrower && keepAtProvider, "of two links, both Macs keep the one the borrower dialed")
    try check(LinkArbiter.keepsIncoming(localID: "bb", localMode: .provider, remoteID: "aa", remoteMode: .provider) !=
              LinkArbiter.keepsIncoming(localID: "aa", localMode: .provider, remoteID: "bb", remoteMode: .provider),
              "without a borrower the smaller device ID decides, consistently")

    // The machine dials only with a target, in either role.
    var machine = ConnectionState(role: .borrower)
    _ = machine.reduce(.start, now: 0)
    try check(machine.reduce(.tick, now: 1).isEmpty, "a Mac with nobody to dial only listens")
    try check(machine.reduce(.dialTarget(true), now: 1) == [.redial] && machine.reduce(.dialTarget(true), now: 1).isEmpty,
              "a borrower dials as soon as its provider appears, once")
    _ = machine.reduce(.dialStarted, now: 1)
    _ = machine.reduce(.closed(.refused), now: 2)
    try check(machine.reduce(.tick, now: 2.5).isEmpty && machine.reduce(.tick, now: 3.1) == [.dial], "a failed dial is retried with backoff")
    _ = machine.reduce(.dialStarted, now: 3.1); _ = machine.reduce(.dialCancelled, now: 3.2)
    try check(machine.link == .idle && machine.failures == 1 && machine.reduce(.tick, now: 3.3) == [.dial],
              "a dial dropped for a new target is neither stuck nor counted as a failure")
    _ = machine.reduce(.dialTarget(false), now: 4)
    _ = machine.reduce(.closed(.connectTimeout), now: 4)
    try check(machine.reduce(.tick, now: 30).isEmpty, "no target, no dialing")
    _ = machine.reduce(.listenerFailed, now: 5)
    try check(machine.reduce(.tick, now: 7.1) == [.startListener], "every role restarts a failed listener")

    // Status: presence explains why there is no link.
    func status(_ peer: PeerAvailability, role: Role = .borrower) -> BridgeStatus {
        var c = ConnectionState(role: role); _ = c.reduce(.start, now: 0)
        return BridgeStatus.derive(StatusInputs(connection: c, peer: peer))
    }
    try check(status(.appClosed) == .peerAppClosed && status(.paused) == .peerPaused && status(.asleep) == .peerAsleep && status(.busy) == .peerBusy,
              "the panel says whether the other Mac is closed, paused, asleep or busy")
    try check(status(.online(.borrower)) == .roleConflict && status(.online(.provider), role: .provider) == .roleConflict &&
              status(.online(.provider)) == .searching(longWait: false),
              "two Macs in the same role are told apart from a Mac that is just not linked yet")
    var ready = ConnectionState(role: .provider); _ = ready.reduce(.start, now: 0); _ = ready.reduce(.handshakeOK, now: 1)
    try check(BridgeStatus.derive(StatusInputs(connection: ready, peer: .paused)) == .ready, "a stale guess never hides a working link")
    let copy = CopyContext(role: .borrower, peer: "MacBook")
    try check(StatusCopy.title(.peerAppClosed, copy) == "MacBook 上未打开 MicBridge" && StatusCopy.title(.roleConflict, copy).contains("没有在提供"),
              "presence titles name the other Mac")
    try check(StatusCopy.subtitle(.peerBusy, copy).contains("提供麦克风") && StatusCopy.subtitle(.peerBusy, CopyContext(role: .provider, peer: "x")).contains("使用另一台"),
              "a busy Mac is explained from this Mac's role")

    // Upgrading a 0.7.0 pair to 0.7.1, seen from each Mac's store.
    let suite = "MicBridgeSelfTest-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(Data(#"{"name":"MacBook","model":"MacBook Pro"}"#.utf8), forKey: PeerStore.legacyRecordKey(.borrower))
    let studio = PeerStore(defaults: defaults)
    let oldHello = PeerHello(name: "MacBook", version: "0.7.0.1")
    try check(studio.recordID(for: oldHello, dialed: nil) == PairedDevice.legacyProviderID, "a 0.7.0 provider dialing in maps to the migrated record")
    let laptopID = DeviceKey.id(for: Keys.generate())
    let newHello = PeerHello(name: "MacBook", model: "MacBook Pro", version: "0.7.1", device: laptopID, mode: .provider, features: Set(ProtocolFeature.all))
    let mapped = studio.recordID(for: newHello, dialed: nil)
    studio.noteLink(mapped, hello: newHello, theyDialed: true, localRole: .borrower)
    try check(mapped == laptopID && studio.device(PairedDevice.legacyProviderID) == nil && studio.device(laptopID)?.hasOurKey == true &&
              studio.device(laptopID)?.mode == .provider && studio.devices.count == 1,
              "after the upgrade the same provider takes its device ID; no duplicate record")
    let otherBorrower = PeerHello(version: "0.7.1", device: DeviceKey.id(for: Keys.generate()), mode: .borrower)
    try check(studio.recordID(for: otherBorrower, dialed: nil) == otherBorrower.device, "a different Mac gets its own record")
    let dialedID = DeviceKey.id(for: Keys.generate())
    try check(studio.recordID(for: PeerHello(version: "0.6.0"), dialed: dialedID) == dialedID, "a Mac this one dialed is recorded under the key it was dialed with")
    studio.noteLink(dialedID, hello: PeerHello(name: "Studio", version: "0.6.0", hosts: ["192.168.1.9"]), theyDialed: false, localRole: .provider)
    try check(studio.device(dialedID)?.name == "Studio" && studio.device(dialedID)?.hasOurKey == false && studio.device(dialedID)?.mode == .borrower,
              "a Mac dialed here is not assumed to hold this Mac's key")

    print("\(count) peer identity, presence and compatibility checks passed.")
}
