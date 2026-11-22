import Foundation

/// Values the wording depends on besides the status itself.
struct CopyContext: Equatable {
    var role: Role
    /// The other Mac's display name (or the Mac asking to pair).
    var peer: String
    /// The app recording on the borrower, if known.
    var client = ""
    /// Borrower: name of the virtual microphone in use.
    var device = ""
    /// Borrower: the virtual microphone is the system default input.
    var defaultInput = true
    /// Borrower: an app is recording but no provider is connected.
    var waiting = false
    var driver = DriverStatus.notInstalled
}

/// All user-facing status wording, in both languages. Roles are generic:
/// never a machine model.
enum StatusCopy {
    static func title(_ status: BridgeStatus, _ c: CopyContext) -> String {
        let p = c.peer, provider = c.role == .provider
        switch status {
        case .sleeping: return tr("已休眠", "Asleep")
        // One sentence; the code and Decline / Allow sit right under it.
        case .incomingPairing(let peer, _): return tr("两边代码一致，就允许\(peer)配对", "Allow \(peer) if the codes match")
        case .setup(.noVirtualMicrophone): return c.driver.waitingTitle
        case .setup(let issue): return setupTitle(issue)
        case .problem: return tr("需要处理", "Needs attention")
        case .paused: return tr("已暂停", "Paused")
        case .settingUp: return tr("先完成设置", "Finish setting up")
        case .waitingForKeychain: return tr("等待钥匙串授权", "Waiting for keychain access")
        case .pairing: return p.isEmpty ? tr("正在配对", "Pairing") : tr("与\(p)配对", "Pairing with \(p)")
        case .inUse(.activating):
            return provider ? tr("正在打开麦克风", "Turning on the microphone") : tr("正在打开\(p)的麦克风", "Turning on \(p)’s microphone")
        case .inUse(.live):
            return provider ? tr("正在为\(p)提供麦克风", "Sharing with \(p)") : tr("正在使用\(p)的麦克风", "Using \(p)’s microphone")
        case .inUse(.finishing): return tr("正在关闭麦克风", "Turning off the microphone")
        case .ready: return provider ? tr("已连接\(p)", "Connected to \(p)") : tr("已连接\(p)的麦克风", "Connected to \(p)’s microphone")
        case .noPairedDevices: return tr("还没有配对的 Mac", "No paired Macs yet")
        case .localNetworkBlocked: return tr("连接被系统拦截", "Blocked by macOS")
        case .peerBusy: return tr("\(p)正忙", "\(p) is busy")
        case .roleConflict:
            return provider ? tr("\(p)也在提供麦克风", "\(p) is sharing too") : tr("\(p)没有在提供麦克风", "\(p) isn’t sharing its microphone")
        case .peerPaused: return tr("\(p)已暂停", "\(p) is paused")
        case .peerAsleep: return tr("\(p)在睡眠", "\(p) is asleep")
        case .peerAppClosed: return tr("\(p)上未打开 MicBridge", "MicBridge isn’t open on \(p)")
        case .connecting: return tr("正在连接\(p)", "Connecting to \(p)")
        case .searching: return provider ? tr("正在寻找\(p)", "Looking for \(p)") : tr("等待\(p)", "Waiting for \(p)")
        }
    }

