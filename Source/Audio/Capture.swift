import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox
import os

private let halLog = Logger(subsystem: "com.weaveneuron.MicBridge", category: "hal")

/// Core Audio calls are synchronous IPC to the audio server and can take
/// seconds when it is busy. They run on background queues; the main thread
/// only ever waits for their results to arrive.
enum AudioHAL {
    /// Device lists and other one-off queries.
    static let queue = DispatchQueue(label: "micbridge.audio.hal", qos: .userInitiated)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var caught: [String] = []
    /// HAL work that ran on the main thread (`offMain` records it).
    static var violations: [String] { lock.withLock { caught } }
    static func resetViolations() { lock.withLock { caught.removeAll() } }
    /// Marks the start of HAL work that must stay off the main thread.
    static func offMain(_ what: String) {
        guard Thread.isMainThread else { return }
        lock.withLock { caught.append(what) }
        halLog.fault("Core Audio call on the main thread: \(what, privacy: .public)")
    }
}

/// What the capture side needs from the audio hardware. The real one wraps
/// AVAudioEngine; tests inject a fake to count builds and check threads.
/// Every method is called on `Microphone`'s control queue.
protocol CaptureGraph: AnyObject {
    var deviceUID: String { get }
    func start() throws
    func pause()
    func stop()
    /// Still bound to its device with the format it was built for.
    func stillMatches() -> Bool
}

/// Where a graph delivers its results. `samples` and `failure` are called on
/// `processing` (serial: finishing waits for it), `changed` on whatever
/// thread AVFAudio posts from.
struct CaptureSink {
    var processing: DispatchQueue
    var samples: (Data, Float, TimeInterval) -> Void
    var failure: (String) -> Void
    var changed: () -> Void
}

typealias CaptureFactory = (AudioDevice, CaptureSink) throws -> CaptureGraph

enum MicrophoneError: LocalizedError {
    case cancelled, deviceMissing
    var errorDescription: String? {
        switch self {
        case .cancelled: return tr("麦克风操作已取消。", "The microphone request was cancelled.")
        case .deviceMissing: return tr("选定的麦克风已断开，请在设置中重新选择。", "The selected microphone was disconnected. Choose another in Settings.")
        }
    }
}

/// The sharing Mac's microphone. Called on the main thread; every Core Audio
/// call (building the graph, starting, pausing, stopping, format checks)
/// runs in order on a private serial queue, and results come back on main.
///
/// The graph is built once per device and kept: a reconnect reuses it, and
/// only a pause, another device or a real configuration change drops it.
final class Microphone {
    var onPCM: ((Data, Float) -> Void)?
    var onFailure: ((String) -> Void)?
    var onConfigurationChange: (() -> Void)?

    /// Main-thread view of the graph: built for this device, IO running.
    private(set) var preparedDeviceUID: String?
    private(set) var isRunning = false
    /// Graphs built so far (tests).
    private(set) var builds = 0
    private(set) var configurationEvents = 0
    private(set) var ignoredConfigurationEvents = 0

    private let control = DispatchQueue(label: "micbridge.capture.control", qos: .userInitiated)
    private let processing = DispatchQueue(label: "micbridge.capture", qos: .userInteractive)
    private let factory: CaptureFactory
    /// Only touched on `control`.
    private final class Box { var graph: CaptureGraph? }
    private let box = Box()
    /// Changes whenever the graph is dropped; late results are ignored.
    private var generation = UUID()
    /// Changes whenever IO is closed; a start still in flight then reports cancelled.
    private var ioEpoch = UUID()
    private var pending: (uid: String, waiting: [(Error?) -> Void])?

    init(factory: @escaping CaptureFactory = EngineCapture.make) { self.factory = factory }
    deinit { let box = box; control.async { box.graph?.stop(); box.graph = nil } }

