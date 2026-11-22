import Foundation

/// One Mac in the panel's device list, as plain values.
struct DeviceRow: Identifiable, Equatable {
    enum State: Equatable {
        case connected, online, busy, paused, asleep, appClosed, offline
        /// Being paired from this Mac right now.
        case pairing
    }
    var id: String
    var name: String
    var model: String
    /// What it does, as last seen (nil: never said).
    var mode: PeerMode?
    var state: State
    /// Paired with this Mac (else: nearby, not paired).
    var paired: Bool
    /// The Mac on the active link.
    var isCurrent = false
    /// The active link and a microphone is capturing right now.
    var micInUse = false
    /// Borrower: the provider it picked (used whenever it is available).
    var isChosen = false
    /// Borrower: it provides, so this Mac may pick it.
    var canUse = false
    /// A 0.6.0 / 0.7.0 Mac (no presence information).
    var legacy = false
    /// Paired, but its key is missing here: pair again to connect.
    var needsPairing = false
    /// Set only when another row (or this Mac) has the same name: its model,
    /// or a short code from its device ID ("3F2A").
    var tag: String?
}

/// Short, readable forms of a device's identity, for telling apart Macs
/// that share a name. Display only; trust always uses the full device ID.
enum DeviceTag {
    /// The first `length` hex digits of a device ID, upper case.
    static func code(_ id: String, length: Int = 4) -> String { String(id.prefix(length)).uppercased() }
    /// "MacBook Pro (14-inch, 2021)" → "MacBook Pro".
    static func shortModel(_ model: String) -> String {
        let cut = model.firstIndex(of: "(").map { String(model[..<$0]) } ?? model
        return cut.trimmingCharacters(in: .whitespaces)
    }
    /// A name as compared for clashes: case, width and spacing ignored.
    static func key(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    /// "Studio (3F2A)" / "Studio（3F2A）"; the name alone without a tag.
    static func label(_ name: String, _ tag: String?) -> String {
        guard let tag, !tag.isEmpty else { return name }
        return tr("\(name)（\(tag)）", "\(name) (\(tag))")
    }
}

/// Builds the panel's two groups: "My Macs" (paired) and "Nearby" (running
/// MicBridge, not paired). Pure, so ordering and states are tested.
enum DeviceList {
    struct Inputs {
        var role: Role
        var devices: [PairedDevice]
        /// Device IDs with a key in the keychain; nil before it is read.
        var keys: Set<String>?
        var presence: [String: PeerPresence]
        var nearby: [NearbyService]
        var linked: String?
        var preferred: String?
        var micActive = false
        var localID = ""
        /// Device ID being paired from this Mac.
        var pairing: String?
    }

