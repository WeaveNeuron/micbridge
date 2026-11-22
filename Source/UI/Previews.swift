import Cocoa
import SwiftUI

/// Panel states for the preview build and `--render-previews`. Names are
/// neutral examples ("Studio", "MacBook"), never real machines.
enum PreviewFixtures {
    /// Which device list a fixture shows.
    enum Devices { case none, nearby, one, four, twins }
    struct Fixture {
        var slug: String
        var zh: String
        var en: String
        var role: Role
        var status: BridgeStatus
        var micActive = false
        var devices = Devices.one
        var driver = DriverStatus.ready
        var firewall = FirewallState.off
        var label: String { tr(zh, en) }
    }
    static let all: [Fixture] = [
        Fixture(slug: "borrower-ready", zh: "使用方 · 已连接", en: "Using · connected", role: .borrower, status: .ready),
        Fixture(slug: "borrower-in-use", zh: "使用方 · 收音中", en: "Using · listening", role: .borrower, status: .inUse(.live), micActive: true),
        Fixture(slug: "borrower-four-macs", zh: "使用方 · 4 台 Mac", en: "Using · four Macs", role: .borrower, status: .inUse(.live), micActive: true, devices: .four),
        Fixture(slug: "borrower-same-name", zh: "使用方 · 两台同名 Mac", en: "Using · two Macs, one name", role: .borrower, status: .ready, devices: .twins),
        Fixture(slug: "borrower-activating", zh: "使用方 · 正在打开", en: "Using · turning on", role: .borrower, status: .inUse(.activating)),
        Fixture(slug: "borrower-searching", zh: "使用方 · 等待", en: "Using · waiting", role: .borrower, status: .searching(longWait: false)),
        Fixture(slug: "first-run-setting-up", zh: "首次 · 设置中", en: "First run · setting up", role: .borrower, status: .settingUp, devices: .none),
        Fixture(slug: "first-run-empty", zh: "首次 · 附近没有 Mac", en: "First run · nothing nearby", role: .borrower, status: .noPairedDevices, devices: .none),
        Fixture(slug: "first-run-nearby", zh: "首次 · 附近有 Mac", en: "First run · a Mac nearby", role: .borrower, status: .noPairedDevices, devices: .nearby),
        Fixture(slug: "pairing-outgoing", zh: "正在添加", en: "Adding a Mac", role: .borrower, status: .pairing(code: "482193", message: ""), devices: .nearby),
        Fixture(slug: "pairing-incoming", zh: "配对请求", en: "Pairing request", role: .provider, status: .incomingPairing(peer: "Studio", code: "482193"), devices: .nearby),
        Fixture(slug: "borrower-no-virtual-mic", zh: "使用方 · 没有虚拟麦克风", en: "Using · no virtual microphone", role: .borrower, status: .setup(.noVirtualMicrophone), driver: .notInstalled),
        Fixture(slug: "borrower-driver-update", zh: "使用方 · 需要更新驱动", en: "Using · driver update needed", role: .borrower, status: .setup(.noVirtualMicrophone), driver: .outdated(installed: "90000")),
        Fixture(slug: "borrower-driver-reload", zh: "使用方 · 驱动未加载", en: "Using · driver not loaded", role: .borrower, status: .setup(.noVirtualMicrophone), driver: .installedNotLoaded),
        Fixture(slug: "provider-ready", zh: "提供方 · 已连接", en: "Sharing · connected", role: .provider, status: .ready),
        Fixture(slug: "provider-in-use", zh: "提供方 · 收音中", en: "Sharing · listening", role: .provider, status: .inUse(.live), micActive: true),
        Fixture(slug: "provider-four-macs", zh: "提供方 · 4 台 Mac", en: "Sharing · four Macs", role: .provider, status: .ready, devices: .four),
        Fixture(slug: "provider-connecting", zh: "提供方 · 正在连接", en: "Sharing · connecting", role: .provider, status: .connecting),
        Fixture(slug: "provider-searching-long", zh: "提供方 · 仍未找到", en: "Sharing · still looking", role: .provider, status: .searching(longWait: true)),
        Fixture(slug: "provider-firewall", zh: "提供方 · 防火墙拦截", en: "Sharing · firewall blocks", role: .provider, status: .searching(longWait: true), firewall: .blocksApp),
        Fixture(slug: "provider-network-blocked", zh: "提供方 · 本地网络被拦截", en: "Sharing · local network blocked", role: .provider, status: .localNetworkBlocked),
        Fixture(slug: "provider-peer-busy", zh: "提供方 · 对方正忙", en: "Sharing · other Mac busy", role: .provider, status: .peerBusy),
        Fixture(slug: "borrower-peer-app-closed", zh: "使用方 · 对方未打开 App", en: "Using · app closed there", role: .borrower, status: .peerAppClosed),
        Fixture(slug: "borrower-peer-paused", zh: "使用方 · 对方已暂停", en: "Using · other Mac paused", role: .borrower, status: .peerPaused),
        Fixture(slug: "borrower-peer-asleep", zh: "使用方 · 对方在睡眠", en: "Using · other Mac asleep", role: .borrower, status: .peerAsleep),
        Fixture(slug: "borrower-role-conflict", zh: "使用方 · 角色冲突", en: "Using · both using", role: .borrower, status: .roleConflict),
        Fixture(slug: "keychain", zh: "等待钥匙串授权", en: "Waiting for Keychain", role: .provider, status: .waitingForKeychain),
        Fixture(slug: "provider-mic-denied", zh: "需要麦克风权限", en: "Microphone not allowed", role: .provider, status: .setup(.microphoneDenied)),
        Fixture(slug: "paused", zh: "已暂停", en: "Paused", role: .provider, status: .paused),
        Fixture(slug: "sleeping", zh: "已休眠", en: "Asleep", role: .borrower, status: .sleeping),
    ]
}

