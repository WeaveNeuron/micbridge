import Cocoa
import CoreAudio

// Observing HAL state does not capture audio and does not require microphone,
// Accessibility, Input Monitoring, or Screen Recording permission.
enum AudioState {
    static func scalar(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0; var size: UInt32 = 4
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        return value
    }
    static func objects(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var values = [AudioObjectID](repeating: 0, count: Int(size) / 4)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &values) == noErr else { return [] }
        return values
    }
    static func processes() -> [AudioObjectID] { objects(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList) }
    static func ownInputRunning() -> Bool {
        processes().contains { scalar($0, kAudioProcessPropertyPID) == UInt32(ProcessInfo.processInfo.processIdentifier) && scalar($0, kAudioProcessPropertyIsRunningInput) != 0 }
    }
}

/// Watches the virtual microphone: any app other than MicBridge that reads
/// input from it (dictation, voice input methods, chat apps, recorders…) is a demand.
///
/// Event-driven: Core Audio notifies us when the process list or a process's
/// input state changes, so idle cost is near zero (the old 40 ms poll cost
/// ~1000 IPC calls per second into coreaudiod). A slow fallback check covers
/// any missed notification. All HAL calls run on a private queue, never on
/// the main thread, so a busy audio server cannot freeze the interface.
final class DemandMonitor {
    var onChange: ((Bool) -> Void)?
    private(set) var requested = false
    private(set) var clientName = ""
    private(set) var eventCount = 0
    private(set) var fallbackCount = 0
    private let ownPID = UInt32(ProcessInfo.processInfo.processIdentifier)
    private let queue = DispatchQueue(label: "micbridge.demand", qos: .userInitiated)
    private var generation = 0                       // main thread
    // Queue-confined state.
    private var deviceID: AudioDeviceID = 0
    private var running = false
    private var watched: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var listBlock: AudioObjectPropertyListenerBlock?
    private var deviceBlock: AudioObjectPropertyListenerBlock?
    private var fallback: DispatchSourceTimer?
    private static let system = AudioObjectID(kAudioObjectSystemObject)
    private static let listAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    /// Per-process IsRunningInput notifications never arrive for some clients
    /// (one voice input method: every hold was caught only by the 0.5 s fallback). The
    /// device's running-state notification fires whenever a client starts IO
    /// on it, even if the value itself does not change; use it as a wake-up.
    private static let deviceAddresses = [kAudioDevicePropertyDeviceIsRunningSomewhere, kAudioDevicePropertyDeviceIsRunning].map {
        AudioObjectPropertyAddress(mSelector: $0, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
    private static let processAddresses = [kAudioProcessPropertyIsRunningInput, kAudioProcessPropertyDevices].map {
        AudioObjectPropertyAddress(mSelector: $0, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    func start(device: AudioDevice) {
        stop()
        generation += 1
        let epoch = generation, id = device.id
        queue.async { [self] in
            deviceID = id; running = true
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.processesChanged(epoch) }
            var address = Self.listAddress
            if AudioObjectAddPropertyListenerBlock(Self.system, &address, queue, block) == noErr { listBlock = block }
            let wake: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.evaluate(epoch, fromEvent: true, source: "device") }
            for var device in Self.deviceAddresses { AudioObjectAddPropertyListenerBlock(id, &device, queue, wake) }
            deviceBlock = wake
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 0.5, repeating: 0.5, leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in self?.evaluate(epoch, fromEvent: false, source: "fallback") }
            timer.resume(); fallback = timer
            processesChanged(epoch)
        }
    }
    /// Queue: keep one listener on every audio process.
    private func processesChanged(_ epoch: Int) {
        guard running else { return }
        let current = Set(AudioState.processes())
        for (process, block) in watched where !current.contains(process) { removeListeners(process, block); watched[process] = nil }
        for process in current where watched[process] == nil {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.evaluate(epoch, fromEvent: true, source: "process") }
            for var address in Self.processAddresses { AudioObjectAddPropertyListenerBlock(process, &address, queue, block) }
            watched[process] = block
        }
        evaluate(epoch, fromEvent: true, source: "list")
    }
    private func removeListeners(_ process: AudioObjectID, _ block: @escaping AudioObjectPropertyListenerBlock) {
        for var address in Self.processAddresses { AudioObjectRemovePropertyListenerBlock(process, &address, queue, block) }
    }
    /// Queue: is any other process reading input from the virtual microphone?
    private func removeDeviceListener() {
        guard let deviceBlock else { return }
        for var device in Self.deviceAddresses { AudioObjectRemovePropertyListenerBlock(deviceID, &device, queue, deviceBlock) }
        self.deviceBlock = nil
    }
    private func evaluate(_ epoch: Int, fromEvent: Bool, source: String) {
        guard running else { return }
        // Cheapest test first: most processes are not running input at all.
        let client = watched.keys.first {
            AudioState.scalar($0, kAudioProcessPropertyIsRunningInput) != 0 &&
            AudioState.scalar($0, kAudioProcessPropertyPID) != ownPID &&
            AudioState.objects($0, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput).contains(deviceID)
        }
        let active = client != nil
        let name = client.map(Self.name(of:)) ?? ""
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == epoch else { return }
            if fromEvent { self.eventCount += 1 } else if active != self.requested { self.fallbackCount += 1 }
            guard active != self.requested || (active && name != self.clientName) else { return }
            self.requested = active
            if active { self.clientName = name }
            mark("demand \(active ? "on" : "off") via \(source) \(name)")
            self.onChange?(active)
        }
    }
    static func name(of process: AudioObjectID) -> String {
        let pid = pid_t(AudioState.scalar(process, kAudioProcessPropertyPID))
        if let app = NSRunningApplication(processIdentifier: pid)?.localizedName { return app }
        let bundle = Devices.string(process, kAudioProcessPropertyBundleID)
        return bundle.isEmpty ? "" : bundle.components(separatedBy: ".").last ?? bundle
    }
    func stop() {
        generation += 1; requested = false; clientName = ""
        queue.async { [self] in
            running = false
            fallback?.cancel(); fallback = nil
            if let listBlock { var address = Self.listAddress; AudioObjectRemovePropertyListenerBlock(Self.system, &address, queue, listBlock) }
            listBlock = nil
            removeDeviceListener()
            for (process, block) in watched { removeListeners(process, block) }
            watched.removeAll()
        }
    }
    deinit {
        // No queue.sync here: the last reference is often released by a block
        // running on `queue` itself, and a sync would deadlock. Nothing else can
        // touch this state any more, so clean up directly.
        fallback?.cancel()
        if let listBlock { var address = Self.listAddress; AudioObjectRemovePropertyListenerBlock(Self.system, &address, queue, listBlock) }
        removeDeviceListener()
        for (process, block) in watched { removeListeners(process, block) }
    }
}
