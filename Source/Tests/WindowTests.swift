import Foundation

/// One MicBridge window at a time, and pairing in one place: which window
/// opens and closes, and what the panel says before and after pairing.
func runWindowTests() throws {
    var count = 0
    func check(_ condition: Bool, _ description: String) throws {
        guard condition else { throw BridgeError("FAIL: \(description)") }
        count += 1; print("PASS: \(description)")
    }
    func after(_ request: AppWindow, _ open: Set<AppWindow>, pairing: Bool = false) -> Set<AppWindow> {
        let plan = WindowPolicy.resolve(request, open: open, pairingRequest: pairing)
        return open.subtracting(plan.close).union([plan.show])
    }

    // Whatever is open and whatever is asked for, one window remains.
    let all = AppWindow.allCases
    var subsets: [Set<AppWindow>] = [[]]
    for window in all { subsets += subsets.map { $0.union([window]) } }
    try check(subsets.allSatisfy { open in all.allSatisfy { after($0, open).count == 1 && after($0, open, pairing: true).count == 1 } },
              "any window asked for, from any state, leaves exactly one open")
    try check(after(.panel, [.settings]) == [.panel] && after(.settings, [.panel]) == [.settings],
              "the panel and Settings replace each other")
    try check(after(.panel, [.welcome]) == [.welcome] && after(.settings, [.welcome]) == [.welcome],
              "during setup, the menu bar icon and Settings bring the welcome window forward")
    try check(after(.panel, [.welcome], pairing: true) == [.panel] && after(.panel, [.settings], pairing: true) == [.panel] &&
              after(.panel, [.panel], pairing: true) == [.panel],
              "a pairing request opens the panel alone, over the welcome window or Settings")

    // Pairing happens in the panel only: the welcome window has no pairing step.
    try check(OnboardingView.steps == 2, "the welcome window asks the role and permissions only; pairing is in the panel")

    // The Mac asked to pair: one sentence, the code, then back to normal.
    var inputs = StatusInputs(connection: ConnectionState(role: .provider))
    inputs.connection.lifecycle = .active; inputs.connection.link = .ready
    inputs.incomingPairing = (peer: "Studio", code: "482193")
    for lang in Lang.allCases {
        try withLanguage(lang) {
            let asked = PanelSnapshot(status: BridgeStatus.derive(inputs), role: .provider, peerName: "Studio")
            let sentences = asked.title.filter { "。.!?！？".contains($0) }.count
            try check(asked.title.contains("Studio") && sentences == 0 && asked.subtitle.isEmpty && asked.formattedCode == "482 193",
                      "\(lang): the approving Mac shows one sentence and the code")
        }
    }
    var request = PanelSnapshot(status: .incomingPairing(peer: "Studio", code: "482193"), role: .provider, peerName: "Studio")
    var outgoing = PanelSnapshot(status: .pairing(code: "482193", message: ""), role: .borrower, peerName: "MacBook")
    outgoing.pairingOutgoing = true
    try check(request.pairingOnCard && outgoing.pairingOnCard && !PanelSnapshot(status: .ready, role: .borrower).pairingOnCard,
              "while a pairing is answered on the card, the list offers no Add or Cancel of its own")
    request.status = .ready
    try check(!request.pairingOnCard, "once answered, the list's actions come back")
    var windows = after(.panel, [.welcome], pairing: true)
    inputs.incomingPairing = nil
    let approved = BridgeStatus.derive(inputs)
    try check(approved == .ready && windows == [.panel], "after Allow the panel goes back to its normal state; no other window opens")

    // The Mac that asked: code in the panel, then back to normal.
    var asking = StatusInputs(connection: ConnectionState(role: .borrower))
    asking.connection.lifecycle = .active; asking.hasPairedDevices = false
    asking.pairingActive = true; asking.pairingCode = "482193"
    windows = after(.panel, [])
    try check(BridgeStatus.derive(asking) == .pairing(code: "482193", message: "") && windows == [.panel],
              "the asking Mac shows the code in the panel")
    asking.pairingActive = false; asking.pairingCode = ""; asking.hasPairedDevices = true
    let paired = BridgeStatus.derive(asking)
    if case .pairing = paired { throw BridgeError("FAIL: pairing ended") }
    try check(windows == [.panel], "when pairing succeeds the asking Mac's panel returns to normal (\(paired))")

    print("Windows: \(count) checks passed")
}
