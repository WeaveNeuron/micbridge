import Foundation

/// The actual startup and device-change paths, with fake device facts and
/// an audio continuation recorder. No launch(), HAL, TCC, keychain,
/// administrator prompt or system driver directory is used.
func runDriverStartupTests() throws {
    var count = 0
    func check(_ condition: Bool, _ description: String) throws {
        guard condition else { throw BridgeError("FAIL: \(description)") }
        count += 1; print("PASS: \(description)")
    }
    func spin(until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !done() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }
    let virtual = AudioDevice(id: 10, uid: VirtualDevice.uid, name: "MicBridge Microphone", inputChannels: 2, outputChannels: 2, builtIn: false)
    let realMic = AudioDevice(id: 11, uid: "TestMicrophone", name: "Test Microphone", inputChannels: 1, outputChannels: 0, builtIn: true)
    let ready = DriverFacts(embeddedVersion: "1000000", installedVersion: "1000000", deviceLoaded: true)
    let blocked: [DriverFacts] = [
        DriverFacts(embeddedVersion: "1000000", deviceLoaded: false),
        DriverFacts(embeddedVersion: "1000000", installedVersion: "90000", deviceLoaded: false),
        DriverFacts(embeddedVersion: "1000000", installedVersion: "1000000", deviceLoaded: false),
        DriverFacts(deviceLoaded: false),
    ]
    var suites: [String] = []
    defer { for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) } }
    func model(role: Role = .borrower, facts: DriverFacts) -> AppModel {
        let suite = "MicBridgeDriverStartupTest-\(UUID().uuidString)"; suites.append(suite)
        let m = AppModel(previewMode: false, initialRole: role, defaults: UserDefaults(suiteName: suite)!)
        setDevices(m, facts)
        return m
    }
    func setDevices(_ m: AppModel, _ facts: DriverFacts, id: UInt32 = 10) {
        let device = AudioDevice(id: id, uid: virtual.uid, name: virtual.name, inputChannels: 2, outputChannels: 2, builtIn: false)
        let snapshot = DeviceSnapshot(all: [realMic] + (facts.deviceLoaded ? [device] : []), defaultInput: realMic.id)
        m.readAudioDevices = { (snapshot, facts) }
    }
    /// Queue a marker after the device-change read and wait for both main
    /// callbacks; repeated notifications must never start the output twice.
    func changed(_ m: AppModel, _ facts: DriverFacts, id: UInt32 = 10) throws {
        setDevices(m, facts, id: id)
        m.audioDevicesChanged()
        var done = false
        m.refreshDevices { done = true }
        spin { done }
        try check(done, "device-change callbacks completed")
    }
    func panel(_ m: AppModel) -> PanelSnapshot {
        PanelSnapshot(status: m.currentStatus(), role: m.role, enabled: m.enabled, driver: DriverStatus.derive(m.driverFacts))
    }

    for facts in blocked {
        let driver = DriverStatus.derive(facts)
        let m = model(facts: facts)
        var started: [UInt32] = []
        m.activateAudio = { device, _ in started.append(device.id) }
        m.toggleEnabled()
        spin { m.waitingForDriver }
        let s = panel(m)
        try check(m.enabled && m.defaults.bool(forKey: "demandEnabled") && !m.defaults.bool(forKey: "userPausedV5"),
                  "\(driver): turning on preserves enabled and demandEnabled")
        try check(s.status == .setup(.noVirtualMicrophone) && !s.paused && s.showsSwitch && s.status.needsAttention && started.isEmpty,
                  "\(driver): startup waits for the driver, visibly on, before authorization or audio")
        try check(MenuIconState(s.status) == .idle, "\(driver): the unchanged menu glyph shows not connected")
        for lang in Lang.allCases {
            try withLanguage(lang) {
                try check(s.title == driver.waitingTitle && s.subtitle == driver.waitingDetail && !s.title.isEmpty && !s.subtitle.isEmpty,
                          "\(lang) \(driver): panel explains the specific driver state")
                let settings = s.driverPermission
                let onboarding = PermissionList.essentials(role: .borrower, facts: s.permissions, driver: driver).first
                try check(settings?.kind == .virtualMicrophone && settings?.state == .needed && settings?.detail == driver.detail && onboarding == settings,
                          "\(lang) \(driver): Settings and Use onboarding explain the driver first")
                try check(s.offersDriverInstall == driver.canInstall &&
                          settings?.action == (driver.canInstall ? .installDriver : nil) &&
                          (!driver.canInstall || settings?.actionTitle == driver.installTitle),
                          "\(lang) \(driver): panel and Settings expose the same install, update or reload action")
            }
        }
        // An unrelated device change and a repeated click to start cannot
        // bypass the driver or discard the pending intent.
        try changed(m, facts)
        m.start()
        try check(m.waitingForDriver && started.isEmpty, "\(driver): unrelated changes keep waiting")
        try changed(m, ready, id: 20)
        try check(started == [20] && m.enabled && m.defaults.bool(forKey: "demandEnabled") && !m.waitingForDriver && m.stopReason == nil,
                  "\(driver): a current, loaded driver automatically continues on the new device")
        try changed(m, ready, id: 20)
        try check(started == [20], "\(driver): repeated notifications do not start audio again")
    }

    // An older driver that is loaded keeps working; the panel offers the update.
    let old = model(facts: DriverFacts(embeddedVersion: "1000000", installedVersion: "90000", deviceLoaded: true))
    var oldStarts: [UInt32] = []
    old.activateAudio = { device, _ in oldStarts.append(device.id) }
    old.toggleEnabled(); spin { !oldStarts.isEmpty }
    let oldPanel = PanelSnapshot(status: .ready, role: .borrower, driver: DriverStatus.derive(old.driverFacts))
    try check(oldStarts == [10] && old.enabled && !old.waitingForDriver && oldPanel.showsDriverNotice && oldPanel.offersDriverInstall,
              "a loaded older driver keeps working while the panel offers the update")
    for lang in Lang.allCases {
        try withLanguage(lang) {
            let d = DriverStatus.outdated(installed: "90000")
            try check(d.title != d.waitingTitle && d.detail != d.waitingDetail && (lang == .zh ? d.detail.contains("仍可使用") : d.detail.contains("still works")),
                      "\(lang): a working older driver says it still works; only a waiting one says update needed")
        }
    }

    // Explicit pause wins over driver readiness, including delayed reads.
    let paused = model(facts: blocked[0])
    var pausedStarts = 0
    paused.activateAudio = { _, _ in pausedStarts += 1 }
    paused.toggleEnabled(); spin { paused.waitingForDriver }
    paused.toggleEnabled(); spin { !paused.enabled }
    try changed(paused, ready)
    try check(!paused.enabled && !paused.defaults.bool(forKey: "demandEnabled") && pausedStarts == 0 && panel(paused).paused,
              "turning off while waiting prevents automatic recovery")
    let pausedNotice = PanelSnapshot(status: .paused, role: .borrower, driver: .notInstalled)
    try check(pausedNotice.showsDriverNotice && pausedNotice.offersDriverInstall,
              "a deliberately paused borrower still sees the driver notice and install action")

    let delayed = model(facts: blocked[0])
    let gate = DispatchSemaphore(value: 0)
    delayed.readAudioDevices = { gate.wait(); return (DeviceSnapshot(all: [virtual]), ready) }
    var delayedStarts = 0
    delayed.activateAudio = { _, _ in delayedStarts += 1 }
    delayed.toggleEnabled(); spin { delayed.enabled }
    delayed.toggleEnabled(); spin { !delayed.enabled }
    gate.signal()
    try changed(delayed, ready)
    try check(!delayed.enabled && delayedStarts == 0, "a startup read completing after pause cannot re-enable the bridge")

    let sleeping = model(facts: blocked[0])
    var sleepStarts = 0
    sleeping.activateAudio = { _, _ in sleepStarts += 1 }
    sleeping.toggleEnabled(); spin { sleeping.waitingForDriver }
    sleeping.suspend()
    try changed(sleeping, ready)
    try check(sleeping.enabled && sleeping.suspended && sleepStarts == 0 && panel(sleeping).status == .sleeping,
              "driver readiness while asleep preserves intent without starting audio")

    // Sharing never needs the driver, regardless of its installation state.
    for facts in blocked + [ready] {
        let m = model(role: .provider, facts: facts)
        var started: [String] = []
        m.activateAudio = { device, _ in started.append(device.uid) }
        m.toggleEnabled(); spin { !started.isEmpty }
        let s = panel(m)
        try check(started == [realMic.uid] && m.enabled && m.stopReason == nil && !m.waitingForDriver && !s.offersDriverInstall && !s.showsDriverNotice,
                  "provider with \(s.driver): starts its real microphone without a driver requirement")
        try check(PermissionList.essentials(role: .provider, facts: s.permissions, driver: s.driver).allSatisfy { $0.kind != .virtualMicrophone },
                  "provider onboarding has no driver requirement")
    }
    print("Driver startup: \(count) checks passed; no system audio or drivers touched")
}
