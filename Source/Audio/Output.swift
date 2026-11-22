import Foundation
import CoreAudio
import AudioToolbox
import Synchronization
import OSLog

let audioLog = Logger(subsystem: "com.weaveneuron.MicBridge", category: "output")
/// Per-recording timing marks (no audio, no text). Read with:
/// log show --predicate 'subsystem == "com.weaveneuron.MicBridge" AND category == "timing"'
let timingLog = Logger(subsystem: "com.weaveneuron.MicBridge", category: "timing")
func mark(_ text: String) { timingLog.notice("\(text, privacy: .public)") }

// Main-thread producer / audio-thread consumer. No locks, allocation or IO in
// the render loop. Reset is only called after stopping the audio unit.
final class PCMQueue {
    let capacity = 48_000
    let data: UnsafeMutablePointer<Float>
    let read = Atomic<Int>(0)
    let written = Atomic<Int>(0)
    init() { data = .allocate(capacity: capacity); data.initialize(repeating: 0, count: capacity) }
    deinit { data.deinitialize(count: capacity); data.deallocate() }
    var pending: Int { max(0, written.load(ordering: .acquiring) - read.load(ordering: .acquiring)) }
    func reset() { read.store(0, ordering: .relaxed); written.store(0, ordering: .relaxed) }
    func append(_ bytes: Data) throws {
        let n = bytes.count / 4
        guard n > 0, bytes.count % 4 == 0, n <= packetFrames, pending + n <= 24_000 else { throw BridgeError(tr("音频积压或帧格式异常，本次已停止。", "Audio fell behind or arrived malformed; this recording stopped.")) }
        let offset = written.load(ordering: .relaxed)
        try bytes.withUnsafeBytes { raw in
            for i in 0..<n {
                let value = raw.loadUnaligned(fromByteOffset: i * 4, as: Float.self)
                guard value.isFinite, abs(value) <= 4 else { throw BridgeError(tr("音频采样无效。", "Invalid audio samples.")) }
            }
            for i in 0..<n { data[(offset + i) % capacity] = raw.loadUnaligned(fromByteOffset: i * 4, as: Float.self) }
        }
        written.store(offset + n, ordering: .releasing)
    }
}

final class VirtualMicrophone {
    var unit: AudioUnit?
    var running = false
    var generation = UUID()
    var onDrained: (() -> Void)?
    var onFailure: ((String) -> Void)?
    let queue = PCMQueue()
    let ending = Atomic<Bool>(false)
    let playing = Atomic<Bool>(false)
    let notified = Atomic<Bool>(false)
    let underrunCount = Atomic<Int>(0)
    var budget = PlaybackBudget()
    var underruns: Int { underrunCount.load(ordering: .relaxed) }

