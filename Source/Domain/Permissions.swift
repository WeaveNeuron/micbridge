import Foundation

/// What macOS has said about one permission.
enum Access: Equatable {
    case granted
    /// Never asked: the first request shows macOS's prompt.
    case notAsked
    /// Turned off in System Settings.
    case denied
    /// macOS doesn't tell (Local Network before anything has connected).
    case unknown
}

enum LoginItemState: Equatable { case on, off, needsApproval }

/// The raw facts the permission list is made from, read live while a
/// window shows them.
struct PermissionFacts: Equatable {
    var microphone = Access.unknown
    var localNetwork = Access.unknown
    var loginItem = LoginItemState.off
    var firewall = FirewallState.unknown
}

/// One row of the permission list (Settings › Permissions and onboarding).
struct PermissionItem: Equatable, Identifiable {
    enum Kind: String { case microphone, localNetwork, virtualMicrophone, firewall }
    enum State: Equatable {
        case ready
        /// Needed and not there yet; the action fixes it.
        case needed
        /// Turned off by the user; the action opens System Settings.
        case denied
        /// Not needed in this role (or not knowable yet): no badge.
        case optional
    }
    enum Action: Equatable {
        case requestMicrophone
        case openPrivacy(String)
        case installDriver
        case openFirewall
    }
    var kind: Kind
    var state: State
    var detail: String
    var action: Action?
    var actionTitle: String = ""
    var id: String { kind.rawValue }

    var title: String {
        switch kind {
        case .microphone: return tr("麦克风", "Microphone")
        case .localNetwork: return tr("本地网络", "Local Network")
        case .virtualMicrophone: return tr("虚拟麦克风", "Virtual Microphone")
        case .firewall: return tr("防火墙", "Firewall")
        }
    }
    var symbol: String {
        switch kind {
        case .microphone: return "mic.fill"
        case .localNetwork: return "network"
        case .virtualMicrophone: return "waveform"
        case .firewall: return "shield.lefthalf.filled"
        }
    }
    var stateLabel: String {
        switch state {
        case .ready where kind == .firewall: return tr("未拦截", "Not Blocking")
        case .ready: return tr("已就绪", "Ready")
        case .needed: return tr("需要", "Needed")
        case .denied: return tr("未允许", "Off")
        case .optional: return ""
        }
    }
}

enum PermissionList {
    static let microphonePane = "Privacy_Microphone"
    static let localNetworkPane = "Privacy_LocalNetwork"
    static func settingsURL(_ pane: String) -> URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }
    /// System Settings › Network. No link reaches the Firewall page itself
    /// (macOS 27 ignores the `Firewall` anchor), so the button says where
    /// to click next.
    static let firewallURL = URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension?Firewall")!
    static var firewallActionTitle: String { tr("打开网络设置 › 防火墙", "Network › Firewall") }

    /// The rows for this role, required ones first. Each says in one short
    /// sentence why it is needed and offers the one action that fixes it.
    static func items(role: Role, facts: PermissionFacts, driver: DriverStatus) -> [PermissionItem] {
        let provider = role == .provider
        var microphone = PermissionItem(kind: .microphone, state: .ready,
                                        detail: provider ? tr("只在另一台 Mac 收音时打开。", "On only while your other Mac is listening.")
                                                         : tr("提供麦克风时才需要。", "Needed only to share this Mac’s microphone."))
        switch facts.microphone {
        case .granted: microphone.state = .ready
        case .notAsked, .unknown:
            microphone.state = provider ? .needed : .optional
            microphone.action = .requestMicrophone; microphone.actionTitle = tr("允许…", "Allow…")
        case .denied:
            microphone.state = provider ? .denied : .optional
            if provider { microphone.detail = tr("已在系统设置中关闭。", "Turned off in System Settings.") }
            microphone.action = .openPrivacy(microphonePane); microphone.actionTitle = tr("打开系统设置", "Open System Settings")
        }

        var network = PermissionItem(kind: .localNetwork, state: .optional,
                                     detail: tr("两台 Mac 直接加密连接。", "Your Macs connect directly, encrypted."))
        switch facts.localNetwork {
        case .granted: network.state = .ready
        case .denied:
            network.state = .denied
            network.detail = tr("连接被 macOS 拦截。", "macOS is blocking the connection.")
            network.action = .openPrivacy(localNetworkPane); network.actionTitle = tr("打开系统设置", "Open System Settings")
        case .notAsked, .unknown:
            network.detail = tr("macOS 询问时选“允许”。", "Choose Allow when macOS asks.")
        }

        var virtual = PermissionItem(kind: .virtualMicrophone, state: .ready,
                                     detail: provider ? tr("用另一台 Mac 的麦克风时才需要。", "Needed only to use another Mac’s microphone.")
                                                      : tr("应用通过它听到另一台 Mac。", "Apps here hear the other Mac through it."))
        switch driver {
        case .ready: break
        case .bundleMissing:
            virtual.state = provider ? .optional : .needed
        case .notInstalled, .installedNotLoaded, .outdated:
            virtual.state = provider ? .optional : .needed
            virtual.action = .installDriver
            virtual.actionTitle = driver.installTitle
        }
        if !provider && driver != .ready { virtual.detail = driver.detail }
        // Last, never in onboarding, and only once it has been read: only a
        // blocking firewall needs a word.
        var firewall = PermissionItem(kind: .firewall, state: .ready, detail: "")
        if facts.firewall.blocksIncoming {
            firewall.state = .denied
            firewall.detail = tr("拦截了传入连接。", "Blocks incoming connections.")
            firewall.action = .openFirewall; firewall.actionTitle = firewallActionTitle
        }
        let last = facts.firewall == .unknown ? [] : [firewall]
        // What this role needs first, then the rest.
        return (provider ? [microphone, network, virtual] : [virtual, network, microphone]) + last
    }

    /// The rows onboarding asks about: only what this role needs.
    static func essentials(role: Role, facts: PermissionFacts, driver: DriverStatus) -> [PermissionItem] {
        Array(items(role: role, facts: facts, driver: driver).prefix(2))
    }

    /// Local Network can't be queried: blocked when the link says so,
    /// granted once anything was found or connected, else unknown.
    static func localNetwork(blocked: Bool, connected: Bool, foundNearby: Bool) -> Access {
        if blocked { return .denied }
        return connected || foundNearby ? .granted : .unknown
    }
}
