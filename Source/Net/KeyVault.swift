import Foundation
import Security

/// Where keys are stored. The real store is the keychain; tests use a fake.
protocol KeyStore: AnyObject {
    func lookup(_ account: String) -> KeyLookup
    func save(_ data: Data, account: String) throws
}

final class SystemKeyStore: KeyStore {
    func lookup(_ account: String) -> KeyLookup { Keys.lookup(account) }
    func save(_ data: Data, account: String) throws { try Keys.save(data, account: account) }
}

struct KeychainError: LocalizedError, Equatable {
    let status: OSStatus
    var errorDescription: String? {
        tr("无法读取配对密钥（错误 \(status)），请重试并点“始终允许”。",
           "Couldn’t read the pairing keys (error \(status)). Try again and click Always Allow.")
    }
}

private extension Result {
    var failureError: Failure? { if case .failure(let error) = self { return error }; return nil }
}

/// Keychain access off the main thread. A keychain call can block for as
/// long as macOS shows an authorization prompt (it does after the app's code
/// signature changes); the app must stay responsive and say what it waits for.
/// Completions run on the main thread. Keys are cached after the first read.
final class KeyVault {
    private let store: KeyStore
    private let queue = DispatchQueue(label: "micbridge.keychain", qos: .userInitiated)
    private(set) var listeningKey: Data?
    private(set) var peerKeys: [String: Data]?
    /// When the oldest unfinished keychain call started.
    private(set) var pendingSince: TimeInterval?
    private var pending = 0
    var onChange: (() -> Void)?

    init(store: KeyStore = SystemKeyStore()) { self.store = store }

    /// Reads are normally instant; only a call still running after this long
    /// is shown as "waiting for keychain authorization".
    static let promptThreshold: TimeInterval = 0.5
    func isWaiting(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        pendingSince.map { now - $0 >= Self.promptThreshold } ?? false
    }

    /// This Mac's own key, created only if the keychain has none. A failed
    /// read (denied, cancelled) never creates a new key: that would silently
    /// break every existing pairing.
    func loadListeningKey(_ done: @escaping (Result<Data, Error>) -> Void) {
        if let listeningKey { done(.success(listeningKey)); return }
        run({ store -> Result<Data, Error> in
            switch store.lookup(Keys.listeningAccount) {
            case .found(let key): return .success(key)
            case .failed(let status): return .failure(KeychainError(status: status))
            case .missing:
                let key = Keys.generate()
                do { try store.save(key, account: Keys.listeningAccount); return .success(key) }
                catch { return .failure(error) }
            }
        }) { [weak self] result in
            if case .success(let key) = result { self?.listeningKey = key }
            done(result)
        }
    }
    /// Device keys of paired Macs, by device ID: one keychain item, so one
    /// read (and at most one prompt) at start. On first use the 0.7.0 key in
    /// `sender-v2` is carried over; that item stays for downgrades.
    func loadPeerKeys(_ done: @escaping (Result<[String: Data], Error>) -> Void) {
        if let peerKeys { done(.success(peerKeys)); return }
        run({ store in Self.readBundle(store) }) { [weak self] result in
            if case .success(let keys) = result { self?.peerKeys = keys }
            done(result)
        }
    }
    /// Adds or replaces one Mac's key. Read-modify-write on the keychain
    /// queue; a failed read never overwrites the bundle. `legacy` also writes
    /// 0.7.0's single slot so a downgraded provider still dials it.
    func savePeerKey(_ key: Data, for id: String, legacy: Bool = false, _ done: @escaping (Error?) -> Void) {
        changeBundle({ $0[id] = key }, legacy: legacy ? key : nil, done)
    }
    func removePeerKey(_ id: String, _ done: @escaping (Error?) -> Void) {
        changeBundle({ $0.removeValue(forKey: id) }, legacy: nil, done)
    }

    static let peerKeysAccount = "peer-keys-v1"
    private func changeBundle(_ change: @escaping (inout [String: Data]) -> Void, legacy: Data?, _ done: @escaping (Error?) -> Void) {
        run({ store -> Result<[String: Data], Error> in
            let current = Self.readBundle(store)
            guard case .success(var keys) = current else { return .failure(current.failureError ?? BridgeError(tr("无法读取钥匙串。", "Couldn’t read the keychain."))) }
            change(&keys)
            do {
                try store.save(Self.encode(keys), account: Self.peerKeysAccount)
                if let legacy { try store.save(legacy, account: Keys.peerAccount) }
                return .success(keys)
            } catch { return .failure(error) }
        }) { [weak self] result in
            switch result {
            case .success(let keys): self?.peerKeys = keys; done(nil)
            case .failure(let error): done(error)
            }
        }
    }
    private static func readBundle(_ store: KeyStore) -> Result<[String: Data], Error> {
        switch store.lookup(peerKeysAccount) {
        case .found(let data):
            guard let keys = decode(data) else { return .failure(BridgeError(tr("钥匙串中的配对密钥已损坏。请重新配对。", "The pairing keys in the keychain are damaged. Pair again."))) }
            return .success(keys)
        case .failed(let status): return .failure(KeychainError(status: status))
        case .missing:
            switch store.lookup(Keys.peerAccount) {
            case .found(let key) where key.count == 32:
                let keys = [DeviceKey.id(for: key): key]
                try? store.save(encode(keys), account: peerKeysAccount)
                return .success(keys)
            case .failed(let status): return .failure(KeychainError(status: status))
            default: return .success([:])
            }
        }
    }
    private static func encode(_ keys: [String: Data]) -> Data {
        (try? JSONEncoder().encode(keys.mapValues { $0.base64EncodedString() })) ?? Data()
    }
    private static func decode(_ data: Data) -> [String: Data]? {
        guard let raw = try? JSONDecoder().decode([String: String].self, from: data) else { return nil }
        var keys: [String: Data] = [:]
        for (id, text) in raw { guard let key = Data(base64Encoded: text), key.count == 32 else { return nil }; keys[id] = key }
        return keys
    }

    private func run<T>(_ work: @escaping (KeyStore) -> T, then done: @escaping (T) -> Void) {
        pending += 1
        if pendingSince == nil { pendingSince = ProcessInfo.processInfo.systemUptime }
        let store = self.store
        queue.async { [weak self] in
            let result = work(store)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pending -= 1
                if self.pending == 0 { self.pendingSince = nil }
                done(result)
                self.onChange?()
            }
        }
        // Surface the waiting state once the threshold passes.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.promptThreshold + 0.05) { [weak self] in
            if self?.pendingSince != nil { self?.onChange?() }
        }
    }
}
