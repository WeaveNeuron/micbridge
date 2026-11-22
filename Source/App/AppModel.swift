import Cocoa
import AVFoundation
import Network
import UserNotifications

/// The coordinator: owns the connection state machine, the link and the
/// controller for this Mac's role, and executes the machine's effects.
final class AppModel: NSObject, RoleHost {
    let ui = BridgeUIModel()
    let previewMode: Bool
    let defaults: UserDefaults
    /// System edges are replaceable so startup tests never enter HAL or TCC.
    var readAudioDevices: () -> (DeviceSnapshot, DriverFacts) = {
        let devices = Devices.snapshot()
        return (devices, DriverBundle.facts(devices: devices.all))
    }
    lazy var activateAudio: (AudioDevice, UUID) -> Void = { [weak self] in self?.authorize(device: $0, epoch: $1) }
    var menuBar: MenuBarController!
    var menuStatus: NSMenuItem!
    var menuToggle: NSMenuItem!
    var settingsController: SettingsWindowController?
    var settingsWindow: NSWindow? { settingsController?.window }
    var onboardingWindow: NSWindow?

    // Role and audio device. The role is the user's choice; devices are
    // picked automatically unless Settings overrides them.
    private(set) var role: Role
    var devices: [AudioDevice] = []
    var selectedDevice: AudioDevice?
    /// The system's default input when the devices were last read.
    var defaultInput: AudioDeviceID = 0
    var deviceKey: String { role == .borrower ? "outputUID" : "inputUID" }
    /// The MicBridge Microphone driver: what is known, and its installer.
    var driverFacts = DriverFacts(deviceLoaded: false)
    let driverInstaller = DriverInstaller()
    let deviceWatcher = AudioDeviceWatcher()
    /// The application firewall, read (never changed) while a window shows it.
    let firewall = FirewallMonitor()

    // Connection.
    private(set) var state: ConnectionState
    /// User intent: the bridge should run (survives sleep and lock).
    private(set) var enabled = false
    private(set) var suspended = false
    var stopReason: StopReason?
    var statusText = ""
    var peerVersion = ""
    let link = LinkManager()
    let peers: PeerStore
    /// Every MicBridge service nearby, and what is known about paired Macs.
    let browser = NearbyBrowser()
    var presence: [String: PeerPresence] = [:]
    /// The paired Mac on the active link.
    var linkedDevice: String?
    /// Since when there has been no link (for the provider's fallback dial).
    var unlinkedSince: TimeInterval = 0
    var lastNameCheck: TimeInterval = 0
    let provider = ProviderController()
    let borrower: BorrowerController
    var connectionGeneration = UUID()
    /// Keychain access runs off the main thread (a prompt can block it).
    let vault = KeyVault()
    var debouncer = StatusDebouncer()
    var menuIcon: MenuIconState?

    // Pairing. This Mac asks (`pairTarget`, the client) or is asked
    // (`incomingPair`, the server); keys go both ways.
    var pairTarget: String?
    var pairCode = "", pairPeer = "", pairMessage = ""
    var incomingPair = false
    var incomingPeer = "", incomingCode = ""
    /// Who asked to pair (model and device ID, if it said).
    var incomingRequest: PairRequest?
    let pairingServer = NearbyPairingServer()
    let pairingClient = NearbyPairingClient()
    var pairingRetryAt: TimeInterval = 0
    var nextPermissionCheck: TimeInterval = 0

    private var timer: Timer?
    private let audioSetup = DispatchQueue(label: "micbridge.audio.setup", qos: .userInitiated)
    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// This Mac's name: the computer name from System Settings › Sharing,
    /// the same one other Macs show for it.
    var localName: String { DeviceIdentity.localName }
    var peerName: String { peer.displayName }

    init(previewMode: Bool, initialRole: Role? = nil, defaults: UserDefaults = .standard) {
        self.previewMode = previewMode
        self.defaults = defaults
        peers = PeerStore(defaults: defaults)
        borrower = BorrowerController(defaults: defaults)
        let role = initialRole ?? Role.saved(in: defaults) ?? Role.suggested(hasBuiltInMicrophone: Devices.all().contains { $0.builtIn && $0.inputChannels > 0 })
        self.role = role
        state = ConnectionState(role: role)
        super.init()
    }

