import Foundation

/// A Mac this one is paired with. Keys stay in the keychain (`KeyVault`,
/// keyed by the same `id`); this holds only names, addresses and hints.
struct PairedDevice: Codable, Equatable, Identifiable {
    /// `DeviceKey.id` of its device key, or a placeholder for a Mac migrated
    /// from 0.7.0 whose key is not known yet.
    var id: String
    /// Its own name (the computer name in its System Settings › Sharing), as
    /// it reported it: TXT record, handshake or pairing card.
    var name: String?
    /// A local rename; shown instead of `name` on this Mac only.
    var alias: String?
    var model: String?
    /// Where it listens (.local host).
    var host: String?
    /// Its wired IPv4 addresses, tried first.
    var wiredHosts: [String] = []
    /// The last mode it reported.
    var mode: PeerMode?
    var lastConnected: Date?
    /// It holds this Mac's device key, so it can dial here.
    var hasOurKey = false

    /// A provider that dialed in before 0.7.1 (no device ID on the wire).
    static let legacyProviderID = "legacy-provider"
    /// The borrower a 0.7.0 provider dialed, until its key is read.
    static let legacyBorrowerID = "legacy-borrower"
    var isPlaceholder: Bool { id == Self.legacyProviderID || id == Self.legacyBorrowerID }

    static let fallbackName = "另一台 Mac"
    /// Alias, then its own name. The .local host name is only a last resort
    /// for a Mac that never reported a name (0.6.0): it often differs from
    /// the computer name ("studio-2.local" vs "Studio").
    var displayName: String {
        for candidate in [alias, name, host.flatMap(displayName(fromHost:))] {
            if let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty { return value }
        }
        return Self.fallbackName
    }
}

/// The paired Macs, most recently connected first.
final class PeerStore {
    static let storeKey = "pairedDevices.v8"
    /// 0.7.0 keys (one record per role) and 0.6.0 keys, read once for
    /// migration and left in place so a downgrade still works.
    static func legacyRecordKey(_ role: Role) -> String { "peer.\(role.rawValue).v7" }
    static let legacyHostKey = "studioHostV2", legacyWiredKey = "studioWiredHosts"

    private let defaults: UserDefaults
    private(set) var devices: [PairedDevice] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storeKey), let saved = try? JSONDecoder().decode([PairedDevice].self, from: data) {
            devices = saved
        } else {
            devices = Self.migrated(from: defaults)
            if !devices.isEmpty { save() }
        }
    }

    func device(_ id: String) -> PairedDevice? { devices.first { $0.id == id } }
    var isEmpty: Bool { devices.isEmpty }

    /// Inserts or changes a device.
    func update(_ id: String, _ change: (inout PairedDevice) -> Void) {
        var device = self.device(id) ?? PairedDevice(id: id)
        let before = device
        change(&device)
        guard device != before || self.device(id) == nil else { return }
        if let index = devices.firstIndex(where: { $0.id == id }) { devices[index] = device } else { devices.append(device) }
        sort(); save()
    }
    /// A placeholder learned its real ID: keep what the user set (alias) and
    /// what is known, preferring the real record's fresher values.
    func merge(_ placeholder: String, into id: String) {
        guard placeholder != id, let old = device(placeholder) else { return }
        devices.removeAll { $0.id == placeholder }
        update(id) { d in
            d.name = d.name ?? old.name; d.alias = d.alias ?? old.alias; d.model = d.model ?? old.model
            d.host = d.host ?? old.host
            if d.wiredHosts.isEmpty { d.wiredHosts = old.wiredHosts }
            d.mode = d.mode ?? old.mode; d.lastConnected = d.lastConnected ?? old.lastConnected
            d.hasOurKey = d.hasOurKey || old.hasOurKey
        }
    }
    func remove(_ id: String) { devices.removeAll { $0.id == id }; save() }

    /// After the keychain bundle loads: the migrated 0.7.0 borrower takes the
    /// ID of the one key no record claims yet.
    func reconcile(keyIDs: Set<String>) {
        guard device(PairedDevice.legacyBorrowerID) != nil else { return }
        let unclaimed = keyIDs.subtracting(devices.map(\.id))
        if unclaimed.count == 1, let id = unclaimed.first { merge(PairedDevice.legacyBorrowerID, into: id) }
    }

    /// Which record a link that just came up belongs to, merging a 0.7.0
    /// placeholder once the Mac reports its device ID.
    func recordID(for hello: PeerHello, dialed target: String?) -> String {
        // Dialed with its key: it is the target, whatever it reports.
        if let target { return target }
        guard let id = hello.device else { return PairedDevice.legacyProviderID }
        if device(id) == nil, device(PairedDevice.legacyProviderID) != nil, hello.mode != .borrower {
            merge(PairedDevice.legacyProviderID, into: id)
        }
        return id
    }
    /// Records what a Mac said in the handshake.
    func noteLink(_ id: String, hello: PeerHello, theyDialed: Bool, localRole: Role, at date: Date = Date()) {
        update(id) { d in
            if let name = hello.name, !name.isEmpty { d.name = name }
            if let model = hello.model, !model.isEmpty { d.model = model }
            if let hosts = hello.hosts { d.wiredHosts = hosts }
            d.mode = hello.mode?.role.map { PeerMode(role: $0, enabled: true) } ?? (localRole == .provider ? .borrower : .provider)
            d.lastConnected = date
            // It dialed with this Mac's key.
            if theyDialed { d.hasOurKey = true }
        }
    }

    private func sort() {
        devices.sort { ($0.lastConnected ?? .distantPast) > ($1.lastConnected ?? .distantPast) }
    }
    private func save() {
        if let data = try? JSONEncoder().encode(devices) { defaults.set(data, forKey: Self.storeKey) }
    }

    private struct LegacyRecord: Codable {
        var name: String?, alias: String?, model: String?, host: String?
        var wiredHosts: [String]?
    }
    private static func migrated(from defaults: UserDefaults) -> [PairedDevice] {
        func record(_ role: Role) -> LegacyRecord? {
            defaults.data(forKey: legacyRecordKey(role)).flatMap { try? JSONDecoder().decode(LegacyRecord.self, from: $0) }
        }
        var result: [PairedDevice] = []
        // This Mac dialed a borrower (0.7.0 provider, or 0.6.0's saved host).
        let dialed = record(.provider) ?? defaults.string(forKey: legacyHostKey).map {
            LegacyRecord(host: $0, wiredHosts: defaults.stringArray(forKey: legacyWiredKey))
        }
        if let r = dialed, r.host != nil {
            result.append(PairedDevice(id: PairedDevice.legacyBorrowerID, name: r.name, alias: r.alias, model: r.model,
                                       host: r.host, wiredHosts: r.wiredHosts ?? [], mode: .borrower))
        }
        // A provider dialed this Mac (0.7.0 borrower).
        if let r = record(.borrower), r.name != nil || r.alias != nil {
            result.append(PairedDevice(id: PairedDevice.legacyProviderID, name: r.name, alias: r.alias, model: r.model,
                                       wiredHosts: r.wiredHosts ?? [], mode: .provider, hasOurKey: true))
        }
        return result
    }
}
