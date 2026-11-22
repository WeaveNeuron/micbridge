import Foundation

/// Whether the bridge is running at all.
enum Lifecycle: Equatable {
    case paused      // the user turned it off, or a problem stopped it
    case suspended   // sleep, lock or fast user switching; resumes by itself
    case active
}

/// The state of the link to the other Mac.
enum LinkPhase: Equatable {
    case idle        // nothing in flight: waiting to dial, or for a dial-in
    case pairing     // a provider without a pairing yet
    case dialing     // connecting / handshaking
    case connected   // handshake done, waiting for the provider's `ready`
    case ready       // both ends ready: audio can flow on demand
}

enum ConnectionEvent: Equatable {
    case start, pause, suspend
    case needsPairing
    case dialStarted
    /// A dial in flight was dropped on purpose (new target, fresh start).
    case dialCancelled
    case handshakeOK
    case peerReady
    case closed(CloseReason)
    /// Deliberately dropped a working link to switch routes; dial again now.
    case rerouting
    /// The Mac to dial is visible on the network (or not).
    case peerVisible(Bool)
    /// There is (or no longer is) a paired Mac this one should dial.
    case dialTarget(Bool)
    case listenerReady, listenerFailed
    case tick
}

enum ConnectionEffect: Equatable {
    /// Dial the next route (only issued while idle).
    case dial
    /// Drop any attempt in flight and dial again from the first route.
    case redial
    /// A browser started before Local Network access was granted does not
    /// recover by itself; restart it.
    case restartDiscovery
    case startListener
}

/// Connection lifecycle as a pure state machine. Audio sessions are not part
/// of it; they live in the role controllers. Since 0.7.1 every Mac listens,
/// and whether this one dials is decided by `DialPlanner` (`dialTarget`),
/// not by its role.
struct ConnectionState: Equatable {
    let role: Role
    var lifecycle: Lifecycle = .paused
    var link: LinkPhase = .idle
    /// Consecutive attempts that never completed a handshake.
    var failures = 0
    var retryAt: TimeInterval = 0
    var retryDelay: TimeInterval = 1
    /// When the current link finished its handshake.
    var linkedAt: TimeInterval?
    /// A link must stay up this long before the back-off starts over, so a
    /// link that keeps dropping right after its handshake cannot redial
    /// every second.
    static let stableLink: TimeInterval = 10
    var peerVisible = false
    var localNetworkBlocked = false
    var lastClose: CloseReason?
    var listening = false
    var listenerRetryAt: TimeInterval = 0
    /// A paired Mac to dial exists.
    var canDial = false

    init(role: Role) { self.role = role }

    var isActive: Bool { lifecycle == .active }
    var isConnected: Bool { link == .connected || link == .ready }
    var isReady: Bool { link == .ready }
    /// The other Mac is visible yet every attempt stalls. On macOS this is
    /// almost always Local Network privacy (granted per signing identity),
    /// which can leave a connection in .preparing without an error.
    var localNetworkIssue: Bool {
        canDial && isActive && !isConnected && (localNetworkBlocked || (peerVisible && failures >= 3))
    }

    mutating func reduce(_ event: ConnectionEvent, now: TimeInterval) -> [ConnectionEffect] {
        switch event {
        case .start:
            self = ConnectionState(role: role)
            lifecycle = .active; retryAt = now
            return []
        case .pause, .suspend:
            self = ConnectionState(role: role)
            lifecycle = event == .pause ? .paused : .suspended
            return []
        case .needsPairing:
            link = .pairing
            return []
        case .dialStarted:
            guard isActive else { return [] }
            link = .dialing
            return []
        case .dialCancelled:
            if link == .dialing { link = .idle; retryAt = now }
            return []
        case .handshakeOK:
            guard isActive else { return [] }
            lastClose = nil; linkedAt = now
            if role == .provider {
                link = .ready; failures = 0; localNetworkBlocked = false
            } else {
                link = .connected
            }
            return []
        case .peerReady:
            guard isActive, link == .connected else { return [] }
            link = .ready
            return []
        case .closed(let reason):
            var effects: [ConnectionEffect] = []
            if !isConnected {
                failures += 1
                if canDial, failures % 3 == 0 { effects.append(.restartDiscovery) }
            }
            if reason == .localNetworkDenied { localNetworkBlocked = true }
            if isConnected, let linkedAt, now - linkedAt >= Self.stableLink { retryDelay = 1 }
            linkedAt = nil
            lastClose = reason
            if link != .pairing { link = .idle }
            retryAt = now + retryDelay
            retryDelay = min(10, retryDelay * 2)
            return effects
        case .rerouting:
            guard isActive else { return [] }
            link = .idle; retryAt = now
            return [.dial]
        case .peerVisible(let visible):
            let appeared = visible && !peerVisible
            peerVisible = visible
            guard appeared, canDial, isActive, !isConnected, link != .pairing else { return [] }
            retryAt = now; retryDelay = 1
            return [.redial]
        case .dialTarget(let available):
            let appeared = available && !canDial
            canDial = available
            guard appeared, isActive, !isConnected, link != .pairing else { return [] }
            retryAt = now; retryDelay = 1
            return [.redial]
        case .listenerReady:
            listening = true
            return []
        case .listenerFailed:
            listening = false; listenerRetryAt = now + 2
            return []
        case .tick:
            guard isActive else { return [] }
            if canDial, link == .idle, now >= retryAt { return [.dial] }
            if !listening, listenerRetryAt > 0, now >= listenerRetryAt {
                listenerRetryAt = now + 3
                return [.startListener]
            }
            return []
        }
    }
}