private struct PreviewMac { var id: String; var name: String; var model: String }
private let studio = PreviewMac(id: "preview-studio", name: "Studio", model: "Mac Studio (2023)")
private let laptop = PreviewMac(id: "3f2a8c51e07d94b6a2c1", name: "MacBook", model: "MacBook Pro (14-inch, 2023)")
private let mini = PreviewMac(id: "preview-mini", name: "Mac mini", model: "Mac mini (2024)")
private let air = PreviewMac(id: "preview-air", name: "MacBook Air", model: "MacBook Air (13-inch, M3, 2024)")
private let imac = PreviewMac(id: "preview-imac", name: "iMac", model: "iMac (24-inch, 2023)")

/// The snapshot a fixture shows, shared by the preview app and the renderer.
func previewSnapshot(_ f: PreviewFixtures.Fixture) -> PanelSnapshot {
    let live = f.status.isLive
    let local = f.role == .borrower ? studio : laptop
    let peer = f.role == .borrower ? laptop : studio
    let peerMode: PeerMode = f.role == .borrower ? .provider : .borrower
    func row(_ mac: PreviewMac, _ state: DeviceRow.State, mode: PeerMode?, paired: Bool = true) -> DeviceRow {
        var row = DeviceRow(id: mac.id, name: mac.name, model: mac.model, mode: mode, state: state, paired: paired)
        row.isCurrent = state == .connected
        row.micInUse = row.isCurrent && f.micActive
        if f.role == .borrower && paired { row.canUse = mode != .borrower }
        return row
    }

    var mine: [DeviceRow] = [], nearby: [DeviceRow] = []
    switch f.devices {
    case .none: break
    case .nearby:
        let state: DeviceRow.State
        switch f.status { case .pairing, .incomingPairing: state = .pairing; default: state = .online }
        nearby = [row(peer, state, mode: f.status == .noPairedDevices || f.role == .borrower ? .provider : .borrower, paired: false)]
    case .one:
        let state: DeviceRow.State
        var mode: PeerMode? = peerMode
        switch f.status {
        case .ready, .inUse: state = .connected
        case .peerBusy: state = .busy
        case .peerPaused: state = .paused; mode = .paused
        case .peerAsleep, .sleeping: state = .asleep
        case .peerAppClosed: state = .appClosed
        case .connecting, .waitingForKeychain, .paused: state = .online
        case .roleConflict: state = .online; mode = f.role == .borrower ? .borrower : .provider
        default: state = .offline
        }
        var only = row(peer, state, mode: mode)
        only.isChosen = only.canUse
        mine = [only]
    case .four:
        if f.role == .borrower {
            var current = row(laptop, .connected, mode: .provider); current.isChosen = true
            mine = [current, row(mini, .online, mode: .provider), row(air, .asleep, mode: .provider), row(imac, .appClosed, mode: .borrower)]
            nearby = [row(PreviewMac(id: "preview-pro", name: "Mac Pro", model: "Mac Pro (2023)"), .online, mode: .provider, paired: false)]
        } else {
            mine = [row(studio, .connected, mode: .borrower), row(mini, .online, mode: .borrower), row(air, .busy, mode: .borrower), row(imac, .offline, mode: nil)]
        }
    case .twins:
        // Two Macs called "MacBook", same model: told apart by device code.
        var current = row(laptop, .connected, mode: .provider); current.isChosen = true
        let twin = PreviewMac(id: "c71b09e4d2a85f3b6e10", name: "MacBook", model: laptop.model)
        mine = [current]
        nearby = [row(twin, .online, mode: .provider, paired: false)]
    }
    let tagged = DeviceList.disambiguate(mine + nearby, localName: local.name, localModel: local.model)
    mine = Array(tagged.prefix(mine.count)); nearby = Array(tagged.dropFirst(mine.count))
    let peerLabel = (mine + nearby).first { $0.name == peer.name && $0.isCurrent }?.label ?? peer.name

    let outgoing: Bool = { if case .pairing = f.status { return true }; return false }()
    return PanelSnapshot(
        status: f.status, role: f.role, enabled: f.status != .paused && f.status != .settingUp, connected: live,
        micActive: f.micActive, level: f.micActive ? 0.42 : 0,
        localName: local.name, localModel: local.model,
        peerName: peerLabel, peerModel: peer.model,
        pairingOutgoing: outgoing, mine: mine, nearby: nearby, browsing: true,
        device: f.role == .borrower ? "MicBridge Microphone" : tr("内置麦克风", "Built-in Microphone"),
        peerVersion: live ? bridgeVersion : "", route: tr("有线", "Wired"),
        client: tr("备忘录", "Notes"), defaultInput: true,
        permissions: PermissionFacts(microphone: .granted, localNetwork: .granted, loginItem: .on, firewall: f.firewall), customName: "", computerName: local.name, localCode: "5D0E",
        driver: f.driver, driverVersion: f.driver == .ready ? bridgeVersion : "", preview: true)
}

