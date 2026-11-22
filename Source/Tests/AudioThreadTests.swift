import Foundation
import CoreAudio

/// The sharing Mac's capture path: which device it may use, that Core Audio
/// work never runs on the main thread, that reconnecting reuses the graph,
/// and that a flapping link backs off. A fake graph stands in for
/// AVAudioEngine, so nothing records and no permission is needed.
func runAudioThreadTests() throws {
    var count = 0
    func check(_ condition: Bool, _ description: String) throws {
        guard condition else { throw BridgeError("FAIL: \(description)") }
        count += 1; print("PASS: \(description)")
    }
    func spin(_ seconds: TimeInterval, until done: () -> Bool = { false }) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    // Which microphone the sharing Mac may send.
    let virtual = AudioDevice(id: 1, uid: VirtualDevice.uid, name: "MicBridge Microphone", inputChannels: 2, outputChannels: 2, builtIn: false)
    let aggregate = AudioDevice(id: 2, uid: "Aggregate-1", name: "Aggregate", inputChannels: 3, outputChannels: 2, builtIn: false,
                                subDevices: ["BuiltInMic", VirtualDevice.uid])
    let builtIn = AudioDevice(id: 3, uid: "BuiltInMic", name: "MacBook Microphone", inputChannels: 1, outputChannels: 0, builtIn: true)
    let usb = AudioDevice(id: 4, uid: "USB-1", name: "USB Microphone", inputChannels: 1, outputChannels: 0, builtIn: false)
    let plainAggregate = AudioDevice(id: 5, uid: "Aggregate-2", name: "Aggregate 2", inputChannels: 2, outputChannels: 0, builtIn: false,
                                     subDevices: ["BuiltInMic", "USB-1"])
    let all = [virtual, aggregate, builtIn, usb, plainAggregate]
    try check(virtual.containsVirtual && aggregate.containsVirtual && !builtIn.containsVirtual && !plainAggregate.containsVirtual,
              "MicBridge Microphone and aggregates built on it are recognised")
    try check(SourcePicker.candidates(all).map(\.uid) == ["BuiltInMic", "USB-1", "Aggregate-2"],
              "the sharing Mac never lists its own virtual microphone or an aggregate containing it")
    try check(SourcePicker.pick(all, saved: VirtualDevice.uid, defaultInput: 1)?.uid == "BuiltInMic" &&
              SourcePicker.pick(all, saved: "Aggregate-1", defaultInput: 2)?.uid == "BuiltInMic",
              "a saved or default virtual device is never shared; the built-in microphone is")
    try check(SourcePicker.pick([virtual, aggregate, usb], saved: nil, defaultInput: 1)?.uid == "USB-1" &&
              SourcePicker.pick([virtual, aggregate], saved: nil, defaultInput: 1) == nil,
              "without a built-in microphone another real one is used, never the virtual one")
    try check(SourcePicker.pick(all, saved: "USB-1", defaultInput: 3)?.uid == "USB-1", "a saved real microphone is kept")

    // The thread check itself.
    AudioHAL.resetViolations()
    AudioHAL.offMain("probe")
    try check(AudioHAL.violations == ["probe"], "Core Audio work on the main thread is caught")
    AudioHAL.resetViolations()

    let fake = FakeCapture(delay: 0.25)
    let microphone = Microphone(factory: fake.make)
    var refused: Error?
    microphone.prepare(device: virtual) { refused = $0 }
    spin(2) { refused != nil }
    try check(refused != nil && fake.builds == 0, "the microphone refuses to build on MicBridge Microphone")
    refused = nil
    microphone.prepare(device: aggregate) { refused = $0 }
    spin(2) { refused != nil }
    try check(refused != nil && fake.builds == 0, "…or on an aggregate device containing it")

    let host = RecordingHost()
    let provider = ProviderController(microphone: microphone)
    provider.host = host; provider.device = builtIn
    provider.isActive = { true }; provider.isLinkReady = { true }

    // Reconnect storm: one build, the main thread never waits.
    let before = Date()
    provider.linkUp()
    let blocked = Date().timeIntervalSince(before)
    try check(blocked < 0.05, "a link coming up returns at once while the graph builds (\(Int(blocked * 1000)) ms)")
    try check(host.count("ready") == 0, "ready waits for the graph")
    spin(3) { host.count("ready") == 1 }
    try check(host.count("ready") == 1 && fake.builds == 1, "ready follows the first build")
    for round in 1...20 {
        provider.reset()
        provider.linkUp()
        spin(1) { host.count("ready") == round + 1 }
    }
    try check(host.count("ready") == 21 && fake.builds == 1 && microphone.builds == 1,
              "20 reconnects reuse the graph: built once (\(fake.builds))")
    provider.linkUp(); provider.linkUp()
    spin(1) { host.count("ready") == 23 }
    try check(host.count("ready") == 23 && fake.builds == 1, "a replaced link says ready again without rebuilding")

    provider.shutDown()
    provider.linkUp(); provider.linkUp(); provider.linkUp()
    spin(3) { host.count("ready") == 26 }
    try check(fake.builds == 2 && host.count("ready") == 26, "links that come up while it builds share one build")
    provider.shutDown()
    provider.linkUp(); provider.reset()
    spin(0.6)
    try check(host.count("ready") == 26, "a link lost while the graph builds says nothing")
    spin(2) { microphone.preparedDeviceUID != nil }

    // A recording on the reused graph.
    let builds = fake.builds
    provider.handle(Message(kind: "start", session: "s1"))
    try check(host.count("started") == 0, "start returns before the microphone opens")
    spin(2) { host.count("started") == 1 }
    try check(host.count("started") == 1 && fake.starts == 1 && fake.builds == builds && microphone.isRunning,
              "a recording opens the prepared graph without rebuilding it")
    provider.handle(Message(kind: "stop", session: "s1"))
    spin(2) { host.count("ended") == 1 && host.count("idle") == 1 }
    try check(host.count("ended") == 1 && host.count("idle") == 1 && fake.pauses == 1 && !microphone.isRunning,
              "stopping closes the microphone and reports idle")

    // Configuration changes: our own device switch is ignored, a real one drops the graph.
    fake.changed()
    spin(1) { microphone.configurationEvents == 1 }
    try check(microphone.ignoredConfigurationEvents == 1 && microphone.preparedDeviceUID == builtIn.uid,
              "a configuration notice with the same device and format keeps the graph")
    fake.matches = false; fake.changed()
    spin(1) { microphone.configurationEvents == 2 }
    try check(microphone.preparedDeviceUID == nil, "a real format change in standby drops the graph")
    fake.matches = true
    provider.linkUp()
    spin(3) { fake.builds == builds + 1 }
    try check(fake.builds == builds + 1, "…and the next link builds a fresh one")

    try check(fake.mainThreadCalls == 0, "no graph call ran on the main thread")
    try check(AudioHAL.violations.isEmpty, "no Core Audio work was flagged on the main thread")
    provider.shutDown()

    // Back-off: a link that keeps dropping right after its handshake.
    var state = ConnectionState(role: .provider)
    _ = state.reduce(.start, now: 0); _ = state.reduce(.dialTarget(true), now: 0)
    var t: TimeInterval = 0, delays: [TimeInterval] = []
    for _ in 0..<6 {
        _ = state.reduce(.dialStarted, now: t); _ = state.reduce(.handshakeOK, now: t)
        t += 0.5
        _ = state.reduce(.closed(.heartbeat), now: t)
        delays.append(state.retryAt - t)
        t = state.retryAt
    }
    try check(delays == [1, 2, 4, 8, 10, 10], "a link that drops right after its handshake backs off: \(delays)")
    _ = state.reduce(.dialStarted, now: t); _ = state.reduce(.handshakeOK, now: t)
    _ = state.reduce(.closed(.heartbeat), now: t + ConnectionState.stableLink)
    try check(state.retryAt - (t + ConnectionState.stableLink) == 1, "a link that stayed up starts the back-off over")

    print("Audio thread tests: \(count) passed")
}

