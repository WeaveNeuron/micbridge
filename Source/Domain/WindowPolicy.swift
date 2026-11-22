import Foundation

/// MicBridge's windows. It shows one at a time.
enum AppWindow: Hashable, CaseIterable {
    case panel, settings, welcome
}

/// Which window to show, and which to close, when one is asked for. Pure, so
/// "never two at once" is tested without windows.
///
/// The welcome window keeps the screen until setup is done: the panel or
/// Settings asked for meanwhile bring it forward instead. A pairing request
/// is the exception: it ends setup and takes the panel, the one place where
/// pairing happens.
enum WindowPolicy {
    static func resolve(_ request: AppWindow, open: Set<AppWindow>, pairingRequest: Bool = false) -> (show: AppWindow, close: Set<AppWindow>) {
        var show = request
        if open.contains(.welcome), request != .welcome, !pairingRequest { show = .welcome }
        if pairingRequest { show = .panel }
        return (show, open.subtracting([show]))
    }
}
