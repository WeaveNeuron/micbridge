import Foundation
import IOKit
import SystemConfiguration

/// How this Mac presents itself to others: the system computer name and the
/// hardware model. Nothing here decides behaviour; it is only for display.
enum DeviceIdentity {
    static var computerName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? ProcessInfo.processInfo.hostName
    }
    static let customNameKey = "localDisplayName"
    /// A name chosen in MicBridge's settings, shown on every Mac instead of
    /// the computer name. Nil follows System Settings › General › Sharing.
    static var customName: String? {
        get {
            let value = UserDefaults.standard.string(forKey: customNameKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value : nil
        }
        set {
            let value = newValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let value, !value.isEmpty { UserDefaults.standard.set(String(value.prefix(40)), forKey: customNameKey) }
            else { UserDefaults.standard.removeObject(forKey: customNameKey) }
        }
    }
    /// What this Mac calls itself on the network and in its own panel.
    static var localName: String { customName ?? computerName }
    /// Marketing name on Apple silicon ("MacBook Pro (14-inch, 2021)"),
    /// otherwise the model identifier ("MacBookPro16,1", "Mac14,13").
    static let model: String = productName() ?? hardwareModel() ?? ""

    private static func productName() -> String? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        guard let value = IORegistryEntryCreateCFProperty(entry, "product-name" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Data else { return nil }
        let text = String(decoding: value.prefix { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }
    private static func hardwareModel() -> String? {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return nil }
        return String(cString: bytes)
    }
}

/// The kind of Mac, for choosing an icon. Unknown models fall back to a
/// generic desktop; nothing depends on this being exact.
enum DeviceKind: Equatable {
    case laptop, studio, mini, imac, pro, generic

    init(model: String) {
        let m = model.lowercased()
        if m.contains("macbook") { self = .laptop }
        else if m.contains("studio") { self = .studio }
        else if m.contains("mini") { self = .mini }
        else if m.contains("imac") { self = .imac }
        else if m.hasPrefix("mac pro") || m.hasPrefix("macpro") { self = .pro }
        else { self = .generic }
    }
}

/// Readable fallback name from a Bonjour host ("Studio-2.local" → "Studio 2").
func displayName(fromHost host: String) -> String? {
    var name = host
    if name.hasSuffix(".local") { name.removeLast(6) }
    if name.hasSuffix(".") { name.removeLast() }
    name = name.replacingOccurrences(of: "-", with: " ").trimmingCharacters(in: .whitespaces)
    return name.isEmpty || name.allSatisfy({ $0.isNumber || $0 == "." || $0 == ":" }) ? nil : name
}
