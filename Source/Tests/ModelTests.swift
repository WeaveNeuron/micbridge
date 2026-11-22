import Foundation

/// Pure-logic checks for roles, the connection state machine, status
/// derivation, route planning and protocol compatibility. No audio, network,
/// keychain or user defaults outside a throwaway suite.
func runModelTests() throws {
    var count = 0
    func check(_ condition: Bool, _ description: String) throws {
        guard condition else { throw BridgeError("FAIL: \(description)") }
        count += 1; print("PASS: \(description)")
    }

    // Roles: user's choice, migrated from 0.6.0's Int setting.
    let suiteName = "MicBridgeSelfTest-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    try check(Role.saved(in: defaults) == nil, "no role is assumed before the user or 0.6.0 chose one")
    defaults.set(1, forKey: Role.legacyDefaultsKey)
    try check(Role.saved(in: defaults) == .borrower, "0.6.0 role 1 migrates to borrower")
    defaults.set(0, forKey: Role.legacyDefaultsKey)
    try check(Role.saved(in: defaults) == .provider, "0.6.0 role 0 migrates to provider")
    Role.save(.borrower, in: defaults)
    try check(Role.saved(in: defaults) == .borrower && defaults.object(forKey: Role.legacyDefaultsKey) != nil,
              "a new choice wins over the 0.6.0 value, which stays for downgrades")
    try check(Role.suggested(hasBuiltInMicrophone: false) == .borrower && Role.suggested(hasBuiltInMicrophone: true) == .provider,
              "first-use suggestion follows the microphone, not the model name")

    // Paired devices: 0.6.0 and 0.7.0 records carry over.
    defaults.set("old-mac.local", forKey: PeerStore.legacyHostKey)
    defaults.set(["192.168.1.9"], forKey: PeerStore.legacyWiredKey)
    let store = PeerStore(defaults: defaults)
    let migrated = store.device(PairedDevice.legacyBorrowerID)
    try check(migrated?.host == "old-mac.local" && migrated?.wiredHosts == ["192.168.1.9"] && migrated?.mode == .borrower,
              "the provider keeps the 0.6.0 pairing host and wired addresses")
    try check(migrated?.displayName == "old mac", "a Mac that never reported a name is shown by its host name")
    let realID = DeviceKey.id(for: Keys.generate())
    store.reconcile(keyIDs: [realID])
    try check(store.device(PairedDevice.legacyBorrowerID) == nil && store.device(realID)?.host == "old-mac.local",
              "the migrated record takes the ID of the key read from the keychain")
    store.update(realID) { $0.name = "Studio" }
    try check(store.device(realID)?.displayName == "Studio", "a Mac's own computer name wins over its .local host name")
    store.update(realID) { $0.alias = "录音机" }
    try check(store.device(realID)?.displayName == "录音机" && PeerStore(defaults: defaults).device(realID)?.alias == "录音机",
              "a local alias wins and is saved")
    try check(PairedDevice(id: "x").displayName == PairedDevice.fallbackName, "an unknown peer has a neutral name")
    let v7Suite = "MicBridgeSelfTest-\(UUID().uuidString)"
    let v7 = UserDefaults(suiteName: v7Suite)!
    defer { v7.removePersistentDomain(forName: v7Suite) }
    v7.set(Data(#"{"name":"工作室","host":"studio.local","wiredHosts":["10.0.0.2"]}"#.utf8), forKey: PeerStore.legacyRecordKey(.provider))
    v7.set(Data(#"{"name":"MacBook","model":"MacBook Pro"}"#.utf8), forKey: PeerStore.legacyRecordKey(.borrower))
    let fromV7 = PeerStore(defaults: v7)
    try check(fromV7.device(PairedDevice.legacyBorrowerID)?.name == "工作室" && fromV7.device(PairedDevice.legacyProviderID)?.name == "MacBook",
              "0.7.0 records for both roles become paired devices")
    let providerID = DeviceKey.id(for: Keys.generate())
    fromV7.merge(PairedDevice.legacyProviderID, into: providerID)
    try check(fromV7.device(providerID)?.name == "MacBook" && fromV7.device(PairedDevice.legacyProviderID) == nil,
              "a provider that dialed before 0.7.1 is recognised once it reports its device ID")

    // Device kind is only for icons and never decides behaviour.
    try check(DeviceKind(model: "MacBook Pro (14-inch, 2021)") == .laptop && DeviceKind(model: "MacBookAir10,1") == .laptop,
              "laptops are recognised from marketing name or identifier")
    try check(DeviceKind(model: "Mac Studio (2023)") == .studio && DeviceKind(model: "Macmini9,1") == .mini && DeviceKind(model: "Mac14,13") == .generic,
              "desktops are recognised; unknown identifiers fall back to a generic icon")

    // Route planner: wired first, rotation, failure cool-down, upgrade limit.
    var routes = RoutePlanner(wiredHosts: ["10.0.0.2"])
    try check(routes.next(discovered: true, savedHost: "b.local", now: 0) == .wired("10.0.0.2"), "the wired address is tried first")
    try check(routes.next(discovered: true, savedHost: "b.local", now: 0) == .discovered, "then the nearby service")
    try check(routes.next(discovered: true, savedHost: "b.local", now: 0) == .saved("b.local"), "then the saved host name")
    routes.failed(.wired("10.0.0.2"), now: 0)
    try check(routes.candidates(discovered: false, savedHost: "b.local", now: 30) == [.saved("b.local")] &&
              routes.candidates(discovered: false, savedHost: "b.local", now: 61).first == .wired("10.0.0.2"),
              "a failed wired address is skipped for a minute")
    try check(Route.wired("x").timeout == 2 && Route.discovered.timeout == 6, "a dead LAN address is abandoned after 2 s")
    try check(routes.shouldUpgrade(remoteHost: "192.168.1.5", now: 700) && !routes.shouldUpgrade(remoteHost: "192.168.1.5", now: 800),
              "an idle Wi-Fi link moves to the wire at most once per 10 minutes")
    try check(!routes.shouldUpgrade(remoteHost: "10.0.0.2", now: 2000), "a link already on the wire is left alone")

    // Connection state machine.
    var provider = ConnectionState(role: .provider)
    _ = provider.reduce(.start, now: 0); _ = provider.reduce(.dialTarget(true), now: 0)
    try check(provider.isActive && provider.reduce(.tick, now: 0) == [.dial], "an idle Mac with a target dials")
    _ = provider.reduce(.dialStarted, now: 0)
    try check(provider.reduce(.tick, now: 1) == [], "no second dial while one is in flight")
    _ = provider.reduce(.closed(.refused), now: 1)
    try check(provider.link == .idle && provider.failures == 1 && provider.reduce(.tick, now: 1.5) == [] && provider.reduce(.tick, now: 2) == [.dial],
              "a failed attempt backs off before dialing again")
    _ = provider.reduce(.dialStarted, now: 2); _ = provider.reduce(.closed(.connectTimeout), now: 4)
    _ = provider.reduce(.dialStarted, now: 8)
    try check(provider.reduce(.closed(.connectTimeout), now: 10) == [.restartDiscovery], "every third failure restarts discovery")
    try check(provider.retryDelay == 10 || provider.retryDelay == 8, "back-off grows towards 10 s")
    _ = provider.reduce(.peerVisible(true), now: 11)
    try check(provider.localNetworkIssue, "visible but unreachable three times reads as a Local Network block")
    var visible = ConnectionState(role: .provider); _ = visible.reduce(.start, now: 0); _ = visible.reduce(.dialTarget(true), now: 0)
    try check(visible.reduce(.peerVisible(true), now: 0) == [.redial], "the other Mac appearing triggers an immediate fresh dial")
    _ = visible.reduce(.dialStarted, now: 0); _ = visible.reduce(.handshakeOK, now: 0)
    try check(visible.isReady && visible.failures == 0 && visible.reduce(.peerVisible(true), now: 1) == [],
              "a connected provider is ready at once and ignores rediscovery")
    _ = visible.reduce(.closed(.heartbeat), now: 2)
    try check(visible.failures == 0 && visible.link == .idle && !visible.isReady, "losing a working link is not counted as a failed attempt")
    var denied = ConnectionState(role: .provider); _ = denied.reduce(.start, now: 0); _ = denied.reduce(.dialTarget(true), now: 0)
    _ = denied.reduce(.dialStarted, now: 0); _ = denied.reduce(.closed(.localNetworkDenied), now: 0)
    try check(denied.localNetworkIssue, "an explicit privacy denial is reported at once")
    _ = denied.reduce(.dialStarted, now: 5); _ = denied.reduce(.handshakeOK, now: 5)
    try check(!denied.localNetworkIssue, "granting Local Network access recovers without a restart")
    var rerouted = visible; _ = rerouted.reduce(.dialStarted, now: 3); _ = rerouted.reduce(.handshakeOK, now: 3)
    try check(rerouted.reduce(.rerouting, now: 4) == [.dial] && rerouted.link == .idle, "a route switch dials again immediately")
    var borrower = ConnectionState(role: .borrower); _ = borrower.reduce(.start, now: 0)
    try check(borrower.reduce(.tick, now: 100) == [], "a borrower without a target only listens")
    _ = borrower.reduce(.handshakeOK, now: 1)
    try check(borrower.isConnected && !borrower.isReady, "a borrower waits for the provider's ready")
    _ = borrower.reduce(.peerReady, now: 1)
    try check(borrower.isReady, "ready makes the provider available")
    _ = borrower.reduce(.listenerFailed, now: 5)
    try check(borrower.reduce(.tick, now: 6) == [] && borrower.reduce(.tick, now: 7) == [.startListener] && borrower.reduce(.tick, now: 8) == [],
              "a failed listener is retried with a pause")
    var paused = borrower; _ = paused.reduce(.pause, now: 9)
    try check(paused.lifecycle == .paused && !paused.isConnected && paused.reduce(.tick, now: 20) == [], "pausing stops everything")
    var asleep = provider; _ = asleep.reduce(.suspend, now: 9)
    try check(asleep.lifecycle == .suspended && asleep.failures == 0 && asleep.reduce(.tick, now: 20) == [], "sleep stops dialing and clears failures")

    // Status: one derivation, fixed priority.
    var inputs = StatusInputs(connection: ConnectionState(role: .provider))
    try check(BridgeStatus.derive(inputs) == .paused, "a stopped bridge reads as paused")
    inputs.stopReason = .setup(.microphoneDenied)
    try check(BridgeStatus.derive(inputs) == .setup(.microphoneDenied), "a setup problem outranks paused")
    inputs.incomingPairing = (peer: "A", code: "123456")
    try check(BridgeStatus.derive(inputs) == .incomingPairing(peer: "A", code: "123456"), "a pairing request outranks everything awake")
    inputs.connection.lifecycle = .suspended
    try check(BridgeStatus.derive(inputs) == .sleeping, "sleep outranks everything")
    inputs = StatusInputs(connection: visible)
    try check(BridgeStatus.derive(inputs) == .searching(longWait: false), "a provider that lost its link searches")
    inputs.connection = rerouted; _ = inputs.connection.reduce(.dialStarted, now: 5)
    try check(BridgeStatus.derive(inputs) == .connecting, "a first attempt reads as connecting")
    inputs.connection = provider
    try check(BridgeStatus.derive(inputs) == .localNetworkBlocked, "a Local Network block is named")
    var busy = ConnectionState(role: .provider); _ = busy.reduce(.start, now: 0); _ = busy.reduce(.dialStarted, now: 0); _ = busy.reduce(.closed(.busy), now: 0)
    try check(BridgeStatus.derive(StatusInputs(connection: busy)) == .peerBusy, "a busy peer is named, not reported as a failure")
    var ready = StatusInputs(connection: borrower)
    try check(BridgeStatus.derive(ready) == .ready, "a ready link reads as ready")
    ready.captureRequested = true
    try check(BridgeStatus.derive(ready) == .inUse(.activating), "a requested recording reads as activating")
    ready.micActive = true
    try check(BridgeStatus.derive(ready) == .inUse(.live), "a running remote microphone reads as in use")
    ready.captureFinishing = true
    try check(BridgeStatus.derive(ready) == .inUse(.finishing), "a stopping recording reads as finishing")
    var waitingProvider = ConnectionState(role: .provider); _ = waitingProvider.reduce(.start, now: 0); _ = waitingProvider.reduce(.dialTarget(true), now: 0)
    for t in 0..<3 { _ = waitingProvider.reduce(.dialStarted, now: Double(t)); _ = waitingProvider.reduce(.closed(.connectTimeout), now: Double(t)) }
    try check(BridgeStatus.derive(StatusInputs(connection: waitingProvider)) == .searching(longWait: true), "repeated failures say so")

    // Debounce: ready survives a blip; in-use is always truthful.
    var debounce = StatusDebouncer()
    _ = debounce.update(.ready, now: 0)
    try check(debounce.update(.connecting, now: 1) == .ready && debounce.update(.connecting, now: 3.9) == .ready && debounce.update(.connecting, now: 4.1) == .connecting,
              "a link that was ready keeps showing ready for 3 s")
    _ = debounce.update(.ready, now: 5)
    try check(debounce.update(.ready, now: 5.1) == .ready && debounce.update(.inUse(.live), now: 5.2) == .inUse(.live), "real changes show at once")
    try check(debounce.update(.searching(longWait: false), now: 5.3) == .searching(longWait: false), "in-use is never held after the microphone stops")
    _ = debounce.update(.localNetworkBlocked, now: 6)
    try check(debounce.update(.connecting, now: 6.5) == .localNetworkBlocked && debounce.update(.connecting, now: 7.9) == .localNetworkBlocked && debounce.update(.connecting, now: 8.1) == .connecting,
              "a retry does not flash over a Local Network block")

    // Protocol compatibility with 0.6.0.
    let legacyHello = Data(#"{"version":2,"id":"x","date":0,"kind":"hello","session":"","text":"c","clientVersion":"0.6.0"}"#.utf8)
    let decoded = try JSONDecoder().decode(Message.self, from: legacyHello)
    try check(decoded.name == nil && decoded.model == nil && decoded.clientVersion == "0.6.0", "a 0.6.0 hello without names still decodes")
    let modern = try JSONDecoder().decode(Message.self, from: JSONEncoder().encode(Message(kind: "helloOK", name: "工作室", model: "Mac Studio")))
    try check(modern.name == "工作室" && modern.model == "Mac Studio" && modern.version == 2, "names travel in the handshake and the wire version stays 2")
    let json = String(decoding: try JSONEncoder().encode(Message(kind: "ready")), as: UTF8.self)
    try check(!json.contains("\"name\"") && !json.contains("\"model\""), "messages without names add no keys for older peers")
    try check(CloseReason.connectionError(.posix(.ECONNREFUSED), path: nil) == .refused &&
              CloseReason.connectionError(.dns(-65570), path: nil) == .localNetworkDenied,
              "a refused connection and a privacy block are told apart")

    print("\(count) role, connection, status and compatibility checks passed.")
}
