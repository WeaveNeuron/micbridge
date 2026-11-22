import Cocoa

/// The MicBridge Microphone driver: when to offer it, the confirmation and
/// what happens after. Installing always asks first, here and then in
/// macOS's administrator prompt; nothing is installed on its own.
extension AppModel {
    func wireDriver() {
        driverInstaller.confirm = { [weak self] action, status in self?.confirmDriver(action, status) ?? false }
        guard !previewMode else { return }
        deviceWatcher.start { [weak self] in self?.audioDevicesChanged() }
    }

    /// A driver came or went, or another device did.
    func audioDevicesChanged() {
        let before = driverFacts
        refreshDevices { [weak self] in
            guard let self else { return }
            // Re-check all driver requirements without changing the on intent.
            if self.waitingForDriver {
                self.continueStartup(epoch: self.connectionGeneration)
            }
            if before != self.driverFacts { self.syncUI(force: true) }
        }
    }

    func runDriverAction(_ action: DriverAction) {
        refreshDevices { [weak self] in self?.performDriverAction(action) }
    }
    private func performDriverAction(_ action: DriverAction) {
        let status = DriverStatus.derive(driverFacts)
        driverInstaller.perform(action, status: status) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .declined, .cancelled: break
            case .failed(let message):
                self.ui.notify(action == .install ? tr("没有装好驱动：\(message)", "The driver wasn’t installed: \(message)")
                                                  : tr("没有卸载驱动：\(message)", "The driver wasn’t removed: \(message)"))
            case .done:
                self.ui.notify(action == .install ? tr("已安装 MicBridge Microphone", "MicBridge Microphone installed")
                                                  : tr("已卸载 MicBridge Microphone", "MicBridge Microphone removed"))
                self.settleAfterDriverChange(expectLoaded: action == .install)
            }
            self.syncUI(force: true)
        }
        syncUI(force: true)
    }

    /// The audio service restarts after the script: wait (up to ~10 s) for
    /// the device to appear or go, then pick devices again.
    func settleAfterDriverChange(expectLoaded: Bool, attempt: Int = 0) {
        refreshDevices { [weak self] in self?.settledDevices(expectLoaded: expectLoaded, attempt: attempt) }
    }
    private func settledDevices(expectLoaded: Bool, attempt: Int) {
        if driverFacts.deviceLoaded != expectLoaded && attempt < 20 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.settleAfterDriverChange(expectLoaded: expectLoaded, attempt: attempt + 1) }
            return
        }
        // Core Audio restarted under a running bridge: start it over.
        if enabled && !suspended { restart() }
        syncUI(force: true)
    }

    /// What will happen, before anything does. True to go ahead.
    func confirmDriver(_ action: DriverAction, _ status: DriverStatus) -> Bool {
        let alert = NSAlert()
        switch action {
        case .install:
            switch status {
            case .outdated: alert.messageText = tr("更新 MicBridge Microphone？", "Update MicBridge Microphone?")
            case .installedNotLoaded: alert.messageText = tr("重新加载 MicBridge Microphone？", "Reload MicBridge Microphone?")
            default: alert.messageText = tr("安装 MicBridge Microphone？", "Install MicBridge Microphone?")
            }
            alert.informativeText = tr("需要管理员密码，安装时本机声音会中断几秒。",
                                       "Needs an administrator password, and sound pauses for a few seconds.")
            alert.addButton(withTitle: status.installTitle)
        case .uninstall:
            alert.messageText = tr("卸载 MicBridge Microphone？", "Remove MicBridge Microphone?")
            alert.informativeText = tr("需要管理员密码；卸载后，本机不能再使用另一台 Mac 的麦克风。",
                                       "Needs an administrator password; afterwards this Mac can’t use another Mac’s microphone.")
            alert.alertStyle = .warning
            alert.addButton(withTitle: tr("卸载…", "Remove…")).hasDestructiveAction = true
        }
        alert.addButton(withTitle: tr("取消", "Cancel"))
        return runAlert(alert)
    }
}

/// "90000" → "0.9.0" (build numbers as build.sh makes them).
func versionName(_ build: String) -> String {
    guard let n = Int(build) else { return build }
    let parts = [n / 1_000_000, n / 10_000 % 100, n / 100 % 100, n % 100]
    return parts[3] == 0 ? parts[0..<3].map(String.init).joined(separator: ".") : parts.map(String.init).joined(separator: ".")
}
