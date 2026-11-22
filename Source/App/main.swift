import Cocoa

if CommandLine.arguments.contains("--probe-background-output") {
    DispatchQueue.global(qos: .userInitiated).async {
        do { try runSilentOutputProbe(); exit(0) }
        catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
    }
    RunLoop.main.run()
}
if CommandLine.arguments.contains("--self-test") {
    Lang.override = .zh  // copy assertions are written in Chinese; English has its own tests
    // Run every suite even when one fails (for example, a sandbox may
    // refuse loopback listeners). Never hide a failure or skip later checks.
    let suites: [(String, () throws -> Void)] = [
        ("Legacy", runSelfTests), ("Demand", runDemandTests), ("Connection", runConnectionTests),
        ("Pairing", runPairingTests), ("Model", runModelTests), ("Key vault", runKeyVaultTests),
        ("Peers", runPeerTests), ("Link", runLinkTests), ("Panel", runPanelTests),
        ("Driver", runDriverTests), ("Driver startup", runDriverStartupTests),
        ("Audio threads", runAudioThreadTests), ("Windows", runWindowTests),
        ("Permissions", runPermissionTests), ("Firewall", runFirewallTests),
        ("Switch", { try MainActor.assumeIsolated { try runSwitchTests() } }),
        ("UI", { _ = NSApplication.shared; try runUITests() }),
    ]
    var failures: [String] = []
    for (name, run) in suites {
        do { try run() }
        catch {
            let failure = "\(name): \(error.localizedDescription)"
            failures.append(failure); fputs("\(failure)\n", stderr)
        }
    }
    if !failures.isEmpty { fputs("Self-test: \(failures.count) suite(s) failed\n", stderr) }
    else { print("Self-test: all \(suites.count) suites passed") }
    exit(failures.isEmpty ? 0 : 1)
}
if CommandLine.arguments.contains("--discovery-test") {
    do { try runDiscoveryProbe(); exit(0) }
    catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
}
if CommandLine.arguments.contains("--probe-silent-output") {
    do { try runSilentOutputProbe(); exit(0) }
    catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
}
if let flag = CommandLine.arguments.firstIndex(of: "--render-previews") {
    let path = CommandLine.arguments.indices.contains(flag + 1) ? CommandLine.arguments[flag + 1] : "previews"
    do { try MainActor.assumeIsolated { try renderPreviews(to: URL(fileURLWithPath: path)) }; exit(0) }
    catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
}
if let flag = CommandLine.arguments.firstIndex(of: "--render-icons") {
    let path = CommandLine.arguments.indices.contains(flag + 1) ? CommandLine.arguments[flag + 1] : "icons"
    do { try BrandArt.renderIcons(to: URL(fileURLWithPath: path)); exit(0) }
    catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
}
if CommandLine.arguments.contains("--list-audio-devices") {
    for d in Devices.all() { print("\(d.name): input=\(d.inputChannels), output=\(d.outputChannels), loopback=\(d.loopback)") }; exit(0)
}
let app = NSApplication.shared
let delegate = AppDelegate(); app.delegate = delegate
app.setActivationPolicy(.accessory); app.run()