    func start(device: AudioDevice) throws {
        audioLog.notice("Preparing output-only HAL unit")
        stop()
        guard device.loopback, device.inputChannels > 0, device.outputChannels > 0 else { throw BridgeError(tr("只能向已安装的虚拟麦克风写入音频。", "Audio can only be written to an installed virtual microphone.")) }
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput, componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { throw BridgeError(tr("系统音频输出组件不可用。", "The system audio output unit is unavailable.")) }
        var instance: AudioUnit?
        try check(AudioComponentInstanceNew(component, &instance), tr("创建虚拟麦克风输出", "Creating the virtual microphone output"))
        guard let instance else { throw BridgeError(tr("无法创建系统音频组件。", "Couldn’t create the system audio unit.")) }
        unit = instance
        do {
            var disabled: UInt32 = 0, enabled: UInt32 = 1, id = device.id
            audioLog.notice("Disabling input IO")
            try check(AudioUnitSetProperty(instance, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &disabled, 4), tr("关闭输出组件的输入端", "Disabling the output unit’s input"))
            audioLog.notice("Enabling output IO")
            try check(AudioUnitSetProperty(instance, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enabled, 4), tr("启用音频输出", "Enabling audio output"))
            audioLog.notice("Selecting virtual output device")
            try check(AudioUnitSetProperty(instance, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, 4), tr("选择虚拟麦克风", "Selecting the virtual microphone"))
            audioLog.notice("Device selected; setting format")
            var format = AudioStreamBasicDescription(mSampleRate: pcmRate, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
                mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
            try check(AudioUnitSetProperty(instance, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, UInt32(MemoryLayout.size(ofValue: format))), tr("设置虚拟麦克风格式", "Setting the virtual microphone format"))
            var callback = AURenderCallbackStruct(inputProc: { context, _, _, _, frames, buffers in
                guard let buffers else { return noErr }
                return Unmanaged<VirtualMicrophone>.fromOpaque(context).takeUnretainedValue().render(frames: Int(frames), buffers: buffers)
            }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
            try check(AudioUnitSetProperty(instance, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, UInt32(MemoryLayout.size(ofValue: callback))), tr("设置音频写入回调", "Setting the audio callback"))
            try check(AudioUnitInitialize(instance), tr("准备虚拟麦克风", "Preparing the virtual microphone"))
            audioLog.notice("Output initialized")
            var actual: AudioDeviceID = 0, size: UInt32 = 4
            try check(AudioUnitGetProperty(instance, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &actual, &size), tr("核对输出设备", "Checking the output device"))
            guard actual == device.id else { throw BridgeError(tr("输出设备不匹配，已停止。", "The output device didn’t match; stopped.")) }
        } catch { stop(); throw error }
    }
    func check(_ code: OSStatus, _ operation: String) throws { guard code == noErr else { throw BridgeError(tr("\(operation)失败（\(code)）。", "\(operation) failed (\(code)).")) } }
    func begin() {
        cancel(); notified.store(false, ordering: .relaxed)
        guard let unit else { onFailure?(tr("虚拟麦克风尚未就绪。", "The virtual microphone isn’t ready yet.")); return }
        let result = AudioOutputUnitStart(unit)
        if result == noErr { running = true }
        else { DispatchQueue.main.async { [weak self] in self?.onFailure?(tr("无法启动音频写入（\(result)）。", "Couldn’t start writing audio (\(result)).")) } }
    }
    func enqueue(_ data: Data) throws {
        guard unit != nil, running else { throw BridgeError(tr("虚拟麦克风输出尚未运行。", "The virtual microphone output isn’t running.")) }
        try queue.append(data); budget.pendingFrames = queue.pending; budget.totalFrames += data.count / 4
    }
    func end() {
        budget.ending = true; ending.store(true, ordering: .releasing)
        if queue.pending == 0, !notified.exchange(true, ordering: .acquiringAndReleasing) { completeDrain() }
    }
    func completeDrain() {
        budget.pendingFrames = queue.pending
        if budget.pendingFrames == 0 { onDrained?() }
    }
    func render(frames: Int, buffers: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let list = UnsafeMutableAudioBufferListPointer(buffers)
        for buffer in list { if let p = buffer.mData { memset(p, 0, Int(buffer.mDataByteSize)) } }
        let offset = queue.read.load(ordering: .relaxed), available = max(0, queue.written.load(ordering: .acquiring) - offset)
        let finishing = ending.load(ordering: .acquiring)
        if !playing.load(ordering: .relaxed), available >= packetFrames * 2 || (finishing && available > 0) {
            playing.store(true, ordering: .relaxed)
        }
        guard playing.load(ordering: .relaxed) else { return noErr }
        let n = min(frames, available)
        for buffer in list {
            guard let pointer = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let channels = max(1, Int(buffer.mNumberChannels)), capacity = Int(buffer.mDataByteSize) / 4
            for i in 0..<min(n, capacity / channels) {
                let value = queue.data[(offset + i) % queue.capacity]
                for channel in 0..<channels { pointer[i * channels + channel] = value }
            }
        }
        queue.read.store(offset + n, ordering: .releasing)
        if n < frames, !finishing { _ = underrunCount.wrappingAdd(1, ordering: .relaxed) }
        if finishing, offset + n >= queue.written.load(ordering: .acquiring), !notified.exchange(true, ordering: .acquiringAndReleasing) {
            let epoch = generation
            DispatchQueue.main.async { [weak self] in if self?.generation == epoch { self?.completeDrain() } }
        }
        return noErr
    }
    func cancel() {
        if let unit, running { AudioOutputUnitStop(unit) }
        generation = UUID()
        running = false; queue.reset(); budget = PlaybackBudget()
        ending.store(false, ordering: .relaxed); playing.store(false, ordering: .relaxed); notified.store(false, ordering: .relaxed); underrunCount.store(0, ordering: .relaxed)
    }
    func stop() {
        cancel()
        if let unit { AudioUnitUninitialize(unit); AudioComponentInstanceDispose(unit) }
        unit = nil
    }
    deinit { stop() }
}
