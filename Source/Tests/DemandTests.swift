import Foundation
import AudioToolbox

func runDemandTests() throws {
    var count = 0
    func check(_ value: Bool, _ label: String) throws { guard value else { throw BridgeError("FAIL: \(label)") }; count += 1; print("PASS: \(label)") }
    var policy = DemandPolicy()
    try check(policy.observe(true, available: false, active: false, now: 0) == .none, "no capture while the provider is unavailable")
    try check(policy.observe(true, available: true, active: false, now: 0) == .start, "an app already listening gets audio once the provider connects")
    try check(policy.observe(true, available: true, active: true, now: 0) == .none, "a continuing recording does not start duplicates")
    try check(policy.observe(false, available: true, active: true, now: 0) == .stop, "the provider microphone closes when the app stops")
    try check(policy.observe(false, available: false, active: true, now: 0) == .stop, "stop is honoured even while unavailable")
    _ = policy.observe(true, available: false, active: false, now: 0)
    _ = policy.observe(false, available: false, active: false, now: 0)
    try check(policy.observe(false, available: true, active: false, now: 0) == .none, "a recording that ended while unavailable is never replayed")
    policy.failed(now: 10)
    try check(policy.observe(true, available: true, active: false, now: 10.5) == .none, "a failed capture backs off before retrying")
    try check(policy.observe(true, available: true, active: false, now: 11.1) == .start, "a failed capture retries after the back-off")
    policy.failed(now: 12); policy.failed(now: 14)
    try check(policy.observe(true, available: true, active: false, now: 100) == .none, "repeated failures stop retrying for this recording")
    _ = policy.observe(false, available: true, active: false, now: 100)
    try check(policy.observe(true, available: true, active: false, now: 100) == .start, "a new recording after failures works")
    for _ in 0..<20 {
        try check(policy.observe(false, available: true, active: true, now: 100) == .stop && policy.observe(true, available: true, active: false, now: 100) == .start, "consecutive recordings remain usable")
    }
    // Real Core Audio listeners (no audio IO is opened): start, stop and release
    // must neither deadlock nor leave the monitor alive.
    weak var released: DemandMonitor?
    do {
        let monitor = DemandMonitor(); released = monitor
        if let device = Devices.all().first {
            monitor.start(device: device)
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            monitor.stop()
        }
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    try check(released == nil, "demand monitor stops its listeners and is released without deadlock")
    let output = VirtualMicrophone()
    let samples = (0..<(packetFrames * 2)).map { Float($0 % 97) / 100 }
    let audio = samples.withUnsafeBytes { Data($0) }
    try output.queue.append(Data(audio.prefix(packetFrames * 4)))
    let rendered = UnsafeMutablePointer<Float>.allocate(capacity: packetFrames * 2)
    rendered.initialize(repeating: -1, count: packetFrames * 2)
    defer { rendered.deinitialize(count: packetFrames * 2); rendered.deallocate() }
    var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(packetFrames * 2 * 4), mData: rendered))
    _ = output.render(frames: packetFrames * 2, buffers: &list)
    try check(output.queue.pending == packetFrames && rendered[0] == 0, "output waits for jitter buffer and writes silence")
    try output.queue.append(Data(audio.suffix(packetFrames * 4)))
    output.ending.store(true, ordering: .releasing)
    _ = output.render(frames: packetFrames * 2, buffers: &list)
    try check(output.queue.pending == 0 && Array(UnsafeBufferPointer(start: rendered, count: samples.count)) == samples, "render callback preserves exact PCM and drains")
    output.cancel()
    _ = output.render(frames: packetFrames * 2, buffers: &list)
    try check(rendered[0] == 0 && output.queue.pending == 0, "cancelled audio cannot leak into a later recording")
    var invalid = Float.nan
    do { try output.queue.append(withUnsafeBytes(of: &invalid) { Data($0) }); throw BridgeError("FAIL: non-finite audio accepted") }
    catch { try check(output.queue.pending == 0, "invalid samples do not publish partial output") }
    let maxQueue = PCMQueue()
    let packet = Data(repeating: 0, count: packetFrames * 4)
    for _ in 0..<25 { try maxQueue.append(packet) }
    var rejected = false
    do { try maxQueue.append(packet) } catch { rejected = true }
    try check(rejected && maxQueue.pending == 24_000, "output queue enforces half-second latency budget")
    print("\(count) demand lifecycle tests passed. No microphone or keyboard access.")
}
