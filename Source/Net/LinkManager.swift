import Foundation
import Network

/// What the other Mac said about itself during the handshake.
struct PeerHello: Equatable {
    var name: String?
    var model: String?
    /// 0.3.x peers did not report a version.
    var version: String
    /// Its wired IPv4 addresses (0.6.0 sent them only from the listener).
    var hosts: [String]?
    /// Sender's clock when the hello left (to judge audio packet age).
    var sentAt: TimeInterval = 0
    /// 0.7.1+: device ID, mode and understood post-handshake kinds.
    var device: String?
    var mode: PeerMode?
    var features: Set<String> = []

    init(name: String? = nil, model: String? = nil, version: String, hosts: [String]? = nil, sentAt: TimeInterval = 0,
         device: String? = nil, mode: PeerMode? = nil, features: Set<String> = []) {
        self.name = name; self.model = model; self.version = version; self.hosts = hosts; self.sentAt = sentAt
        self.device = device; self.mode = mode; self.features = features
    }
    init(_ m: Message) {
        self.init(name: m.name, model: m.model, version: m.clientVersion ?? "0.3.x", hosts: m.hosts, sentAt: m.date,
                  device: m.device, mode: m.mode.flatMap(PeerMode.init(rawValue:)), features: Set(m.features ?? []))
    }
    func supports(_ feature: String) -> Bool { features.contains(feature) }
    /// Same Mac as another hello. Two Macs without IDs (0.6.0 / 0.7.0) are
    /// treated as the same, as 0.6.0 did.
    func sameDevice(as other: PeerHello) -> Bool { device == other.device }
}

/// What this Mac says about itself in hello / helloOK.
struct LocalHello: Equatable {
    var name: String
    var model: String
    var device: String
    var mode: PeerMode
}

/// A paired Mac to dial: its device key and addresses.
struct DialTarget: Equatable {
    var id: String
    var key: Data
    var host: String?
    var wiredHosts: [String] = []
    var port: UInt16 = bridgePort
}

/// Sockets only: the listener and its Bonjour advert, the dialer, and the
/// encrypted handshake. Reports typed `ConnectionEvent`s and forwards
/// post-handshake messages; it knows nothing about audio.
///
/// Since 0.7.1 every Mac listens on `bridgePort` with its device key and
/// advertises a fingerprint of it plus a TXT presence record; either side
/// may dial. There is at most one active link: another Mac that dials in
/// while it is up gets `busy`. If both Macs dial each other at once, both
/// keep the link `LinkArbiter` picks.
final class LinkManager {
    var onEvent: ((ConnectionEvent) -> Void)?
    var onMessage: ((Message) -> Void)?
    /// A link became active (also after a duplicate was swapped in).
    var onHello: ((PeerHello) -> Void)?
    /// The active link was swapped for a duplicate to the same Mac.
    var onReplaced: (() -> Void)?
    /// Outcome of a dial to a target ID: nil on success.
    var onDialResult: ((String, CloseReason?) -> Void)?
    /// One-line progress for diagnostics.
    var onStatus: ((String) -> Void)?
    /// An active recording is never interrupted by a reconnecting peer.
    var canReplacePeer: () -> Bool = { true }
    /// While paused, the advert stays up but connections are turned away.
    var acceptsConnections: () -> Bool = { true }
    /// While the Local Network issue is shown, a failure says nothing about
    /// the route.
    var localNetworkIssue: () -> Bool = { false }
    var local: () -> LocalHello = { LocalHello(name: DeviceIdentity.computerName, model: DeviceIdentity.model, device: "", mode: .paused) }

    /// Tests: bind to 127.0.0.1 on any port, no Bonjour.
    var loopbackOnly = false
    /// Wired addresses sent in hello / helloOK; never looked up inline.
    var wired = WiredAddresses.shared

    /// The active, handshaken link.
    private(set) var peer: Wire?
    private(set) var peerInfo: PeerHello?
    private(set) var peerDialedByUs = false
    /// Our dial in flight.
    private var attempt: Wire?
    /// Incoming connections still in the handshake.
    private var candidates: [UUID: Wire] = [:]
    private var listener: NWListener?
    private var listenKey: Data?
    private(set) var listeningPort: UInt16?
    /// The TXT presence record; changing it updates the advert in place.
    var advert: PresenceAdvert? { didSet { if advert != oldValue { publish() } } }

