import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox

let pcmRate: Double = 48_000
let packetFrames = 960 // 20 ms for the LAN hop; independent of hardware tap sizes.

struct AudioDevice {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let inputChannels: Int
    let outputChannels: Int
    let builtIn: Bool
    /// An aggregate device's members, by UID (empty for other devices).
    var subDevices: [String] = []
    var loopback: Bool { uid == VirtualDevice.uid }
    /// MicBridge Microphone itself, or an aggregate device built on it.
    /// Sharing either would send this Mac's own virtual microphone back.
    var containsVirtual: Bool { loopback || subDevices.contains(VirtualDevice.uid) }
}

/// The devices and the default input, read together off the main thread.
struct DeviceSnapshot {
    var all: [AudioDevice] = []
    var defaultInput: AudioDeviceID = 0
}

/// Which microphone the sharing Mac sends. Pure, so it is tested without
/// hardware: never MicBridge Microphone or an aggregate containing it, even
/// when it is the saved choice or the system's default input.
enum SourcePicker {
    static func candidates(_ all: [AudioDevice]) -> [AudioDevice] {
        all.filter { $0.inputChannels > 0 && !$0.containsVirtual }
    }
    static func pick(_ devices: [AudioDevice], saved: String?, defaultInput: AudioDeviceID) -> AudioDevice? {
        let usable = candidates(devices)
        if let saved, let device = usable.first(where: { $0.uid == saved }) { return device }
        return usable.first { $0.builtIn } ?? usable.first { $0.id == defaultInput } ?? usable.first
    }
}

enum Devices {
    static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?; var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return "" }
        return value?.takeRetainedValue() as String? ?? ""
    }
    static func channels(_ id: AudioDeviceID, _ scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, memory) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
    }
    /// Every device and the default input. Synchronous IPC to the audio
    /// server: call it on `AudioHAL.queue`, never on the main thread.
    static func snapshot() -> DeviceSnapshot {
        AudioHAL.offMain("Devices.snapshot")
        return DeviceSnapshot(all: all(), defaultInput: defaultInput())
    }
    static func subDevices(_ id: AudioDeviceID) -> [String] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioAggregateDevicePropertyFullSubDeviceList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFArray>?; var size = UInt32(MemoryLayout<Unmanaged<CFArray>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return [] }
        return value?.takeRetainedValue() as? [String] ?? []
    }
    static func all() -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.map { id in
            var transportAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var transport: UInt32 = 0; var transportSize: UInt32 = 4
            AudioObjectGetPropertyData(id, &transportAddress, 0, nil, &transportSize, &transport)
            return AudioDevice(id: id, uid: string(id, kAudioDevicePropertyDeviceUID), name: string(id, kAudioObjectPropertyName),
                inputChannels: channels(id, kAudioObjectPropertyScopeInput), outputChannels: channels(id, kAudioObjectPropertyScopeOutput), builtIn: transport == kAudioDeviceTransportTypeBuiltIn,
                subDevices: transport == kAudioDeviceTransportTypeAggregate ? subDevices(id) : [])
        }
    }
    @discardableResult static func setDefaultInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value = id
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &value) == noErr
    }
    static func defaultInput() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id: AudioDeviceID = 0; var size: UInt32 = 4
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return id
    }
}

// Packetization and pre-roll contain no hardware dependencies, so timing and boundary
// cases are tested without recording from a microphone.
struct Packetizer {
    var pending = Data()
    mutating func append(_ data: Data) -> [Data] {
        pending.append(data)
        var packets: [Data] = []
        while pending.count >= packetFrames * 4 {
            packets.append(Data(pending.prefix(packetFrames * 4)))
            pending.removeFirst(packetFrames * 4)
        }
        return packets
    }
    mutating func finish() -> Data? {
        defer { pending.removeAll(keepingCapacity: true) }
        return pending.isEmpty ? nil : pending
    }
}

func convertPCM(_ input: AVAudioPCMBuffer, using converter: AVAudioConverter, target: AVAudioFormat) throws -> (Data, Float) {
    let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * target.sampleRate / input.format.sampleRate)) + 64
    guard let result = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { throw BridgeError(tr("无法分配音频转换缓冲区。", "Couldn’t allocate the audio conversion buffer.")) }
    var supplied = false; var error: NSError?
    let state = converter.convert(to: result, error: &error) { _, inputStatus in
        if supplied { inputStatus.pointee = .noDataNow; return nil }
        supplied = true; inputStatus.pointee = .haveData; return input
    }
    guard state != .error else { throw BridgeError(tr("音频转换失败。", "Audio conversion failed.")) }
    guard let samples = result.floatChannelData?[0], result.frameLength > 0 else { return (Data(), 0) }
    let count = Int(result.frameLength)
    var peak: Float = 0
    for i in 0..<count { peak = max(peak, abs(samples[i])) }
    return (Data(bytes: samples, count: count * 4), peak)
}

struct PlaybackBudget {
    var pendingFrames = 0
    var totalFrames = 0
    var ending = false
    var started = false
    mutating func enqueue(_ frames: Int) throws {
        guard frames > 0, frames <= packetFrames, pendingFrames + frames <= 24_000 else {
            throw BridgeError(tr("音频积压超过半秒，已停止本次输入。", "Audio fell half a second behind; this input stopped."))
        }
        pendingFrames += frames; totalFrames += frames
    }
    mutating func completed(_ frames: Int) { pendingFrames = max(0, pendingFrames - frames) }
    var shouldPlay: Bool { !started && pendingFrames > 0 && (pendingFrames >= packetFrames * 2 || ending) }
    var drained: Bool { ending && pendingFrames == 0 }
}

