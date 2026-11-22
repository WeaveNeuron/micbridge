import Foundation

/// What this Mac does with microphones. Chosen by the user; never derived
/// from the machine's model or name.
///   provider — lends its microphone to another Mac
///   borrower — uses another Mac's microphone through a virtual microphone
enum Role: String, CaseIterable, Equatable {
    case provider, borrower

    static let defaultsKey = "mode"
    /// 0.6.0 stored an Int: 0 = the Mac that captured, 1 = the Mac that played.
    static let legacyDefaultsKey = "role"

    /// The saved choice, migrating 0.6.0's setting. Nil when never chosen.
    static func saved(in defaults: UserDefaults = .standard) -> Role? {
        if let raw = defaults.string(forKey: defaultsKey), let role = Role(rawValue: raw) { return role }
        if let legacy = defaults.object(forKey: legacyDefaultsKey) as? Int { return legacy == 1 ? .borrower : .provider }
        return nil
    }
    /// The 0.6.0 key is left in place so a downgrade keeps working.
    static func save(_ role: Role, in defaults: UserDefaults = .standard) {
        defaults.set(role.rawValue, forKey: defaultsKey)
    }
    /// A suggestion for first use only: a Mac without a built-in microphone
    /// usually wants to borrow one. The user can always switch.
    static func suggested(hasBuiltInMicrophone: Bool) -> Role { hasBuiltInMicrophone ? .provider : .borrower }

    var other: Role { self == .provider ? .borrower : .provider }
}
