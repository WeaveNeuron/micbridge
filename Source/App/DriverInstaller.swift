import Foundation

enum DriverAction: Equatable { case install, uninstall }

enum DriverInstallOutcome: Equatable {
    /// The user said no in MicBridge's own confirmation; nothing ran.
    case declined
    /// The user cancelled macOS's administrator prompt.
    case cancelled
    case done
    case failed(String)
}

/// Installs or removes the MicBridge Microphone driver, always in this
/// order: MicBridge explains what will happen and the user confirms; only
/// then is the bundled script run through macOS's administrator prompt,
/// where the user types the password. Nothing is ever run without both.
final class DriverInstaller {
    typealias Runner = (_ appleScript: String, _ done: @escaping (DriverInstallOutcome) -> Void) -> Void

    /// MicBridge's confirmation (an alert in the app). True to go ahead.
    var confirm: (DriverAction, DriverStatus) -> Bool = { _, _ in false }
    /// Runs the AppleScript; tests replace it with a recorder.
    var run: Runner = DriverInstaller.administratorPrompt
    var script: URL? = Bundle.main.url(forResource: "install-driver", withExtension: "sh")
    var bundle: URL? = DriverBundle.embedded
    private(set) var busy = false

    func perform(_ action: DriverAction, status: DriverStatus, done: @escaping (DriverInstallOutcome) -> Void) {
        guard !busy else { return }
        guard let script, let bundle, FileManager.default.fileExists(atPath: script.path),
              action == .uninstall || FileManager.default.fileExists(atPath: bundle.path) else {
            done(.failed(tr("这个版本的 MicBridge 没有附带驱动。", "This copy of MicBridge doesn’t include the driver."))); return
        }
        guard confirm(action, status) else { done(.declined); return }
        busy = true
        run(Self.appleScript(Self.command(action, script: script, bundle: bundle))) { [weak self] outcome in
            self?.busy = false
            done(outcome)
        }
    }

    /// The shell command, with every path quoted.
    static func command(_ action: DriverAction, script: URL, bundle: URL) -> String {
        switch action {
        case .install: return "/bin/sh \(shellQuote(script.path)) install \(shellQuote(bundle.path))"
        case .uninstall: return "/bin/sh \(shellQuote(script.path)) uninstall"
        }
    }
    static func shellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    /// `do shell script … with administrator privileges`: macOS asks for an
    /// administrator's password and runs the command as root.
    static func appleScript(_ command: String) -> String {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\" with administrator privileges"
    }

    /// The real runner: osascript off the main thread, result on main.
    static func administratorPrompt(_ appleScript: String, _ done: @escaping (DriverInstallOutcome) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process(), errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", appleScript]
            process.standardError = errors
            process.standardOutput = FileHandle.nullDevice
            var outcome = DriverInstallOutcome.done
            do {
                try process.run()
                process.waitUntilExit()
                let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if process.terminationStatus != 0 { outcome = message.contains("-128") ? .cancelled : .failed(message) }
            } catch {
                outcome = .failed(error.localizedDescription)
            }
            DispatchQueue.main.async { done(outcome) }
        }
    }
}
