import Foundation

let bridgePort: UInt16 = 45874
let maxFrame = 262_144
let syntheticTag: Int64 = 0x4D49434252494447

struct BridgeError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

/// One encrypted frame on the link. Wire format version 2 since 0.3.x.
///
/// Compatibility rules (0.6.0 peers must keep working):
/// - `version` stays 2; `Codec.decode` rejects anything else.
/// - Every field added after 0.6.0 is optional, so older JSON still decodes,
///   and older peers ignore keys they do not know.
/// - Before the handshake completes a peer only accepts challenge / hello /
///   helloOK (and `busy`), so new information travels as optional fields of
///   hello / helloOK. New message kinds are only sent after the handshake.
///
/// Message kinds by role (not by who dialed):
///   borrower → provider: start, stop, cancel
///   provider → borrower: ready, started, pcm, ended, sourceError, idle
struct Message: Codable {
    var version = 2
    var id = UUID().uuidString
    var date = Date().timeIntervalSince1970
    var kind: String
    var session: String = ""
    var text: String = ""
    var audio: Data? = nil
    var sequence: UInt64? = nil
    var clientVersion: String? = nil
    /// Sender's wired IPv4 addresses (helloOK; also hello since 0.7.1).
    /// Older peers ignore the key.
    var hosts: [String]? = nil
    /// Sender's display name and hardware model (hello / helloOK, 0.7+).
    var name: String? = nil
    var model: String? = nil
    /// 0.7.1+: sender's device ID (`DeviceKey.id`), mode and the
    /// post-handshake kinds it understands (`ProtocolFeature`).
    var device: String? = nil
    var mode: String? = nil
    var features: [String]? = nil
}

/// One Mac's pairing card: where it listens and its device key. Encoded form
/// is shared by copy/paste pairing. `name` / `model` are 0.7.1 additions that
/// older Macs ignore.
struct Pairing: Codable {
    var version = 2
    var host: String
    var key: String
    var name: String? = nil
    var model: String? = nil
    var encoded: String { "micbridge://" + (try! JSONEncoder().encode(self)).base64EncodedString() }
    var keyData: Data? { Data(base64Encoded: key) }
    func validated() throws -> Pairing {
        guard version == 2, !host.isEmpty, host.count < 256, keyData?.count == 32 else {
            throw BridgeError(tr("连接信息无效，请重新复制完整内容。", "Invalid connection info. Copy all of it again."))
        }
        return self
    }
    static func parse(_ value: String) throws -> Pairing {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("micbridge://"),
              let data = Data(base64Encoded: String(trimmed.dropFirst(12))),
              let pair = try? JSONDecoder().decode(Pairing.self, from: data) else {
            throw BridgeError(tr("连接信息无效，请重新复制完整内容。", "Invalid connection info. Copy all of it again."))
        }
        return try pair.validated()
    }
}
