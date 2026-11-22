import Foundation
import CoreAudio
import CoreAudio.AudioServerPlugIn

/// The MicBridge Microphone driver without installing it: which virtual
/// microphone is used, and the driver's state as the app shows it.
func runDriverTests() throws {
    var count = 0
    func check(_ condition: Bool, _ description: String) throws {
        guard condition else { throw BridgeError("FAIL: \(description)") }
        count += 1; print("PASS: \(description)")
    }

    // The only device written to is MicBridge Microphone.
    func device(_ id: AudioDeviceID, _ uid: String, _ name: String) -> AudioDevice {
        AudioDevice(id: id, uid: uid, name: name, inputChannels: 2, outputChannels: 2, builtIn: false)
    }
    let ours = device(3, VirtualDevice.uid, "MicBridge Microphone"), speakers = device(4, "BuiltInSpeakerDevice", "Speakers"),
        other = device(5, "SomeVirtualDevice_UID", "Another Virtual Device")
    try check(VirtualDevice.find([speakers, other, ours])?.id == 3 && VirtualDevice.find([speakers, other]) == nil,
              "MicBridge Microphone is found among other devices; without it there is none")
    try check(ours.loopback && !speakers.loopback && !other.loopback, "only MicBridge Microphone is written to")

    // Driver state.
    func status(embedded: String? = "90000", installed: String?, loaded: Bool) -> DriverStatus {
        DriverStatus.derive(DriverFacts(embeddedVersion: embedded, installedVersion: installed, deviceLoaded: loaded))
    }
    try check(status(installed: nil, loaded: false) == .notInstalled && status(installed: nil, loaded: false).canInstall, "not installed: the app offers to install")
    try check(status(embedded: nil, installed: nil, loaded: false) == .bundleMissing && !DriverStatus.bundleMissing.canInstall, "an app without a driver offers nothing")
    try check(status(installed: "90000", loaded: true) == .ready && !DriverStatus.ready.canInstall, "installed and loaded is ready")
    try check(status(installed: "90000", loaded: false) == .installedNotLoaded, "installed but not loaded asks for an audio service restart")
    try check(status(installed: "80000", loaded: true) == .outdated(installed: "80000") && status(installed: "80000", loaded: false) == .outdated(installed: "80000"),
              "an older installed driver is offered an update, loaded or not")
    try check(status(installed: "100000", loaded: true) == .ready, "build numbers compare as numbers, not text")
    try check(status(embedded: nil, installed: "90000", loaded: true) == .ready && status(installed: nil, loaded: true) == .ready,
              "a loaded driver is ready even if this app has none, or it was installed elsewhere")
    try check(DriverStatus.outdated(installed: "1").isInstalled && !DriverStatus.notInstalled.isInstalled, "installed states are told apart")
    func snapshot(_ status: BridgeStatus, _ driver: DriverStatus) -> PanelSnapshot {
        var s = PanelSnapshot(status: status, role: .borrower); s.driver = driver; return s
    }
    try check(snapshot(.setup(.noVirtualMicrophone), .notInstalled).offersDriverInstall && snapshot(.setup(.noVirtualMicrophone), .installedNotLoaded).offersDriverInstall,
              "without a virtual microphone the panel offers to install or reload the driver")
    try check(!snapshot(.setup(.noVirtualMicrophone), .bundleMissing).offersDriverInstall && !snapshot(.ready, .ready).offersDriverInstall &&
              !snapshot(.setup(.virtualMicrophoneTimeout), .ready).offersDriverInstall,
              "the panel never pushes the driver while the bridge works, or when it cannot install")
    try check(snapshot(.ready, .ready).hasVirtualMicrophone && !snapshot(.ready, .notInstalled).hasVirtualMicrophone,
              "only an installed, loaded driver counts as a virtual microphone")

    try runDriverInProcess(check)
    try runInstallerTests(check)
    print("\(count) driver checks passed. Nothing installed; Core Audio untouched.")
}

// MARK: - The built driver, loaded into this process

private typealias DriverFactory = @convention(c) (CFAllocator?, CFUUID?) -> UnsafeMutableRawPointer?
private let kInputStream: AudioObjectID = 3, kOutputStream: AudioObjectID = 4, kDeviceObject: AudioObjectID = 2
private func fourCC(_ text: String) -> UInt32 { text.utf8.reduce(0) { $0 << 8 | UInt32($1) } }