    private(set) var target: DialTarget?
    /// The target's Bonjour service, if seen.
    private(set) var discoveredEndpoint: NWEndpoint?
    private(set) var routes = RoutePlanner()
    private(set) var currentRoute: Route?
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    var handshaken: Bool { peer != nil }
    var isListening: Bool { listener != nil }
    var isDialing: Bool { attempt != nil }
    var routeLabel: String { peerDialedByUs || attempt != nil ? currentRoute?.label ?? tr("自动连接", "Automatic") : peer != nil ? tr("对方连入", "Incoming") : tr("自动连接", "Automatic") }
    var wiredHosts: [String] { routes.wiredHosts }

    func send(_ message: Message) { peer?.send(message) }

    // MARK: Tear-down

    /// Closes every link, keeps listening. No events are reported. If the
    /// peer understands it, it is told why first.
    func disconnect(_ reason: String, bye: ByeReason? = nil) {
        for wire in candidates.values { wire.onClose = nil; wire.close(.local(reason)) }
        candidates.removeAll()
        drop(attempt, reason); attempt = nil
        if let peer, let bye, peerInfo?.supports(ProtocolFeature.bye) == true {
            detach(peer)
            peer.send(Message(kind: "bye", text: bye.rawValue)) { peer.close(.local(reason)) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { peer.close(.local(reason)) }
        } else { drop(peer, reason) }
        peer = nil; peerInfo = nil; peerDialedByUs = false
        target = nil; discoveredEndpoint = nil; currentRoute = nil
    }
    func stopListening() {
        listener?.cancel(); listener = nil; listeningPort = nil
    }
    func closeAll(_ reason: String, bye: ByeReason? = nil) {
        disconnect(reason, bye: bye); stopListening()
    }
    private func detach(_ wire: Wire) { wire.onClose = nil; wire.onMessage = nil; wire.onReady = nil }
    private func drop(_ wire: Wire?, _ reason: String) {
        guard let wire else { return }
        detach(wire); wire.close(.local(reason))
    }

    // MARK: Listening

    func listen(key: Data) throws {
        stopListening()
        listenKey = key
        let parameters = Wire.parameters()
        let l: NWListener
        if loopbackOnly {
            parameters.includePeerToPeer = false
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            l = try NWListener(using: parameters)
        } else {
            l = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: bridgePort)!)
        }
        listener = l
        publish()
        l.stateUpdateHandler = { [weak self, weak l] state in
            guard let self, let l, self.listener === l else { return }
            if case .ready = state { self.listeningPort = l.port?.rawValue; self.onEvent?(.listenerReady) }
            if case .failed(let error) = state {
                self.stopListening()
                self.onEvent?(.listenerFailed)
                self.onStatus?(tr("连接服务正在恢复：\(error.localizedDescription)", "Restarting the connection service: \(error.localizedDescription)"))
            }
        }
        l.newConnectionHandler = { [weak self] connection in self?.accept(connection, key: key) }
        l.start(queue: .main)
    }
    /// The advertised name is a fingerprint of the key, never the key.
    private func publish() {
        guard let listener, !loopbackOnly, let listenKey else { return }
        let name = BridgeDiscovery.serviceName(for: listenKey)
        listener.service = advert.map {
            NWListener.Service(name: name, type: BridgeDiscovery.serviceType, txtRecord: NWTXTRecord($0.txt))
        } ?? NWListener.Service(name: name, type: BridgeDiscovery.serviceType)
    }
    private func accept(_ connection: NWConnection, key: Data) {
        guard acceptsConnections(), candidates.count < 4 else { connection.cancel(); return }
        let id = UUID(), challenge = Keys.generate().base64EncodedString()
        let wire = Wire(connection: connection, key: key); candidates[id] = wire
        wire.onReady = { [weak wire] in
            wire?.send(Message(kind: "challenge", text: challenge))
            do { try wire?.useChallenge(challenge) } catch { wire?.close(.handshake(error.localizedDescription)) }
        }
        wire.onMessage = { [weak self, weak wire] m in
            guard let self, let wire else { return }
            guard m.kind == "hello", m.text == challenge else { wire.close(.handshake(tr("握手无效", "Invalid handshake"))); return }
            self.candidates.removeValue(forKey: id)
            self.completed(wire, hello: PeerHello(m), dialedByUs: false)
        }
        wire.onClose = { [weak self] _ in self?.candidates.removeValue(forKey: id) }
        wire.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self, weak wire] in
            if self?.candidates[id] != nil { wire?.close(.handshake(tr("握手超时", "The handshake timed out"))) }
        }
    }

    // MARK: Dialing

    /// The Mac to dial, or nil. A different Mac drops an attempt in flight.
    func setTarget(_ newTarget: DialTarget?) {
        guard newTarget != target else { return }
        if newTarget?.id != target?.id {
            routes = RoutePlanner(wiredHosts: newTarget?.wiredHosts ?? [])
            currentRoute = nil; discoveredEndpoint = nil
            if attempt != nil { drop(attempt, "switching to another Mac"); attempt = nil; if peer == nil { onEvent?(.dialCancelled) } }
        } else if let newTarget {
            routes.wiredHosts = newTarget.wiredHosts
        }
        target = newTarget
    }
    func setDiscovered(_ endpoint: NWEndpoint?) { discoveredEndpoint = endpoint }

    /// Dials the next route. Does nothing while linked or an attempt is in flight.
    func dial() {
        guard peer == nil, attempt == nil, let target else { return }
        guard let route = routes.next(discovered: discoveredEndpoint != nil, savedHost: target.host ?? "", now: now) else { return }
        let port = NWEndpoint.Port(rawValue: target.port)!
        let endpoint: NWEndpoint
        switch route {
        case .wired(let host), .saved(let host): endpoint = .hostPort(host: NWEndpoint.Host(host), port: port)
        case .discovered:
            guard let discoveredEndpoint else { return }
            endpoint = discoveredEndpoint
        }
        currentRoute = route
        let parameters = Wire.parameters()
        if loopbackOnly { parameters.includePeerToPeer = false }
        let wire = Wire(connection: NWConnection(to: endpoint, using: parameters), key: target.key)
        attempt = wire
        let id = target.id
        wire.onMessage = { [weak self, weak wire] m in
            guard let self, let wire, self.attempt === wire else { return }
            self.handshake(m, on: wire, target: id)
        }
        wire.onClose = { [weak self, weak wire] reason in
            guard let self, let wire, self.attempt === wire else { return }
            self.attempt = nil
            if reason != .localNetworkDenied, !self.localNetworkIssue() { self.routes.failed(route, now: self.now) }
            self.onDialResult?(id, reason)
            if self.peer == nil { self.onEvent?(.closed(reason)) }
        }
        wire.start()
        onEvent?(.dialStarted)
        onStatus?(tr("正在连接（\(route.label)）。", "Connecting (\(route.label))."))
        DispatchQueue.main.asyncAfter(deadline: .now() + route.timeout) { [weak self, weak wire] in
            if let self, let wire, self.attempt === wire { wire.close(.connectTimeout) }
        }
    }
    /// Drops an attempt in flight (never a working link) and starts over.
    func redial() {
        if attempt != nil { drop(attempt, "redial"); attempt = nil; if peer == nil { onEvent?(.dialCancelled) } }
        routes.restart()
        dial()
    }
    /// Linked over Wi-Fi or AWDL by our own dial while a wired address is
    /// known: drop the idle link so the next dial goes over the wire.
    func preferWiredRoute() -> Bool {
        guard target != nil, let current = peer, peerDialedByUs else { return false }
        var remote = ""
        if case .hostPort(let host, _)? = current.connection.currentPath?.remoteEndpoint { remote = "\(host)" }
        guard routes.shouldUpgrade(remoteHost: remote, now: now) else { return false }
        drop(current, "moving to the wired route"); peer = nil; peerInfo = nil
        routes.restart()
        return true
    }
    /// Dialing side of the handshake.
    private func handshake(_ m: Message, on wire: Wire, target id: String) {
        if m.kind == "challenge" {
            do {
                try wire.useChallenge(m.text)
                wire.send(helloMessage(kind: "hello", text: m.text))
            } catch { wire.close(.handshake(error.localizedDescription)) }
        } else if m.kind == "helloOK", wire.challengeApplied {
            attempt = nil
            if let route = currentRoute { routes.connected(via: route) }
            if let hosts = m.hosts { routes.wiredHosts = hosts }
            onDialResult?(id, nil)
            completed(wire, hello: PeerHello(m), dialedByUs: true)
        } else if m.kind == "busy" {
            wire.close(.busy)
        } else {
            wire.close(.handshake(tr("握手失败", "The handshake failed")))
        }
    }

    // MARK: Shared

    private func helloMessage(kind: String, text: String = "") -> Message {
        let me = local()
        return Message(kind: kind, text: text, clientVersion: bridgeVersion, hosts: wired.current,
                       name: me.name, model: me.model, device: me.device.isEmpty ? nil : me.device,
                       mode: me.mode.rawValue, features: ProtocolFeature.all)
    }

    /// A link finished its handshake. Decides whether it becomes the active
    /// link, replaces it, or is turned away.
    private func completed(_ wire: Wire, hello: PeerHello, dialedByUs: Bool) {
        let me = local()
        // Is a link with this initiator the one both Macs keep?
        func preferred(_ byUs: Bool) -> Bool {
            guard let remote = hello.device, !me.device.isEmpty else { return !byUs }
            let incomingWins = LinkArbiter.keepsIncoming(localID: me.device, localMode: me.mode, remoteID: remote, remoteMode: hello.mode)
            return byUs ? !incomingWins : incomingWins
        }
        if let active = peer, let info = peerInfo {
            guard info.sameDevice(as: hello) else {
                // Another Mac while linked.
                if dialedByUs { drop(wire, "linked to another Mac") } else { turnAway(wire) }
                return
            }
            if peerDialedByUs == dialedByUs {
                // The same Mac dialed again: its old link is stale.
                guard canReplacePeer() else { turnAway(wire); return }
            } else if !preferred(dialedByUs) {
                // Both dialed at once and this is the link both Macs drop.
                if dialedByUs { drop(wire, "duplicate link") } else { turnAway(wire) }
                return
            }
            if !dialedByUs { wire.send(helloMessage(kind: "helloOK")) }
            // A 0.6.0 Mac stops using a link only when told it was superseded.
            if hello.device == nil { retire(active, saying: "superseded", "duplicate link") } else { drop(active, "duplicate link") }
            activate(wire, hello: hello, dialedByUs: dialedByUs)
            onHello?(hello)
            onReplaced?()
            return
        }
        // An incoming link that both Macs prefer wins over our dial in
        // flight; otherwise our dial continues and may replace it later.
        if !dialedByUs, let attempt, target?.id != hello.device || preferred(false) {
            drop(attempt, "the other Mac dialed in"); self.attempt = nil
        }
        if !dialedByUs { wire.send(helloMessage(kind: "helloOK")) }
        activate(wire, hello: hello, dialedByUs: dialedByUs)
        onHello?(hello)
        onEvent?(.handshakeOK)
        onStatus?(dialedByUs ? tr("已连接。", "Connected.") : tr("已连接，等待对方就绪。", "Connected; waiting for the other Mac."))
    }
    private func turnAway(_ wire: Wire) { retire(wire, saying: "busy", "busy") }
    /// Detaches a link, tells the other Mac why, and closes it once that
    /// message left (closing at once could discard it).
    private func retire(_ wire: Wire, saying kind: String, _ reason: String) {
        detach(wire)
        wire.send(Message(kind: kind)) { wire.close(.local(reason)) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { wire.close(.local(reason)) }
    }
    private func activate(_ wire: Wire, hello: PeerHello, dialedByUs: Bool) {
        peer = wire; peerInfo = hello; peerDialedByUs = dialedByUs
        wire.onMessage = { [weak self, weak wire] m in
            guard let self, let wire, self.peer === wire else { return }
            self.onMessage?(m)
        }
        wire.onClose = { [weak self, weak wire] reason in
            guard let self, let wire, self.peer === wire else { return }
            self.peer = nil; self.peerInfo = nil; self.peerDialedByUs = false
            // Both dialed at once and the other Mac dropped this link: our own
            // dial to it is about to take over, and reports if it fails.
            if self.attempt != nil, hello.device != nil, self.target?.id == hello.device { return }
            self.onEvent?(.closed(reason))
        }
    }
}