    /// Builds the idle graph for `device` (never starts IO). Completes at once
    /// when it is already built; a second request while one is building
    /// waits for the same build.
    func prepare(device: AudioDevice, completion: @escaping (Error?) -> Void) {
        if preparedDeviceUID == device.uid { completion(nil); return }
        if let pending, pending.uid == device.uid { self.pending?.waiting.append(completion); return }
        pending.map { finish($0.waiting, MicrophoneError.cancelled) }
        pending = (device.uid, [completion])
        let epoch = generation
        control.async { [box] in
            let result = Result { try self.ensure(device, in: box, epoch: epoch) }
            DispatchQueue.main.async {
                guard self.generation == epoch, self.pending?.uid == device.uid else { return }
                let waiting = self.pending?.waiting ?? []; self.pending = nil
                self.settle(result, uid: device.uid)
                self.finish(waiting, result.error)
            }
        }
    }
    /// Opens the microphone. Builds first when needed; `refresh` looks the
    /// device up again by UID (after a configuration change).
    func start(device: AudioDevice, refresh: Bool = false, completion: @escaping (Error?) -> Void) {
        let epoch = generation, io = ioEpoch
        control.async { [box] in
            let result = Result {
                var target = device
                if refresh {
                    guard let fresh = Devices.all().first(where: { $0.uid == device.uid && $0.inputChannels > 0 }) else { throw MicrophoneError.deviceMissing }
                    target = fresh
                }
                let built = try self.ensure(target, in: box, epoch: epoch)
                try box.graph?.start()
                return built
            }
            DispatchQueue.main.async {
                guard self.generation == epoch else { completion(MicrophoneError.cancelled); return }
                self.settle(result, uid: device.uid)
                guard self.ioEpoch == io else { completion(MicrophoneError.cancelled); return }
                if case .success = result { self.isRunning = true }
                completion(result.error)
            }
        }
    }
    /// Stops taking samples, delivers those already taken, then completes.
    /// The graph stays built for the next recording.
    func finish(_ completion: @escaping () -> Void) {
        let epoch = generation
        control.async { [box, processing] in
            box.graph?.pause()
            processing.async {
                DispatchQueue.main.async {
                    guard self.generation == epoch else { return }
                    self.isRunning = false
                    completion()
                }
            }
        }
    }
    /// Closes the microphone at once; the graph stays built (a reconnect
    /// reuses it). Samples still in flight are dropped.
    func close() {
        isRunning = false; ioEpoch = UUID()
        control.async { [box] in box.graph?.stop() }
    }
    /// Drops the graph: the bridge paused, the device changed, or its
    /// format did. The next prepare or start builds a new one.
    func discard() {
        generation = UUID(); ioEpoch = UUID(); isRunning = false; preparedDeviceUID = nil
        pending.map { finish($0.waiting, MicrophoneError.cancelled) }; pending = nil
        control.async { [box] in box.graph?.stop(); box.graph = nil }
    }
    /// Privacy check: does this process still record from any device? If so
    /// (and `close`), IO is stopped. Reports whether it still was running.
    func checkOwnInput(close: Bool, completion: @escaping (_ wasRunning: Bool, _ stillRunning: Bool) -> Void) {
        control.async { [box] in
            AudioHAL.offMain("ownInputRunning")
            let was = AudioState.ownInputRunning()
            if was, close { box.graph?.stop() }
            let still = was && close ? AudioState.ownInputRunning() : was
            DispatchQueue.main.async {
                if was, close { self.isRunning = false }
                completion(was, still)
            }
        }
    }

    // MARK: Control queue

    /// Builds a graph for `device` unless the current one still fits.
    /// True when it built one.
    private func ensure(_ device: AudioDevice, in box: Box, epoch: UUID) throws -> Bool {
        AudioHAL.offMain("Microphone.ensure")
        guard device.inputChannels > 0, !device.containsVirtual else {
            throw BridgeError(tr("请选择内置麦克风或实体麦克风。", "Choose the built-in or another physical microphone."))
        }
        if let graph = box.graph, graph.deviceUID == device.uid { return false }
        box.graph?.stop(); box.graph = nil
        var built: CaptureGraph?
        let sink = CaptureSink(
            processing: processing,
            samples: { [weak self] data, peak, acquired in
                DispatchQueue.main.async { self?.deliver(data, peak: peak, acquired: acquired, epoch: epoch) }
            },
            failure: { [weak self] reason in
                DispatchQueue.main.async { guard let self, self.generation == epoch, self.isRunning else { return }; self.onFailure?(reason) }
            },
            changed: { [weak self, box] in
                self?.control.async {
                    guard let self, let graph = built, box.graph === graph else { return }
                    let same = graph.stillMatches()
                    DispatchQueue.main.async {
                        guard self.generation == epoch else { return }
                        self.configurationEvents += 1
                        if same { self.ignoredConfigurationEvents += 1 } else { self.onConfigurationChange?() }
                    }
                }
            })
        let graph = try factory(device, sink)
        built = graph; box.graph = graph
        return true
    }