/// Loads the driver the build put inside this app with `dlopen` and talks
/// to it exactly as Core Audio would, through a stand-in host. It is not
/// installed and coreaudiod never sees it.
private func runDriverInProcess(_ check: (Bool, String) throws -> Void) throws {
    guard let bundle = DriverBundle.embedded, FileManager.default.fileExists(atPath: bundle.path) else {
        throw BridgeError("FAIL: the app carries no MicBridge Microphone driver (build.sh builds it)")
    }
    try check(DriverBundle.version(at: bundle) == String(buildNumber(bundledDriverVersion)), "the embedded driver carries its own version, not the app's")
    let embedded = DriverBundle.version(at: bundle)
    try check(DriverStatus.derive(DriverFacts(embeddedVersion: embedded, installedVersion: embedded, deviceLoaded: true)) == .ready &&
              DriverStatus.derive(DriverFacts(embeddedVersion: embedded, installedVersion: "90000", deviceLoaded: true)) == .outdated(installed: "90000"),
              "the same driver needs nothing; a 0.9.0 driver is offered the update")
    // Never closed: the driver keeps its state in globals, as in coreaudiod.
    guard let handle = dlopen(DriverBundle.executable(in: bundle).path, RTLD_NOW | RTLD_LOCAL),
          let symbol = dlsym(handle, "MicBridge_Create") else {
        throw BridgeError("FAIL: could not load the driver: \(dlerror().map { String(cString: $0) } ?? "?")")
    }
    let create = unsafeBitCast(symbol, to: DriverFactory.self)
    let pluginType = CFUUIDGetConstantUUIDWithBytes(nil, 0x44, 0x3A, 0xBA, 0xB8, 0xE7, 0xB3, 0x49, 0x1A, 0xB9, 0x85, 0xBE, 0xB9, 0x18, 0x70, 0x30, 0xDB)
    let otherType = CFUUIDGetConstantUUIDWithBytes(nil, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16)
    try check(create(nil, otherType) == nil, "the driver answers only Core Audio's plug-in type")
    guard let raw = create(nil, pluginType) else { throw BridgeError("FAIL: the driver factory returned nothing") }
    let driver = raw.assumingMemoryBound(to: UnsafeMutablePointer<AudioServerPlugInDriverInterface>?.self)
    guard let vtable = driver.pointee?.pointee else { throw BridgeError("FAIL: the driver has no interface") }

    // The Info.plist wiring coreaudiod follows: the plug-in type names a
    // factory, the factory names the exported function. Read from this
    // bundle's own Info.plist and resolved in the copy loaded above, never
    // through CFPlugIn's process-wide registry: factories are registered
    // by UUID, so once an installed copy in /Library/Audio/Plug-Ins/HAL is
    // registered, the embedded copy's lookup comes back empty.
    let wiring = { (bundle: URL) -> String? in
        guard let data = try? Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let types = info["CFPlugInTypes"] as? [String: [String]],
              let factories = info["CFPlugInFactories"] as? [String: String],
              let ids = types["443ABAB8-E7B3-491A-B985-BEB9187030DB"], ids.count == 1 else { return nil }
        return factories[ids[0]]
    }
    let factoryName = wiring(bundle)
    try check(factoryName.flatMap { dlsym(handle, $0) } == symbol, "Info.plist maps Core Audio's plug-in type to the driver's factory")
    // The same holds with another copy registered first (as on a Mac
    // where the driver is installed).
    let copy = FileManager.default.temporaryDirectory.appendingPathComponent("micbridge-driver-\(getpid())").appendingPathComponent(DriverBundle.name)
    try? FileManager.default.removeItem(at: copy.deletingLastPathComponent())
    try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: bundle, to: copy)
    defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
    if let other = CFPlugInCreate(nil, copy as CFURL) { _ = CFPlugInFindFactoriesForPlugInTypeInPlugIn(pluginType, other) }
    try check(wiring(bundle) == factoryName && factoryName.flatMap { dlsym(handle, $0) } == symbol,
              "the wiring check is unaffected by an installed copy of the driver")

    // A host that stores nothing.
    let host = UnsafeMutablePointer<AudioServerPlugInHostInterface>.allocate(capacity: 1)
    host.initialize(to: AudioServerPlugInHostInterface(
        PropertiesChanged: { _, _, _, _ in noErr },
        CopyFromStorage: { _, _, out in out.pointee = nil; return noErr },
        WriteToStorage: { _, _, _ in noErr },
        DeleteFromStorage: { _, _ in noErr },
        RequestDeviceConfigurationChange: { _, _, _, _ in noErr }))
    try check(vtable.Initialize(driver, host) == noErr, "the driver initializes with a host")

    // COM: the driver interface and IUnknown, nothing else.
    var found: UnsafeMutableRawPointer?
    let driverInterface = CFUUIDGetUUIDBytes(CFUUIDGetConstantUUIDWithBytes(nil, 0xEE, 0xA5, 0x77, 0x3D, 0xCC, 0x43, 0x49, 0xF1, 0x8E, 0x00, 0x8F, 0x96, 0xE7, 0xD2, 0x3B, 0x17))
    let queried = vtable.QueryInterface(raw, driverInterface, &found)
    try check(queried == 0 && found == raw && vtable.Release(raw) >= 0, "the driver hands out its interface by UUID")
    try check(vtable.QueryInterface(raw, CFUUIDGetUUIDBytes(otherType), &found) != 0, "an unknown interface is refused")

    func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                  qualifier: UnsafeRawPointer? = nil, qualifierSize: UInt32 = 0, as: T.Type) -> T? {
        var a = address(selector, scope)
        let size = UInt32(MemoryLayout<T>.size)
        var out: UInt32 = 0
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { buffer.deallocate() }
        guard vtable.GetPropertyData(driver, object, 0, &a, qualifierSize, qualifier, size, &out, buffer) == noErr, out == size else { return nil }
        return buffer.load(as: T.self)
    }
    func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        value(object, selector, as: Unmanaged<CFString>.self).map { $0.takeUnretainedValue() as String }
    }
    func ids(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var a = address(selector, scope), size: UInt32 = 0
        guard vtable.GetPropertyDataSize(driver, object, 0, &a, 0, nil, &size) == noErr else { return [] }
        var list = [AudioObjectID](repeating: 0, count: Int(size) / 4)
        guard !list.isEmpty, vtable.GetPropertyData(driver, object, 0, &a, 0, nil, size, &size, &list) == noErr else { return [] }
        return Array(list.prefix(Int(size) / 4))
    }

    // What apps see.
    let plugIn = AudioObjectID(kAudioObjectPlugInObject)
    try check(ids(plugIn, kAudioPlugInPropertyDeviceList) == [kDeviceObject] && value(plugIn, kAudioObjectPropertyClass, as: UInt32.self) == kAudioPlugInClassID,
              "the plug-in owns exactly one device")
    try check(string(kDeviceObject, kAudioObjectPropertyName) == "MicBridge Microphone" && string(kDeviceObject, kAudioDevicePropertyDeviceUID) == VirtualDevice.uid &&
              string(kDeviceObject, kAudioObjectPropertyManufacturer) == "MicBridge",
              "the device is MicBridge Microphone with the UID the catalog ranks first")
    try check(value(kDeviceObject, kAudioDevicePropertyTransportType, as: UInt32.self) == kAudioDeviceTransportTypeVirtual, "it says it is virtual")
    try check(ids(kDeviceObject, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput) == [kInputStream] &&
              ids(kDeviceObject, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput) == [kOutputStream] &&
              ids(kDeviceObject, kAudioDevicePropertyStreams) == [kInputStream, kOutputStream],
              "one input stream for apps, one output stream for MicBridge")
    try check(value(kInputStream, kAudioStreamPropertyDirection, as: UInt32.self) == 1 && value(kOutputStream, kAudioStreamPropertyDirection, as: UInt32.self) == 0 &&
              value(kInputStream, kAudioStreamPropertyTerminalType, as: UInt32.self) == kAudioStreamTerminalTypeMicrophone,
              "the input stream is a microphone")
    let format = value(kInputStream, kAudioStreamPropertyVirtualFormat, as: AudioStreamBasicDescription.self)
    try check(format?.mSampleRate == 48_000 && format?.mChannelsPerFrame == 2 && format?.mBitsPerChannel == 32 &&
              (format.map { $0.mFormatFlags & kAudioFormatFlagIsFloat != 0 } ?? false) && value(kDeviceObject, kAudioDevicePropertyNominalSampleRate, as: Float64.self) == 48_000,
              "48 kHz, 2-channel float, the rate MicBridge sends")
    try check(value(kDeviceObject, kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeInput, as: UInt32.self) == 1 &&
              value(kDeviceObject, kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeOutput, as: UInt32.self) == 0 &&
              value(kDeviceObject, kAudioDevicePropertyDeviceCanBeDefaultSystemDevice, as: UInt32.self) == 0,
              "it can be the default microphone, never the default output or alert device")
    func translate(_ uid: String) -> AudioObjectID? {
        withUnsafePointer(to: uid as CFString) { pointer in
            value(plugIn, kAudioPlugInPropertyTranslateUIDToDevice, qualifier: UnsafeRawPointer(pointer),
                  qualifierSize: UInt32(MemoryLayout<CFString>.size), as: AudioObjectID.self)
        }
    }
    try check(translate(VirtualDevice.uid) == kDeviceObject && translate("BuiltInMicrophoneDevice") == AudioObjectID(kAudioObjectUnknown),
              "its UID finds it; another UID does not")
    var unknown = address(fourCC("zzzz"))
    try check(!vtable.HasProperty(driver, kDeviceObject, 0, &unknown).boolValue && value(99, kAudioObjectPropertyClass, as: UInt32.self) == nil,
              "unknown properties and objects are refused")

    // Fixed rate and format.
    var rate = address(kAudioDevicePropertyNominalSampleRate), settable: DarwinBoolean = true
    var fortyFour: Float64 = 44_100
    try check(vtable.IsPropertySettable(driver, kDeviceObject, 0, &rate, &settable) == noErr && !settable.boolValue &&
              vtable.SetPropertyData(driver, kDeviceObject, 0, &rate, 0, nil, 8, &fortyFour) != noErr &&
              value(kDeviceObject, kAudioDevicePropertyNominalSampleRate, as: Float64.self) == 48_000,
              "another sample rate is refused")
    var virtualFormat = address(kAudioStreamPropertyVirtualFormat)
    if var same = format {
        var slower = same; slower.mSampleRate = 44_100
        let asbd = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(vtable.SetPropertyData(driver, kInputStream, 0, &virtualFormat, 0, nil, asbd, &same) == noErr &&
                  vtable.SetPropertyData(driver, kInputStream, 0, &virtualFormat, 0, nil, asbd, &slower) == kAudioDeviceUnsupportedFormatError,
                  "a stream keeps its one format")
    }

    // IO: what MicBridge writes, apps read back once.
    var willDo: DarwinBoolean = false, inPlace: DarwinBoolean = false
    _ = vtable.WillDoIOOperation(driver, kDeviceObject, 1, fourCC("read"), &willDo, &inPlace)
    let reads = willDo.boolValue
    _ = vtable.WillDoIOOperation(driver, kDeviceObject, 1, fourCC("rite"), &willDo, &inPlace)
    let writes = willDo.boolValue
    _ = vtable.WillDoIOOperation(driver, kDeviceObject, 1, fourCC("cinp"), &willDo, &inPlace)
    try check(reads && writes && !willDo.boolValue, "it reads input and writes the mix, nothing else")
    try check(value(kDeviceObject, kAudioDevicePropertyDeviceIsRunning, as: UInt32.self) == 0 && vtable.StartIO(driver, kDeviceObject, 1) == noErr &&
              value(kDeviceObject, kAudioDevicePropertyDeviceIsRunning, as: UInt32.self) == 1, "starting IO runs the device")
    var t1 = 0.0, h1: UInt64 = 0, s1: UInt64 = 0, t2 = 0.0, h2: UInt64 = 0, s2: UInt64 = 0
    _ = vtable.GetZeroTimeStamp(driver, kDeviceObject, 1, &t1, &h1, &s1)
    Thread.sleep(forTimeInterval: 0.4)  // longer than one 16384-frame period
    _ = vtable.GetZeroTimeStamp(driver, kDeviceObject, 1, &t2, &h2, &s2)
    try check(h1 > 0 && t2 > t1 && h2 > h1 && t2.truncatingRemainder(dividingBy: 16_384) == 0, "the clock advances one period at a time")

    func cycle(_ sampleTime: Float64) -> AudioServerPlugInIOCycleInfo {
        var c = AudioServerPlugInIOCycleInfo()
        c.mInputTime.mSampleTime = sampleTime; c.mOutputTime.mSampleTime = sampleTime
        return c
    }
    func roundTrip(at sampleTime: Float64, frames: Int) -> (first: [Float32], again: [Float32], sent: [Float32]) {
        var info = cycle(sampleTime)
        var sent = (0..<frames * 2).map { Float32(sin(Double($0) * 0.05) * 0.5) }
        var first = [Float32](repeating: 9, count: frames * 2), again = first
        _ = vtable.DoIOOperation(driver, kDeviceObject, kOutputStream, 1, fourCC("rite"), UInt32(frames), &info, &sent, nil)
        _ = vtable.DoIOOperation(driver, kDeviceObject, kInputStream, 1, fourCC("read"), UInt32(frames), &info, &first, nil)
        _ = vtable.DoIOOperation(driver, kDeviceObject, kInputStream, 1, fourCC("read"), UInt32(frames), &info, &again, nil)
        return (first, again, sent)
    }
    let plain = roundTrip(at: 1_000, frames: 512)
    try check(plain.first == plain.sent, "what MicBridge writes, apps read back sample for sample")
    try check(plain.again.allSatisfy { $0 == 0 }, "once read it is silence: a stopped bridge never replays old sound")
    let wrapped = roundTrip(at: 16_384 * 3 - 100, frames: 512)
    try check(wrapped.first == wrapped.sent && wrapped.again.allSatisfy { $0 == 0 }, "audio crossing the end of the ring stays intact")
    try check(vtable.StopIO(driver, kDeviceObject, 1) == noErr && value(kDeviceObject, kAudioDevicePropertyDeviceIsRunning, as: UInt32.self) == 0 &&
              vtable.StopIO(driver, kDeviceObject, 1) != noErr, "stopping IO stops the device; stopping twice is an error")
}

