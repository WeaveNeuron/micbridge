import Cocoa

/// The preview build ("MicBridge Preview.app", MICBRIDGE_PREVIEW=1) walks
/// through the whole flow on made-up Macs: onboarding, pairing, using or
/// sharing, pausing and installing the driver. Nothing touches audio, the
/// network, the keychain or login items. It keeps its own defaults (its
/// own bundle ID); a first run is `defaults delete
/// com.weaveneuron.MicBridge.Preview`, or MICBRIDGE_FIRST_RUN=1.
extension AppModel {
    func startPreview() {
        switch ProcessInfo.processInfo.environment["MICBRIDGE_APPEARANCE"] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        if let directory = walkthroughDirectory {
            defaults.removeObject(forKey: Self.onboardingKey)
            DispatchQueue.main.async { self.runWalkthrough(to: directory) }
        }
        let firstRun = walkthroughDirectory != nil
            || ProcessInfo.processInfo.environment["MICBRIDGE_FIRST_RUN"] == "1"
            || !defaults.bool(forKey: Self.onboardingKey)
        guard firstRun else {
            showPreview(0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.showPanel() }
            return
        }
        // A fresh Mac: nothing paired, allowed or installed; paused until
        // onboarding chooses a role.
        previewShow("first-run-nearby")
        ui.snapshot.enabled = false
        ui.snapshot.driver = .notInstalled; ui.snapshot.driverVersion = ""
        ui.snapshot.permissions = PermissionFacts(microphone: .notAsked, localNetwork: .unknown, loginItem: .off)
        showOnboarding()
    }

    func showPreview(_ index: Int) {
        guard previewMode, PreviewFixtures.all.indices.contains(index) else { return }
        let keep = ui.snapshot
        ui.previewIndex = index
        ui.snapshot = previewSnapshot(PreviewFixtures.all[index])
        // What the user did in this session outlives a fixture change.
        if keep.preview {
            ui.snapshot.permissions = keep.permissions
            if keep.driver == .ready || ui.snapshot.driver != .ready { ui.snapshot.driver = keep.driver; ui.snapshot.driverVersion = keep.driverVersion }
        }
        ui.audioDevices = [DeviceChoice(id: "preview", name: ui.snapshot.device)]
        menuStatus?.title = ui.snapshot.title
        menuBar?.item.button?.image = MenuIcon.image(MenuIconState(ui.snapshot.status))
    }
    func previewShow(_ slug: String, role: Role? = nil) {
        if let index = PreviewFixtures.all.firstIndex(where: { $0.slug == slug }) { showPreview(index) }
        if let role { ui.snapshot.role = role }
    }

    /// Share / Use / Pause in the preview.
    func previewSetMode(_ mode: PeerMode) {
        let s = ui.snapshot
        let paired = !s.mine.isEmpty
        switch mode {
        case .paused:
            ui.snapshot.status = .paused; ui.snapshot.enabled = false
            ui.snapshot.connected = false; ui.snapshot.micActive = false
            ui.snapshot.mine = s.mine.map { var row = $0; if row.state == .connected { row.state = .online }; row.isCurrent = false; row.micInUse = false; return row }
            showPreviewIcon()
        case .provider, .borrower:
            let role: Role = mode == .provider ? .provider : .borrower
            if !paired {
                ui.snapshot.role = role; ui.snapshot.enabled = true; ui.snapshot.status = .noPairedDevices
            } else if role == .borrower && !ui.snapshot.hasVirtualMicrophone {
                previewShow("borrower-no-virtual-mic")
            } else {
                previewShow(role == .provider ? "provider-ready" : "borrower-ready")
            }
        }
        menuStatus?.title = ui.snapshot.title
    }
    /// Add: the code shows on both Macs, then the other one allows it.
    func previewPair() {
        let role = ui.snapshot.role
        previewShow("pairing-outgoing", role: role)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, case .pairing = self.ui.snapshot.status else { return }
            self.previewPaired()
        }
    }
    func previewPaired() {
        let role = ui.snapshot.role
        ui.notify(tr("已与另一台 Mac 配对", "Paired with your other Mac"))
        if role == .borrower && !ui.snapshot.hasVirtualMicrophone { previewShow("borrower-no-virtual-mic") }
        else { previewShow(role == .provider ? "provider-ready" : "borrower-ready") }
    }
    func previewInstallDriver() {
        ui.snapshot.installing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            self.ui.snapshot.installing = false
            self.ui.snapshot.driver = .ready; self.ui.snapshot.driverVersion = bundledDriverVersion
            self.ui.notify(tr("已安装 MicBridge Microphone", "MicBridge Microphone installed"))
            if self.ui.snapshot.status == .setup(.noVirtualMicrophone) { self.previewShow("borrower-ready") }
        }
    }
    func previewFinishOnboarding() {
        if ui.snapshot.status == .noPairedDevices || ui.snapshot.status == .paused {
            previewSetMode(ui.snapshot.role == .provider ? .provider : .borrower)
        }
        showPanel()
    }
    private func showPreviewIcon() {
        menuBar?.item.button?.image = MenuIcon.image(.paused)
    }
}

