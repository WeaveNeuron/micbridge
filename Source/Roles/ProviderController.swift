import Foundation

/// The Mac that lends its microphone. Opens it only for the length of one
/// recording requested by the borrower, and guarantees it is closed between
/// recordings.
final class ProviderController {
    weak var host: RoleHost?
    /// Bridge running, link ready (handshake done). Set by the app.
    var isActive: () -> Bool = { false }
    var isLinkReady: () -> Bool = { false }

    let microphone: Microphone
    var device: AudioDevice?
    private(set) var session: String?
    private(set) var stopping = false
    private(set) var level = 0.0
    private(set) var sentPackets = 0
    private(set) var starts = 0
    private var startedAt: TimeInterval = 0
    private var lastAudio: TimeInterval = 0
    private var packetizer = Packetizer()
    private var sequence: UInt64 = 0
    private var recovery = CaptureRecovery()
    private var firstCaptureLogged = true
    private var lastMicCheck: TimeInterval = 0
    private var lastDeepMicCheck: TimeInterval = 0
    private var generation = UUID()
    /// Changes on every link loss; a prepare that finishes later says nothing.
    private var linkEpoch = 0
    /// The microphone is opening (Core Audio work in flight).
    private var opening = false
    private var deepCheckInFlight = false
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    var micActive: Bool { microphone.isRunning }

    init(microphone: Microphone = Microphone()) {
        self.microphone = microphone
        microphone.onPCM = { [weak self] data, peak in self?.captured(data, peak: peak) }
        microphone.onFailure = { [weak self] reason in self?.failed(reason) }
        microphone.onConfigurationChange = { [weak self] in self?.recoverConfiguration() }
    }

    /// Builds the (idle) capture graph off the main thread so the first
    /// recording only pays for starting IO. Never opens the microphone.
    /// `completion` runs on the main thread.
    func prepare(_ completion: @escaping (Error?) -> Void = { _ in }) {
        guard let device else { completion(nil); return }
        microphone.prepare(device: device, completion: completion)
    }
    /// Handshake done (or the same Mac on a fresh link): tell the borrower
    /// this Mac is ready once the graph is built. A graph already built for
    /// this device is reused, so reconnecting never rebuilds it, and the main
    /// thread never waits for Core Audio.
    func linkUp() {
        let epoch = linkEpoch
        prepare { [weak self] error in
            guard let self, self.linkEpoch == epoch, self.isLinkReady() else { return }
            if let error, !(error is MicrophoneError) { mark("prepare failed: \(error.localizedDescription)") }
            self.host?.send(Message(kind: "ready"))
            self.host?.status(tr("已连接并待命，麦克风关闭。", "Connected and standing by; the microphone is off."))
        }
    }
    /// Link lost: the microphone closes at once. The idle graph is kept for
    /// the next link to the same device.
    func reset() {
        generation = UUID(); linkEpoch += 1; opening = false
        session = nil; stopping = false; packetizer = Packetizer(); microphone.close(); level = 0
    }
    /// Bridge stopped or the device changed: also drop the graph.
    func shutDown() {
        reset(); microphone.discard()
    }

