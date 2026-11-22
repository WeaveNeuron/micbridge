import SwiftUI

let bridgeVersion = "1.0.1"

extension BridgeStatus {
    /// Live: green. Needs the user: orange. On its way: accent. Else grey.
    var tint: Color {
        if isLive { return Palette.live }
        if needsAttention { return .orange }
        if isWaiting { return .accentColor }
        return .secondary
    }
    var pairingCode: String {
        switch self {
        case .incomingPairing(_, let code), .pairing(let code, _): return code
        default: return ""
        }
    }
    var symbol: String? {
        switch self {
        case .setup, .problem, .localNetworkBlocked: return "exclamationmark.triangle.fill"
        case .waitingForKeychain: return "key.fill"
        case .roleConflict: return "arrow.left.arrow.right"
        case .sleeping: return "moon.zzz.fill"
        case .paused: return "pause.circle.fill"
        case .settingUp: return "checklist"
        default: return nil
        }
    }
}

enum Palette {
    static let live = Color(red: 0.16, green: 0.66, blue: 0.42)
}

extension DeviceKind {
    var symbol: String {
        switch self {
        case .laptop: return "laptopcomputer"
        case .studio: return "macstudio"
        case .mini: return "macmini"
        case .imac, .generic: return "desktopcomputer"
        case .pro: return "macpro.gen3"
        }
    }
}

/// Everything the panel shows, as plain values.
struct PanelSnapshot: Equatable {
    var status: BridgeStatus = .paused
    var role: Role = .borrower
    var enabled = false
    var connected = false
    var micActive = false
    var level = 0.0
    var localName = ""
    var localModel = ""
    /// The Mac the status talks about.
    var peerName = PairedDevice.fallbackName
    var peerModel = ""
    /// This Mac asked another to pair (shows Cancel, not Allow).
    var pairingOutgoing = false
    var mine: [DeviceRow] = []
    var nearby: [DeviceRow] = []
    /// Nearby services were looked for (the browser runs).
    var browsing = true
    var device = ""
    var deviceUID = ""
    var peerVersion = ""
    var route = ""
    var client = ""
    var waiting = false
    var defaultInput = true
    /// Microphone, Local Network and login item, read live.
    var permissions = PermissionFacts()
    var customName = ""
    var computerName = ""
    /// This Mac's short device code, as other Macs show it next to a
    /// name they share with another Mac.
    var localCode = ""
    /// The MicBridge Microphone driver on this Mac.
    var driver = DriverStatus.notInstalled
    /// Installed driver version ("1.0.0"), empty if none.
    var driverVersion = ""
    /// The installer is waiting for the administrator prompt.
    var installing = false
    /// Using another Mac's microphone can work right now.
    var hasVirtualMicrophone: Bool { driver == .ready }
    /// The borrower can fix its driver even before turning the bridge on.
    var offersDriverInstall: Bool { role == .borrower && driver.canInstall }
    /// The status card already explains it while startup waits; otherwise
    /// keep a separate notice visible, including while deliberately paused.
    var showsDriverNotice: Bool { role == .borrower && driver != .ready && status != .setup(.noVirtualMicrophone) }
    var driverPermission: PermissionItem? { permissionItems.first { $0.kind == .virtualMicrophone } }
    var preview = false

