import Cocoa
import Network

/// Paired Macs: presence, whom to dial, key exchange and pairing.
extension AppModel {
    static let preferredProviderKey = "preferredProvider"

    func wireLink() {
        link.onEvent = { [weak self] in self?.dispatch($0) }
        link.onMessage = { [weak self] in self?.received($0) }
        link.onHello = { [weak self] in self?.linked($0) }
        link.onReplaced = { [weak self] in
            // The same Mac on a new link: tell it again that this side is ready.
            guard let self, self.role == .provider else { return }
            self.provider.linkUp()
        }
        link.onDialResult = { [weak self] id, reason in self?.presence[id, default: PeerPresence()].dialed(reason.flatMap(DialOutcome.init)) }
        link.onStatus = { [weak self] in self?.status($0) }
        link.canReplacePeer = { [weak self] in self?.captureIdle ?? true }
        // A borrower takes links only once its virtual microphone runs, as before.
        link.acceptsConnections = { [weak self] in
            self.map { $0.enabled && !$0.suspended && ($0.role == .provider || $0.borrower.outputReady) } ?? false
        }
        link.localNetworkIssue = { [weak self] in self?.state.localNetworkIssue ?? false }
        link.local = { [weak self] in
            self?.localHello ?? LocalHello(name: DeviceIdentity.computerName, model: DeviceIdentity.model, device: "", mode: .paused)
        }
        browser.onChange = { [weak self] in self?.nearbyChanged($0) }
    }

    /// This Mac's device ID: the fingerprint of its device key.
    var deviceID: String { vault.listeningKey.map(DeviceKey.id(for:)) ?? "" }
    var localHello: LocalHello {
        LocalHello(name: localName, model: DeviceIdentity.model, device: deviceID, mode: PeerMode(role: role, enabled: enabled))
    }

    /// The paired Mac the panel talks about: the linked one, else the one
    /// being dialed, else the one this Mac used last in the other role.
    var peer: PairedDevice {
        if let id = linkedDevice ?? link.target?.id, let device = peers.device(id) { return device }
        if role == .borrower, let id = defaults.string(forKey: Self.preferredProviderKey), let device = peers.device(id) { return device }
        let wanted: PeerMode = role == .provider ? .borrower : .provider
        return peers.devices.first { $0.mode == wanted } ?? peers.devices.first ?? PairedDevice(id: "")
    }
    var peerAvailability: PeerAvailability { presence[peer.id]?.availability ?? .unknown }

    // MARK: Presence

    /// Loads this Mac's device key, then listens and advertises. Also while
    /// paused (the advert says so); only sleep takes this Mac off the network.
    func goOnline() {
        vault.loadListeningKey { [weak self] result in
            guard let self, !self.suspended else { return }
            switch result {
            case .success:
                if !self.link.isListening { self.startListening() }
                if !self.browser.isRunning { self.browser.start() }
            case .failure(let error):
                if self.enabled { self.stop(.problem(error.localizedDescription)) } else { self.status(error.localizedDescription) }
            }
        }
    }
    func startListening() {
        guard let key = vault.listeningKey, !suspended else { return }
        WiredAddresses.shared.start()
        refreshAdvert()
        do { try link.listen(key: key) }
        catch { dispatch(.listenerFailed); status(tr("正在恢复连接服务。", "Restarting the connection service.")) }
    }
    /// The TXT record follows mode, busy and the computer name. Republished
    /// only when something changed.
    func refreshAdvert() {
        guard vault.listeningKey != nil else { return }
        link.advert = PresenceAdvert(mode: PeerMode(role: role, enabled: enabled && !suspended), version: bridgeVersion,
                                     name: localName, model: DeviceIdentity.model, busy: link.handshaken)
    }
    func presenceTick() {
        guard now - lastNameCheck >= 1 else { return }
        lastNameCheck = now
        refreshAdvert()
        updateTarget()
    }
    /// Nearby services by device ID (the first of each), never by name:
    /// two Macs may share one.
    static func servicesByID(_ services: [NearbyService]) -> [String: NearbyService] {
        var byID: [String: NearbyService] = [:]
        for service in services { if let id = service.deviceID, byID[id] == nil { byID[id] = service } }
        return byID
    }
    /// Another Mac here (paired or nearby), or this one, has this name.
    func sharesName(_ name: String, id key: Data) -> Bool {
        let id = DeviceKey.id(for: key), wanted = DeviceTag.key(name)
        let others = peers.devices.filter { $0.id != id }.map(\.displayName)
            + browser.services.filter { $0.deviceID != id }.compactMap { $0.advert?.name } + [localName]
        return others.contains { DeviceTag.key($0) == wanted }
    }
    func nearbyChanged(_ services: [NearbyService]) {
        let byID = Self.servicesByID(services)
        for device in peers.devices where !device.isPlaceholder {
            var p = presence[device.id] ?? PeerPresence()
            guard let service = byID[device.id] else { p.vanished(); presence[device.id] = p; continue }
            if !p.visible || p.advert != service.advert { p.seen(service.advert) }
            presence[device.id] = p
            guard let advert = service.advert else { continue }
            // Its own name, as it advertises it: the same name it shows itself.
            peers.update(device.id) { d in
                if !advert.name.isEmpty { d.name = advert.name }
                if !advert.model.isEmpty { d.model = advert.model }
                if let role = advert.mode.role { d.mode = PeerMode(role: role, enabled: true) }
            }
        }
        if let id = link.target?.id { link.setDiscovered(byID[id]?.endpoint) }
        updateTarget()
        syncUI()
    }