    static func mine(_ i: Inputs) -> [DeviceRow] {
        let rows = i.devices.map { device -> DeviceRow in
            let presence = i.presence[device.id] ?? PeerPresence()
            let current = device.id == i.linked
            let mode = presence.advert?.mode ?? device.mode
            var row = DeviceRow(id: device.id, name: device.displayName, model: presence.advert?.model ?? device.model ?? "",
                                mode: mode, state: current ? .connected : state(presence.availability), paired: true)
            row.isCurrent = current
            row.micInUse = current && i.micActive
            row.legacy = device.isPlaceholder
            row.needsPairing = !device.isPlaceholder && i.keys.map { !$0.contains(device.id) } == true
            if i.role == .borrower {
                row.canUse = !device.isPlaceholder && !row.needsPairing && mode != .borrower
                row.isChosen = row.canUse && device.id == i.preferred
            }
            return row
        }
        // The linked Mac first, then those that can connect now; otherwise
        // the store's order (most recently connected first) is kept.
        func rank(_ row: DeviceRow) -> Int {
            if row.isCurrent { return 0 }
            switch row.state {
            case .online, .busy, .pairing: return 1
            default: return 2
            }
        }
        return rows.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    static func nearby(_ i: Inputs) -> [DeviceRow] {
        let paired = Set(i.devices.map(\.id))
        var seen = Set<String>()
        var rows: [DeviceRow] = []
        for service in i.nearby {
            // Only 0.7.1+ Macs say who they are; older ones pair manually.
            guard let id = service.deviceID, let advert = service.advert, id != i.localID, !paired.contains(id),
                  seen.insert(id).inserted else { continue }
            let state: DeviceRow.State = id == i.pairing ? .pairing : advert.mode == .paused ? .paused : advert.busy ? .busy : .online
            rows.append(DeviceRow(id: id, name: advert.name.isEmpty ? PairedDevice.fallbackName : advert.name, model: advert.model,
                                  mode: advert.mode, state: state, paired: false))
        }
        return rows.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Both groups, with same-name rows told apart.
    static func groups(_ i: Inputs, localName: String, localModel: String) -> (mine: [DeviceRow], nearby: [DeviceRow]) {
        let mine = mine(i), nearby = nearby(i)
        let tagged = disambiguate(mine + nearby, localName: localName, localModel: localModel)
        return (Array(tagged.prefix(mine.count)), Array(tagged.dropFirst(mine.count)))
    }

    /// Tags rows whose names clash with another row's or this Mac's: by
    /// model when every Mac in the clash has a different one, else by the
    /// shortest device-ID prefix (from 4 digits) that differs. Unique names
    /// get no tag.
    static func disambiguate(_ rows: [DeviceRow], localName: String, localModel: String) -> [DeviceRow] {
        var result = rows
        let localKey = DeviceTag.key(localName)
        let groups = Dictionary(grouping: rows.indices, by: { DeviceTag.key(rows[$0].name) })
        for (key, indices) in groups {
            let clashesWithLocal = !localKey.isEmpty && key == localKey
            guard indices.count > 1 || clashesWithLocal else { continue }
            var models = indices.map { DeviceTag.shortModel(rows[$0].model) }
            if clashesWithLocal { models.append(DeviceTag.shortModel(localModel)) }
            if models.allSatisfy({ !$0.isEmpty }) && Set(models).count == models.count {
                for (n, index) in indices.enumerated() { result[index].tag = models[n] }
                continue
            }
            var length = 4
            while length < 20 && Set(indices.map { DeviceTag.code(rows[$0].id, length: length) }).count < indices.count { length += 2 }
            for index in indices { result[index].tag = DeviceTag.code(rows[index].id, length: length) }
        }
        return result
    }

    static func state(_ availability: PeerAvailability) -> DeviceRow.State {
        switch availability {
        case .connected: return .connected
        case .online: return .online
        case .busy: return .busy
        case .paused: return .paused
        case .asleep: return .asleep
        case .appClosed: return .appClosed
        case .unreachable, .unknown: return .offline
        }
    }
}

/// Row wording, in both languages.
extension DeviceRow {
    /// The name with its tag, for sentences and notifications.
    var label: String { DeviceTag.label(name, tag) }
    var roleLabel: String {
        switch mode {
        case .provider?: return tr("提供麦克风", "Shares its mic")
        case .borrower?: return tr("使用麦克风", "Uses a mic")
        case .paused?: return tr("已暂停", "Paused")
        case nil: return legacy ? tr("旧版 MicBridge", "Older MicBridge") : ""
        }
    }
    var stateLabel: String {
        switch state {
        case .connected: return micInUse ? tr("麦克风使用中", "Mic in use") : tr("已连接", "Connected")
        case .online: return tr("在线", "Online")
        case .busy:
            return mode == .borrower ? tr("正在使用其他 Mac 的麦克风", "Using another Mac’s mic") : tr("正在为其他 Mac 提供麦克风", "Sharing with another Mac")
        case .paused: return tr("已暂停", "Paused")
        case .asleep: return tr("睡眠", "Asleep")
        case .appClosed: return tr("未打开 MicBridge", "MicBridge not open")
        case .offline: return tr("离线", "Offline")
        case .pairing: return tr("正在配对…", "Pairing…")
        }
    }
    /// One line under the name: what it does and how it is doing.
    var detail: String {
        if needsPairing { return tr("需要重新配对", "Pair again to connect") }
        let parts = [state == .paused || state == .busy ? "" : roleLabel, stateLabel].filter { !$0.isEmpty }
        return parts.joined(separator: " · ")
    }
}
