import Cocoa
import SwiftUI

enum SettingsTab: Int, CaseIterable {
    case general, permissions, advanced, about
    var title: String {
        switch self {
        case .general: return tr("通用", "General")
        case .permissions: return tr("权限", "Permissions")
        case .advanced: return tr("高级", "Advanced")
        case .about: return tr("关于", "About")
        }
    }
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .permissions: return "hand.raised"
        case .advanced: return "wrench.and.screwdriver"
        case .about: return "info.circle"
        }
    }
    static let width: CGFloat = 480
    func height(_ s: PanelSnapshot) -> CGFloat {
        switch self {
        case .general: return s.role == .provider ? 194 : (s.driver == .ready ? 150 : 240)
        case .permissions: return 280
        case .advanced: return s.preview ? 360 : 290
        case .about: return 250
        }
    }
}

/// The Settings window: native toolbar tabs, one SwiftUI page each. The
/// window takes each page's size and title.
final class SettingsWindowController: NSWindowController {
    private let tabs = NSTabViewController()

    init(model: BridgeUIModel) {
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = [.allowUserInteraction]
        for tab in SettingsTab.allCases {
            let page = NSHostingController(rootView: SettingsPage(tab: tab, model: model))
            page.sizingOptions = [.preferredContentSize]
            page.title = tab.title
            let item = NSTabViewItem(viewController: page)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ tab: SettingsTab?) {
        if let tab { tabs.selectedTabViewItemIndex = tab.rawValue }
        window?.makeKeyAndOrderFront(nil)
    }
}

/// One page of Settings, at its fixed size.
struct SettingsPage: View {
    let tab: SettingsTab
    @ObservedObject var model: BridgeUIModel
    var body: some View {
        Group {
            switch tab {
            case .general: GeneralSettings(model: model)
            case .permissions: PermissionSettings(model: model)
            case .advanced: AdvancedSettings(model: model)
            case .about: AboutView(code: model.snapshot.localCode)
            }
        }
        .frame(width: SettingsTab.width, height: tab.height(model.snapshot))
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) {
            if !model.toast.isEmpty { Toast(text: model.toast).padding(.bottom, 12) }
        }
        .animation(.easeOut(duration: 0.18), value: model.toast)
    }
}

struct GeneralSettings: View {
    @ObservedObject var model: BridgeUIModel
    @State private var name = ""
    var s: PanelSnapshot { model.snapshot }

