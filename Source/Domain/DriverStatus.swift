import Foundation

/// The MicBridge Microphone driver's own version, separate from the app's:
/// raise it only when Driver/ changes, so an app update never asks for a
/// driver reinstall (and an administrator password) it doesn't need.
/// build.sh reads it from here.
let bundledDriverVersion = "1.0.0"

/// What is known about the MicBridge Microphone driver on this Mac.
struct DriverFacts: Equatable {
    /// The driver inside this app (nil: built without it).
    var embeddedVersion: String?
    /// The driver in /Library/Audio/Plug-Ins/HAL (nil: not installed).
    var installedVersion: String?
    /// Core Audio lists the MicBridge Microphone device.
    var deviceLoaded: Bool
}

/// The driver's state, as the onboarding, the panel and Settings show it.
enum DriverStatus: Equatable {
    /// Running and current.
    case ready
    /// Not installed (the app can install it).
    case notInstalled
    /// Installed, but Core Audio has not loaded it: the audio service
    /// needs a restart (reinstalling does that).
    case installedNotLoaded
    /// Installed, older than the one in this app.
    case outdated(installed: String)
    /// Not installed, and this app has no driver to install.
    case bundleMissing

    /// Every state, for tests and previews.
    static let allCases: [DriverStatus] = [.ready, .notInstalled, .installedNotLoaded, .outdated(installed: "80000"), .bundleMissing]

    static func derive(_ f: DriverFacts) -> DriverStatus {
        guard let installed = f.installedVersion else {
            if f.deviceLoaded { return .ready }
            return f.embeddedVersion == nil ? .bundleMissing : .notInstalled
        }
        if let embedded = f.embeddedVersion, installed.compare(embedded, options: .numeric) == .orderedAscending {
            return .outdated(installed: installed)
        }
        return f.deviceLoaded ? .ready : .installedNotLoaded
    }

    var isUpdate: Bool { if case .outdated = self { return true }; return false }
    /// The app can install (or reinstall) its driver from here.
    var canInstall: Bool { self != .bundleMissing && self != .ready }
    var isInstalled: Bool {
        switch self {
        case .ready, .installedNotLoaded, .outdated: return true
        case .notInstalled, .bundleMissing: return false
        }
    }
}

/// Driver wording, in both languages.
extension DriverStatus {
    var isOutdated: Bool { if case .outdated = self { return true } else { return false } }
    /// The button that installs, updates or reloads it.
    var installTitle: String {
        switch self {
        case .outdated: return tr("更新驱动…", "Update Driver…")
        case .installedNotLoaded: return tr("重新加载驱动…", "Reload Driver…")
        default: return tr("安装驱动…", "Install Driver…")
        }
    }
    /// Shared by the panel, Settings and the welcome window.
    var title: String {
        switch self {
        case .ready: return tr("驱动已就绪", "Driver ready")
        case .notInstalled: return tr("需要安装驱动", "Driver installation needed")
        case .outdated: return tr("建议更新驱动", "Driver update recommended")
        case .installedNotLoaded: return tr("需要加载驱动", "Driver reload needed")
        case .bundleMissing: return tr("未附带驱动", "Driver not included")
        }
    }
    /// While Use waits for the driver. An older driver only waits when it
    /// is not loaded, so it can't say "still works" there.
    var waitingTitle: String { isOutdated ? tr("需要更新驱动", "Driver update needed") : title }
    var waitingDetail: String { isOutdated ? tr("驱动版本较旧且未加载，更新后自动继续。", "The older driver isn't loaded; resumes after updating.") : detail }
    var detail: String {
        switch self {
        case .ready: return tr("虚拟麦克风已就绪。", "The virtual microphone is ready.")
        case .notInstalled: return tr("尚未安装驱动，安装后自动继续。", "Not installed; resumes after installation.")
        case .outdated: return tr("驱动版本较旧，仍可使用，建议更新。", "The driver is older but still works; updating is recommended.")
        case .installedNotLoaded: return tr("已安装但未加载，重新加载后继续。", "Installed but not loaded; reload to continue.")
        case .bundleMissing: return tr("此版本未附带驱动，请重新下载。", "This copy has no driver; download MicBridge again.")
        }
    }
    func label(version: String) -> String {
        switch self {
        case .ready: return version.isEmpty ? tr("已安装", "Installed") : tr("已安装 \(version)", "Installed (\(version))")
        case .notInstalled: return tr("未安装", "Not installed")
        case .installedNotLoaded: return tr("已安装，尚未加载", "Installed, not loaded yet")
        case .outdated: return tr("有新版本（已安装 \(version)）", "Update available (\(version) installed)")
        case .bundleMissing: return tr("这个版本没有附带驱动", "Not included in this copy")
        }
    }
}
