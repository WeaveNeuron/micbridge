import CoreAudio
import Foundation

/// Calls back on the main queue whenever Core Audio's device list changes:
/// a driver installed or removed, a microphone plugged in.
final class AudioDeviceWatcher {
    private var block: AudioObjectPropertyListenerBlock?
    private static var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                                            mElement: kAudioObjectPropertyElementMain)
    func start(_ changed: @escaping () -> Void) {
        stop()
        let listener: AudioObjectPropertyListenerBlock = { _, _ in changed() }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.address, .main, listener) == noErr { block = listener }
    }
    func stop() {
        guard let block else { return }
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.address, .main, block)
        self.block = nil
    }
}
