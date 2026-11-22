import Cocoa

/// Process-level concerns only: single instance, sleep / wake / lock and
/// termination. Everything else is forwarded to `AppModel`.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var previewMode: Bool { Bundle.main.object(forInfoDictionaryKey: "MicBridgePreview") as? Bool == true }
    private(set) var model: AppModel!

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !previewMode, !claimInstance() { return }
        let model = AppModel(previewMode: previewMode)
        self.model = model
        model.launch()
        guard !previewMode else { return }
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(model, selector: #selector(AppModel.suspend), name: NSWorkspace.willSleepNotification, object: nil)
        nc.addObserver(model, selector: #selector(AppModel.suspend), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        nc.addObserver(model, selector: #selector(AppModel.resume), name: NSWorkspace.didWakeNotification, object: nil)
        nc.addObserver(model, selector: #selector(AppModel.resume), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        let dc = DistributedNotificationCenter.default()
        dc.addObserver(model, selector: #selector(AppModel.suspend), name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        dc.addObserver(model, selector: #selector(AppModel.resume), name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        model?.quit()
        // Give the goodbye to the linked Mac a moment to leave.
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { model?.showPanel(); return true }

    /// Keeps the newest process. Replacing an older copy uses a normal quit,
    /// so its capture and network cleanup run before this copy connects.
    private func claimInstance() -> Bool {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.weaveneuron.MicBridge")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        let launched = NSRunningApplication.current.launchDate ?? .distantPast
        if let existing = others.first(where: {
            let date = $0.launchDate ?? .distantPast
            return date > launched || (date == launched && $0.processIdentifier > ProcessInfo.processInfo.processIdentifier)
        }) {
            existing.activate(options: [.activateAllWindows]); NSApp.terminate(nil); return false
        }
        // Choose the newest process, not the on-disk bundle version (the file
        // may already have been replaced while an old process is still alive).
        others.forEach { _ = $0.terminate() }
        return true
    }
}