    func launch() {
        buildUI()
        wireDriver()
        if previewMode { startPreview(); return }
        wireLink()
        provider.host = self
        provider.isActive = { [weak self] in self?.state.isActive ?? false }
        provider.isLinkReady = { [weak self] in self?.state.isReady ?? false }
        borrower.host = self
        borrower.providerAvailable = { [weak self] in self.map { $0.state.isActive && $0.state.isReady } ?? false }
        borrower.peerName = { [weak self] in self?.peerName ?? PairedDevice.fallbackName }
        borrower.onFatal = { [weak self] in self?.stop(.problem($0)) }
        pairingServer.name = { DeviceIdentity.localName }
        pairingServer.deviceID = { [weak self] in self?.deviceID ?? "" }
        pairingServer.payload = { [weak self] in
            guard let self else { throw BridgeError(tr("MicBridge 已停止。", "MicBridge stopped.")) }
            return try self.pairingCard()
        }
        pairingServer.onPairedBack = { [weak self] card in self?.adoptReturnedCard(card) }
        pairingClient.payload = { [weak self] in try self?.pairingCard() }
        pairingServer.onRequest = { [weak self] request in
            guard let self else { return }
            self.incomingPair = true; self.incomingPeer = request.name; self.incomingCode = request.code
            self.incomingRequest = request
            // The panel is the one place for it, even over the welcome window.
            self.present(.panel, pairingRequest: true); self.syncUI()
        }
        pairingServer.onCancelled = { [weak self] in self?.clearIncomingPair(); self?.ui.notify(tr("配对请求已取消", "The pairing request was cancelled")) }
        pairingClient.onStatus = { [weak self] message, code, peer in
            guard let self else { return }
            self.pairMessage = message; self.pairCode = code; self.pairPeer = peer; self.syncUI()
        }
        pairingClient.onPaired = { [weak self] pairing in self?.adoptPairing(pairing) }
        pairingClient.onFailed = { [weak self] reason in self?.pairingFailed(reason) }
        vault.onChange = { [weak self] in self?.syncUI() }
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
        // Tolerance lets macOS coalesce wake-ups with other timers.
        timer?.tolerance = 0.02
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        // Recover a default-input hand-over left behind by a crash.
        if defaults.string(forKey: BorrowerController.previousInputKey) != nil { borrower.releaseDefaultInput() }
        if role == .borrower { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in } }
        // Listen and advertise even while paused, so others can say so.
        goOnline()
        // First launch waits for the user to choose what this Mac does.
        if needsOnboarding { showOnboarding(); return }
        // Open into standby unless the user explicitly paused.
        if !defaults.bool(forKey: "userPausedV5") { start() } else { refreshDevices() }
    }

    // MARK: RoleHost

    func send(_ message: Message) { link.send(message) }
    func status(_ text: String) { statusText = text; syncUI() }
    /// Per-recording problems are reported briefly; the bridge stays ready.
    func transient(_ text: String) { statusText = text; ui.notify(text); syncUI() }
    func captureChanged() { updateUI() }

    // MARK: Role and devices

    func setRole(_ newRole: Role) {
        guard newRole != role else { return }
        Role.save(newRole, in: defaults)
        let wasEnabled = enabled
        if enabled { enabled = false; tearDown(bye: .mode) }
        role = newRole
        state = ConnectionState(role: newRole)
        stopReason = nil
        refreshAdvert()
        if newRole == .borrower { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in } }
        if wasEnabled { start() } else { refreshDevices() }
    }
    /// Reads the devices off the main thread (Core Audio IPC can stall for
    /// seconds), then applies them and refreshes the UI. `reselect` picks the
    /// device again even while running (only `start` does that).
    func refreshDevices(reselect: Bool = false, then done: (() -> Void)? = nil) {
        let read = readAudioDevices
        AudioHAL.queue.async { [weak self] in
            let (snapshot, facts) = read()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.apply(snapshot, facts: facts, reselect: reselect)
                self.syncUI()
                done?()
            }
        }
    }
    func apply(_ snapshot: DeviceSnapshot, facts: DriverFacts, reselect: Bool = false) {
        driverFacts = facts
        defaultInput = snapshot.defaultInput
        devices = role == .borrower ? snapshot.all.filter(\.loopback) : SourcePicker.candidates(snapshot.all)
        ui.audioDevices = devices.map { DeviceChoice(id: $0.uid, name: $0.name) }
        // Keep the running device stable; a change goes through restart().
        if reselect || !enabled || waitingForDriver || selectedDevice == nil { selectedDevice = automaticOrSavedDevice() }
    }
    var automaticDevice: AudioDevice? {
        if role == .borrower { return VirtualDevice.find(devices) }
        return SourcePicker.pick(devices, saved: nil, defaultInput: defaultInput)
    }
    func automaticOrSavedDevice() -> AudioDevice? {
        // Only the shared microphone is a choice; the virtual one is always MicBridge Microphone.
        guard role == .provider else { return automaticDevice }
        return SourcePicker.pick(devices, saved: defaults.string(forKey: deviceKey), defaultInput: defaultInput)
    }
    /// Only on an explicit click: lets every app here use the bridge by default.
    func makeDefaultInput() {
        guard role == .borrower else { return }
        borrower.device = selectedDevice
        ui.notify(borrower.makeDefaultInput() ? tr("已设为默认麦克风", "Set as the default microphone") : tr("无法更改默认麦克风", "Couldn’t change the default microphone"))
        syncUI()
    }
    func chooseDevice(uid: String) {
        if uid.isEmpty { defaults.removeObject(forKey: deviceKey) } else { defaults.set(uid, forKey: deviceKey) }
        if enabled { restart() } else { selectedDevice = automaticOrSavedDevice(); syncUI() }
    }

    // MARK: Lifecycle

    @objc func toggleEnabled() {
        // Return from the Accessibility/menu action before entering Core Audio's
        // synchronous device calls. AX invocation may otherwise hold an IPC lock.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.enabled {
                self.defaults.set(true, forKey: "userPausedV5")
                self.stop(nil)
            } else {
                self.defaults.set(false, forKey: "userPausedV5")
                self.stopReason = nil; self.start()
            }
        }
    }
    func restart() {
        stopReason = nil
        guard enabled else { refreshDevices(); return }
        enabled = false; tearDown(bye: nil); start()
    }
    func restartEnabled() {
        defaults.set(false, forKey: "userPausedV5")
        stopReason = nil; enabled = false; tearDown(bye: nil); start()
    }
    func start() {
        guard !enabled else { return }
        enabled = true; suspended = false; stopReason = nil
        dispatch(.start)
        defaults.set(true, forKey: "demandEnabled"); updateUI()
        let epoch = connectionGeneration
        refreshDevices(reselect: true) { [weak self] in
            self?.continueStartup(epoch: epoch)
        }
    }
    /// Missing, outdated or unloaded driver: keep the user's on intent and
    /// wait for a device notification instead of stopping the bridge.
    var waitingForDriver: Bool { enabled && role == .borrower && stopReason == .setup(.noVirtualMicrophone) }
    func continueStartup(epoch: UUID) {
        guard enabled, !suspended, connectionGeneration == epoch else { return }
        // An older driver that is loaded still works: carry on and let the
        // panel offer the update. Anything else waits for the driver.
        let driver = DriverStatus.derive(driverFacts)
        let usable = driver == .ready || (driver.isOutdated && driverFacts.deviceLoaded)
        if role == .borrower, !usable || selectedDevice == nil {
            stopReason = .setup(.noVirtualMicrophone)
            status(DriverStatus.derive(driverFacts).waitingDetail)
            return
        }
        guard let device = selectedDevice else { stop(.setup(.noMicrophone)); return }
        stopReason = nil
        activateAudio(device, epoch)
    }
    private func authorize(device: AudioDevice, epoch: UUID) {
        // Registering output IO on the duplex loopback also performs a TCC
        // microphone check. Ask explicitly before entering synchronous HAL IPC;
        // a permission dialog must never be mistaken for an audio-server hang.
        let authorized = { [weak self] (granted: Bool) in
            DispatchQueue.main.async {
                guard let self, self.enabled, self.connectionGeneration == epoch else { return }
                guard granted else { self.stop(.setup(.microphoneDenied)); return }
                self.startAuthorized(device: device, epoch: epoch)
            }
        }
        status(tr("正在检查麦克风权限。", "Checking microphone access."))
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: authorized(true)
        case .notDetermined: AVCaptureDevice.requestAccess(for: .audio, completionHandler: authorized)
        default: authorized(false)
        }
    }
    private func startAuthorized(device: AudioDevice, epoch: UUID) {
        guard role == .borrower else {
            provider.device = device
            // Pre-build the capture graph off the main thread so a request
            // opens the microphone at once; connect meanwhile (`ready` waits
            // for the graph).
            provider.prepare { [weak self] error in
                guard let self, self.enabled, self.connectionGeneration == epoch, let error, !(error is MicrophoneError) else { return }
                self.stop(.problem(error.localizedDescription))
            }
            connect(epoch: epoch); return
        }
        borrower.device = device
        status(tr("正在连接虚拟麦克风…", "Connecting the virtual microphone…"))
        borrower.startOutput(device: device, on: audioSetup) { [weak self] result in
            guard let self else { return }
            guard self.enabled, self.connectionGeneration == epoch else { self.borrower.tearDown(); return }
            switch result {
            case .success: self.connect(epoch: epoch)
            case .failure(let error): self.stop(.problem(error.localizedDescription))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.enabled, self.connectionGeneration == epoch, !self.borrower.outputReady else { return }
            self.stop(.setup(.virtualMicrophoneTimeout))
        }
    }
    func tearDown(bye: ByeReason? = .paused) {
        connectionGeneration = UUID()
        borrower.tearDown(); provider.shutDown()
        link.disconnect("stopped", bye: bye)
        linkLost()
        pairingServer.stop(); pairingClient.stop()
        incomingPair = false; incomingPeer = ""; incomingCode = ""; incomingRequest = nil
        pairTarget = nil; pairPeer = ""; pairCode = ""; pairMessage = ""
        updateUI()
    }
    /// Quitting: tell the linked Mac, withdraw the advert.
    func quit() {
        tearDown(bye: .quit)
        link.stopListening(); browser.stop()
    }
    /// Stops standby. A reason is shown until the user acts; nil is a deliberate pause.
    func stop(_ reason: StopReason?) {
        enabled = false; defaults.set(false, forKey: "demandEnabled")
        tearDown(); dispatch(.pause); stopReason = reason
        refreshAdvert()
        status(reason.map(StatusCopy.describe) ?? tr("已暂停，麦克风已关闭。", "Paused; the microphone is off."))
    }
    @objc func suspend() {
        guard !suspended else { return }
        suspended = true; tearDown(bye: .sleep); dispatch(.suspend)
        // Asleep: not on the network at all.
        link.stopListening(); browser.stop()
        status(tr("睡眠或锁屏：麦克风已关闭。", "Asleep or locked; the microphone is off."))
    }
    @objc func resume() {
        guard suspended else { return }
        suspended = false
        goOnline()
        guard enabled else { dispatch(.pause); syncUI(); return }
        enabled = false; start()
    }

    // MARK: Connection

    func dispatch(_ event: ConnectionEvent) {
        let wasReady = state.isReady
        let effects = state.reduce(event, now: now)
        switch event {
        case .handshakeOK:
            if role == .provider { provider.linkUp() }
            // Settle first, then move an idle Wi-Fi link onto the wire.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.preferWiredRoute() }
            refreshAdvert()
        case .closed(let reason):
            if role == .provider { provider.reset() } else { borrower.linkDown() }
            linkLost()
            status(tr("\(reason.message) 麦克风已关闭，将自动重连。", "\(reason.message) The microphone is off; reconnecting automatically."))
        default: break
        }
        if role == .borrower, !wasReady, state.isReady { borrower.providerReady() }
        for effect in effects { perform(effect) }
        updateUI()
    }
    private func perform(_ effect: ConnectionEffect) {
        switch effect {
        case .dial: link.dial()
        case .redial: link.redial()
        case .restartDiscovery: browser.start()
        case .startListener: startListening()
        }
    }
    func preferWiredRoute() {
        guard state.isActive, state.isReady, captureIdle else { return }
        // Idle by the guard above: the prepared capture graph is kept.
        if link.preferWiredRoute() { linkLost(); dispatch(.rerouting) }
    }
    var captureIdle: Bool {
        role == .provider ? provider.session == nil && !provider.stopping : borrower.voice == nil
    }
    func received(_ m: Message) {
        switch m.kind {
        case "superseded": stop(.problem(tr("另一份 MicBridge 接管了连接，请只保留一份。", "Another copy of MicBridge took over; keep only one running."))); return
        case "peerKey": receivedPeerKey(m); return
        case "bye": if let id = linkedDevice, let reason = ByeReason(rawValue: m.text) { presence[id, default: PeerPresence()].said(reason) }; return
        default: break
        }
        switch role {
        case .provider: provider.handle(m)
        case .borrower:
            if m.kind == "ready" { dispatch(.peerReady) } else { borrower.handle(m) }
        }
    }

    // MARK: Timer

    func tick() {
        syncUI()
        recoverWhenMicrophoneAllowed()
        guard !suspended else { return }
        presenceTick()
        guard enabled, !waitingForDriver else { return }
        for effect in state.reduce(.tick, now: now) { perform(effect) }
        if link.isListening, now >= pairingRetryAt { startPairingService() }
        switch role {
        case .provider: provider.tick()
        case .borrower: borrower.tick(providerReady: state.isReady)
        }
    }
}
