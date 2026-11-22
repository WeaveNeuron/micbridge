import Foundation
import Network

final class Wire {
    let connection: NWConnection
    var codec: Codec
    let sharedKey: Data
    var challengeApplied = false
    var buffer = FrameBuffer()
    var onReady: (() -> Void)?
    var onMessage: ((Message) -> Void)?
    var onClose: ((CloseReason) -> Void)?
    var closed = false
    var pendingBytes = 0
    var lastReceived = Date()
    var heartbeat: Timer?
    /// Tests only: extra latency before each received frame (and the remote
    /// close) is handled, like a real network. Order on one wire is kept.
    static var testLatency: (() -> TimeInterval)?
    private var deliverAt: TimeInterval = 0
    static func isLocalNetworkDenied(_ error: NWError?, path: NWPath?) -> Bool {
        if path?.unsatisfiedReason == .localNetworkDenied { return true }
        if case .dns(let code)? = error, code == -65570 /* kDNSServiceErr_PolicyDenied */ { return true }
        return false
    }
    /// Audio link: 20 ms packets must leave immediately. With Nagle on, the
    /// tail of each packet waited for a delayed ACK and audio arrived in
    /// 150-180 ms bursts, which then stayed queued and cut the last word.
    static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp); parameters.includePeerToPeer = true
        return parameters
    }
    init(connection: NWConnection, key: Data) { self.connection = connection; sharedKey = key; codec = Codec(key: key) }
    func useChallenge(_ value: String) throws {
        guard !challengeApplied, let data = Data(base64Encoded: value), data.count == 32 else {
            throw BridgeError(tr("连接握手无效。", "Invalid handshake."))
        }
        codec = Codec(key: Keys.sessionKey(shared: sharedKey, challenge: data))
        challengeApplied = true
    }
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.closed else { return }
            switch state {
            case .ready:
                self.deliver { self.onReady?(); self.receive() }
            case .failed(let error): self.close(.connectionError(error, path: self.connection.currentPath))
            case .waiting(let error):
                self.close(.connectionError(error, path: self.connection.currentPath))
            case .cancelled: self.close(.peerClosed)
            default: break
            }
        }
        connection.pathUpdateHandler = { [weak self] path in
            guard let self, !self.closed, Wire.isLocalNetworkDenied(nil, path: path) else { return }
            self.close(.localNetworkDenied)
        }
        connection.start(queue: .main)
        heartbeat = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self else { return }
            if Date().timeIntervalSince(self.lastReceived) > 35 { self.close(.heartbeat) }
            else { self.send(Message(kind: "ping")) }
        }
        if let heartbeat { RunLoop.main.add(heartbeat, forMode: .common) }
    }
    /// `then` runs on the main queue once the frame left (or failed).
    func send(_ message: Message, then: (() -> Void)? = nil) {
        guard !closed else { then?(); return }
        do {
            let frame = try codec.encode(message)
            guard pendingBytes + frame.count < 96_000 else { close(.sendBacklog); then?(); return }
            pendingBytes += frame.count
            connection.send(content: frame, completion: .contentProcessed { [weak self] error in
                self?.pendingBytes -= frame.count
                if let error { self?.close(.sendFailed(error.localizedDescription)) }
                then?()
            })
        } catch { close(.sendFailed(error.localizedDescription)); then?() }
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            guard let self, !self.closed else { return }
            do {
                if let data {
                    for frame in try self.buffer.append(data) {
                        let message = try self.codec.decode(frame)
                        self.deliver {
                            self.lastReceived = Date()
                            if message.kind == "ping" { self.send(Message(kind: "pong")) }
                            else if message.kind != "pong" { self.onMessage?(message) }
                        }
                        if self.closed { return }
                    }
                }
                if done || error != nil { self.deliver { self.close(.peerClosed) } }
                else { self.receive() }
            } catch { self.close(.invalid(error.localizedDescription)) }
        }
    }
    private func deliver(_ work: @escaping () -> Void) {
        guard let latency = Wire.testLatency else { work(); return }
        let now = ProcessInfo.processInfo.systemUptime
        deliverAt = max(deliverAt, now + latency())
        DispatchQueue.main.asyncAfter(deadline: .now() + (deliverAt - now)) { [weak self] in
            guard let self, !self.closed else { return }
            work()
        }
    }
    func close(_ reason: CloseReason) {
        guard !closed else { return }
        closed = true
        heartbeat?.invalidate()
        heartbeat = nil
        connection.stateUpdateHandler = nil; connection.pathUpdateHandler = nil
        connection.cancel()
        onClose?(reason)
    }
    deinit { heartbeat?.invalidate(); connection.cancel() }
}
