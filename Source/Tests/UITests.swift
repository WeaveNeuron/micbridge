import Cocoa

/// 0.9.1 interface checks that need AppKit but no window: the icons.
func runUITests() throws {
    var count = 0
    func check(_ condition: Bool, _ description: String) throws {
        guard condition else { throw BridgeError("FAIL: \(description)") }
        count += 1; print("PASS: \(description)")
    }
    /// Fraction of pixels with any opacity, and whether any pixel is
    /// coloured (not grey).
    func coverage(_ image: CGImage) -> (ink: Double, coloured: Bool) {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var ink = 0, coloured = false
        for i in stride(from: 0, to: data.count, by: 4) where data[i + 3] > 0 {
            ink += 1
            if abs(Int(data[i]) - Int(data[i + 2])) > 40 { coloured = true }
        }
        return (Double(ink) / Double(w * h), coloured)
    }

    // App icon: every iconset size draws the tile on the macOS grid.
    for px in [16, 32, 64, 128, 256, 512, 1024] {
        let icon = BrandArt.appIcon(pixels: px)
        let c = coverage(icon)
        try check(icon.width == px && icon.height == px, "app icon renders at \(px) px")
        try check(c.ink > 0.55 && c.ink < 0.85 && c.coloured, "app icon at \(px) px is a coloured tile inside the icon grid")
    }
    // Menu bar: one bridge in every state, as monochrome template images.
    /// The glyph's alpha at 2x (36 × 36 px), top row first.
    func mask(_ state: MenuIconState) -> [UInt8] {
        let px = 36
        var data = [UInt8](repeating: 0, count: px * px * 4)
        let ctx = CGContext(data: &data, width: px, height: px, bitsPerComponent: 8, bytesPerRow: px * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: 2, y: 2)
        MenuIcon.draw(state, in: ctx)
        return stride(from: 3, to: data.count, by: 4).map { data[$0] }
    }
    var seen: [Data] = []
    for state in MenuIconState.allCases {
        let image = MenuIcon.image(state)
        try check(image.isTemplate && image.size == NSSize(width: 18, height: 18), "menu bar icon (\(state)) is an 18 pt template")
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw BridgeError("FAIL: menu bar icon renders") }
        let c = coverage(cg)
        try check(!c.coloured && c.ink > 0.1, "menu bar icon (\(state)) is monochrome")
        seen.append(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) ?? Data())
    }
    try check(Set(seen).count == MenuIconState.allCases.count, "every menu bar state looks different")
    let idle = mask(.idle), paused = mask(.paused), connected = mask(.connected)
    try check(connected.indices.allSatisfy { (paused[$0] > 0 ? connected[$0] > 0 : connected[$0] < 3) } && paused.max()! <= UInt8(255 * MenuIcon.pausedAlpha) + 1 && connected.max()! == 255,
              "paused is the same bridge, only fainter")
    // The open ends are round caps, so allow their antialiased edge.
    try check(idle.indices.allSatisfy { Int(idle[$0]) <= Int(connected[$0]) + 40 } && connected.filter { $0 > 0 }.count > idle.filter { $0 > 0 }.count,
              "not linked leaves only a gap in the cable")
    // The gap is under the microphone, in the middle of the cable.
    let mid = MenuIcon.cablePoint(0.5), row = Int((18 - mid.y) * 2), col = Int(mid.x * 2)
    try check(idle[row * 36 + col] == 0 && connected[row * 36 + col] > 200, "the cable opens in the middle while not linked")
    // The microphone never rises above the towers.
    let topRow = { (m: [UInt8], x0: Int, x1: Int) in (0..<36).first { r in (x0..<x1).contains { m[r * 36 + $0] > 0 } }! }
    try check(topRow(connected, 14, 22) >= topRow(connected, 0, 10), "the microphone stays below the tower tops")
    let ink = idle.filter { $0 > 0 }.count
    try check(ink > 36 * 36 / 10 && ink < 36 * 36 / 2, "the bridge fills the icon without crowding it")
    try check(MenuIconState(.paused) == .paused && MenuIconState(.settingUp) == .idle && MenuIconState(.setup(.microphoneDenied)) == .idle &&
              MenuIconState(.incomingPairing(peer: "Studio", code: "123456")) == .idle,
              "paused is faint; setup, a missing permission and a pairing request read as not linked")
    try check(MenuIconState(.ready) == .connected && MenuIconState(.inUse(.live)) == .connected &&
              MenuIconState(.searching(longWait: false)) == .idle && MenuIconState(.noPairedDevices) == .idle && MenuIconState(.connecting) == .idle,
              "connected closes the cable; searching and connecting leave it open")
    print("UI: \(count) checks passed")
}

