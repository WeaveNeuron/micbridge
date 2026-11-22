import Foundation
import UserNotifications

/// The Mac that uses another Mac's microphone. Plays the provider's audio
/// into a virtual microphone whenever any app here reads from it, and makes
/// that virtual microphone the default input while the provider is connected.
final class BorrowerController {
    private let defaults: UserDefaults
    weak var host: RoleHost?
    /// Provider connected, ready and the bridge running. Set by the app.
    var providerAvailable: () -> Bool = { false }
    var peerName: () -> String = { PairedDevice.fallbackName }
    var onFatal: ((String) -> Void)?

    private(set) var output = VirtualMicrophone()
    let demand = DemandMonitor()
    private var policy = DemandPolicy()
    var device: AudioDevice?
    private(set) var voice: VoiceSession?
    private(set) var peerMicRunning = false
    private(set) var level = 0.0
    private(set) var receivedPackets = 0
    private(set) var startLatencyMs: Int?
    private(set) var demandWaitingSince: TimeInterval?
    private var notifiedWaiting = false
    private var claimedDefault = false
    private var lostSince: TimeInterval?
    private var defaultInputCache = false
    private var lastDefaultInputCheck: TimeInterval = 0
    private var defaultInputCheckInFlight = false
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    static let previousInputKey = "previousInputUID"
    var isDefaultInput: Bool { defaultInputCache }
    /// A recording was requested and has not been asked to stop.
    var capturing: Bool { voice != nil && voice?.endRequested == false }
    var finishing: Bool { voice?.endRequested == true }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        demand.onChange = { [weak self] active in self?.observeDemand(active) }
    }

    /// Starts the virtual microphone output off the main thread (Core Audio
    /// calls are synchronous IPC). `completion` runs on the main thread.
    func startOutput(device: AudioDevice, on queue: DispatchQueue, completion: @escaping (Result<Void, Error>) -> Void) {
        let candidate = VirtualMicrophone()
        queue.async { [weak self] in
            do {
                try candidate.start(device: device)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { queue.async { candidate.stop() }; return }
                    self.output = candidate
                    candidate.onFailure = { [weak self] in self?.onFatal?($0) }
                    candidate.onDrained = { [weak self] in self?.drained() }
                    self.demand.start(device: device)
                    completion(.success(()))
                }
            } catch { DispatchQueue.main.async { completion(.failure(error)) } }
        }
    }
    var outputReady: Bool { output.unit != nil }

    func tearDown() {
        releaseDefaultInput(); demandWaitingSince = nil; notifiedWaiting = false
        abortVoice(); demand.stop(); output.stop()
        level = 0; peerMicRunning = false
    }
    /// Link lost: the current recording cannot continue.
    func linkDown() {
        abortVoice(); peerMicRunning = false
    }

    /// The provider said `ready`: its microphone can be used from now on.
    func providerReady() {
        claimDefaultInput()
        host?.status(tr("已连接\(peerName())的麦克风。", "Connected to \(peerName())’s microphone."))
    }

    func handle(_ m: Message) {
        switch m.kind {
        case "started":
            guard voice?.id == m.session else { return }
            voice?.streamStarted = true; peerMicRunning = true; startLatencyMs = Int((now - (voice?.startedAt ?? now)) * 1000)
            host?.captureChanged()
            mark("started after \(startLatencyMs ?? -1) ms")
        case "pcm":
            guard voice?.id == m.session, let data = m.audio else { return }
            do {
                guard Date().timeIntervalSince1970 - m.date - clockOffset < 0.5 else { throw BridgeError(tr("局域网延迟过高，本次已中止。", "The network delay was too high; this recording stopped.")) }
                if m.sequence == 0 { mark("first pcm, age \(Int((Date().timeIntervalSince1970 - m.date - clockOffset) * 1000)) ms, since start \(Int((now - (voice?.startedAt ?? now)) * 1000)) ms") }
                try voice?.accept(sequence: m.sequence, now: now)
                // The app has already stopped reading. Late samples are
                // counted but discarded instead of leaking into the next one.
                if voice?.endRequested == false { try output.enqueue(data); level = peak(data) }
                receivedPackets += 1
            } catch { failVoice(error.localizedDescription) }
        case "ended":
            guard voice?.id == m.session else { return }
            guard voice?.streamStarted == true, voice?.streamEnded == false, m.sequence == voice?.expectedSequence else { failVoice(tr("音频结束顺序异常，本次已停止。", "The audio ended out of order; this recording stopped.")); return }
            peerMicRunning = false; voice?.streamEnded = true; voice?.endedAt = now; output.end(); host?.captureChanged()
        case "sourceError": failVoice(m.text)
        case "idle": peerMicRunning = m.text == "1"; host?.captureChanged()
        default: break
        }
    }
    /// Set from the provider's hello; used to judge packet age.
    var clockOffset: TimeInterval = 0

    // MARK: Demand

    func observeDemand(_ active: Bool) {
        switch policy.observe(active, available: providerAvailable(), active: capturing, now: now) {
        case .start: if voice == nil { beginVoice() }
        case .stop: endVoice()
        case .none: break
        }
        noteWaitingDemand(active)
    }
    /// An app is recording from the virtual microphone but no provider is
    /// there: say so instead of letting it record silence.
    private func noteWaitingDemand(_ active: Bool) {
        guard active, !providerAvailable() else { demandWaitingSince = nil; if !active { notifiedWaiting = false }; return }
        let since = demandWaitingSince ?? now; demandWaitingSince = since
        guard !notifiedWaiting, now - since > 0.8 else { return }
        notifiedWaiting = true; host?.captureChanged()
        let content = UNMutableNotificationContent()
        content.title = tr("\(peerName())的麦克风暂不可用", "\(peerName())’s microphone isn’t available")
        content.body = tr("\(appLead(demand.clientName))在等待麦克风，请唤醒\(peerName())。", "\(appName(demand.clientName)) is waiting for the microphone. Wake \(peerName()).")
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "micbridge.waiting", content: content, trigger: nil))
    }
    private func failVoice(_ reason: String) { abortVoice(); policy.failed(now: now); host?.transient(reason) }

    private func beginVoice() {
        guard providerAvailable(), demand.requested, device != nil else { return }
        let session = VoiceSession(); voice = session; output.begin()
        host?.send(Message(kind: "start", session: session.id)); mark("start sent")
        host?.status(tr("\(demand.clientName) 开始收音，正在打开\(peerName())的麦克风。", "\(appName(demand.clientName)) started listening; turning on \(peerName())’s microphone."))
        host?.captureChanged()
    }
    private func endVoice() {
        guard let id = voice?.id, voice?.endRequested == false else { return }
        mark("stop sent, received \(receivedPackets) packets, queued \(output.queue.pending) frames, underruns \(output.underruns)")
        voice?.endRequested = true; output.cancel(); level = 0
        host?.send(Message(kind: "stop", session: id)); host?.status(tr("收音结束，正在确认对方已关闭麦克风。", "Recording ended; confirming the other Mac’s microphone is off."))
        host?.captureChanged()
    }
    private func drained() {
        guard voice?.streamEnded == true else { return }
        voice = nil; level = 0; policy.succeeded(); host?.status(tr("收音结束，对方麦克风已关闭。", "Recording ended; the other Mac’s microphone is off."))
        host?.captureChanged()
    }
    func abortVoice() {
        if let id = voice?.id { host?.send(Message(kind: "cancel", session: id)) }
        voice = nil; output.cancel(); level = 0; peerMicRunning = false
        host?.captureChanged()
    }
    private func peak(_ data: Data) -> Double {
        var p: Float = 0
        data.withUnsafeBytes { raw in for i in stride(from: 0, to: raw.count - 3, by: 4) { p = max(p, abs(raw.loadUnaligned(fromByteOffset: i, as: Float.self))) } }
        return Double(p)
    }

    // MARK: Default input

    /// The once-a-second check reads the default input off the main thread.
    private func pollDefaultInput() {
        guard !defaultInputCheckInFlight else { return }
        defaultInputCheckInFlight = true; lastDefaultInputCheck = now
        let id = device?.id
        AudioHAL.queue.async { [weak self] in
            let current = Devices.defaultInput()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.defaultInputCheckInFlight = false
                if self.device?.id == id { self.defaultInputCache = id == current }
            }
        }
    }
    func refreshDefaultInput() { defaultInputCache = device.map { $0.id == Devices.defaultInput() } ?? false; lastDefaultInputCheck = now }
    /// Only on an explicit click: lets every app here use the bridge by default.
    @discardableResult func makeDefaultInput() -> Bool {
        guard let device else { return false }
        let ok = Devices.setDefaultInput(device.id)
        refreshDefaultInput()
        return ok
    }
    /// While the provider is connected its microphone becomes the default
    /// input, like AirPods; the previous input returns after it leaves.
    func claimDefaultInput() {
        guard let device else { return }
        lostSince = nil
        let current = Devices.defaultInput()
        guard current != device.id else { return }
        let previous = Devices.all().first { $0.id == current }?.uid ?? ""
        defaults.set(previous, forKey: Self.previousInputKey)
        claimedDefault = Devices.setDefaultInput(device.id)
        refreshDefaultInput()
    }
    func releaseDefaultInput() {
        guard let previous = defaults.string(forKey: Self.previousInputKey) else { claimedDefault = false; return }
        defaults.removeObject(forKey: Self.previousInputKey); claimedDefault = false; lostSince = nil
        // Respect a manual change: only hand back if the bridge is still the default.
        let devicesNow = Devices.all(), current = Devices.defaultInput()
        guard devicesNow.first(where: { $0.id == current })?.loopback == true,
              let restore = devicesNow.first(where: { $0.uid == previous && $0.inputChannels > 0 }) else { return }
        Devices.setDefaultInput(restore.id)
        refreshDefaultInput()
    }

    /// Every timer tick while the bridge runs.
    func tick(providerReady: Bool) {
        // Level-triggered demand: re-evaluate the current state (no HAL calls here).
        observeDemand(demand.requested)
        if now - lastDefaultInputCheck > 1 { pollDefaultInput() }
        if let voice, voice.timedOut(now: now) { failVoice(tr("本次收音没有完成，请重新开始语音输入。", "This recording didn’t finish. Start dictating again.")) }
        // Short network blips keep the default input; a real departure hands it back.
        if claimedDefault, !providerReady {
            let since = lostSince ?? now; lostSince = since
            if now - since > 10 { releaseDefaultInput() }
        }
    }
}

/// Chinese: the app name followed by a space only when it ends in Latin
/// text ("Safari 正在…", "备忘录正在…"). Empty names read as "应用".
func appLead(_ client: String) -> String {
    let name = client.isEmpty ? "应用" : client
    return name.last.map { $0.isASCII } == true ? name + " " : name
}
/// English: the app name, or "An app".
func appName(_ client: String, capitalized: Bool = true) -> String {
    client.isEmpty ? (capitalized ? "An app" : "an app") : client
}