    // MARK: Dialing

    /// After audio is ready: this Mac's key (to listen), the paired keys, then
    /// whoever `DialPlanner` picks. A provider without pairings pairs first.
    func connect(epoch: UUID) {
        status(tr("正在读取配对密钥…", "Reading the pairing keys…"))
        vault.loadListeningKey { [weak self] result in
            guard let self, self.enabled, self.connectionGeneration == epoch else { return }
            if case .failure(let error) = result { self.stop(.problem(error.localizedDescription)); return }
            if !self.link.isListening { self.startListening() }
            if !self.browser.isRunning { self.browser.start() }
            self.refreshAdvert()
            self.vault.loadPeerKeys { [weak self] result in
                guard let self, self.enabled, self.connectionGeneration == epoch else { return }
                switch result {
                // Denied or cancelled: keep the pairings and let the user retry.
                case .failure(let error): self.stop(.problem(error.localizedDescription))
                case .success(let keys):
                    self.peers.reconcile(keyIDs: Set(keys.keys))
                    self.startPairingService()
                    self.unlinkedSince = self.now
                    self.status(self.role == .provider ? tr("等待使用麦克风的 Mac。", "Waiting for a Mac that uses this microphone.") : tr("等待提供麦克风的 Mac。", "Waiting for a Mac that shares its microphone."))
                    self.updateTarget()
                }
            }
        }
    }
    /// Every Mac that is on can be asked to pair, whatever its role.
    func startPairingService() {
        guard enabled, !suspended, pairingServer.listener == nil else { return }
        pairingRetryAt = now + 5
        try? pairingServer.start()
    }
    /// Points the link at the Mac to dial, or at nobody.
    func updateTarget() {
        guard enabled, !suspended, !waitingForDriver, linkedDevice == nil, state.link != .pairing, let keys = vault.peerKeys else { return }
        let id = DialPlanner.target(role: role, devices: peers.devices, keys: Set(keys.keys), presence: presence,
                                    preferred: defaults.string(forKey: Self.preferredProviderKey), idleFor: now - unlinkedSince)
        if let id, let device = peers.device(id), let key = keys[id] {
            link.setTarget(DialTarget(id: id, key: key, host: device.host, wiredHosts: device.wiredHosts))
            link.setDiscovered(browser.services.first { $0.deviceID == id }?.endpoint)
        } else {
            link.setTarget(nil)
        }
        let visible = id.map { presence[$0]?.visible ?? false } ?? false
        if state.peerVisible != visible { dispatch(.peerVisible(visible)) }
        if state.canDial != (id != nil) { dispatch(.dialTarget(id != nil)) }
    }

    // MARK: Link