/// Settings › Permissions and onboarding: which rows, in what state, with
/// which action. No window and no real permission is touched.
func runPermissionTests() throws {
    var count = 0
    func check(_ condition: Bool, _ description: String) throws {
        guard condition else { throw BridgeError("FAIL: \(description)") }
        count += 1; print("PASS: \(description)")
    }
    func item(_ items: [PermissionItem], _ kind: PermissionItem.Kind) -> PermissionItem? { items.first { $0.kind == kind } }
    let fresh = PermissionFacts(microphone: .notAsked, localNetwork: .unknown, loginItem: .off)

    // Provider on a fresh Mac: the microphone is needed and asked from the row.
    var rows = PermissionList.items(role: .provider, facts: PermissionFacts(microphone: .notAsked, localNetwork: .unknown, firewall: .off), driver: .notInstalled)
    try check(rows.map(\.kind) == [.microphone, .localNetwork, .virtualMicrophone, .firewall], "a sharing Mac lists the microphone first, the firewall last")
    try check(item(rows, .microphone)?.state == .needed && item(rows, .microphone)?.action == .requestMicrophone, "an unasked microphone offers Allow")
    try check(item(rows, .virtualMicrophone)?.state == .optional, "a sharing Mac doesn't need the virtual microphone")
    try check(item(rows, .localNetwork)?.state == .optional && item(rows, .localNetwork)?.action == nil, "unknown Local Network shows a hint, no button")

    // Denied: the row says so and opens the exact System Settings pane.
    rows = PermissionList.items(role: .provider, facts: PermissionFacts(microphone: .denied, localNetwork: .denied), driver: .ready)
    try check(item(rows, .microphone)?.state == .denied && item(rows, .microphone)?.action == .openPrivacy("Privacy_Microphone"), "a denied microphone opens Privacy › Microphone")
    try check(item(rows, .localNetwork)?.state == .denied && item(rows, .localNetwork)?.action == .openPrivacy("Privacy_LocalNetwork"), "a blocked network opens Privacy › Local Network")
    try check(PermissionList.settingsURL("Privacy_Microphone").absoluteString == "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone", "the System Settings link names the pane")

    // Borrower: the driver first.
    rows = PermissionList.items(role: .borrower, facts: fresh, driver: .notInstalled)
    try check(rows.first?.kind == .virtualMicrophone && rows.first?.state == .needed && rows.first?.action == .installDriver, "a using Mac without a virtual microphone offers Install")
    try check(item(rows, .microphone)?.state == .optional, "a using Mac doesn't need microphone access")
    let outdated = PermissionList.items(role: .borrower, facts: fresh, driver: .outdated(installed: "90000")).first
    try check(outdated?.action == .installDriver && outdated?.actionTitle == DriverStatus.outdated(installed: "90000").installTitle, "an old driver offers Update")
    try check(PermissionList.items(role: .borrower, facts: fresh, driver: .ready).first?.state == .ready, "an installed driver is ready")
    try check(PermissionList.essentials(role: .borrower, facts: fresh, driver: .ready).map(\.kind) == [.virtualMicrophone, .localNetwork], "onboarding asks a using Mac about the driver and network only")
    try check(PermissionList.essentials(role: .provider, facts: fresh, driver: .ready).map(\.kind) == [.microphone, .localNetwork], "onboarding asks a sharing Mac about the microphone and network only")

    // The firewall: a row only speaks up when it blocks MicBridge.
    for role in [Role.provider, .borrower] {
        try check(item(PermissionList.items(role: role, facts: PermissionFacts(firewall: .unknown), driver: .ready), .firewall) == nil,
                  "\(role): no firewall row until it has been read")
    }
    for (state, expected, action) in [(FirewallState.off, PermissionItem.State.ready, PermissionItem.Action?.none), (.allows, .ready, nil),
                                      (.blocksApp, .denied, .openFirewall), (.blocksAll, .denied, .openFirewall)] {
        for role in [Role.provider, .borrower] {
            let row = item(PermissionList.items(role: role, facts: PermissionFacts(firewall: state), driver: .ready), .firewall)
            try check(row?.state == expected && row?.action == action && (expected == .denied) == !(row?.detail.isEmpty ?? true),
                      "\(role) firewall \(state): \(expected), \(action.map { "\($0)" } ?? "no button")")
        }
    }
    try check(!PermissionList.essentials(role: .borrower, facts: PermissionFacts(firewall: .blocksApp), driver: .ready).contains { $0.kind == .firewall },
              "onboarding never asks about the firewall")
    try check(PermissionList.firewallURL.absoluteString == "x-apple.systempreferences:com.apple.Network-Settings.extension?Firewall",
              "the firewall link opens System Settings › Network (the Firewall anchor, where a system honours it)")
    for lang in Lang.allCases {
        let (title, rowTitle) = withLanguage(lang) {
            (PermissionList.firewallActionTitle,
             item(PermissionList.items(role: .provider, facts: PermissionFacts(firewall: .blocksApp), driver: .ready), .firewall)?.actionTitle)
        }
        let path = lang == .zh ? ["网络", "防火墙"] : ["Network", "Firewall"]
        try check(title.contains(" › ") && path.allSatisfy(title.contains) && title.count <= 28 && rowTitle == title,
                  "\(lang): the firewall button names the path, Network › Firewall (\(title))")
    }

    // Local Network is inferred.
    try check(PermissionList.localNetwork(blocked: true, connected: true, foundNearby: true) == .denied, "a reported block wins")
    try check(PermissionList.localNetwork(blocked: false, connected: false, foundNearby: true) == .granted, "finding a Mac nearby proves access")
    try check(PermissionList.localNetwork(blocked: false, connected: false, foundNearby: false) == .unknown, "nothing found yet is unknown")

    // Copy: one short sentence each, in both languages.
    for lang in [Lang.zh, .en] {
        Lang.override = lang
        for role in [Role.provider, .borrower] {
            for facts in [fresh, PermissionFacts(microphone: .denied, localNetwork: .denied, firewall: .blocksApp), PermissionFacts(microphone: .granted, localNetwork: .granted)] {
                for row in PermissionList.items(role: role, facts: facts, driver: .notInstalled) {
                    let sentences = row.detail.filter { "。.".contains($0) }.count
                    try check(sentences <= 1 && row.detail.count <= (lang == .zh ? 20 : 48), "\(lang) \(role) \(row.kind) detail is one short sentence")
                }
            }
        }
    }
    // Every status line in the panel: one sentence, in both languages.
    let statuses: [BridgeStatus] = [
        .sleeping, .incomingPairing(peer: "Studio", code: "482193"), .paused, .settingUp, .waitingForKeychain,
        .pairing(code: "482193", message: ""), .pairing(code: "", message: ""), .inUse(.activating), .inUse(.live), .inUse(.finishing),
        .ready, .noPairedDevices, .localNetworkBlocked, .peerBusy, .roleConflict, .peerPaused, .peerAsleep, .peerAppClosed,
        .connecting, .searching(longWait: false), .searching(longWait: true),
        .setup(.microphoneDenied), .setup(.noMicrophone), .setup(.noVirtualMicrophone), .setup(.virtualMicrophoneTimeout),
    ]
    for lang in [Lang.zh, .en] {
        Lang.override = lang
        for role in [Role.provider, .borrower] {
            for waiting in [false, true] {
                let context = CopyContext(role: role, peer: "MacBook", client: "Notes", device: "MicBridge Microphone", defaultInput: !waiting, waiting: waiting)
                for status in statuses {
                    let line = StatusCopy.subtitle(status, context)
                    let stops = lang == .zh ? line.filter { $0 == "。" }.count : line.components(separatedBy: ". ").count - 1 + (line.hasSuffix(".") ? 1 : 0)
                    guard stops <= 1 else { throw BridgeError("FAIL: \(lang) \(role) \(status) subtitle is one sentence: \(line)") }
                }
            }
        }
    }
    try check(true, "every panel status line is one sentence in both languages")
    Lang.override = .zh
    print("Permissions: \(count) checks passed")
}
