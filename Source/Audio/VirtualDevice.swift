import Foundation

/// The MicBridge Microphone device, the only virtual microphone MicBridge
/// writes into. Any other device is never written to.
enum VirtualDevice {
    static let uid = "MicBridgeMicrophone_UID"
    static func find(_ devices: [AudioDevice]) -> AudioDevice? { devices.first { $0.uid == uid } }
}

/// Where the driver lives: inside the app (Contents/PlugIns, built by
/// build.sh) and, once the user installs it, in the system's HAL plug-in
/// folder.
enum DriverBundle {
    static let name = "MicBridgeMicrophone.driver"
    static let installDirectory = URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL")
    static var installed: URL { installDirectory.appendingPathComponent(name) }
    static var embedded: URL? { Bundle.main.builtInPlugInsURL?.appendingPathComponent(name) }
    static func executable(in bundle: URL) -> URL { bundle.appendingPathComponent("Contents/MacOS/MicBridgeMicrophone") }

    /// CFBundleVersion of a driver bundle, nil if it is not there. Reading
    /// the installed one needs no privileges.
    static func version(at bundle: URL?) -> String? {
        guard let bundle else { return nil }
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return info["CFBundleVersion"] as? String
    }
    /// What is true right now, for `DriverStatus.derive`.
    static func facts(devices: [AudioDevice] = Devices.all()) -> DriverFacts {
        DriverFacts(embeddedVersion: version(at: embedded), installedVersion: version(at: installed),
                    deviceLoaded: VirtualDevice.find(devices) != nil)
    }
}