    // MARK: Main thread

    private func settle(_ result: Result<Bool, Error>, uid: String) {
        switch result {
        case .success(let built): preparedDeviceUID = uid; if built { builds += 1 }
        case .failure: preparedDeviceUID = nil
        }
    }
    private func finish(_ waiting: [(Error?) -> Void], _ error: Error?) { for done in waiting { done(error) } }
    private func deliver(_ data: Data, peak: Float, acquired: TimeInterval, epoch: UUID) {
        guard generation == epoch, isRunning else { return }
        guard ProcessInfo.processInfo.systemUptime - acquired < 0.3 else {
            onFailure?(tr("音频处理积压超过 300 ms，请降低系统负载。", "Audio fell more than 300 ms behind. Reduce the system load."))
            return
        }
        onPCM?(data, peak)
    }
}

private extension Result {
    var error: Failure? { if case .failure(let e) = self { return e }; return nil }
}
private extension Result where Failure == Error {
    init(_ body: () throws -> Success) { do { self = .success(try body()) } catch { self = .failure(error) } }
}

/// The real capture graph: AVAudioEngine's input node feeding a sink node.
final class EngineCapture: CaptureGraph {
    let deviceUID: String
    private let deviceID: AudioDeviceID
    private let engine = AVAudioEngine()
    private let source: AVAudioFormat
    private var observer: NSObjectProtocol?

    static func make(_ device: AudioDevice, _ sink: CaptureSink) throws -> CaptureGraph { try EngineCapture(device, sink) }

    private init(_ device: AudioDevice, _ sink: CaptureSink) throws {
        AudioHAL.offMain("EngineCapture")
        deviceUID = device.uid; deviceID = device.id
        let input = engine.inputNode
        guard let unit = input.audioUnit else { throw BridgeError(tr("麦克风音频单元不可用。", "The microphone’s audio unit is unavailable.")) }
        var id = device.id
        let selected = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard selected == noErr else { throw BridgeError(tr("无法选择麦克风（\(selected)）。", "Couldn’t select the microphone (\(selected)).")) }
        let source = input.outputFormat(forBus: 0)
        guard source.sampleRate > 0, source.channelCount > 0,
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: pcmRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: source, to: output) else { throw BridgeError(tr("麦克风音频格式不可用。", "The microphone’s audio format is unavailable.")) }
        self.source = source
        converter.primeMethod = .none
        let processing = sink.processing
        // AVAudioSinkNode runs at the hardware IO size (~512 frames, 11.6 ms).
        // installTap on macOS ignores small requests and delivers 100 ms blocks,
        // which delayed the first word and dropped the last one at release.
        let node = AVAudioSinkNode { _, frameCount, list -> OSStatus in
            // Realtime IO thread: copy the samples out and return immediately.
            let acquired = ProcessInfo.processInfo.systemUptime
            guard frameCount > 0, let copied = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: frameCount) else { return noErr }
            copied.frameLength = frameCount
            let from = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
            let to = UnsafeMutableAudioBufferListPointer(copied.mutableAudioBufferList)
            for index in 0..<min(from.count, to.count) {
                if let src = from[index].mData, let dst = to[index].mData {
                    memcpy(dst, src, Int(min(from[index].mDataByteSize, to[index].mDataByteSize)))
                }
            }
            processing.async {
                do {
                    let (data, peak) = try convertPCM(copied, using: converter, target: output)
                    if !data.isEmpty { sink.samples(data, peak, acquired) }
                } catch { sink.failure(tr("音频转换失败。", "Audio conversion failed.")) }
            }
            return noErr
        }
        engine.attach(node)
        engine.connect(input, to: node, format: source)
        // prepare allocates resources but does not start the audio IO thread.
        engine.prepare()
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { _ in sink.changed() }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func start() throws { AudioHAL.offMain("EngineCapture.start"); try engine.start() }
    func pause() { engine.pause() }
    func stop() { engine.stop() }
    func stillMatches() -> Bool {
        AudioHAL.offMain("EngineCapture.stillMatches")
        guard let unit = engine.inputNode.audioUnit else { return false }
        var current: AudioDeviceID = 0; var size: UInt32 = 4
        let status = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &current, &size)
        return status == noErr && current == deviceID && engine.inputNode.outputFormat(forBus: 0) == source
    }
}
