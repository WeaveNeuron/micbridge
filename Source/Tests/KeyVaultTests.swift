import Foundation
import Security

/// Keychain access off the main thread, against a fake store that can hold
/// a call open the way macOS's authorization prompt does. Never touches the
/// real keychain.
func runKeyVaultTests() throws {
    var count = 0
    func check(_ condition: Bool, _ description: String) throws {
        guard condition else { throw BridgeError("FAIL: \(description)") }
        count += 1; print("PASS: \(description)")
    }
    func spin(until done: () -> Bool, timeout: TimeInterval = 3) {
        let deadline = Date().addingTimeInterval(timeout)
        while !done() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    // A read held open (as by a prompt) leaves the main thread free and is
    // reported as waiting only after the threshold.
    let store = FakeKeyStore()
    store.items[Keys.listeningAccount] = Data(repeating: 7, count: 32)
    store.gate = DispatchSemaphore(value: 0)
    let vault = KeyVault(store: store)
    var loaded: Data?
    let started = Date()
    vault.loadListeningKey { if case .success(let key) = $0 { loaded = key } }
    try check(Date().timeIntervalSince(started) < 0.1 && loaded == nil, "a keychain read never blocks the main thread")
    var ticks = 0
    let ticker = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in ticks += 1 }
    try check(!vault.isWaiting(), "a read that may finish at once is not shown as waiting")
    var changes = 0
    vault.onChange = { changes += 1 }
    spin(until: { changes >= 1 })
    try check(vault.isWaiting() && ticks >= 5 && changes >= 1, "the main run loop keeps running and the waiting state is announced while the prompt is open")
    var activeBorrower = ConnectionState(role: .borrower); activeBorrower.lifecycle = .active
    let inputs = StatusInputs(connection: activeBorrower, keychainPending: true)
    try check(BridgeStatus.derive(inputs) == .waitingForKeychain, "the status says the keychain is waiting")
    var live = inputs; live.micActive = true
    try check(BridgeStatus.derive(live) == .inUse(.live), "a live microphone is never hidden behind the keychain prompt")
    var paused = inputs; paused.connection = ConnectionState(role: .borrower)
    try check(BridgeStatus.derive(paused) == .paused, "a paused bridge shows paused, not a stale keychain wait")
    store.gate?.signal()
    spin(until: { loaded != nil })
    ticker.invalidate()
    try check(loaded == Data(repeating: 7, count: 32) && !vault.isWaiting() && vault.pendingSince == nil, "the existing key arrives once the prompt is answered")
    store.gate = nil
    let readsBefore = store.reads
    var cached: Data?
    vault.loadListeningKey { if case .success(let key) = $0 { cached = key } }
    try check(cached == loaded && store.reads == readsBefore, "a second read comes from the cache, without another prompt")

    // A denied read must never replace the key: that would break every pairing.
    let denied = FakeKeyStore()
    denied.items[Keys.listeningAccount] = Data(repeating: 1, count: 32)
    denied.failure = errSecAuthFailed
    let deniedVault = KeyVault(store: denied)
    var deniedResult: Result<Data, Error>?
    deniedVault.loadListeningKey { deniedResult = $0 }
    spin(until: { deniedResult != nil })
    var deniedError: Error?
    if case .failure(let error)? = deniedResult { deniedError = error }
    try check((deniedError as? KeychainError)?.status == errSecAuthFailed, "a denied read is reported with its status")
    try check(denied.saves == 0 && denied.items[Keys.listeningAccount] == Data(repeating: 1, count: 32) && deniedVault.listeningKey == nil,
              "a denied read never generates or overwrites the key")
    var peerLoad: Result<[String: Data], Error>?
    deniedVault.loadPeerKeys { peerLoad = $0 }
    spin(until: { peerLoad != nil })
    var peerFailed = false
    if case .failure? = peerLoad { peerFailed = true }
    try check(peerFailed && deniedVault.peerKeys == nil, "a denied peer key read is not mistaken for having no pairings")
    var denySave: Error?? = .none
    deniedVault.savePeerKey(Keys.generate(), for: "x") { denySave = .some($0) }
    spin(until: { denySave != nil })
    try check(denySave! != nil && denied.saves == 0, "a pairing is never saved over a bundle that could not be read")

    // First run: no key yet, so one is created and saved once.
    let fresh = FakeKeyStore()
    let freshVault = KeyVault(store: fresh)
    var created: Data?
    freshVault.loadListeningKey { if case .success(let key) = $0 { created = key } }
    spin(until: { created != nil })
    try check(created?.count == 32 && fresh.items[Keys.listeningAccount] == created && fresh.saves == 1, "a missing key is created and saved once")
    var none: [String: Data]?
    freshVault.loadPeerKeys { if case .success(let keys) = $0 { none = keys } }
    spin(until: { none != nil })
    try check(none == [:] && fresh.items[KeyVault.peerKeysAccount] == nil, "no pairing reads as an empty list and writes nothing")
    let first = Data(repeating: 9, count: 32), second = Data(repeating: 8, count: 32)
    var saved = 0
    freshVault.savePeerKey(first, for: DeviceKey.id(for: first), legacy: true) { if $0 == nil { saved += 1 } }
    freshVault.savePeerKey(second, for: DeviceKey.id(for: second)) { if $0 == nil { saved += 1 } }
    spin(until: { saved == 2 })
    try check(freshVault.peerKeys?.count == 2 && fresh.items[Keys.peerAccount] == first, "each paired Mac's key is kept, and the first also in 0.7.0's slot")
    var removed = false
    freshVault.removePeerKey(DeviceKey.id(for: second)) { removed = $0 == nil }
    spin(until: { removed })
    try check(freshVault.peerKeys == [DeviceKey.id(for: first): first], "removing a Mac removes only its key")

    // Upgrade from 0.7.0: the single key moves into the bundle.
    let upgraded = FakeKeyStore()
    upgraded.items[Keys.peerAccount] = first
    let upgradedVault = KeyVault(store: upgraded)
    var carried: [String: Data]?
    upgradedVault.loadPeerKeys { if case .success(let keys) = $0 { carried = keys } }
    spin(until: { carried != nil })
    try check(carried == [DeviceKey.id(for: first): first] && upgraded.items[KeyVault.peerKeysAccount] != nil && upgraded.items[Keys.peerAccount] == first,
              "the 0.7.0 pairing key carries over and its old slot stays for downgrades")

    print("\(count) keychain checks passed.")
}

/// In-memory key store. `gate` holds each call open until signalled.
private final class FakeKeyStore: KeyStore {
    private let lock = NSLock()
    private var _items: [String: Data] = [:]
    var items: [String: Data] {
        get { lock.lock(); defer { lock.unlock() }; return _items }
        set { lock.lock(); _items = newValue; lock.unlock() }
    }
    var gate: DispatchSemaphore?
    var failure: OSStatus?
    private(set) var reads = 0
    private(set) var saves = 0

    func lookup(_ account: String) -> KeyLookup {
        gate?.wait()
        reads += 1
        if let failure { return .failed(failure) }
        return items[account].map(KeyLookup.found) ?? .missing
    }
    func save(_ data: Data, account: String) throws {
        gate?.wait()
        if let failure { throw KeychainError(status: failure) }
        saves += 1
        items[account] = data
    }
}
