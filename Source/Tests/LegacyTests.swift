import Foundation
import Network
import AVFoundation

func runSelfTests() throws {
    var count = 0
    func check(_ value: Bool, _ name: String) throws {
        guard value else { throw BridgeError("FAIL: \(name)") }
        count += 1
        print("PASS: \(name)")
    }
    func rejected(_ name: String, _ operation: () throws -> Void) throws {
        var didThrow = false
        do { try operation() } catch { didThrow = true }
        try check(didThrow, name)
    }
    let key = Keys.generate()
    let challenge = Keys.generate()
    let connectionKey = Keys.sessionKey(shared: key, challenge: challenge)
    try check(connectionKey == Keys.sessionKey(shared: key, challenge: challenge), "both endpoints derive same connection key")
    try check(connectionKey != Keys.sessionKey(shared: key, challenge: Keys.generate()), "new connection invalidates previous encrypted messages")
    let sender = Codec(key: key), receiver = Codec(key: key)
    let original = Message(kind: "commit", session: "test", text: "你好，MicBridge！\n第二行 🎙️")
    let encrypted = try sender.encode(original)
    try check(!encrypted.contains(Data(original.text.utf8)), "transcript is encrypted")
    var buffer = FrameBuffer()
    var frames: [Data] = []
    for byte in encrypted { frames += try buffer.append(Data([byte])) }
    try check(frames.count == 1 && buffer.bytes.isEmpty, "one-byte TCP fragmentation")
    let decoded = try receiver.decode(frames[0])
    try check(decoded.text == original.text && decoded.id == original.id, "Unicode transcript round trip")
    try rejected("reject replay") { _ = try receiver.decode(frames[0]) }
    try rejected("reject wrong pairing key") { _ = try Codec(key: Keys.generate()).decode(frames[0]) }
    var tampered = frames[0]; tampered[tampered.startIndex + 12] ^= 1
    try rejected("reject tampered ciphertext") { _ = try Codec(key: key).decode(tampered) }
    try rejected("reject stale message") { _ = try Codec(key: key).decode(frames[0], now: original.date + 61) }
    var invalid = FrameBuffer()
    try rejected("reject oversized frame before allocation") { _ = try invalid.append(Data([255, 255, 255, 255])) }
    var joined = FrameBuffer()
    let next = try sender.encode(Message(kind: "fnUp", session: "test"))
    try check(try joined.append(encrypted + next).count == 2, "coalesced TCP frames")
    let pair = Pairing(host: "studio.local", key: key.base64EncodedString())
    try check(try Pairing.parse(pair.encoded).key == pair.key, "pairing round trip")
    try rejected("reject malformed pairing") { _ = try Pairing.parse("dbbridge://invalid") }
    var packets = Packetizer()
    let raw = Data((0..<(packetFrames * 4 * 3 + 128)).map { UInt8($0 % 251) })
    var rebuilt = Data()
    for offset in stride(from: 0, to: raw.count, by: 317) {
        for packet in packets.append(Data(raw.dropFirst(offset).prefix(317))) {
            try check(packet.count == packetFrames * 4, "fixed-size audio packet")
            rebuilt.append(packet)
        }
    }
    if let tail = packets.finish() { rebuilt.append(tail) }
    try check(rebuilt == raw && packets.pending.isEmpty, "audio fragmentation and tail are lossless")
    var budget = PlaybackBudget()
    try budget.enqueue(packetFrames)
    try check(!budget.shouldPlay, "jitter buffer waits for two packets")
    try budget.enqueue(packetFrames)
    try check(budget.shouldPlay, "jitter buffer starts at 40 ms")
    budget.started = true; budget.ending = true
    budget.completed(packetFrames)
    try check(!budget.drained, "drain waits for final audio")
    budget.completed(packetFrames)
    try check(budget.drained, "drain completes after final audio")
    var quick = PlaybackBudget()
    try quick.enqueue(32); quick.ending = true
    try check(quick.shouldPlay, "short recording drains partial packet")
    var overload = PlaybackBudget()
    for _ in 0..<25 { try overload.enqueue(packetFrames) }
    try rejected("reject half-second audio backlog") { try overload.enqueue(packetFrames) }
    var voice = VoiceSession(id: "test", now: 0)
    voice.endRequested = true
    try check(!voice.streamStarted && voice.endRequested, "release before start remains pending")
    try rejected("reject audio before start") { try voice.accept(sequence: 0, now: 0.1) }
    voice.streamStarted = true
    try voice.accept(sequence: 0, now: 0.1)
    try rejected("reject duplicate audio frame") { try voice.accept(sequence: 0, now: 0.2) }
    try rejected("reject out-of-order audio frame") { try voice.accept(sequence: 2, now: 0.2) }
    try voice.accept(sequence: 1, now: 0.2)
    try check(voice.timedOut(now: 1.5), "stalled audio ends session")
    voice.streamEnded = true
    try rejected("reject audio after end") { try voice.accept(sequence: 2, now: 0.3) }
    try check(voice.timedOut(now: maxVoiceDuration + 1), "stuck hold has bounded duration")
    voice.endedAt = 1
    try check(voice.timedOut(now: 3.1), "stalled output drain releases hold")

    for rate in [44_100.0, 48_000.0] {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false)!
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: pcmRate, channels: 1, interleaved: false)!
        let converter = AVAudioConverter(from: format, to: target)!
        converter.primeMethod = .none
        var convertedFrames = 0; var peak: Float = 0
        for chunk in 0..<10 {
            let frames = Int(rate / 100)
            let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
            input.frameLength = AVAudioFrameCount(frames)
            for i in 0..<frames {
                let sample = Float(sin(Double(chunk * frames + i) * 2 * .pi * 440 / rate) * 0.2)
                input.floatChannelData![0][i] = sample; input.floatChannelData![1][i] = sample
            }
            let (data, value) = try convertPCM(input, using: converter, target: target)
            convertedFrames += data.count / 4; peak = max(peak, value)
        }
        try check(abs(convertedFrames - 4800) < 100 && peak > 0.1 && peak < 0.5, "real AVAudioConverter \(Int(rate)) Hz stereo to 48 kHz mono")
    }

    // Actual loopback sockets exercise the same encrypted Wire implementation as the apps.
    let loopback = NWParameters.tcp
    loopback.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    let listener = try NWListener(using: loopback)
    var server: Wire?, client: Wire?
    var networkDone = false
    var networkError: String?
    let samples = (0..<(packetFrames * 6)).map { Float(sin(Double($0) * 2 * .pi * 440 / pcmRate) * 0.2) }
    let wave = samples.withUnsafeBytes { Data($0) }
    var receivedWave = Data()
    var networkSession = VoiceSession(id: "audio-test")
    listener.newConnectionHandler = { connection in
        server = Wire(connection: connection, key: key)
        server?.onReady = {
            server?.send(Message(kind: "challenge", text: challenge.base64EncodedString()))
            do { try server?.useChallenge(challenge.base64EncodedString()) }
            catch { networkError = error.localizedDescription }
        }
        server?.onMessage = { message in
            if message.kind == "hello" && message.text == challenge.base64EncodedString() {
                server?.send(Message(kind: "helloOK"))
            } else if message.kind == "started" {
                networkSession.streamStarted = true
            } else if message.kind == "pcm", let audio = message.audio {
                do {
                    try networkSession.accept(sequence: message.sequence, now: ProcessInfo.processInfo.systemUptime)
                    receivedWave.append(audio)
                } catch { networkError = error.localizedDescription }
            } else if message.kind == "ended", message.sequence == networkSession.expectedSequence, receivedWave == wave {
                server?.send(Message(kind: "result", session: message.session, text: "ok"))
            } else { networkError = "unexpected request" }
        }
        server?.start()
    }
    listener.stateUpdateHandler = { state in
        if case .ready = state, let port = listener.port {
            client = Wire(connection: NWConnection(host: "127.0.0.1", port: port, using: .tcp), key: key)
            client?.onMessage = { message in
                if message.kind == "challenge" {
                    do { try client?.useChallenge(message.text); client?.send(Message(kind: "hello", text: message.text)) }
                    catch { networkError = error.localizedDescription }
                } else if message.kind == "helloOK" {
                    client?.send(Message(kind: "started", session: "audio-test"))
                    for n in 0..<6 {
                        let packet = Data(wave.dropFirst(n * packetFrames * 4).prefix(packetFrames * 4))
                        client?.send(Message(kind: "pcm", session: "audio-test", audio: packet, sequence: UInt64(n)))
                    }
                    client?.send(Message(kind: "ended", session: "audio-test", sequence: 6))
                }
                else { networkDone = message.kind == "result" && message.text == "ok" }
            }
            client?.onClose = { networkError = $0.message }
            client?.start()
        }
        if case .failed(let error) = state { networkError = error.localizedDescription }
    }
    listener.start(queue: .main)
    let deadline = Date().addingTimeInterval(5)
    while !networkDone && networkError == nil && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    try check(networkDone && networkError == nil, "encrypted TCP PCM stream and end acknowledgement (\(networkError ?? "OK"))")
    try check(receivedWave == wave && networkSession.expectedSequence == 6, "network PCM is byte-exact and ordered")
    var disconnected = false
    client?.onClose = { _ in disconnected = true }
    server?.close(.local("test disconnect"))
    let disconnectDeadline = Date().addingTimeInterval(3)
    while !disconnected && Date() < disconnectDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    try check(disconnected && client?.closed == true, "remote disconnect closes sender without retry")
    client?.onClose = nil; server?.onClose = nil
    client?.close(.local("test complete")); listener.cancel()
    // Test closures capture these wires; clear them so leak checks stay meaningful.
    for wire in [client, server] { wire?.onMessage = nil; wire?.onReady = nil; wire?.onClose = nil }
    listener.newConnectionHandler = nil; listener.stateUpdateHandler = nil
    print("\(count) tests passed. No keyboard events were injected.")
}

func runSilentOutputProbe() throws {
    guard let device = VirtualDevice.find(Devices.all()) else {
        throw BridgeError("No virtual microphone is installed; no output probe performed.")
    }
    let output = VirtualMicrophone()
    var drained = false
    var failure: String?
    output.onDrained = { drained = true }
    output.onFailure = { failure = $0 }
    try output.start(device: device)
    defer { output.stop() }
    output.begin()
    for _ in 0..<4 { try output.enqueue(Data(repeating: 0, count: packetFrames * 4)) }
    output.end()
    let deadline = Date().addingTimeInterval(5)
    while !drained && failure == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    guard drained, failure == nil, output.budget.pendingFrames == 0 else {
        throw BridgeError("Silent hardware output probe failed: \(failure ?? "did not drain")")
    }
    print("PASS: 80 ms of digital silence scheduled, rendered, and drained through installed \(device.name).")
    print("No microphone captured; no Fn injected; default audio devices unchanged.")
}
