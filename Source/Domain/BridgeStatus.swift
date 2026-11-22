import Foundation

/// Something the user must fix before the bridge can run.
enum SetupIssue: Equatable {
    case microphoneDenied
    case noMicrophone
    case noVirtualMicrophone
    case virtualMicrophoneTimeout
}

/// Why the bridge is stopped, if it stopped itself.
enum StopReason: Equatable {
    case setup(SetupIssue)
    case problem(String)
}

enum CaptureStage: Equatable { case activating, live, finishing }

/// The one status every view, the menu bar icon and the tests read.
enum BridgeStatus: Equatable {
    case sleeping
    case incomingPairing(peer: String, code: String)
    case setup(SetupIssue)
    case problem(String)
    case paused
    /// First launch: not started yet, the welcome window is open.
    case settingUp
    /// A keychain read is waiting on macOS's authorization prompt.
    case waitingForKeychain
    case pairing(code: String, message: String)
    case inUse(CaptureStage)
    case ready
    /// Running, but no Mac is paired yet.
    case noPairedDevices
    case localNetworkBlocked
    /// Both Macs provide, or both borrow.
    case roleConflict
    case peerBusy
    case peerPaused
    case peerAsleep
    /// The other Mac is awake but MicBridge is not running there.
    case peerAppClosed
    case connecting
    case searching(longWait: Bool)

    var isLive: Bool {
        switch self { case .ready, .inUse: return true; default: return false }
    }
    var isWaiting: Bool {
        switch self {
        case .connecting, .searching, .pairing, .incomingPairing, .inUse(.activating): return true
        default: return false
        }
    }
    var needsAttention: Bool {
        switch self { case .setup, .problem, .localNetworkBlocked, .waitingForKeychain: return true; default: return false }
    }
}

/// Everything `BridgeStatus.derive` looks at. Plain values, so the priority
/// rules are tested without audio or network.
struct StatusInputs: Equatable {
    var connection: ConnectionState
    var stopReason: StopReason?
    var incomingPairing: (peer: String, code: String)?
    var pairingCode = ""
    var pairingMessage = ""
    /// Borrower: a recording was requested from the provider.
    var captureRequested = false
    var captureFinishing = false
    /// Remote (borrower) or local (provider) microphone is capturing.
    var micActive = false
    /// A keychain call has been running long enough to be a prompt.
    var keychainPending = false
    /// The Mac the panel talks about.
    var peer: PeerAvailability = .unknown
    /// A pairing started on this Mac is in progress (while linked too).
    var pairingActive = false
    var hasPairedDevices = true
    /// The welcome window is open on first launch.
    var settingUp = false

    static func == (a: StatusInputs, b: StatusInputs) -> Bool {
        a.connection == b.connection && a.stopReason == b.stopReason &&
        a.incomingPairing?.peer == b.incomingPairing?.peer && a.incomingPairing?.code == b.incomingPairing?.code &&
        a.pairingCode == b.pairingCode && a.pairingMessage == b.pairingMessage &&
        a.captureRequested == b.captureRequested && a.captureFinishing == b.captureFinishing && a.micActive == b.micActive &&
        a.keychainPending == b.keychainPending && a.peer == b.peer &&
        a.pairingActive == b.pairingActive && a.hasPairedDevices == b.hasPairedDevices && a.settingUp == b.settingUp
    }
}

extension BridgeStatus {
    /// First match wins.
    static func derive(_ i: StatusInputs) -> BridgeStatus {
        let c = i.connection
        if c.lifecycle == .suspended { return .sleeping }
        if let request = i.incomingPairing { return .incomingPairing(peer: request.peer, code: request.code) }
        if case .setup(let issue)? = i.stopReason { return .setup(issue) }
        if case .problem(let text)? = i.stopReason, !text.isEmpty { return .problem(text) }
        // Not started yet because the welcome window is open: that is not a pause.
        if c.lifecycle == .paused { return i.settingUp ? .settingUp : .paused }
        // Never hide a live microphone behind the prompt.
        if i.keychainPending && !i.micActive && !i.captureRequested && !i.captureFinishing { return .waitingForKeychain }
        if c.link == .pairing || i.pairingActive { return .pairing(code: i.pairingCode, message: i.pairingMessage) }
        if i.captureFinishing { return .inUse(.finishing) }
        if i.micActive { return .inUse(.live) }
        if i.captureRequested { return .inUse(.activating) }
        if c.isReady { return .ready }
        if !i.hasPairedDevices { return .noPairedDevices }
        if c.localNetworkIssue { return .localNetworkBlocked }
        switch i.peer {
        case .online(let mode) where mode.role == c.role: return .roleConflict
        case .busy: return .peerBusy
        case .paused: return .peerPaused
        case .asleep: return .peerAsleep
        case .appClosed: return .peerAppClosed
        default: break
        }
        if c.lastClose == .busy, !c.isConnected { return .peerBusy }
        if (c.link == .dialing || c.link == .connected) && c.failures == 0 { return .connecting }
        return .searching(longWait: c.canDial && c.failures >= 3)
    }
}

/// Smooths brief network blips so the panel does not flicker:
/// - a link that was ready keeps showing "ready" for up to 3 s after it drops;
/// - a retry while "local network blocked" or "busy" is shown only replaces
///   it after 1.5 s.
struct StatusDebouncer: Equatable {
    private(set) var shown: BridgeStatus = .paused
    private var pendingSince: TimeInterval?

    mutating func update(_ raw: BridgeStatus, now: TimeInterval) -> BridgeStatus {
        let transient: Bool
        switch raw { case .connecting, .searching: transient = true; default: transient = false }
        guard transient, shown != raw else { shown = raw; pendingSince = nil; return shown }
        let since = pendingSince ?? now
        pendingSince = since
        let hold: TimeInterval
        switch shown {
        // Never hold "in use": the microphone state must always be truthful.
        case .ready: hold = 3
        // A retry during these must not flash "connecting" on every attempt.
        case .localNetworkBlocked, .peerBusy, .peerPaused, .peerAsleep, .peerAppClosed, .roleConflict: hold = 1.5
        default: hold = 0
        }
        if now - since >= hold { shown = raw; pendingSince = nil }
        return shown
    }
}
