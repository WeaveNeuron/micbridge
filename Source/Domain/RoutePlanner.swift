import Foundation

/// One way to reach the listening Mac.
enum Route: Equatable {
    /// Its wired IPv4 address, learned at the last handshake. Lowest latency:
    /// measured ~6 ms RTT vs ~25 ms (100–200 ms spikes) over its Wi-Fi.
    case wired(String)
    /// The Bonjour service found nearby (survives host renames).
    case discovered
    /// The saved .local host name.
    case saved(String)

    var wiredHost: String? { if case .wired(let host) = self { return host }; return nil }
    /// A LAN address answers in milliseconds; don't sit on a dead one.
    var timeout: TimeInterval { wiredHost == nil ? 6 : 2 }
    var label: String {
        switch self {
        case .wired(let host): return tr("有线 \(host)", "Wired \(host)")
        case .discovered: return tr("附近自动发现", "Found nearby")
        case .saved(let host): return host
        }
    }
}

/// Order of attempts: wired address first, then the Bonjour result, then the
/// saved host name, rotating so one stale route never blocks reconnection.
struct RoutePlanner: Equatable {
    var wiredHosts: [String]
    private(set) var failedUntil: [String: TimeInterval] = [:]
    private(set) var attempts = 0
    private(set) var lastUpgrade: TimeInterval = -1000

    init(wiredHosts: [String] = []) { self.wiredHosts = wiredHosts }

    func candidates(discovered: Bool, savedHost: String, now: TimeInterval) -> [Route] {
        var routes = wiredHosts.filter { (failedUntil[$0] ?? 0) <= now }.map(Route.wired)
        if discovered { routes.append(.discovered) }
        if !savedHost.isEmpty { routes.append(.saved(savedHost)) }
        return routes
    }
    /// Nil when no address is known yet (a Mac only ever seen via Bonjour).
    mutating func next(discovered: Bool, savedHost: String, now: TimeInterval) -> Route? {
        let routes = candidates(discovered: discovered, savedHost: savedHost, now: now)
        guard !routes.isEmpty else { return nil }
        defer { attempts += 1 }
        return routes[attempts % routes.count]
    }
    mutating func restart() { attempts = 0 }
    /// A wired address that failed is skipped for a minute; a privacy block
    /// says nothing about the route and must not be recorded here.
    mutating func failed(_ route: Route, now: TimeInterval) {
        if let host = route.wiredHost { failedUntil[host] = now + 60 }
    }
    mutating func connected(via route: Route) {
        attempts = 0
        // On the wire: only a failed switch should cool down further upgrades.
        if route.wiredHost != nil { lastUpgrade = -1000 }
    }
    /// Connected over Wi-Fi or AWDL while a wired address is known and usable:
    /// switch over, but never more than once per 10 minutes.
    mutating func shouldUpgrade(remoteHost: String, now: TimeInterval) -> Bool {
        guard !wiredHosts.contains(remoteHost), now - lastUpgrade > 600,
              wiredHosts.contains(where: { (failedUntil[$0] ?? 0) <= now }) else { return false }
        lastUpgrade = now
        return true
    }
}
