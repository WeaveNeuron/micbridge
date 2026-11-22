import Foundation

/// What the macOS application firewall does to MicBridge's incoming
/// connections (pairing requests and the other Mac dialling in).
enum FirewallState: Equatable {
    /// Not read yet, or the reading failed: show nothing.
    case unknown
    case off
    /// On, and MicBridge may accept connections (allowed, or not listed).
    case allows
    /// "Block all incoming connections" is on.
    case blocksAll
    /// MicBridge is listed as "Block incoming connections".
    case blocksApp

    var blocksIncoming: Bool { self == .blocksAll || self == .blocksApp }

    /// Reads the output of `socketfilterfw --getglobalstate`, `--getblockall`
    /// and `--listapps` (all read-only, no administrator needed).
    /// `--getappblocked` is not used: it says "permitted" for any path, even
    /// one the firewall has never seen.
    static func parse(globalState: String, blockAll: String, apps: String, bundlePath: String) -> FirewallState {
        let global = globalState.lowercased()
        let level: Int?
        if let range = global.range(of: #"state = (\d)"#, options: .regularExpression) {
            level = Int(global[range].filter(\.isNumber))
        } else if global.contains("disabled") {
            level = 0
        } else if global.contains("enabled") {
            level = 1
        } else {
            level = nil
        }
        guard let level else { return .unknown }
        if level == 0 { return .off }
        // State 2 is the older "essential services only", i.e. block all.
        let block = blockAll.lowercased()
        if level >= 2 || (block.contains("block all") && block.contains("enabled")) { return .blocksAll }
        return appBlocked(apps, bundlePath: bundlePath) ? .blocksApp : .allows
    }

    /// `--listapps` lists "N : <path>" lines, each followed by
    /// "(Allow incoming connections)" or "(Block incoming connections)".
    /// The path may be the bundle or the executable inside it.
    static func appBlocked(_ listing: String, bundlePath: String) -> Bool {
        let bundles = Set([bundlePath, (bundlePath as NSString).resolvingSymlinksInPath, privateless(bundlePath)].map(trimmed))
        func ours(_ path: String) -> Bool {
            let candidates = [trimmed(path), trimmed(privateless(path))]
            return candidates.contains { p in bundles.contains { p == $0 || p.hasPrefix($0 + "/") } }
        }
        var current: String?
        var blocked = false
        for raw in listing.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let range = line.range(of: #"^\d+ : "#, options: .regularExpression) {
                current = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("("), let path = current {
                // The last word on our entry wins (a path can appear twice).
                if ours(path) { blocked = line.lowercased().contains("block") }
                current = nil
            }
        }
        return blocked
    }

    private static func trimmed(_ path: String) -> String {
        path.hasSuffix("/") ? String(path.dropLast()) : path
    }
    /// /private/tmp and /tmp are the same folder; the firewall may list either.
    private static func privateless(_ path: String) -> String {
        path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
    }
}
