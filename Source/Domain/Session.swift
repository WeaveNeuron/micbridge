import Foundation

struct CaptureRecovery {
    private(set) var attempts = 0
    mutating func request() -> Bool {
        guard attempts < 2 else { return false }
        attempts += 1
        return true
    }
    static func shouldResume(original: String, current: String?, stopping: Bool) -> Bool {
        original == current && !stopping
    }
}

/// Upper bound for one continuous capture (long transcription is fine; a stuck client is not).
let maxVoiceDuration: TimeInterval = 1800

struct VoiceSession {
    let id: String
    var expectedSequence: UInt64 = 0
    var endRequested = false
    var streamStarted = false
    var streamEnded = false
    var endedAt: TimeInterval?
    var startedAt: TimeInterval
    var lastAudioAt: TimeInterval
    init(id: String = UUID().uuidString, now: TimeInterval = ProcessInfo.processInfo.systemUptime) { self.id = id; startedAt = now; lastAudioAt = now }
    mutating func accept(sequence: UInt64?, now: TimeInterval) throws {
        guard streamStarted, !streamEnded, sequence == expectedSequence else { throw BridgeError(tr("音频帧顺序异常，已中止语音。", "Audio frames arrived out of order; stopped.")) }
        expectedSequence += 1; lastAudioAt = now
    }
    func timedOut(now: TimeInterval) -> Bool {
        now - startedAt > maxVoiceDuration || (streamEnded && now - (endedAt ?? lastAudioAt) > 2) ||
        (streamStarted && !streamEnded ? now - lastAudioAt > 1.2 : now - startedAt > 3 && !streamStarted)
    }
}
