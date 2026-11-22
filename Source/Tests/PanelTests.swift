import Foundation
import Network

/// 0.8.0 panel logic that needs no window: the device list, the empty state
/// and both interface languages.
func runPanelTests() throws {
    var count = 0
    func check(_ condition: Bool, _ description: String) throws {
        guard condition else { throw BridgeError("FAIL: \(description)") }
        count += 1; print("PASS: \(description)")
    }
    func hasCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) || (0x3000...0x303F).contains($0.value) || (0xFF00...0xFFEF).contains($0.value) }
    }

    // Device list: the linked Mac first, then reachable ones, else store order.
    func device(_ id: String, _ name: String, mode: PeerMode? = .provider) -> PairedDevice {
        var d = PairedDevice(id: id, name: name); d.mode = mode; d.model = "Mac mini (2024)"; return d
    }
    func presence(_ advert: PresenceAdvert?, dial: DialOutcome? = nil) -> PeerPresence {
        var p = PeerPresence(); p.seen(advert); p.lastDial = dial; return p
    }
    func advert(_ name: String, _ mode: PeerMode, busy: Bool = false) -> PresenceAdvert {
        PresenceAdvert(mode: mode, version: bridgeVersion, name: name, model: "MacBook Pro (14-inch, 2023)", busy: busy)
    }
    func service(_ id: String?, _ advert: PresenceAdvert?) -> NearbyService {
        NearbyService(serviceName: id.map { "MicBridge-" + $0 } ?? "MicBridge", deviceID: id,
                      endpoint: .service(name: id ?? "x", type: BridgeDiscovery.serviceType, domain: "local.", interface: nil), advert: advert)
    }
    let devices = [device("a", "Studio", mode: .borrower), device("b", "MacBook"), device("c", "Mac mini"), device("d", "iMac")]
    var inputs = DeviceList.Inputs(role: .borrower, devices: devices, keys: ["a", "b", "c"],
                                   presence: ["b": presence(advert("MacBook", .provider)), "c": presence(advert("Mac mini", .provider, busy: true))],
                                   nearby: [], linked: "c", preferred: "b")
    var rows = DeviceList.mine(inputs)
    try check(rows.map(\.id) == ["c", "b", "a", "d"], "the linked Mac comes first, then Macs that can connect now, then the rest in order")
    try check(rows[0].isCurrent && rows[0].state == .connected && !rows[1].isCurrent, "only the linked Mac is marked current")
    try check(rows.first { $0.id == "b" }?.isChosen == true && rows.filter(\.isChosen).count == 1, "the chosen provider is marked")
    try check(rows.first { $0.id == "a" }?.canUse == false && rows.first { $0.id == "b" }?.canUse == true,
              "a borrower can pick providers, not other borrowers")
    try check(rows.first { $0.id == "d" }?.needsPairing == true && rows.first { $0.id == "d" }?.canUse == false,
              "a paired Mac without a key here asks to pair again")
    try check(!rows[0].micInUse, "no microphone is shown in use while idle")
    inputs.micActive = true
    rows = DeviceList.mine(inputs)
    try check(rows[0].micInUse && rows.dropFirst().allSatisfy { !$0.micInUse }, "the microphone in use shows on the linked Mac only")
    inputs.role = .provider
    try check(DeviceList.mine(inputs).allSatisfy { !$0.canUse && !$0.isChosen }, "a provider offers no Use action")
    try check(DeviceList.state(.unreachable) == .offline && DeviceList.state(.unknown) == .offline && DeviceList.state(.appClosed) == .appClosed,
              "unreachable Macs read as offline; a closed app is named")

    // Nearby: 0.7.1+ Macs not paired here, never this Mac itself.
    inputs.localID = "self"
    inputs.nearby = [service("b", advert("MacBook", .provider)), service("self", advert("This Mac", .borrower)),
                     service(nil, nil), service("z", advert("Studio 2", .provider)), service("y", advert("Air", .paused)),
                     service("z", advert("Studio 2", .provider))]
    inputs.pairing = "z"
    let near = DeviceList.nearby(inputs)
    try check(near.map(\.id) == ["y", "z"], "nearby lists unpaired Macs once, sorted, without this Mac or older versions")
    try check(near.allSatisfy { !$0.paired } && near[1].state == .pairing && near[0].state == .paused, "nearby rows show pairing and paused states")

    // Status: nothing paired is an empty state, not an error.
    var idle = ConnectionState(role: .borrower); _ = idle.reduce(.start, now: 0)
    var status = StatusInputs(connection: idle, hasPairedDevices: false)
    try check(BridgeStatus.derive(status) == .noPairedDevices, "with nothing paired the panel shows the empty state")
    status.pairingActive = true; status.pairingCode = "482193"
    try check(BridgeStatus.derive(status) == .pairing(code: "482193", message: ""), "adding a Mac outranks the empty state")
    status = StatusInputs(connection: idle, hasPairedDevices: true)
    try check(BridgeStatus.derive(status) != .noPairedDevices, "a paired Mac is never reported as missing")

    // First launch: not started while the welcome window is open. That is
    // "finish setting up", never "paused", and the switch isn't drawn off.
    let notStarted = ConnectionState(role: .borrower)
    try check(BridgeStatus.derive(StatusInputs(connection: notStarted, hasPairedDevices: false, settingUp: true)) == .settingUp &&
              BridgeStatus.derive(StatusInputs(connection: notStarted, hasPairedDevices: false)) == .paused,
              "before setup is done the bridge reads as setting up; afterwards a stop is a pause")
    try check(BridgeStatus.derive(StatusInputs(connection: notStarted, incomingPairing: ("Studio", "482193"), settingUp: true)) == .incomingPairing(peer: "Studio", code: "482193"),
              "a pairing request still shows while setting up")
    let firstRun = PanelSnapshot(status: .settingUp, role: .borrower, enabled: false)
    try check(!firstRun.paused && !firstRun.showsSwitch && !firstRun.showsPeer && firstRun.status.symbol != PanelSnapshot(status: .paused).status.symbol,
              "setting up: nothing is faded as paused, no off switch, no empty peer")
    try check(PanelSnapshot(status: .paused, role: .borrower, enabled: false).showsSwitch && PanelSnapshot(status: .ready, role: .borrower, enabled: true).showsSwitch,
              "after setup the switch is there, paused or running")
    for lang in Lang.allCases {
        let (title, subtitle) = withLanguage(lang) { (firstRun.title, firstRun.subtitle) }
        try check(!title.isEmpty && !subtitle.isEmpty && title.count <= 20 && title != withLanguage(lang) { StatusCopy.title(.paused, firstRun.context) },
                  "\(lang): setting up has its own short line (\(title))")
    }

    // Both languages: every status has a title and subtitle in each, and
    // English has no Chinese apart from names.
    let statuses: [BridgeStatus] = [
        .sleeping, .incomingPairing(peer: "Studio", code: "482193"), .setup(.microphoneDenied), .setup(.noMicrophone),
        .setup(.noVirtualMicrophone), .setup(.virtualMicrophoneTimeout), .problem("x"), .paused, .settingUp, .waitingForKeychain,
        .pairing(code: "482193", message: ""), .pairing(code: "", message: ""), .inUse(.activating), .inUse(.live), .inUse(.finishing),
        .ready, .noPairedDevices, .localNetworkBlocked, .roleConflict, .peerBusy, .peerPaused, .peerAsleep, .peerAppClosed,
        .connecting, .searching(longWait: false), .searching(longWait: true),
    ]
    var missing: [String] = [], chinese: [String] = []
    for role in [Role.provider, .borrower] {
        let context = CopyContext(role: role, peer: "Studio", client: "Notes", device: "MicBridge Microphone")
        for s in statuses {
            for lang in Lang.allCases {
                let (title, subtitle) = withLanguage(lang) { (StatusCopy.title(s, context), StatusCopy.subtitle(s, context)) }
                // Paused and a pairing request say only their title.
                let titleOnly: Bool = { if case .incomingPairing = s { return true }; return s == .paused || s == .problem("") }()
                if title.isEmpty || (subtitle.isEmpty && !titleOnly) { missing.append("\(lang) \(role) \(s)") }
                if lang == .en && (hasCJK(title) || hasCJK(subtitle)) { chinese.append("\(role) \(s): \(title) / \(subtitle)") }
            }
        }
    }
    try check(missing.isEmpty, "every status has a title and subtitle in both languages \(missing)")
    try check(chinese.isEmpty, "English status copy contains no Chinese \(chinese)")
    let english = withLanguage(.en) { rows.map(\.detail) + near.map(\.detail) + DeviceList.mine(inputs).map(\.stateLabel) }
    try check(english.allSatisfy { !$0.isEmpty && !hasCJK($0) }, "device rows read in English")
    let fixtures = withLanguage(.en) { PreviewFixtures.all.map { previewSnapshot($0) } }
    let chinesePreviews = withLanguage(.en) { fixtures.map { [$0.title, $0.subtitle, $0.micCaption, $0.client, $0.device] }.joined().filter(hasCJK) }
    try check(chinesePreviews.isEmpty, "English previews contain no Chinese \(chinesePreviews)")
    try check(withLanguage(.zh) { tr("已连接", "Connected") } == "已连接" && withLanguage(.en) { tr("已连接", "Connected") } == "Connected",
              "the pinned language picks the sentence")
    let neutral: Set<String> = ["Studio", "MacBook", "Mac mini", "MacBook Air", "iMac", "Mac Pro"]
    let snapshots = PreviewFixtures.all.map(previewSnapshot)
    let names = Set(snapshots.flatMap { s -> [String] in [s.localName] + (s.mine + s.nearby).map(\.name) })
    try check(names.isSubset(of: neutral) && snapshots.allSatisfy { s in neutral.contains { s.peerName == $0 || s.peerName.hasPrefix($0 + "（") || s.peerName.hasPrefix($0 + " (") } },
              "previews use neutral example names only")
    let twins = previewSnapshot(PreviewFixtures.all.first { $0.devices == .twins }!)
    try check(twins.mine[0].tag == "3F2A" && twins.nearby[0].tag == "C71B" && twins.peerName == "MacBook（3F2A）",
              "the same-name preview tells the two MacBooks apart by device code")

    // Same name: rows are told apart by model, else by a device-ID prefix.
    func plain(_ id: String, _ name: String, _ model: String, paired: Bool = true) -> DeviceRow {
        DeviceRow(id: id, name: name, model: model, mode: .provider, state: .online, paired: paired)
    }
    let idA = "3f2a8c51e07d94b6a2c1", idB = "c71b09e4d2a85f3b6e10", idC = "3f2a77aa00bb11cc22dd"
    var tagged = DeviceList.disambiguate([plain(idA, "Studio", "Mac Studio (2023)"), plain(idB, "Studio", "Mac Studio (2023)")], localName: "MacBook", localModel: "")
    try check(tagged.map(\.tag) == ["3F2A", "C71B"], "two Macs with the same name and model show device codes")
    tagged = DeviceList.disambiguate([plain(idA, "Studio", "Mac Studio (2023)"), plain(idB, "studio ", "Mac mini (2024)")], localName: "MacBook", localModel: "")
    try check(tagged.map(\.tag) == ["Mac Studio", "Mac mini"], "same name, different models: the model tells them apart (case and spaces ignored)")
    tagged = DeviceList.disambiguate([plain(idA, "Studio", ""), plain(idC, "Studio", "")], localName: "", localModel: "")
    try check(tagged.map(\.tag) == ["3F2A8C", "3F2A77"], "device codes grow until they differ")
    tagged = DeviceList.disambiguate([plain(idA, "Studio", "Mac Studio (2023)"), plain(idB, "Studio", "Mac Studio (2023)", paired: false), plain("x", "MacBook", "")],
                                     localName: "iMac", localModel: "")
    try check(tagged[0].tag != nil && tagged[1].tag != nil && tagged[2].tag == nil, "a paired and a nearby Mac of one name are both tagged; unique names are not")
    tagged = DeviceList.disambiguate([plain(idA, "MacBook", "MacBook Air (13-inch, M3, 2024)")], localName: "MacBook", localModel: "MacBook Pro (14-inch, 2023)")
    try check(tagged[0].tag == "MacBook Air", "a Mac named like this one is tagged too")
    tagged = DeviceList.disambiguate([plain(idA, "MacBook", "MacBook Pro (14-inch, 2023)")], localName: "MacBook", localModel: "MacBook Pro (14-inch, 2021)")
    try check(tagged[0].tag == "3F2A", "named and built like this one: the device code")
    try check(withLanguage(.en) { tagged[0].label } == "MacBook (3F2A)" && withLanguage(.zh) { tagged[0].label } == "MacBook（3F2A）" &&
              plain(idA, "Studio", "").label == "Studio", "a tagged name reads naturally in both languages; untagged stays as is")

    // Two nearby Macs with one name but different IDs: both listed, and
    // presence goes to each by ID.
    var twinInputs = DeviceList.Inputs(role: .borrower, devices: [], keys: [], presence: [:], nearby: [service(idA, advert("Studio", .provider)), service(idB, advert("Studio", .provider))])
    twinInputs.localID = "self"
    let groups = DeviceList.groups(twinInputs, localName: "MacBook", localModel: "MacBook Pro (14-inch, 2023)")
    try check(groups.nearby.map(\.id).sorted() == [idA, idB] && Set(groups.nearby.compactMap(\.tag)) == ["3F2A", "C71B"],
              "two nearby Macs with the same name are both listed and tagged")
    let byID = AppModel.servicesByID([service(idA, advert("Studio", .provider)), service(idB, advert("Studio", .paused)), service(nil, nil)])
    try check(byID.count == 2 && byID[idA]?.advert?.mode == .provider && byID[idB]?.advert?.mode == .paused,
              "nearby services are matched to paired Macs by device ID, never by name")
    // Pause: a two-way switch for the role, an on/off switch for pausing.
    try check(ModeSwitch.modes == [.provider, .borrower], "the role switch has only Share and Use")
    for role in [Role.provider, .borrower] {
        try check(PanelHeader.mode(on: false, role: role) == .paused && PanelHeader.mode(on: true, role: role) == (role == .provider ? .provider : .borrower),
                  "the on/off switch pauses and resumes the \(role) role unchanged")
    }
    var paused = PanelSnapshot(status: .paused, role: .provider, enabled: false, mine: [rows[0]], nearby: near)
    paused.permissions.firewall = .blocksApp
    try check(paused.paused && paused.mode == .paused && !paused.showsNearby && !paused.showsFirewallNotice,
              "paused: no nearby Macs and no firewall warning")
    try check(withLanguage(.zh) { (paused.title, paused.subtitle) } == ("已暂停", "") && withLanguage(.en) { (paused.title, paused.subtitle) } == ("Paused", ""),
              "paused says one word in each language")
    var on = paused; on.enabled = true; on.status = .ready
    try check(!on.paused && on.showsFirewallNotice && on.showsNearby, "on: the firewall warning and nearby Macs return")
    for state in [FirewallState.unknown, .off, .allows] {
        on.permissions.firewall = state
        try check(!on.showsFirewallNotice, "no firewall warning when it is \(state)")
    }
    on.nearby = []
    try check(!on.showsNearby && { var e = on; e.mine = []; return e.showsNearby }(), "nearby shows when nothing is paired, or when a Mac is near")

    print("\(count) panel, device list and language checks passed.")
}