// MARK: Walkthrough

/// MICBRIDGE_WALKTHROUGH=<dir> (preview build only): runs the first-run
/// flow by itself through the same actions the buttons call, and saves
/// each step as drawn in its real window. MICBRIDGE_APPEARANCE=dark|light
/// pins the look; the language follows -AppleLanguages.
extension AppModel {
    var walkthroughDirectory: URL? {
        guard previewMode, let path = ProcessInfo.processInfo.environment["MICBRIDGE_WALKTHROUGH"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    func runWalkthrough(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let borrower = PeerMode.borrower
        let nearbyID = { [weak self] in self?.ui.snapshot.nearby.first?.id ?? "" }
        let steps: [(String?, () -> Void)] = [
            ("01-onboarding-role", {}),
            ("02-onboarding-needs", { [weak self] in
                self?.ui.onboardingRole = .borrower
                self?.ui.setMode(borrower); self?.ui.onboardingStep = 1 }),
            (nil, { [weak self] in self?.ui.perform(.installDriver) }),
            ("03-onboarding-installing", {}),
            (nil, {}),
            ("04-onboarding-installed", {}),
            ("05-panel-first-run", { [weak self] in self?.ui.finishOnboarding(true) }),
            ("06-panel-pairing", { [weak self] in self?.ui.pair(nearbyID()) }),
            (nil, {}), (nil, {}),
            ("07-panel-paired", {}),
            ("08-panel-ready", { [weak self] in self?.previewShow("borrower-ready") }),
            ("09-panel-in-use", { [weak self] in self?.previewShow("borrower-in-use") }),
            ("10-panel-paused", { [weak self] in self?.ui.setMode(.paused) }),
            ("11-panel-resumed", { [weak self] in self?.ui.setMode(borrower) }),
            ("12-settings-general", { [weak self] in self?.ui.openSettings(.general) }),
            ("13-settings-permissions", { [weak self] in self?.settingsController?.show(.permissions) }),
            ("14-settings-advanced", { [weak self] in self?.settingsController?.show(.advanced) }),
            ("15-settings-about", { [weak self] in self?.settingsController?.show(.about) }),
            ("16-panel-provider", { [weak self] in self?.settingsController?.close(); self?.ui.setMode(.provider); self?.showPanel() }),
            ("17-settings-permissions-provider", { [weak self] in self?.ui.openSettings(.permissions) }),
            ("18-settings-permissions-allowed", { [weak self] in self?.ui.perform(.requestMicrophone) }),
            ("19-panel-incoming-pairing", { [weak self] in self?.settingsController?.close(); self?.previewShow("pairing-incoming"); self?.showPanel() }),
            ("20-panel-mic-denied", { [weak self] in self?.previewShow("provider-mic-denied") }),
        ]
        func run(_ index: Int) {
            guard index < steps.count else { print("walkthrough done"); NSApp.terminate(nil); return }
            steps[index].1()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self] in
                if let name = steps[index].0 { self?.captureVisibleWindows(name, in: directory) }
                run(index + 1)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { run(0) }
    }

    /// The front window as drawn (title bar and toolbar included), or the
    /// panel on the menu's colour.
    func captureVisibleWindows(_ name: String, in directory: URL) {
        let window: NSWindow? = [settingsWindow, onboardingWindow].compactMap { $0 }.first { $0.isVisible } ?? (menuBar.isOpen ? menuBar.panel : nil)
        guard let window, let view = window === menuBar.panel ? window.contentView : (window.contentView?.superview ?? window.contentView),
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { print("nothing to capture for \(name)"); return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let drawn = rep.cgImage else { return }
        let dark = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let ctx = CGContext(data: nil, width: drawn.width, height: drawn.height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        if window === menuBar.panel {
            // The panel's material needs the desktop behind it: use the menu's colour.
            let r = CGFloat(12 * drawn.width) / view.bounds.width
            ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: drawn.width, height: drawn.height), cornerWidth: r, cornerHeight: r, transform: nil))
            ctx.setFillColor(dark ? CGColor(gray: 0.16, alpha: 1) : CGColor(gray: 0.95, alpha: 1)); ctx.fillPath()
        } else {
            ctx.setFillColor((dark ? NSColor(white: 0.19, alpha: 1) : NSColor(white: 0.93, alpha: 1)).cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: drawn.width, height: drawn.height))
        }
        ctx.draw(drawn, in: CGRect(x: 0, y: 0, width: drawn.width, height: drawn.height))
        guard let image = ctx.makeImage(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        try? png.write(to: directory.appendingPathComponent(name + ".png"))
        print("captured \(name) \(Int(window.frame.width))×\(Int(window.frame.height))")
    }
}
