import Foundation

enum DemandAction: Equatable { case none, start, stop }

/// Level-triggered: while any app reads the virtual microphone and the provider
/// is available, the provider supplies audio — including an app that was
/// already listening before the provider connected. Nothing is queued while
/// unavailable, and failures back off so a broken microphone cannot loop.
struct DemandPolicy {
    static let maxFailures = 3
    private(set) var requested = false
    private(set) var failures = 0
    private var retryAt: TimeInterval = 0
    mutating func observe(_ demand: Bool, available: Bool, active: Bool, now: TimeInterval) -> DemandAction {
        requested = demand
        guard demand else { failures = 0; retryAt = 0; return active ? .stop : .none }
        guard available, !active, failures < Self.maxFailures, now >= retryAt else { return .none }
        return .start
    }
    mutating func failed(now: TimeInterval) { failures += 1; retryAt = now + 1 }
    mutating func succeeded() { failures = 0; retryAt = 0 }
}