/// Stands in for AVAudioEngine: slow to build, counts calls, notes the thread.
private final class FakeCapture {
    let delay: TimeInterval
    private let lock = NSLock()
    private var _builds = 0, _starts = 0, _pauses = 0, _main = 0
    private var sink: CaptureSink?
    var matches = true
    init(delay: TimeInterval) { self.delay = delay }
    var builds: Int { lock.withLock { _builds } }
    var starts: Int { lock.withLock { _starts } }
    var pauses: Int { lock.withLock { _pauses } }
    var mainThreadCalls: Int { lock.withLock { _main } }
    func note(_ what: String) {
        AudioHAL.offMain("fake.\(what)")
        lock.withLock {
            if Thread.isMainThread { _main += 1 }
            switch what { case "build": _builds += 1; case "start": _starts += 1; case "pause": _pauses += 1; default: break }
        }
    }
    func make(_ device: AudioDevice, _ sink: CaptureSink) throws -> CaptureGraph {
        note("build")
        Thread.sleep(forTimeInterval: delay)
        lock.withLock { self.sink = sink }
        return Graph(uid: device.uid, owner: self)
    }
    func changed() { lock.withLock { sink }?.changed() }

    final class Graph: CaptureGraph {
        let deviceUID: String
        let owner: FakeCapture
        init(uid: String, owner: FakeCapture) { deviceUID = uid; self.owner = owner }
        func start() throws { owner.note("start") }
        func pause() { owner.note("pause") }
        func stop() { owner.note("stop") }
        func stillMatches() -> Bool { owner.note("matches"); return owner.matches }
    }
}

private final class RecordingHost: RoleHost {
    var sent: [String] = []
    func count(_ kind: String) -> Int { sent.filter { $0 == kind }.count }
    func send(_ message: Message) { sent.append(message.kind) }
    func transient(_ text: String) {}
    func status(_ text: String) {}
    func captureChanged() {}
}