    /// A link came up (or replaced a duplicate): record who it is.
    func linked(_ hello: PeerHello) {
        peerVersion = hello.version
        if role == .borrower { borrower.clockOffset = Date().timeIntervalSince1970 - hello.sentAt }
        let id = peers.recordID(for: hello, dialed: link.peerDialedByUs ? link.target?.id : nil)
        linkedDevice = id
        presence[id, default: PeerPresence()].linked(true)
        peers.noteLink(id, hello: hello, theyDialed: !link.peerDialedByUs, localRole: role)
        if role == .borrower, !(peers.device(id)?.isPlaceholder ?? true) { defaults.set(id, forKey: Self.preferredProviderKey) }
        // Complete a one-way (0.7.0) pairing: give a 0.7.1 peer this Mac's key.
        if hello.supports(ProtocolFeature.peerKey), let key = vault.listeningKey, peers.device(id)?.hasOurKey != true {
            link.send(Message(kind: "peerKey", text: key.base64EncodedString()))
            peers.update(id) { $0.hasOurKey = true }
        }
        // Keep 0.6.0's key current too, so a downgrade still prefers the wire.
        if role == .provider, let hosts = hello.hosts { defaults.set(hosts, forKey: PeerStore.legacyWiredKey) }
        refreshAdvert()
    }
    func linkLost() {
        if let id = linkedDevice { presence[id]?.linked(false) }
        linkedDevice = nil; unlinkedSince = now
        refreshAdvert()
    }
    /// The linked Mac sent its own device key (completing a one-way pairing).
    func receivedPeerKey(_ m: Message) {
        guard let id = linkedDevice, let key = Data(base64Encoded: m.text), key.count == 32 else { return }
        let keyID = DeviceKey.id(for: key)
        // Only the key of the Mac on this link, as it identified itself.
        guard keyID == link.peerInfo?.device, vault.peerKeys?[keyID] != key else { return }
        vault.savePeerKey(key, for: keyID) { [weak self] error in
            guard let self, error == nil else { return }
            if id != keyID { self.peers.merge(id, into: keyID); self.linkedDevice = keyID }
        }
    }

    // MARK: Pairing