    var body: some View {
        Form {
            Section {
                LabeledContent(tr("名称", "Name")) {
                    TextField(tr("名称", "Name"), text: $name, prompt: Text(s.computerName))
                        .labelsHidden().multilineTextAlignment(.trailing)
                        .onSubmit(commitName)
                }
                if s.role == .provider {
                    Picker(tr("麦克风", "Microphone"), selection: Binding(get: { s.deviceUID }, set: model.selectDevice)) {
                        Text(tr("自动", "Automatic")).tag("")
                        ForEach(model.audioDevices) { Text($0.name).tag($0.id) }
                    }
                }
            }
            if s.role == .borrower && s.driver != .ready, let item = s.driverPermission {
                Section {
                    PermissionRow(item: item, busy: s.installing, perform: model.perform)
                }
            }
            Section {
                Toggle(tr("登录时打开", "Open at Login"),
                       isOn: Binding(get: { s.permissions.loginItem != .off }, set: model.setLaunchAtLogin))
                if s.permissions.loginItem == .needsApproval {
                    LabeledContent {
                        Button(tr("打开登录项", "Open Login Items"), action: model.openLoginItems)
                    } label: {
                        Label(tr("需要在系统设置中允许", "Needs approval in System Settings"), systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { name = s.customName; model.refreshDevices() }
        .onDisappear(perform: commitName)
    }
    private func commitName() {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if value != s.customName { model.setLocalName(value.isEmpty ? nil : value) }
    }
}

struct PermissionSettings: View {
    @ObservedObject var model: BridgeUIModel
    var s: PanelSnapshot { model.snapshot }
    var body: some View {
        Form {
            Section {
                ForEach(s.permissionItems) { PermissionRow(item: $0, busy: s.installing, perform: model.perform) }
            }
        }
        .formStyle(.grouped)
    }
}

struct AdvancedSettings: View {
    @ObservedObject var model: BridgeUIModel
    @State private var pairing = ""
    var s: PanelSnapshot { model.snapshot }
    var body: some View {
        Form {
            Section(tr("手动配对", "Pair Manually")) {
                HStack {
                    SecureField(tr("连接信息", "Connection info"), text: $pairing,
                                prompt: Text(tr("粘贴另一台 Mac 的连接信息", "Paste the other Mac’s connection info")))
                        .textFieldStyle(.roundedBorder).labelsHidden()
                    Button(tr("添加", "Add")) { model.pairManually(pairing); pairing = "" }.disabled(pairing.isEmpty)
                }
                LabeledContent(tr("本机的连接信息", "This Mac’s connection info")) {
                    Button(tr("复制", "Copy"), action: model.copyPairing)
                }
            }
            Section {
                if s.driver.isInstalled || s.driver.canInstall {
                    LabeledContent {
                        VStack(alignment: .trailing, spacing: 6) {
                            Text(s.driver.label(version: s.driverVersion)).foregroundStyle(.secondary).lineLimit(1)
                            HStack(spacing: 8) {
                                if s.driver.isInstalled {
                                    Button(tr("卸载…", "Remove…"), action: model.uninstallDriver).disabled(s.installing)
                                }
                                if s.driver.canInstall {
                                    Button(s.driver.installTitle, action: model.installDriver).disabled(s.installing)
                                }
                            }
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("MicBridge Microphone")
                            if s.role == .borrower && s.driver != .ready {
                                Text(s.driver.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                LabeledContent(tr("诊断信息", "Diagnostics")) {
                    Button(tr("复制", "Copy"), action: model.copyDiagnostics)
                }
            }
            if s.preview {
                Section(tr("界面预览", "UI Preview")) {
                    Picker(tr("状态", "State"), selection: Binding(get: { model.previewIndex }, set: model.previewScenario)) {
                        ForEach(PreviewFixtures.all.indices, id: \.self) { Text(PreviewFixtures.all[$0].label).tag($0) }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct AboutView: View {
    var code = ""
    var body: some View {
        VStack(spacing: 0) {
            AppIconView(size: 88)
            Text("MicBridge").font(.system(size: 20, weight: .semibold)).padding(.top, 10)
            Text(tr("借用另一台 Mac 的麦克风", "Borrow another Mac’s microphone"))
                .font(.system(size: 13)).foregroundStyle(.secondary).padding(.top, 4)
            Text(code.isEmpty ? tr("版本 \(bridgeVersion)", "Version \(bridgeVersion)")
                              : tr("版本 \(bridgeVersion) · 识别码 \(code)", "Version \(bridgeVersion) · Code \(code)"))
                .font(.system(size: 11)).foregroundStyle(.tertiary).monospacedDigit()
                .textSelection(.enabled).padding(.top, 14)
                .help(code.isEmpty ? "" : tr("有同名的 Mac 时，用识别码区分", "Tells this Mac apart from one with the same name"))
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// One permission: what it is, one line on why, and its state or the one
/// action that fixes it. Shared by Settings and onboarding.
struct PermissionRow: View {
    let item: PermissionItem
    var busy = false
    let perform: (PermissionItem.Action) -> Void

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: item.symbol).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(item.state == .optional ? Color.gray : Color.accentColor, in: RoundedRectangle(cornerRadius: 6.5, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.system(size: 13))
                if item.state != .ready && !item.detail.isEmpty {
                    Text(item.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.vertical, 2)
        .frame(minHeight: 34)
        .animation(.easeOut(duration: 0.2), value: item.state)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.title), \(item.state == .optional ? item.detail : item.stateLabel)")
    }

    @ViewBuilder private var trailing: some View {
        if busy && item.action == .installDriver {
            HStack(spacing: 6) {
                Spinner(size: 12)
                Text(tr("正在安装…", "Installing…")).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        } else if let action = item.action, item.state != .ready {
            HStack(spacing: 6) {
                if item.state == .denied {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).help(item.stateLabel)
                        .accessibilityLabel(item.stateLabel)
                }
                Button(item.actionTitle) { perform(action) }
                    .disabled(busy && action == .installDriver)
            }
        } else if item.state == .ready {
            Label(item.stateLabel, systemImage: "checkmark.circle.fill").labelStyle(.titleAndIcon)
                .font(.system(size: 12)).foregroundStyle(Palette.live)
        } else if item.state == .denied || item.state == .needed {
            Label(item.stateLabel, systemImage: "exclamationmark.circle.fill").labelStyle(.titleAndIcon)
                .font(.system(size: 12)).foregroundStyle(.orange)
        }
    }
}
