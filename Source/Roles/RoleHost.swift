import Foundation

/// What a role controller needs from the app: the link and the status line.
protocol RoleHost: AnyObject {
    /// Sends on the current link (dropped when there is none).
    func send(_ message: Message)
    /// A per-recording problem: shown briefly; the bridge stays ready.
    func transient(_ text: String)
    /// Diagnostics status line.
    func status(_ text: String)
    /// Capture state changed: refresh the menu bar icon and the window.
    func captureChanged()
}