    func handle(_ m: Message) {
        switch m.kind {
        case "start":
            guard isLinkReady(), session == nil, !m.session.isEmpty, let device else {
                host?.send(Message(kind: "sourceError", text: tr("麦克风尚未就绪。", "The microphone isn’t ready yet."))); return
            }
            mark("start received, age \(Int((Date().timeIntervalSince1970 - m.date) * 1000)) ms")
            let micStart = now, id = m.session
            session = id; recovery = CaptureRecovery(); sequence = 0; packetizer = Packetizer(); stopping = false
            startedAt = now; lastAudio = now; opening = true
            microphone.start(device: device) { [weak self] error in
                guard let self, self.session == id else { return }
                self.opening = false; self.lastAudio = self.now
                if let error { self.failed(error.localizedDescription); return }
                self.starts += 1
                mark("mic start() took \(Int((self.now - micStart) * 1000)) ms"); self.firstCaptureLogged = false
                self.host?.send(Message(kind: "started", session: id))
                if !self.stopping { self.host?.status(tr("正在提供麦克风。", "Sharing the microphone.")) }
                self.host?.captureChanged()
            }
        case "stop":
            guard let id = session, id == m.session, !stopping else { return }
            mark("stop received, sent \(sequence) packets")
            stopping = true; host?.captureChanged()
            microphone.finish { [weak self] in
                guard let self, self.session == id else { return }
                if let tail = self.packetizer.finish() { self.sendAudio(tail) }
                self.host?.send(Message(kind: "ended", session: id, sequence: self.sequence))
                self.session = nil; self.stopping = false; self.level = 0
                self.host?.status(tr("已停止收音，连接保持待命。", "Recording stopped; standing by."))
                self.host?.captureChanged()
                // Some devices keep their IO active across pause. In that case
                // tear the engine down; never keep idle capture for performance.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                    guard let self, self.session == nil else { return }
                    self.microphone.checkOwnInput(close: true) { [weak self] _, still in
                        guard let self, self.session == nil else { return }
                        self.host?.send(Message(kind: "idle", text: still ? "1" : "0"))
                    }
                }
            }
        case "cancel":
            guard session == m.session else { return }
            session = nil; stopping = false; opening = false; microphone.close(); packetizer = Packetizer(); level = 0
            host?.status(m.text.isEmpty ? tr("本次已取消，麦克风已关闭。", "Cancelled; the microphone is off.") : m.text)
            host?.captureChanged()
        default: break
        }
    }

    private func captured(_ data: Data, peak: Float) {
        guard session != nil else { return }
        if !firstCaptureLogged { firstCaptureLogged = true; mark("first audio \(Int((now - startedAt) * 1000)) ms after start received") }
        lastAudio = now; level = Double(peak)
        for packet in packetizer.append(data) { sendAudio(packet) }
    }
    private func sendAudio(_ data: Data) {
        guard let id = session else { return }
        host?.send(Message(kind: "pcm", session: id, audio: data, sequence: sequence)); sequence += 1; sentPackets += 1
    }
    private func failed(_ reason: String) {
        // A failing graph is not reused; the next recording builds a new one.
        microphone.discard(); opening = false; session = nil; stopping = false; packetizer = Packetizer(); level = 0
        host?.send(Message(kind: "sourceError", text: reason)); host?.transient(reason)
        host?.captureChanged()
    }
    private func recoverConfiguration() {
        // Only a real change gets here: the device or its format differs.
        guard isActive() else { microphone.discard(); return }
        guard let id = session, !stopping else {
            // In standby, drop the stale graph without ever starting IO.
            microphone.discard()
            return
        }
        guard recovery.request() else { failed(tr("麦克风格式持续变化，本次收音已停止。", "The microphone format kept changing, so this recording stopped.")); return }
        let epoch = generation
        microphone.discard(); lastAudio = now
        host?.status(tr("麦克风格式正在调整，正在恢复本次收音…", "The microphone format changed; resuming…"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, self.isActive(), self.generation == epoch,
                  CaptureRecovery.shouldResume(original: id, current: self.session, stopping: self.stopping),
                  let selected = self.device else { return }
            self.opening = true
            self.microphone.start(device: selected, refresh: true) { [weak self] error in
                guard let self, self.session == id, self.generation == epoch else { return }
                self.opening = false; self.lastAudio = self.now
                if let error { self.failed(error.localizedDescription); return }
                self.starts += 1
                self.host?.status(tr("正在提供麦克风。", "Sharing the microphone."))
            }
        }
    }

    /// Every timer tick while the bridge runs.
    func tick() {
        if session != nil, !opening && now - lastAudio > 1.2 || now - startedAt > maxVoiceDuration {
            failed(tr("本次音频超时，麦克风已关闭。", "The audio timed out; the microphone is off."))
        }
        // Privacy guard: the microphone must never stay open between recordings.
        if session == nil, now - lastMicCheck > 1 {
            lastMicCheck = now
            let deep = now - lastDeepMicCheck > 5   // HAL scan is costlier; run it less often
            if deep { lastDeepMicCheck = now }
            let notice = tr("检测到待命时音频未释放，已关闭麦克风。", "Audio was still open while idle; the microphone was turned off.")
            if microphone.isRunning { microphone.close(); host?.status(notice) }
            // The process-wide check is Core Audio IPC: off the main thread, one at a time.
            if deep, !deepCheckInFlight {
                deepCheckInFlight = true
                microphone.checkOwnInput(close: true) { [weak self] was, _ in
                    guard let self else { return }
                    self.deepCheckInFlight = false
                    if was, self.session == nil { self.host?.status(notice) }
                }
            }
        }
    }
}
