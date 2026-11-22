import Foundation
import Network

/// Why a link closed. Typed so connection and status logic never have to
/// parse display text. `message` is the user-facing wording.
enum CloseReason: Equatable {
    /// Closed on purpose by this Mac (stop, reroute, replaced, test).
    case local(String)
    /// The other Mac answered but nothing listens on the port: it is awake
    /// and MicBridge is not running there.
    case refused
    /// macOS Local Network privacy blocked the hop.
    case localNetworkDenied
    /// The connection attempt did not complete in time.
    case connectTimeout
    /// Could not connect for another reason (no route, DNS, reset…).
    case unreachable(String)
    /// An established link went quiet for longer than the heartbeat allows.
    case heartbeat
    /// The other side closed the link.
    case peerClosed
    case sendBacklog
    case sendFailed(String)
    /// Authentication, replay or framing failure.
    case invalid(String)
    /// Protocol violation during the handshake.
    case handshake(String)
    /// The other Mac is already busy with a recording for someone else.
    case busy
    /// Another copy of MicBridge took over this link.
    case superseded

    var isDeliberate: Bool { if case .local = self { return true }; return false }

    var message: String {
        switch self {
        case .local(let text): return text
        case .refused: return tr("对方未打开 MicBridge。", "MicBridge isn’t open on the other Mac.")
        case .localNetworkDenied: return tr("本地网络权限未开启。", "Local Network access is off.")
        case .connectTimeout: return tr("连接超时。", "The connection timed out.")
        case .unreachable(let text): return tr("无法连接：\(text)", "Couldn’t connect: \(text)")
        case .heartbeat: return tr("连接已无响应。", "The connection stopped responding.")
        case .peerClosed: return tr("对方已断开。", "The other Mac disconnected.")
        case .sendBacklog: return tr("网络发送积压，已停止本次收音，避免延迟。", "The network fell behind, so this recording stopped to avoid delay.")
        case .sendFailed(let text): return tr("发送失败：\(text)", "Couldn’t send: \(text)")
        case .invalid(let text): return tr("消息校验失败：\(text)", "A message failed verification: \(text)")
        case .handshake(let text): return text
        case .busy: return tr("对方正忙。", "The other Mac is busy.")
        case .superseded: return tr("连接已由另一份 MicBridge 接管。", "Another copy of MicBridge took over the connection.")
        }
    }

    static func connectionError(_ error: NWError, path: NWPath?) -> CloseReason {
        if Wire.isLocalNetworkDenied(error, path: path) { return .localNetworkDenied }
        if case .posix(let code) = error, code == .ECONNREFUSED { return .refused }
        if case .posix(let code) = error, code == .ETIMEDOUT { return .connectTimeout }
        return .unreachable(error.localizedDescription)
    }
}
