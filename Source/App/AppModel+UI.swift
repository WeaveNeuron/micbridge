import Cocoa
import SwiftUI
import AVFoundation

/// The menu bar item, its panel, Settings and onboarding.
extension AppModel {
    static let onboardingKey = "onboardingDone.v8"

    func buildUI() {
        let menu = NSMenu()
        menuStatus = menu.addItem(withTitle: "", action: nil, keyEquivalent: ""); menuStatus.isEnabled = false
        menu.addItem(.separator())
        menuToggle = menu.addItem(withTitle: "", action: #selector(toggleEnabled), keyEquivalent: ""); menuToggle.target = self
        let settings = menu.addItem(withTitle: tr("设置…", "Settings…"), action: #selector(showSettings), keyEquivalent: ","); settings.target = self
        let about = menu.addItem(withTitle: tr("关于 MicBridge", "About MicBridge"), action: #selector(openAbout), keyEquivalent: ""); about.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: tr("退出 MicBridge", "Quit MicBridge"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menuBar = MenuBarController(model: ui, menu: menu)
        menuBar.onVisibilityChange = { [weak self] _ in self?.syncUI() }
        menuBar.onOpen = { [weak self] in self?.showPanel() }
        if previewMode { menuBar.item.button?.toolTip = "MicBridge Preview" }

        // Copy and paste in Settings' text fields (an accessory app has no menu bar of its own).
        let main = NSMenu(), application = NSMenuItem(), edit = NSMenuItem(title: tr("编辑", "Edit"), action: nil, keyEquivalent: "")
        application.submenu = NSMenu()
        application.submenu?.addItem(withTitle: tr("关闭窗口", "Close Window"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        application.submenu?.addItem(withTitle: tr("退出 MicBridge", "Quit MicBridge"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(application); edit.submenu = NSMenu(title: tr("编辑", "Edit"))
        for (title, action, key) in [(tr("剪切", "Cut"), #selector(NSText.cut(_:)), "x"), (tr("复制", "Copy"), #selector(NSText.copy(_:)), "c"),
                                     (tr("粘贴", "Paste"), #selector(NSText.paste(_:)), "v"), (tr("全选", "Select All"), #selector(NSText.selectAll(_:)), "a")] {
            edit.submenu?.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        main.addItem(edit); NSApp.mainMenu = main

        wireActions()
        if !previewMode {
            refreshDevices()
            firewall.onChange = { [weak self] in self?.syncUI(force: true) }
            firewall.refresh()
        }
        updateUI()
    }

    private func wireActions() {
        // In the preview build nothing touches audio, the network or the keychain.
        func live(_ action: @escaping (AppModel) -> Void) -> () -> Void {
            { [weak self] in
                guard let self else { return }
                if self.previewMode { self.ui.notify(tr("预览模式：不执行操作", "Preview: nothing happens")) } else { action(self) }
            }
        }
        ui.setMode = { [weak self] mode in
            guard let self else { return }
            if self.previewMode { self.previewSetMode(mode) } else { self.setMode(mode) }
        }
        ui.retry = { [weak self] in self?.previewMode == true ? self?.previewSetMode(self?.ui.snapshot.role == .provider ? .provider : .borrower) : self?.restartEnabled() }
        ui.approve = { [weak self] in self?.previewMode == true ? self?.previewPaired() : self?.approvePairing() }
        ui.reject = { [weak self] in self?.previewMode == true ? self?.previewShow("first-run-nearby") : self?.rejectPairing() }
        ui.cancelPairing = { [weak self] in self?.previewMode == true ? self?.previewShow("first-run-nearby") : self?.cancelPairing() }
        ui.pair = { [weak self] id in self?.previewMode == true ? self?.previewPair() : self?.pair(with: id) }
        ui.useProvider = { id in live { $0.useProvider(id) }() }
        ui.rename = { [weak self] id in self?.promptRename(id) }
        ui.forget = { [weak self] id in self?.confirmForget(id) }
        ui.selectDevice = { [weak self] uid in
            guard let self, !self.previewMode else { return }
            self.chooseDevice(uid: uid)
        }
        ui.refreshDevices = { [weak self] in
            guard let self, !self.previewMode else { return }
            self.refreshDevices(); self.syncUI()
        }
        ui.pairManually = { text in live { $0.pairManually(text) }() }
        ui.copyPairing = live { $0.copyPairing() }
        ui.copyDiagnostics = { [weak self] in self?.copyDiagnostics() }
        ui.makeDefaultInput = live { $0.makeDefaultInput() }
        ui.setLaunchAtLogin = { [weak self] on in
            guard let self else { return }
            if self.previewMode { self.ui.notify(tr("预览模式：不更改登录项", "Preview: login items unchanged")); return }
            if !LoginItem.set(on) { self.ui.notify(tr("无法更改登录项，请在系统设置中查看。", "Couldn’t change the login item. Check System Settings.")) }
            self.syncUI(force: true)
        }
        ui.setLocalName = { [weak self] name in
            guard let self, !self.previewMode else { return }
            self.setLocalName(name)
        }
        ui.openPrivacy = { pane in live { _ in NSWorkspace.shared.open(PermissionList.settingsURL(pane)) }() }
        ui.openLoginItems = live { _ in LoginItem.openSystemSettings() }
        ui.openFirewall = { NSWorkspace.shared.open(PermissionList.firewallURL) }
        ui.openSettings = { [weak self] tab in self?.openSettings(tab) }
        ui.quit = { NSApp.terminate(nil) }
        ui.finishOnboarding = { [weak self] launchAtLogin in self?.finishOnboarding(launchAtLogin: launchAtLogin) }
        ui.requestMicrophone = { [weak self] done in
            if self?.previewMode == true { self?.ui.snapshot.permissions.microphone = .granted; done(true); return }
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { done(granted); self?.syncUI(force: true) }
            }
        }
        ui.previewScenario = { [weak self] index in self?.showPreview(index) }
        ui.installDriver = { [weak self] in self?.previewMode == true ? self?.previewInstallDriver() : self?.runDriverAction(.install) }
        ui.uninstallDriver = live { $0.runDriverAction(.uninstall) }
    }

    // MARK: Windows

    /// Every window opens through here, so MicBridge shows one at a time
    /// (`WindowPolicy`).
    func present(_ request: AppWindow, tab: SettingsTab? = nil, pairingRequest: Bool = false) {
        let plan = WindowPolicy.resolve(request, open: openWindows, pairingRequest: pairingRequest)
        for window in plan.close { dismiss(window) }
        switch plan.show {
        case .panel:
            menuBar.open()
            syncUI(force: true)
        case .settings:
            if settingsController == nil { settingsController = SettingsWindowController(model: ui) }
            syncUI(force: true)
            NSApp.activate(ignoringOtherApps: true)
            settingsController?.show(tab)
        case .welcome:
            NSApp.activate(ignoringOtherApps: true)
            onboardingWindow?.makeKeyAndOrderFront(nil)
        }
    }
    var openWindows: Set<AppWindow> {
        var open: Set<AppWindow> = []
        if menuBar.isOpen { open.insert(.panel) }
        if settingsWindow?.isVisible == true { open.insert(.settings) }
        if onboardingWindow != nil { open.insert(.welcome) }
        return open
    }
    private func dismiss(_ window: AppWindow) {
        switch window {
        case .panel: menuBar.close()
        case .settings: settingsWindow?.orderOut(nil)
        case .welcome:
            // Only a pairing request closes it: setup ends as if closed.
            let welcome = onboardingWindow
            endOnboarding()
            welcome?.close()
        }
    }
    @objc func showPanel() { present(.panel) }
    @objc func showSettings() { openSettings(nil) }
    @objc func openAbout() { openSettings(.about) }
    func openSettings(_ tab: SettingsTab?) { present(.settings, tab: tab) }
    /// First launch only: nothing paired and never set up.
    var needsOnboarding: Bool {
        !previewMode && !defaults.bool(forKey: Self.onboardingKey) && peers.devices.isEmpty
    }
    func showOnboarding() {
        let view = OnboardingView(model: ui, suggested: role, step: 0)
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = tr("欢迎使用 MicBridge", "Welcome to MicBridge")
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            // Closing it counts as done; everything is in the panel and Settings.
            self?.endOnboarding()
        }
        menuBar.close(); settingsWindow?.orderOut(nil)
        onboardingWindow = window
        present(.welcome)
        syncUI(force: true)
    }
    func finishOnboarding(launchAtLogin: Bool) {
        defaults.set(true, forKey: Self.onboardingKey)
        if previewMode {
            ui.snapshot.permissions.loginItem = launchAtLogin ? .on : .off
            onboardingWindow?.close(); previewFinishOnboarding(); return
        }
        if launchAtLogin { LoginItem.set(true) }
        let window = onboardingWindow
        endOnboarding()
        window?.close()
        showPanel()
    }
    /// The welcome window is done, finished or closed: run in the role it
    /// left (the suggested one if it closed on the first step). Runs once.
    func endOnboarding() {
        guard onboardingWindow != nil else { return }
        onboardingWindow = nil
        // The preview build only pretends; it never starts the bridge.
        guard !previewMode else { return }
        defaults.set(true, forKey: Self.onboardingKey)
        if !enabled { setMode(role == .provider ? .provider : .borrower) } else { syncUI(force: true) }
    }

    func promptRename(_ id: String) {
        guard let device = previewMode ? PairedDevice(id: id, name: ui.snapshot.mine.first { $0.id == id }?.name) : peers.device(id) else { return }
        let alert = NSAlert()
        alert.messageText = tr("重命名“\(device.displayName)”", "Rename “\(device.displayName)”")
        alert.informativeText = tr("只在这台 Mac 上显示，留空则使用原名。", "Shown on this Mac only. Leave it empty to use its own name.")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = device.alias ?? ""
        field.placeholderString = device.name ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: tr("重命名", "Rename"))
        alert.addButton(withTitle: tr("取消", "Cancel"))
        alert.window.initialFirstResponder = field
        guard runAlert(alert), !previewMode else { return }
        rename(id, to: field.stringValue)
    }
    func confirmForget(_ id: String) {
        let name = previewMode ? ui.snapshot.mine.first { $0.id == id }?.name ?? "" : peers.device(id)?.displayName ?? ""
        let alert = NSAlert()
        alert.messageText = tr("移除“\(name)”？", "Remove “\(name)”?")
        alert.informativeText = tr("之后可以在“附近”中重新添加。", "You can add it again from Nearby.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: tr("移除", "Remove")).hasDestructiveAction = true
        alert.addButton(withTitle: tr("取消", "Cancel"))
        guard runAlert(alert), !previewMode else { return }
        forget(id)
    }
    /// The panel floats above alerts, so it steps aside while one is up and
    /// comes back afterwards. True for the first button.
    func runAlert(_ alert: NSAlert) -> Bool {
        let reopen = menuBar.isOpen
        menuBar.close()
        NSApp.activate(ignoringOtherApps: true)
        let confirmed = alert.runModal() == .alertFirstButtonReturn
        if reopen { DispatchQueue.main.async { [weak self] in self?.showPanel() } }
        return confirmed
    }

    // MARK: State → views

    var micActive: Bool { role == .borrower ? borrower.peerMicRunning : provider.micActive }
    var capturing: Bool { role == .borrower ? borrower.capturing : provider.session != nil }

    func updateUI() {
        guard menuBar != nil else { return }
        menuBar.item.button?.setAccessibilityLabel(capturing ? tr("MicBridge 正在收音", "MicBridge is listening") : "MicBridge")
        syncUI()
    }
    func currentStatus() -> BridgeStatus {
        let inputs = StatusInputs(
            connection: state, stopReason: stopReason,
            incomingPairing: incomingPair ? (incomingLabel, incomingCode) : nil,
            pairingCode: pairCode, pairingMessage: pairMessage,
            captureRequested: role == .borrower ? borrower.voice != nil : provider.session != nil,
            captureFinishing: role == .borrower ? borrower.finishing : provider.stopping,
            micActive: micActive, keychainPending: vault.isWaiting(now: now), peer: peerAvailability,
            pairingActive: pairTarget != nil, hasPairedDevices: !peers.devices.isEmpty, settingUp: onboardingWindow != nil)
        return debouncer.update(BridgeStatus.derive(inputs), now: now)
    }
    var anyWindowShown: Bool {
        menuBar.isOpen || settingsWindow?.isVisible == true || onboardingWindow?.isVisible == true
    }
    func syncUI(force: Bool = false) {
        guard !previewMode, menuBar != nil else { return }
        let status = currentStatus()
        // Menu text is cheap and always current; SwiftUI only refreshes
        // while one of the windows is on screen.
        updateMenuText(status)
        // One bridge in every state; paused is drawn faint by the icon
        // itself, and before setup is done it is not paused at all.
        let icon = MenuIconState(status)
        if icon != menuIcon { menuIcon = icon; menuBar.item.button?.image = MenuIcon.image(icon) }
        let shown = anyWindowShown
        if ui.onScreen != shown { ui.onScreen = shown }
        guard shown || force else { return }
        firewall.refresh()
        let next = snapshot(status)
        if ui.snapshot != next { ui.snapshot = next }
    }
    func snapshot(_ status: BridgeStatus) -> PanelSnapshot {
        let record = peer
        let savedUID = role == .provider ? defaults.string(forKey: deviceKey) ?? "" : ""
        let level = role == .borrower ? borrower.level : provider.level
        let inputs = DeviceList.Inputs(role: role, devices: peers.devices, keys: vault.peerKeys.map { Set($0.keys) }, presence: presence,
                                       nearby: browser.services, linked: linkedDevice,
                                       preferred: defaults.string(forKey: Self.preferredProviderKey),
                                       micActive: micActive, localID: deviceID,
                                       pairing: pairTarget ?? (incomingPair ? incomingRequest?.device : nil))
        let outgoing = pairTarget != nil
        let groups = DeviceList.groups(inputs, localName: localName, localModel: DeviceIdentity.model)
        let peerLabel = outgoing && !pairPeer.isEmpty ? pairLabel(groups.nearby) : rowLabel(record, groups.mine)
        return PanelSnapshot(
            status: status, role: role, enabled: enabled, connected: state.isReady,
            micActive: micActive, level: (level * 40).rounded() / 40,
            localName: localName, localModel: DeviceIdentity.model,
            peerName: peerLabel, peerModel: record.model ?? "",
            pairingOutgoing: outgoing,
            mine: groups.mine, nearby: groups.nearby, browsing: browser.isRunning,
            device: selectedDevice?.name ?? "", deviceUID: devices.contains { $0.uid == savedUID } ? savedUID : "",
            peerVersion: peerVersion, route: link.routeLabel,
            client: borrower.demand.clientName, waiting: borrower.demandWaitingSince != nil,
            defaultInput: role == .provider || borrower.isDefaultInput,
            permissions: permissionFacts, customName: DeviceIdentity.customName ?? "", computerName: DeviceIdentity.computerName,
            localCode: deviceID.isEmpty ? "" : DeviceTag.code(deviceID),
            driver: DriverStatus.derive(driverFacts), driverVersion: driverFacts.installedVersion.map(versionName) ?? "",
            installing: driverInstaller.busy)
    }
    var permissionFacts: PermissionFacts {
        PermissionFacts(microphone: Self.microphoneAccess,
                        localNetwork: PermissionList.localNetwork(blocked: state.localNetworkIssue, connected: state.isReady,
                                                                  foundNearby: !browser.services.isEmpty),
                        loginItem: LoginItem.state, firewall: firewall.state)
    }
    static var microphoneAccess: Access {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return .notAsked
        case .denied, .restricted: return .denied
        @unknown default: return .unknown
        }
    }
    /// Stopped for want of microphone access and the user has since turned
    /// it on in System Settings: start again without being asked.
    func recoverWhenMicrophoneAllowed() {
        guard stopReason == .setup(.microphoneDenied), now >= nextPermissionCheck else { return }
        nextPermissionCheck = now + 1
        if Self.microphoneAccess == .granted { restartEnabled() }
    }
    /// A paired Mac's name, with its tag when its name is shared.
    func rowLabel(_ device: PairedDevice, _ rows: [DeviceRow]) -> String {
        rows.first { $0.id == device.id }?.label ?? device.displayName
    }
    /// The Mac being asked to pair, with its tag.
    func pairLabel(_ rows: [DeviceRow]) -> String {
        rows.first { $0.id == pairTarget }?.label ?? pairPeer
    }
    /// The Mac asking to pair: its name, model and device code as it said
    /// them (the six digits are what proves it).
    var incomingLabel: String {
        let name = incomingPeer.isEmpty ? PairedDevice.fallbackName : incomingPeer
        guard let request = incomingRequest else { return name }
        let parts = [request.model.map(DeviceTag.shortModel) ?? "", request.device.map { DeviceTag.code($0) } ?? ""].filter { !$0.isEmpty }
        return DeviceTag.label(name, parts.isEmpty ? nil : parts.joined(separator: " · "))
    }
    func updateMenuText(_ status: BridgeStatus) {
        let context = CopyContext(role: role, peer: pairTarget != nil && !pairPeer.isEmpty ? pairPeer : peerName, driver: DriverStatus.derive(driverFacts))
        let summary = StatusCopy.title(status, context)
        if menuStatus.title != summary { menuStatus.title = summary }
        let toggleTitle = enabled ? tr("暂停", "Pause") : tr("开启", "Turn On")
        if menuToggle.title != toggleTitle { menuToggle.title = toggleTitle }
    }

    // MARK: Diagnostics

    func diagnosticText() -> String {
        let micSide = role == .provider ? provider.microphone : nil
        let devices = peers.devices.map { d -> String in
            let marks = [d.id == linkedDevice ? tr("已连接", "linked") : nil,
                         d.id == link.target?.id && d.id != linkedDevice ? tr("正在连接", "dialing") : nil,
                         vault.peerKeys?[d.id] == nil ? tr("无密钥", "no key") : nil,
                         d.hasOurKey ? nil : tr("对方无本机密钥", "lacks our key")].compactMap { $0 }
            return "· \(d.displayName)\(d.model.map { " (\($0))" } ?? ""): \(Self.describe(presence[d.id]?.availability ?? .unknown))\(marks.isEmpty ? "" : " · " + marks.joined(separator: " · "))"
        }
        let yes = { (flag: Bool) in flag ? tr("是", "yes") : tr("否", "no") }
        return ([
            "MicBridge \(bridgeVersion) · \(role == .provider ? tr("提供方", "provider") : tr("使用方", "borrower")) · \(localName)\(deviceID.isEmpty ? "" : " · \(deviceID.prefix(8))")",
            tr("状态：", "Status: ") + statusText,
            tr("已启用 \(yes(enabled)) · 连接 \(state.link) · 连续失败 \(state.failures)", "Enabled \(yes(enabled)) · link \(state.link) · failures \(state.failures)"),
            tr("本机服务：监听 \(yes(link.isListening)) · 广播 \(link.advert.map { $0.mode.rawValue + ($0.busy ? " busy" : "") } ?? "无") · 附近 \(browser.services.count) 个 · 配对服务 \(yes(pairingServer.listener != nil))",
               "Services: listening \(yes(link.isListening)) · advert \(link.advert.map { $0.mode.rawValue + ($0.busy ? " busy" : "") } ?? "none") · nearby \(browser.services.count) · pairing service \(yes(pairingServer.listener != nil))"),
            tr("连接方式：\(link.routeLabel) · 对方版本 \(peerVersion.isEmpty ? "未知" : peerVersion)", "Route: \(link.routeLabel) · peer version \(peerVersion.isEmpty ? "unknown" : peerVersion)"),
            tr("已配对：\(peers.devices.count) 台", "Paired: \(peers.devices.count)"),
        ] + devices + [
            tr("设备：\(selectedDevice?.name ?? "无")", "Device: \(selectedDevice?.name ?? "none")"),
            tr("触发：事件 \(borrower.demand.eventCount) · 兜底 \(borrower.demand.fallbackCount)", "Triggers: events \(borrower.demand.eventCount) · fallback \(borrower.demand.fallbackCount)"),
            tr("应用收音 \(yes(borrower.demand.requested))", "App listening \(yes(borrower.demand.requested))") + (borrower.demand.clientName.isEmpty ? "" : " (\(borrower.demand.clientName))") +
                tr(" · 默认输入 \(yes(borrower.isDefaultInput)) · 本机麦克风 \(yes(provider.micActive)) · 对方麦克风 \(yes(borrower.peerMicRunning))",
                   " · default input \(yes(borrower.isDefaultInput)) · local mic \(yes(provider.micActive)) · peer mic \(yes(borrower.peerMicRunning))"),
            tr("发送／接收帧：\(provider.sentPackets) / \(borrower.receivedPackets) · 启动 \(provider.starts) 次", "Frames sent/received: \(provider.sentPackets) / \(borrower.receivedPackets) · starts \(provider.starts)"),
            tr("配置通知／已忽略：\(micSide?.configurationEvents ?? 0) / \(micSide?.ignoredConfigurationEvents ?? 0)", "Config changes/ignored: \(micSide?.configurationEvents ?? 0) / \(micSide?.ignoredConfigurationEvents ?? 0)"),
            tr("接入耗时：\(borrower.startLatencyMs.map { "\($0) ms" } ?? "未测试")", "Start latency: \(borrower.startLatencyMs.map { "\($0) ms" } ?? "not measured")"),
            tr("钥匙串：\(vault.pendingSince == nil ? "空闲" : "等待中") · 本机密钥 \(vault.listeningKey == nil ? "未读取" : "已读取") · 已配对密钥 \(vault.peerKeys.map { "\($0.count) 个" } ?? "未读取")",
               "Keychain: \(vault.pendingSince == nil ? "idle" : "waiting") · own key \(vault.listeningKey == nil ? "not read" : "read") · paired keys \(vault.peerKeys.map { "\($0.count)" } ?? "not read")"),
            tr("不含录音、文字或配对密钥。", "Contains no recordings, text or pairing keys."),
        ]).joined(separator: "\n")
    }
    static func describe(_ availability: PeerAvailability) -> String {
        switch availability {
        case .connected: return tr("已连接", "connected")
        case .online(let mode): return mode == .provider ? tr("在线 · 提供麦克风", "online · sharing") : tr("在线 · 使用麦克风", "online · using")
        case .busy: return tr("正忙", "busy")
        case .paused: return tr("已暂停", "paused")
        case .asleep: return tr("睡眠", "asleep")
        case .appClosed: return tr("未打开 MicBridge", "MicBridge not open")
        case .unreachable: return tr("无响应", "not responding")
        case .unknown: return tr("未知", "unknown")
        }
    }
    func copyDiagnostics() {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(diagnosticText(), forType: .string)
        ui.notify(tr("诊断信息已复制", "Diagnostics copied"))
    }
}