    var permissionItems: [PermissionItem] {
        PermissionList.items(role: role, facts: permissions, driver: driver)
    }
    var mode: PeerMode { enabled ? (role == .provider ? .provider : .borrower) : .paused }
    /// Paused: the panel says only that, and everything below it fades.
    /// Not while setting up: nothing has been turned off.
    var paused: Bool { !enabled && status != .settingUp }
    /// The on/off switch: hidden until the welcome window is done, since
    /// there is nothing to pause yet.
    var showsSwitch: Bool { status != .settingUp }
    /// A pairing is being answered on the status card (asked by this Mac or
    /// by another): the one place for it, so the list offers nothing else.
    var pairingOnCard: Bool {
        switch status {
        case .incomingPairing: return true
        case .pairing: return pairingOutgoing
        default: return false
        }
    }
    /// Nearby Macs only while on, and while there is something to say.
    var showsNearby: Bool { enabled && (mine.isEmpty || !nearby.isEmpty) }
    /// A one-line warning under the status, only while the firewall blocks
    /// incoming connections and MicBridge is on.
    var showsFirewallNotice: Bool { enabled && permissions.firewall.blocksIncoming }
    var context: CopyContext {
        CopyContext(role: role, peer: peerName, client: client, device: device, defaultInput: defaultInput, waiting: waiting, driver: driver)
    }
    var title: String { StatusCopy.title(status, context) }
    var subtitle: String { StatusCopy.subtitle(status, context) }
    var micCaption: String { StatusCopy.micCaption(role: role, peer: peerName, enabled: enabled, connected: connected, micActive: micActive) }
    var formattedCode: String {
        let code = status.pairingCode
        return code.count == 6 ? "\(code.prefix(3)) \(code.suffix(3))" : code
    }
    var incomingPairing: Bool { if case .incomingPairing = status { return true }; return false }
    /// The hero shows a peer only once there is one to talk about.
    var showsPeer: Bool {
        switch status {
        case .noPairedDevices, .setup, .problem, .waitingForKeychain, .settingUp: return false
        case .paused, .sleeping: return !mine.isEmpty
        default: return true
        }
    }
}

struct DeviceChoice: Identifiable, Equatable {
    var id: String
    var name: String
}

/// The bridge between AppModel and the SwiftUI views: published values and
/// the actions they may take.
final class BridgeUIModel: ObservableObject {
    @Published var snapshot = PanelSnapshot()
    /// False while no window shows it: animations pause.
    @Published var onScreen = true
    @Published var audioDevices: [DeviceChoice] = []
    @Published var toast = ""
    /// The onboarding step on screen (0-based).
    @Published var onboardingStep = 0
    /// The role picked in onboarding (nil: the suggested one).
    @Published var onboardingRole: Role?
    var setMode: (PeerMode) -> Void = { _ in }
    var retry: () -> Void = {}
    var approve: () -> Void = {}
    var reject: () -> Void = {}
    var cancelPairing: () -> Void = {}
    var pair: (String) -> Void = { _ in }
    var useProvider: (String) -> Void = { _ in }
    var rename: (String) -> Void = { _ in }
    var forget: (String) -> Void = { _ in }
    var selectDevice: (String) -> Void = { _ in }
    var refreshDevices: () -> Void = {}
    var pairManually: (String) -> Void = { _ in }
    var copyPairing: () -> Void = {}
    var copyDiagnostics: () -> Void = {}
    var makeDefaultInput: () -> Void = {}
    var setLaunchAtLogin: (Bool) -> Void = { _ in }
    var setLocalName: (String?) -> Void = { _ in }
    /// Opens a Privacy & Security pane ("Privacy_Microphone").
    var openPrivacy: (String) -> Void = { _ in }
    var openLoginItems: () -> Void = {}
    /// Opens System Settings › Network › Firewall (read-only for MicBridge).
    var openFirewall: () -> Void = {}
    var openSettings: (SettingsTab?) -> Void = { _ in }
    var quit: () -> Void = {}
    var finishOnboarding: (Bool) -> Void = { _ in }
    var requestMicrophone: (@escaping (Bool) -> Void) -> Void = { $0(false) }
    var previewScenario: (Int) -> Void = { _ in }
    var installDriver: () -> Void = {}
    var uninstallDriver: () -> Void = {}
    var previewIndex = 0
    func perform(_ action: PermissionItem.Action) {
        switch action {
        case .requestMicrophone: requestMicrophone { _ in }
        case .openPrivacy(let pane): openPrivacy(pane)
        case .installDriver: installDriver()
        case .openFirewall: openFirewall()
        }
    }
    func notify(_ text: String) {
        toast = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
            if self?.toast == text { self?.toast = "" }
        }
    }
}