    static func subtitle(_ status: BridgeStatus, _ c: CopyContext) -> String {
        let p = c.peer, provider = c.role == .provider
        let zhApp = appLead(c.client), enApp = appName(c.client)
        switch status {
        case .sleeping: return tr("唤醒并解锁后自动恢复。", "Resumes when this Mac wakes and unlocks.")
        case .incomingPairing: return ""
        case .setup(.noVirtualMicrophone): return c.driver.waitingDetail
        case .setup(let issue): return setupMessage(issue)
        case .problem(let message): return message
        case .paused: return ""
        case .settingUp: return tr("在欢迎窗口里选择这台 Mac 的用途。", "Choose what this Mac does in the welcome window.")
        case .waitingForKeychain:
            return tr("请在 macOS 的提示中输入登录密码，并点“始终允许”。", "Enter your login password and click Always Allow when macOS asks.")
        case .pairing(let code, let message):
            if !code.isEmpty { return tr("在\(p)上点“允许”。", "Click Allow on \(p).") }
            return message.isEmpty ? tr("正在寻找附近的 Mac…", "Looking for nearby Macs…") : message
        case .inUse(.activating):
            return provider ? tr("\(p)上的应用开始收音…", "An app on \(p) started listening…") : tr("\(zhApp)开始收音…", "\(enApp) started listening…")
        case .inUse(.live):
            return provider ? tr("收音结束后自动关闭。", "Turns off when the recording ends.")
                            : tr("\(zhApp)正在收音。", "\(enApp) is listening.")
        case .inUse(.finishing):
            return provider ? tr("正在结束本次收音…", "Finishing the recording…") : tr("正在确认\(p)的麦克风已关闭…", "Making sure \(p)’s microphone is off…")
        case .ready:
            if provider { return tr("\(p)需要时，自动打开麦克风。", "Turns on when \(p) needs it.") }
            if c.defaultInput { return tr("所有应用都会用\(p)的麦克风。", "Every app here uses \(p)’s microphone.") }
            return tr("在应用里选择“\(c.device)”。", "Choose “\(c.device)” in your app.")
        case .noPairedDevices:
            return tr("在另一台 Mac 上打开 MicBridge，再在下面添加。", "Open MicBridge on your other Mac, then add it below.")
        case .localNetworkBlocked:
            return tr("在系统设置中允许“本地网络”。", "Allow Local Network in System Settings.")
        case .peerBusy:
            return provider ? tr("\(p)在使用另一台 Mac 的麦克风，结束后重试。", "\(p) is using another Mac’s microphone; retrying after.")
                            : tr("\(p)在给另一台 Mac 提供麦克风，结束后连接。", "\(p) is sharing with another Mac; connecting after.")
        case .roleConflict:
            return provider ? tr("请把其中一台改为“使用”。", "Switch one of them to Use.")
                            : tr("请把\(p)改为“提供”，或在本机提供麦克风。", "Switch \(p) to Share, or share from this Mac.")
        case .peerPaused: return tr("在\(p)上开启 MicBridge 后自动连接。", "Connects when \(p) turns MicBridge back on.")
        case .peerAsleep: return tr("\(p)唤醒后自动连接。", "Connects when \(p) wakes up.")
        case .peerAppClosed: return tr("在\(p)上打开 MicBridge 后自动连接。", "Connects once MicBridge is open on \(p).")
        case .connecting: return tr("正在恢复连接…", "Reconnecting…")
        case .searching(let longWait):
            if !provider {
                return c.waiting ? tr("\(zhApp)在等待麦克风，请唤醒\(p)。", "\(enApp) is waiting for \(p) to wake up.")
                                 : tr("\(p)醒着并开启 MicBridge 时自动连接。", "Connects when \(p) is awake with MicBridge on.")
            }
            return longWait ? tr("请确认\(p)已唤醒，且 MicBridge 已开启。", "Make sure \(p) is awake with MicBridge on.")
                            : tr("请确认\(p)上的 MicBridge 已开启。", "Make sure MicBridge is running on \(p).")
        }
    }

    /// The microphone line. Never claims to know the other Mac's microphone
    /// state while disconnected.
    static func micCaption(role: Role, peer: String, enabled: Bool, connected: Bool, micActive: Bool) -> String {
        switch role {
        case .borrower:
            if micActive { return tr("\(peer)的麦克风使用中", "\(peer)’s microphone is on") }
            if !connected { return enabled ? tr("未连接 · 本机不收音", "Not connected · Not listening") : tr("已暂停 · 本机不收音", "Paused · Not listening") }
            return tr("\(peer)的麦克风已关闭", "\(peer)’s microphone is off")
        case .provider:
            return micActive ? tr("麦克风使用中 · \(peer)", "Microphone on · \(peer)") : tr("本机麦克风已关闭", "This microphone is off")
        }
    }

    static func setupTitle(_ issue: SetupIssue) -> String {
        switch issue {
        case .microphoneDenied: return tr("需要麦克风权限", "Microphone access needed")
        case .noMicrophone: return tr("没有可用的麦克风", "No microphone available")
        case .noVirtualMicrophone: return tr("需要安装虚拟麦克风", "A virtual microphone is needed")
        case .virtualMicrophoneTimeout: return tr("虚拟麦克风没有响应", "The virtual microphone isn’t responding")
        }
    }
    static func setupMessage(_ issue: SetupIssue) -> String {
        switch issue {
        case .microphoneDenied: return tr("在系统设置中允许使用麦克风。", "Allow the microphone in System Settings.")
        case .noMicrophone: return tr("请接入麦克风，或改为使用另一台 Mac 的麦克风。", "Connect a microphone, or use another Mac’s instead.")
        case .noVirtualMicrophone: return tr("安装 MicBridge Microphone 即可使用。", "Install MicBridge Microphone to continue.")
        case .virtualMicrophoneTimeout: return tr("请退出 MicBridge 后重新打开。", "Quit MicBridge and open it again.")
        }
    }
    static func describe(_ reason: StopReason) -> String {
        switch reason {
        case .setup(let issue): return setupMessage(issue)
        case .problem(let text): return text
        }
    }
}
