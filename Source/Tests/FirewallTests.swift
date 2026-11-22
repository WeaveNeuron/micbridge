import Foundation

/// The firewall reading, from socketfilterfw's own output. Nothing is run
/// here and no setting is read or changed.
func runFirewallTests() throws {
    var count = 0
    func check(_ condition: Bool, _ description: String) throws {
        guard condition else { throw BridgeError("FAIL: \(description)") }
        count += 1; print("PASS: \(description)")
    }
    let app = "/Applications/MicBridge.app"
    let on = "Firewall is enabled. (State = 1)", off = "Firewall is disabled. (State = 0)"
    let blockAllOff = "Firewall has block all state set to disabled.", blockAllOn = "Firewall has block all state set to enabled."
    func listing(_ entries: [(String, Bool)]) -> String {
        "Total number of apps = \(entries.count) \n\n" + entries.enumerated().map { index, entry in
            "\(index + 1) : \(entry.0) \n             (\(entry.1 ? "Block" : "Allow") incoming connections)"
        }.joined(separator: "\n")
    }
    func parse(_ global: String, _ blockAll: String = blockAllOff, _ apps: [(String, Bool)] = [], bundle: String = app) -> FirewallState {
        FirewallState.parse(globalState: global, blockAll: blockAll, apps: listing(apps), bundlePath: bundle)
    }

    try check(parse(off, blockAllOn, [(app, true)]) == .off, "a firewall that is off blocks nothing, whatever its lists say")
    try check(parse(on) == .allows, "firewall on, MicBridge not listed: allowed (macOS asks or the signature allows)")
    try check(parse(on, blockAllOff, [(app, false)]) == .allows, "MicBridge listed as allowed")
    try check(parse(on, blockAllOff, [("/Applications/Other.app", true), (app, false)]) == .allows, "another app being blocked is not MicBridge being blocked")
    try check(parse(on, blockAllOff, [(app, true)]) == .blocksApp, "MicBridge listed as blocked")
    try check(parse(on, blockAllOff, [(app + "/Contents/MacOS/MicBridge", true)]) == .blocksApp, "the executable inside the bundle counts as MicBridge")
    try check(parse(on, blockAllOff, [("/Applications/MicBridge.app.old", true)]) == .allows, "a path that only starts with the same letters is another app")
    try check(parse(on, blockAllOff, [("/private/tmp/x/MicBridge.app", true)], bundle: "/tmp/x/MicBridge.app") == .blocksApp,
              "/private/tmp and /tmp are the same place")
    try check(parse(on, blockAllOn) == .blocksAll && parse("Firewall is enabled. (State = 2)") == .blocksAll,
              "block all incoming (and the older essential-services state) blocks MicBridge")
    try check(parse("", "", []) == .unknown && parse("socketfilterfw: unexpected") == .unknown, "an unreadable answer shows nothing")
    try check(FirewallState.blocksApp.blocksIncoming && FirewallState.blocksAll.blocksIncoming &&
              ![FirewallState.unknown, .off, .allows].contains { $0.blocksIncoming }, "only the two blocking states block")

    print("Firewall: \(count) checks passed")
}
