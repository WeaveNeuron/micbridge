import Foundation

/// What the last dial to a Mac said about it.
enum DialOutcome: Equatable {
    case refused       // awake, but nothing listens: MicBridge is not running
    case timeout       // no answer: asleep, off, or on another network
    case unreachable
    case busy          // linked to another Mac
    case localNetworkDenied

    init?(_ reason: CloseReason) {
        switch reason {
        case .refused: self = .refused
        case .connectTimeout: self = .timeout
        case .unreachable: self = .unreachable
        case .busy: self = .busy
        case .localNetworkDenied: self = .localNetworkDenied
        default: return nil
        }
    }
}

/// How a paired Mac is doing, as far as this Mac can tell.
enum PeerAvailability: Equatable {
    case connected
    /// Visible on the network in this mode (provider or borrower).
    case online(PeerMode)
    case busy
    case paused
    case asleep
    case appClosed
    case unreachable
    case unknown
}

/// Everything this Mac knows about one paired Mac's presence: its TXT
/// record, its goodbye, and the last dial. Pure, so the rules are tested.
struct PeerPresence: Equatable {
    var advert: PresenceAdvert?
    /// Visible without a TXT record: a 0.6.0 / 0.7.0 borrower listening.
    var legacyVisible = false
    var bye: ByeReason?
    var lastDial: DialOutcome?
    var connected = false

    var visible: Bool { advert != nil || legacyVisible }

    /// Its service appeared or changed. Fresh information replaces guesses.
    mutating func seen(_ advert: PresenceAdvert?) {
        self.advert = advert; legacyVisible = advert == nil
        bye = nil; lastDial = nil
    }
    mutating func vanished() { advert = nil; legacyVisible = false }
    mutating func said(_ reason: ByeReason) { bye = reason }
    mutating func dialed(_ outcome: DialOutcome?) { lastDial = outcome }
    mutating func linked(_ up: Bool) {
        connected = up
        if up { bye = nil; lastDial = nil }
    }

    var availability: PeerAvailability {
        if connected { return .connected }
        if let advert {
            if advert.mode == .paused { return .paused }
            return advert.busy ? .busy : .online(advert.mode)
        }
        if legacyVisible { return .online(.borrower) }
        switch bye {
        case .paused?: return .paused
        case .sleep?: return .asleep
        case .quit?: return .appClosed
        case .mode?, nil: break
        }
        switch lastDial {
        case .refused?: return .appClosed
        case .timeout?, .unreachable?: return .unreachable
        case .busy?: return .busy
        case .localNetworkDenied?, nil: return .unknown
        }
    }
}

/// Which paired Mac to dial, if any.
///
/// - A borrower dials the provider it uses (the preferred one, else the most
///   recently connected) as soon as it is seen online and free (its own
///   provider even when it looks busy, which may be this Mac's stale link).
/// - A provider dials a borrower that cannot dial it: a 0.6.0 / 0.7.0
///   borrower, one that has not received this Mac's key yet, or one that is
///   not visible at all (Bonjour blocked; wired and saved addresses still
///   work). A 0.7.1 borrower that is visible and has the key gets
///   `fallbackDelay` to dial first; after that the provider dials too and
///   `LinkArbiter` drops the duplicate.
enum DialPlanner {
    static let fallbackDelay: TimeInterval = 10

    static func target(role: Role, devices: [PairedDevice], keys: Set<String>, presence: [String: PeerPresence],
                       preferred: String?, idleFor: TimeInterval) -> String? {
        let dialable = devices.filter { !$0.isPlaceholder && keys.contains($0.id) }
        switch role {
        case .borrower:
            let online = dialable.filter {
                guard let advert = presence[$0.id]?.advert else { return false }
                // Its own provider may still look busy with this Mac's stale
                // link; dialing replaces that link at once.
                return advert.mode == .provider && (!advert.busy || $0.id == preferred)
            }
            return (online.first { $0.id == preferred } ?? online.first)?.id
        case .provider:
            return dialable.first { device in
                let p = presence[device.id] ?? PeerPresence()
                if let advert = p.advert {
                    guard advert.mode == .borrower, !advert.busy else { return false }
                    return !device.hasOurKey || idleFor >= fallbackDelay
                }
                if p.legacyVisible { return true }
                // Not seen: keep trying its wired / saved address, as 0.6.0 did.
                return device.mode == .borrower && (device.host != nil || !device.wiredHosts.isEmpty)
            }?.id
        }
    }
}

/// Two links to the same Mac (both dialed at once): which one survives.
/// Both Macs apply the same rule, so they keep the same link.
enum LinkArbiter {
    /// The link the borrower dialed wins; if modes do not settle it, the one
    /// dialed by the smaller device ID.
    static func keepsIncoming(localID: String, localMode: PeerMode, remoteID: String, remoteMode: PeerMode?) -> Bool {
        let localBorrows = localMode == .borrower, remoteBorrows = remoteMode == .borrower
        if localBorrows != remoteBorrows { return remoteBorrows }
        return remoteID < localID
    }
}