    /// This Mac's pairing card: where it listens and its device key.
    func pairingCard() throws -> Pairing {
        guard let key = vault.listeningKey else { throw BridgeError(tr("配对密钥还没有准备好，请稍后再试。", "The pairing key isn’t ready yet. Try again in a moment.")) }
        return Pairing(host: localBonjourHost(), key: key.base64EncodedString(), name: localName, model: DeviceIdentity.model)
    }
    /// What a Mac does, from its advert if it is nearby, else the opposite of
    /// this Mac (the only pairing that made sense before 0.7.1).
    func advertisedMode(of id: String) -> PeerMode {
        if let mode = browser.services.first(where: { $0.deviceID == id })?.advert?.mode, mode != .paused { return mode }
        return role == .provider ? .borrower : .provider
    }
    /// Saves another Mac's card; the keychain write runs off the main thread.
    func savePairing(_ card: Pairing, name: String?, mode: PeerMode? = nil, hasOurKey: Bool = false, then done: @escaping (String?, Error?) -> Void) {
        guard let key = card.keyData else { done(nil, BridgeError(tr("配对信息无效。", "Invalid pairing info."))); return }
        let id = DeviceKey.id(for: key)
        let mode = mode ?? advertisedMode(of: id)
        vault.savePeerKey(key, for: id, legacy: mode == .borrower) { [weak self] error in
            guard let self else { return }
            if error == nil {
                self.peers.update(id) { device in
                    if device.host != card.host { device.wiredHosts = [] }
                    device.host = card.host; device.mode = mode
                    for candidate in [card.name, name] { if let candidate, !candidate.isEmpty { device.name = candidate; break } }
                    if let model = card.model, !model.isEmpty { device.model = model }
                    if hasOurKey { device.hasOurKey = true }
                }
                // A borrower's first provider is the one it uses.
                if self.role == .borrower, mode == .provider, self.defaults.string(forKey: Self.preferredProviderKey) == nil {
                    self.defaults.set(id, forKey: Self.preferredProviderKey)
                }
            }
            done(id, error)
        }
    }
    /// Asks a nearby Mac to pair; the user there approves.
    func pair(with id: String) {
        guard enabled, let service = browser.services.first(where: { $0.deviceID == id }), let advert = service.advert else {
            ui.notify(enabled ? tr("这台 Mac 已不在附近", "That Mac is no longer nearby") : tr("请先开启 MicBridge", "Turn MicBridge on first"))
            return
        }
        pairTarget = id; pairPeer = advert.name; pairCode = ""; pairMessage = ""
        // By device ID: another Mac nearby may have the same name.
        pairingClient.start(deviceID: id, name: advert.name)
        syncUI()
    }
    func cancelPairing() {
        pairingClient.stop()
        pairTarget = nil; pairCode = ""; pairMessage = ""; pairPeer = ""
        syncUI()
    }
    func pairingFailed(_ reason: String) {
        pairTarget = nil; pairCode = ""; pairMessage = ""; pairPeer = ""
        ui.notify(reason)
        syncUI()
    }
    /// This Mac asked; the other Mac approved and sent its card.
    func adoptPairing(_ card: Pairing) {
        let name = pairPeer
        // Only the Mac picked in the list (the client checked too).
        guard let key = card.keyData, DeviceKey.id(for: key) == pairTarget else { pairingFailed(PairingTarget.wrongMac()); return }
        savePairing(card, name: name) { [weak self] _, error in
            guard let self else { return }
            self.pairTarget = nil; self.pairCode = ""; self.pairMessage = ""; self.pairPeer = ""
            if let error { self.ui.notify(error.localizedDescription); self.syncUI(); return }
            let label = DeviceTag.label(card.name ?? name, self.sharesName(card.name ?? name, id: key) ? DeviceTag.code(DeviceKey.id(for: key)) : nil)
            self.ui.notify(tr("已与\(label)配对", "Paired with \(label)"))
            self.reloadKeysAndDial()
        }
    }
    /// The other Mac asked and this Mac approved; its card came back.
    func adoptReturnedCard(_ card: Pairing) {
        savePairing(card, name: nil, hasOurKey: true) { [weak self] _, error in
            guard let self, error == nil else { return }
            self.reloadKeysAndDial()
        }
    }
    /// After the key bundle changed: pick up the new Mac at once.
    func reloadKeysAndDial() {
        vault.loadPeerKeys { [weak self] _ in self?.updateTarget(); self?.syncUI() }
    }
    func pairManually(_ text: String) {
        let card: Pairing
        do { card = try Pairing.parse(text) } catch { ui.notify(error.localizedDescription); return }
        savePairing(card, name: nil) { [weak self] _, error in
            guard let self else { return }
            if let error { self.ui.notify(error.localizedDescription); return }
            self.ui.notify(tr("已保存连接信息", "Connection info saved"))
            self.restartEnabled()
        }
    }
    func approvePairing() {
        let label = incomingLabel
        do { try pairingServer.approve(); ui.notify(tr("已允许\(label)配对", "Paired with \(label)")) }
        catch { ui.notify(error.localizedDescription) }
        clearIncomingPair()
    }
    func rejectPairing() { pairingServer.reject(); clearIncomingPair() }
    func clearIncomingPair() { incomingPair = false; incomingCode = ""; incomingPeer = ""; incomingRequest = nil; syncUI() }
    func copyPairing() {
        vault.loadListeningKey { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                guard let card = try? self.pairingCard() else { return }
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(card.encoded, forType: .string)
                self.ui.notify(tr("连接信息已复制", "Connection info copied"))
            case .failure(let error): self.ui.notify(error.localizedDescription)
            }
        }
    }

    // MARK: Device list actions

    /// Borrower: always use this provider when it is available.
    func useProvider(_ id: String) {
        guard role == .borrower, peers.device(id) != nil else { return }
        defaults.set(id, forKey: Self.preferredProviderKey)
        if let linked = linkedDevice, linked != id { restart() } else { updateTarget() }
        syncUI()
    }
    /// A name for another Mac, on this Mac only. Empty restores its own name.
    func rename(_ id: String, to alias: String) {
        let value = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        peers.update(id) { $0.alias = value.isEmpty ? nil : String(value.prefix(40)) }
        syncUI()
    }
    /// Forgets a Mac and its key. Pairing again needs approval on both Macs.
    func forget(_ id: String) {
        guard let device = peers.device(id) else { return }
        let wasLinked = linkedDevice == id
        peers.remove(id)
        presence[id] = nil
        if defaults.string(forKey: Self.preferredProviderKey) == id { defaults.removeObject(forKey: Self.preferredProviderKey) }
        ui.notify(tr("已移除\(device.displayName)", "Removed \(device.displayName)"))
        let done = { [weak self] in
            guard let self else { return }
            if wasLinked { self.restart() } else { self.updateTarget() }
            self.syncUI()
        }
        // A 0.7.0 placeholder has no key of its own yet.
        if device.isPlaceholder { done() } else { vault.removePeerKey(id) { _ in done() } }
    }
    /// This Mac's name on every Mac. Nil goes back to the computer name.
    func setLocalName(_ name: String?) {
        DeviceIdentity.customName = name
        refreshAdvert()
        // The pairing service is advertised under the name.
        if pairingServer.listener != nil { pairingServer.stop(); startPairingService() }
        syncUI()
    }
    /// The panel's Share / Use / Pause control.
    func setMode(_ mode: PeerMode) {
        switch mode {
        case .paused:
            if enabled { toggleEnabled() }
        case .provider, .borrower:
            let wanted: Role = mode == .provider ? .provider : .borrower
            if wanted != role { setRole(wanted) }
            if !enabled { toggleEnabled() }
        }
    }
}