/// "0.9.0" → 90000, as build.sh numbers builds.
func buildNumber(_ version: String) -> Int {
    let parts = version.split(separator: ".").map { Int($0) ?? 0 } + [0, 0, 0, 0]
    return parts[0] * 1_000_000 + parts[1] * 10_000 + parts[2] * 100 + parts[3]
}

// MARK: - Installing: asked first, then the script

private func runInstallerTests(_ check: (Bool, String) throws -> Void) throws {
    // Quoting survives spaces, quotes and backslashes, through the shell
    // and through AppleScript.
    let odd = "/tmp/Mic Bridge's \\ \"test\".app"
    let echo = Process(), out = Pipe()
    echo.executableURL = URL(fileURLWithPath: "/bin/sh")
    echo.arguments = ["-c", "printf '%s' \(DriverInstaller.shellQuote(odd))"]
    echo.standardOutput = out
    try echo.run(); echo.waitUntilExit()
    try check(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == odd, "paths are quoted safely for the shell")
    let script = DriverInstaller.appleScript(#"/bin/sh '/a "b"' install '/c\d'"#)
    try check(script == #"do shell script "/bin/sh '/a \"b\"' install '/c\\d'" with administrator privileges"#,
              "the command is escaped inside AppleScript and run with macOS's administrator prompt")
    try check(versionName("90000") == "0.9.0" && versionName("70001") == "0.7.0.1", "build numbers read as versions")
    try check(DriverStatus.allCases.allSatisfy { s in Lang.allCases.allSatisfy { l in withLanguage(l) { !s.label(version: "0.9.0").isEmpty && !s.installTitle.isEmpty } } },
              "every driver state has wording in both languages")

    // The order: MicBridge's confirmation, then the administrator prompt.
    guard let embedded = DriverBundle.embedded, let installScript = Bundle.main.url(forResource: "install-driver", withExtension: "sh") else {
        throw BridgeError("FAIL: the app carries no driver installer")
    }
    let installer = DriverInstaller()
    var asked: [DriverAction] = [], ran: [String] = [], outcome: DriverInstallOutcome?
    var pending: ((DriverInstallOutcome) -> Void)?
    installer.run = { script, done in ran.append(script); pending = done }
    installer.confirm = { action, _ in asked.append(action); return false }
    installer.perform(.install, status: .notInstalled) { outcome = $0 }
    try check(asked == [.install] && ran.isEmpty && outcome == .declined, "declining in MicBridge runs nothing")
    installer.confirm = { action, _ in asked.append(action); return true }
    installer.perform(.install, status: .notInstalled) { outcome = $0 }
    let expected = DriverInstaller.appleScript(DriverInstaller.command(.install, script: installScript, bundle: embedded))
    try check(ran == [expected] && expected.contains("install-driver.sh") && expected.contains(DriverBundle.name) && installer.busy,
              "after the user confirms, only the bundled script runs, through the administrator prompt")
    installer.perform(.uninstall, status: .ready) { _ in }
    try check(ran.count == 1, "nothing else starts while the prompt is up")
    pending?(.cancelled)
    try check(outcome == .cancelled && !installer.busy, "cancelling the password prompt changes nothing")
    let missing = DriverInstaller()
    missing.bundle = URL(fileURLWithPath: "/nonexistent/" + DriverBundle.name)
    var missingAsked = false
    missing.confirm = { _, _ in missingAsked = true; return true }
    missing.run = { _, _ in missingAsked = true }
    missing.perform(.install, status: .notInstalled) { outcome = $0 }
    try check(!missingAsked && { if case .failed = outcome { return true }; return false }(), "without a driver in the app nothing is offered or run")

    // The script itself, into a scratch folder (never the system's; it
    // refuses --dest as root) and without restarting Core Audio.
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("micbridge-driver-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let dest = scratch.appendingPathComponent("HAL")
    func sh(_ arguments: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [installScript.path] + arguments
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        return p.terminationStatus
    }
    let installed = dest.appendingPathComponent(DriverBundle.name)
    try check(try sh(["install", embedded.path, "--dest", dest.path, "--no-restart"]) == 0 &&
              DriverBundle.version(at: installed) == DriverBundle.version(at: embedded), "the script installs the driver")
    let verify = Process()
    verify.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    verify.arguments = ["--verify", "--strict", installed.path]
    verify.standardError = FileHandle.nullDevice
    try verify.run(); verify.waitUntilExit()
    try check(verify.terminationStatus == 0, "the installed copy keeps a valid signature")
    let stray = installed.appendingPathComponent("Contents/stray")
    try Data().write(to: stray)
    try check(try sh(["install", embedded.path, "--dest", dest.path, "--no-restart"]) == 0 && !FileManager.default.fileExists(atPath: stray.path) &&
              (try FileManager.default.contentsOfDirectory(atPath: dest.path)) == [DriverBundle.name],
              "installing again replaces the old copy whole and leaves nothing behind")
    try check(try sh(["uninstall", "--dest", dest.path, "--no-restart"]) == 0 && !FileManager.default.fileExists(atPath: installed.path) &&
              (try sh(["uninstall", "--dest", dest.path, "--no-restart"])) == 0, "the script removes it, and removing twice is harmless")
    let wrongName = scratch.appendingPathComponent("Other.driver")
    try FileManager.default.copyItem(at: embedded, to: wrongName)
    let tampered = scratch.appendingPathComponent("tampered").appendingPathComponent(DriverBundle.name)
    try FileManager.default.createDirectory(at: tampered.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: embedded, to: tampered)
    try Data("<!-- changed -->".utf8).write(to: tampered.appendingPathComponent("Contents/Info.plist"), options: .atomic)
    try check(try sh(["install", wrongName.path, "--dest", dest.path, "--no-restart"]) == 65 &&
              (try sh(["install", tampered.path, "--dest", dest.path, "--no-restart"])) == 66 &&
              !FileManager.default.fileExists(atPath: installed.path), "the script installs only a correctly named bundle with a valid signature")
    try check(try sh(["install"]) == 64 && (try sh(["reinstall", "--dest", dest.path])) == 64 && (try sh(["uninstall", "--bogus"])) == 64,
              "the script refuses unknown commands and options")
}
