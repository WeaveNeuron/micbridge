import Foundation
import CryptoKit
import Security

enum Keys {
    /// Keychain account names predate the role rename and must not change,
    /// or existing pairings are lost.
    /// - listening: this Mac's own key; peers that dial it must hold it.
    /// - peer: the key of the Mac this one dials (received by pairing).
    static let listeningAccount = "receiver-v2"
    static let peerAccount = "sender-v2"
    static func sessionKey(shared: Data, challenge: Data) -> Data {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: shared), salt: challenge,
            info: Data("MicBridge connection v3".utf8), outputByteCount: 32).withUnsafeBytes { Data($0) }
    }
    /// May block for as long as macOS shows a keychain prompt (for example
    /// after the app's signature changed). Never call on the main thread;
    /// use `KeyVault`.
    static func lookup(_ account: String) -> KeyLookup {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.weaveneuron.MicBridge", kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return (result as? Data).map(KeyLookup.found) ?? .failed(errSecDecode)
        case errSecItemNotFound: return .missing
        default: return .failed(status)
        }
    }
    /// Blocks like `lookup`; never call on the main thread.
    static func save(_ data: Data, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.weaveneuron.MicBridge", kSecAttrAccount as String: account]
        let attrs: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(query.merging(attrs) { _, new in new } as CFDictionary, nil) == errSecSuccess else {
                throw BridgeError(tr("无法将配对密钥保存到钥匙串。", "Couldn’t save the pairing key to the keychain."))
            }
        } else if status != errSecSuccess { throw BridgeError(tr("无法更新钥匙串中的配对密钥。", "Couldn’t update the pairing key in the keychain.")) }
    }
    static func generate() -> Data { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } }
}

/// The result of a keychain read. "Missing" and "failed" are different:
/// a denied read must never be treated as "no key" and overwritten.
enum KeyLookup: Equatable {
    case found(Data)
    case missing
    case failed(OSStatus)
}

final class Codec {
    let key: SymmetricKey
    var seen: [String: TimeInterval] = [:]
    private var lastPrune: TimeInterval = 0
    init(key: Data) { self.key = SymmetricKey(data: key) }
    func encode(_ message: Message) throws -> Data {
        let plain = try JSONEncoder().encode(message)
        guard plain.count < maxFrame - 64 else { throw BridgeError(tr("消息过长。", "The message is too long.")) }
        let sealed = try AES.GCM.seal(plain, using: key).combined!
        var size = UInt32(sealed.count).bigEndian
        var frame = withUnsafeBytes(of: &size) { Data($0) }
        frame.append(sealed)
        return frame
    }
    func decode(_ sealed: Data, now: TimeInterval = Date().timeIntervalSince1970) throws -> Message {
        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key)
        let message = try JSONDecoder().decode(Message.self, from: plain)
        guard message.version == 2, abs(now - message.date) < 60 else {
            throw BridgeError(tr("消息已过期，或两台 Mac 的系统时间相差超过一分钟。", "The message expired, or the two Macs’ clocks differ by more than a minute."))
        }
        // Prune at most once per second; rebuilding the table per message
        // was O(n) work for every 20 ms audio packet.
        if now - lastPrune > 1 { seen = seen.filter { now - $0.value < 120 }; lastPrune = now }
        guard seen[message.id] == nil else { throw BridgeError(tr("已拒绝重复消息。", "A repeated message was rejected.")) }
        guard seen.count < 16384 else { throw BridgeError(tr("消息过于频繁。", "Too many messages.")) }
        seen[message.id] = now
        return message
    }
}

struct FrameBuffer {
    var bytes = Data()
    mutating func append(_ chunk: Data) throws -> [Data] {
        bytes.append(chunk)
        var frames: [Data] = []
        while bytes.count >= 4 {
            let size = bytes.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard size >= 28, size <= maxFrame else { throw BridgeError(tr("无效的数据帧。", "Invalid frame.")) }
            guard bytes.count >= Int(size) + 4 else { break }
            frames.append(Data(bytes.dropFirst(4).prefix(Int(size))))
            bytes.removeFirst(Int(size) + 4)
        }
        guard bytes.count <= maxFrame + 4 else { throw BridgeError(tr("数据帧超出限制。", "The frame is too large.")) }
        return frames
    }
}