/// `MicBridge --render-previews <dir>`: renders every fixture's panel in
/// both languages and both appearances, plus Settings and onboarding, to
/// PNG files off screen. No window, audio or network.
@MainActor
func renderPreviews(to directory: URL) throws {
    _ = NSApplication.shared
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let model = BridgeUIModel()
    model.onScreen = false
    let languages: [Lang] = [.zh, .en]
    let schemes: [(String, ColorScheme)] = [("light", .light), ("dark", .dark)]
    defer { Lang.override = nil }

    /// The panel, on the menu's colour (materials need a real window
    /// behind them). Drawn through AppKit too, for its switch.
    func write<V: View>(_ view: V, _ name: String, scheme: ColorScheme) throws {
        try writeAppKit(view, name, scheme: scheme,
                        background: Color(nsColor: scheme == .dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.95, alpha: 1)))
    }

    /// Forms and switches are AppKit underneath, which ImageRenderer cannot
    /// draw: lay the view out in a window that is never shown and cache it.
    func writeAppKit<V: View>(_ view: V, _ name: String, scheme: ColorScheme, background: Color = Color(nsColor: .windowBackgroundColor)) throws {
        let hosting = NSHostingView(rootView: view.background(background).environment(\.colorScheme, scheme))
        hosting.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = hosting.appearance
        window.contentView = hosting
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw BridgeError("Could not render \(name)") }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name + ".png"))
        window.contentView = nil
    }

    for language in languages {
        Lang.override = language
        for (index, fixture) in PreviewFixtures.all.enumerated() {
            model.snapshot = previewSnapshot(fixture)
            for (suffix, scheme) in schemes {
                try write(PanelView(model: model).fixedSize(horizontal: false, vertical: true),
                          String(format: "panel-%02d-%@-%@-%@", index, fixture.slug, language.rawValue, suffix), scheme: scheme)
            }
        }
        model.snapshot = previewSnapshot(PreviewFixtures.all[0])
        model.audioDevices = [DeviceChoice(id: "preview", name: model.snapshot.device)]
        for tab in SettingsTab.allCases {
            for (suffix, scheme) in schemes {
                try writeAppKit(SettingsPage(tab: tab, model: model), "settings-\(tab.rawValue + 1)-\(tab)-\(language.rawValue)-\(suffix)", scheme: scheme)
            }
        }
        // A fresh Mac that shares its microphone: nothing allowed or
        // installed yet, and a denial.
        model.snapshot = previewSnapshot(PreviewFixtures.all.first { $0.slug == "provider-ready" } ?? PreviewFixtures.all[0])
        model.audioDevices = [DeviceChoice(id: "preview", name: tr("MacBook 麦克风", "MacBook Microphone"))]
        model.snapshot.driver = .notInstalled; model.snapshot.driverVersion = ""
        model.snapshot.permissions = PermissionFacts(microphone: .denied, localNetwork: .unknown, loginItem: .needsApproval, firewall: .blocksApp)
        for tab in [SettingsTab.general, .permissions, .advanced] {
            for (suffix, scheme) in schemes {
                try writeAppKit(SettingsPage(tab: tab, model: model), "settings-\(tab.rawValue + 1)-\(tab)-needs-\(language.rawValue)-\(suffix)", scheme: scheme)
            }
        }
        let first = PreviewFixtures.all.firstIndex { $0.slug == "first-run-nearby" } ?? 0
        model.snapshot = previewSnapshot(PreviewFixtures.all[first])
        model.snapshot.permissions = PermissionFacts(microphone: .notAsked, localNetwork: .unknown, loginItem: .off)
        for step in 0..<OnboardingView.steps {
            for (suffix, scheme) in schemes {
                try writeAppKit(OnboardingView(model: model, suggested: .borrower, step: step),
                          "onboarding-\(step + 1)-\(language.rawValue)-\(suffix)", scheme: scheme)
            }
        }
        // The permissions step on a Mac without any virtual microphone, and
        // on a Mac that shares its microphone (not asked yet).
        model.snapshot.driver = .notInstalled
        for (suffix, scheme) in schemes {
            try writeAppKit(OnboardingView(model: model, suggested: .borrower, step: 1), "onboarding-2-install-\(language.rawValue)-\(suffix)", scheme: scheme)
            try writeAppKit(OnboardingView(model: model, suggested: .provider, step: 1), "onboarding-2-provider-\(language.rawValue)-\(suffix)", scheme: scheme)
        }

        // The borrower's actionable driver states in Settings and onboarding.
        for (slug, driver) in [("install", DriverStatus.notInstalled), ("update", .outdated(installed: "90000")), ("reload", .installedNotLoaded)] {
            model.snapshot.role = .borrower
            model.snapshot.enabled = true; model.snapshot.status = .setup(.noVirtualMicrophone)
            model.snapshot.driver = driver; model.snapshot.driverVersion = driver.isInstalled ? "0.9.0" : ""
            for (suffix, scheme) in schemes {
                for tab in [SettingsTab.general, .permissions, .advanced] {
                    try writeAppKit(SettingsPage(tab: tab, model: model), "driver-\(slug)-\(tab)-\(language.rawValue)-\(suffix)", scheme: scheme)
                }
                try writeAppKit(OnboardingView(model: model, suggested: .borrower, step: 1), "driver-\(slug)-onboarding-\(language.rawValue)-\(suffix)", scheme: scheme)
            }
        }
        print("rendered \(language.rawValue)")
    }
}
