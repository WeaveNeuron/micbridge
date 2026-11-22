import Foundation

/// Reads the application firewall's state in the background, at most every
/// few seconds and only when asked (a window is on screen). Read-only: it
/// never changes a setting and needs no administrator.
final class FirewallMonitor {
    static let tool = "/usr/libexec/ApplicationFirewall/socketfilterfw"
    private(set) var state = FirewallState.unknown
    /// Called on the main queue when the state changes.
    var onChange: () -> Void = {}
    private var lastRead: TimeInterval = -.infinity
    private var reading = false
    private let bundlePath: String
    private let queue = DispatchQueue(label: "MicBridge.firewall", qos: .utility)

    init(bundlePath: String = Bundle.main.bundlePath) { self.bundlePath = bundlePath }

    func refresh(now: TimeInterval = ProcessInfo.processInfo.systemUptime, interval: TimeInterval = 5) {
        guard !reading, now - lastRead >= interval, FileManager.default.isExecutableFile(atPath: Self.tool) else { return }
        reading = true; lastRead = now
        let path = bundlePath
        queue.async { [weak self] in
            let next = FirewallState.parse(globalState: Self.run("--getglobalstate"), blockAll: Self.run("--getblockall"),
                                           apps: Self.run("--listapps"), bundlePath: path)
            DispatchQueue.main.async {
                guard let self else { return }
                self.reading = false
                if next != self.state { self.state = next; self.onChange() }
            }
        }
    }

    /// One query; empty on any failure (which reads as unknown).
    private static func run(_ argument: String) -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = [argument]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : ""
    }
}
