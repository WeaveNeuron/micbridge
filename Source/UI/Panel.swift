import SwiftUI

enum PanelMetrics {
    static let width: CGFloat = 340
    static let rowHeight: CGFloat = 50
    static let titleHeight: CGFloat = 28
    /// A longer device list scrolls (about six rows and both titles).
    static let maxListHeight: CGFloat = 360
    /// Cards, the switch and row highlights start here…
    static let edge: CGFloat = 10
    /// …and text and icons inside them line up here.
    static let column: CGFloat = 16
}

/// The menu bar panel: who this Mac is and what it does, the link it has (or
/// why not), and every Mac it knows or sees.
struct PanelView: View {
    @ObservedObject var model: BridgeUIModel
    var s: PanelSnapshot { model.snapshot }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(s: s, setMode: model.setMode)
                .padding(.horizontal, PanelMetrics.edge).padding(.top, 12).padding(.bottom, 10)
            StatusCard(model: model).padding(.horizontal, PanelMetrics.edge)
            if s.showsDriverNotice {
                DriverNotice(model: model).padding(.horizontal, PanelMetrics.edge).padding(.top, 8)
            }
            if s.showsFirewallNotice {
                FirewallNotice(open: model.openFirewall)
                    .padding(.horizontal, PanelMetrics.edge).padding(.top, 8)
                    .transition(.opacity)
            }
            DeviceSections(model: model)
                .opacity(s.paused ? 0.45 : 1)
            if !model.toast.isEmpty {
                Toast(text: model.toast).padding(.top, 8).padding(.horizontal, 14)
            }
            Divider().padding(.horizontal, PanelMetrics.edge).padding(.top, 10)
            PanelFooter(model: model)
        }
        .frame(width: PanelMetrics.width)
        .animation(.easeOut(duration: 0.18), value: model.toast)
        .animation(.easeOut(duration: 0.2), value: s.paused)
        .animation(.easeOut(duration: 0.2), value: s.showsFirewallNotice)
    }
}

/// The firewall blocks incoming connections: one line and the way to fix it.
struct FirewallNotice: View {
    var open: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "shield.lefthalf.filled").font(.system(size: 12, weight: .semibold)).foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(tr("防火墙拦截了传入连接", "The firewall blocks incoming connections"))
                .font(.system(size: 11.5)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            Button(PermissionList.firewallActionTitle, action: open).controlSize(.small).fixedSize()
        }
        .padding(.leading, PanelMetrics.column - PanelMetrics.edge).padding(.trailing, 8).padding(.vertical, 7)
        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

/// Driver setup stays visible even while the user has paused the bridge.
struct DriverNotice: View {
    @ObservedObject var model: BridgeUIModel
    var s: PanelSnapshot { model.snapshot }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(s.driver.title, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.orange)
            Text(s.driver.detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if s.offersDriverInstall {
                Button(s.driver.installTitle, action: model.installDriver).controlSize(.small).disabled(s.installing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

/// A short confirmation ("Diagnostics copied"), gone after a few seconds.
struct Toast: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "info.circle")
            .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
            .transition(.opacity)
            .accessibilityAddTraits(.updatesFrequently)
    }
}

// MARK: Header

struct PanelHeader: View {
    let s: PanelSnapshot
    var setMode: (PeerMode) -> Void
    /// The switch: on keeps this Mac's role, off pauses.
    static func mode(on: Bool, role: Role) -> PeerMode { PeerMode(role: role, enabled: on) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("MicBridge").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                if s.showsSwitch {
                    PanelSwitch(isOn: s.enabled) { setMode(Self.mode(on: $0, role: s.role)) }
                        .help(s.enabled ? tr("暂停 MicBridge", "Pause MicBridge") : tr("开启 MicBridge", "Turn On MicBridge"))
                }
            }
            .padding(.horizontal, PanelMetrics.column - PanelMetrics.edge)
            // The role is chosen in the welcome window while it is open.
            ModeSwitch(role: s.role, paused: s.paused || s.status == .settingUp, setMode: setMode)
        }
    }
}

/// The header's on/off switch, drawn in SwiftUI. The AppKit switch behind
/// Toggle moves its knob with a layer animation that never runs while the
/// panel is off screen, so a panel built paused and shown running drew the
/// knob on the left; and in a window that isn't key it drops the accent
/// colour, so "on" looked grey. This one is drawn from `isOn` every time,
/// keeps its colour like Control Center, and still reads as a switch to
/// VoiceOver.
struct PanelSwitch: View {
    let isOn: Bool
    var set: (Bool) -> Void
    @Environment(\.colorScheme) private var scheme
    static let size = CGSize(width: 30, height: 17)
    static let knob: CGFloat = 13

    var body: some View {
        Button { set(!isOn) } label: {
            Capsule()
                .fill(isOn ? Color.accentColor : Color.primary.opacity(scheme == .dark ? 0.24 : 0.16))
                .overlay(Capsule().strokeBorder(Color.black.opacity(isOn ? 0 : 0.06), lineWidth: 0.5))
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle().fill(Color.white)
                        .shadow(color: .black.opacity(0.22), radius: 0.8, y: 0.5)
                        .frame(width: Self.knob, height: Self.knob)
                        .padding(2)
                }
                .frame(width: Self.size.width, height: Self.size.height)
                .contentShape(Capsule())
                .animation(.spring(response: 0.25, dampingFraction: 0.9), value: isOn)
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle("MicBridge", isOn: Binding(get: { isOn }, set: set))
        }
    }
}

/// Share / Use, Control Center style: one pill slides between them. While
/// paused it stays where it was, dimmed (the header switch turns it on).
struct ModeSwitch: View {
    let role: Role
    var paused = false
    var setMode: (PeerMode) -> Void
    @Namespace private var pill
    @Environment(\.colorScheme) private var scheme

    static let modes: [PeerMode] = [.provider, .borrower]
    private static let items: [(PeerMode, String)] = [(.provider, "mic.fill"), (.borrower, "headphones")]
    private var mode: PeerMode { role == .provider ? .provider : .borrower }
    private func title(_ m: PeerMode) -> String { m == .provider ? tr("提供", "Share") : tr("使用", "Use") }
    private func help(_ m: PeerMode) -> String {
        m == .provider ? tr("把本机的麦克风提供给另一台 Mac", "Let another Mac use this Mac’s microphone")
                       : tr("使用另一台 Mac 的麦克风", "Use another Mac’s microphone")
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Self.items, id: \.0) { item, symbol in
                let selected = item == mode
                Button { if !selected { setMode(item) } } label: {
                    // Dark: white text on the pill (accent text is too faint there), accent icon.
                    let tint = selected && !paused ? Color.accentColor : nil
                    HStack(spacing: 5) {
                        Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(tint ?? (selected ? Color.primary : Color.secondary))
                        Text(title(item)).font(.system(size: 12, weight: selected ? .semibold : .regular))
                            .foregroundStyle(selected ? (scheme == .dark ? Color.primary : (tint ?? Color.primary)) : Color.secondary)
                    }
                    .frame(maxWidth: .infinity).frame(height: 24)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                                .fill(scheme == .dark ? Color.white.opacity(0.16) : Color.white)
                                .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.12), radius: 1, y: 0.5)
                                .matchedGeometryEffect(id: "pill", in: pill)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(help(item))
                .accessibilityLabel(title(item))
                .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(2)
        .background(Color.primary.opacity(scheme == .dark ? 0.09 : 0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .opacity(paused ? 0.45 : 1)
        .disabled(paused)
        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: mode)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tr("模式", "Mode"))
    }
}

// MARK: Status card

struct StatusCard: View {
    @ObservedObject var model: BridgeUIModel
    var s: PanelSnapshot { model.snapshot }

    var body: some View {
        if s.paused {
            Text(tr("已暂停", "Paused")).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(.vertical, 13)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .transition(.opacity)
                .accessibilityAddTraits(.updatesFrequently)
        } else {
            card.transition(.opacity)
        }
    }

    private var card: some View {
        VStack(spacing: 10) {
            if s.showsPeer {
                DeviceFlow(s: s, animate: model.onScreen).padding(.top, 2).transition(.opacity)
            } else {
                Image(systemName: s.status.symbol ?? "person.2.wave.2")
                    .font(.system(size: 24, weight: .regular)).symbolRenderingMode(.hierarchical)
                    .foregroundStyle(s.status.needsAttention ? Color.orange : Color.secondary)
                    .frame(height: 34).padding(.top, 4)
                    .transition(.opacity)
            }
            VStack(spacing: 4) {
                Text(s.title).font(.system(size: 15, weight: .semibold)).multilineTextAlignment(.center)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                if !s.subtitle.isEmpty {
                    Text(s.subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .lineSpacing(1.5).lineLimit(4).fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.updatesFrequently)
            .padding(.horizontal, 6)
            .animation(.easeOut(duration: 0.2), value: s.status)
            ActionRow(model: model).animation(.easeOut(duration: 0.2), value: s.status)
        }
        .padding(.horizontal, 12).padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(s.status.isLive ? Palette.live.opacity(0.35) : s.status.needsAttention ? Color.orange.opacity(0.35) : Color.primary.opacity(0.06)))
        .animation(.easeOut(duration: 0.2), value: s.showsPeer)
        .animation(.easeOut(duration: 0.2), value: s.status.isLive)
        .animation(.easeOut(duration: 0.2), value: s.status.needsAttention)
    }
}

/// Only when the user has something to do.
struct ActionRow: View {
    @ObservedObject var model: BridgeUIModel
    var s: PanelSnapshot { model.snapshot }

    var body: some View {
        switch s.status {
        case .incomingPairing:
            VStack(spacing: 10) {
                PairingCode(code: s.formattedCode)
                HStack(spacing: 8) {
                    Button(tr("拒绝", "Decline"), action: model.reject)
                    Button(tr("允许", "Allow"), action: model.approve).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }.controlSize(.regular)
            }
        case .pairing where s.pairingOutgoing:
            VStack(spacing: 10) {
                if s.status.pairingCode.isEmpty { Spinner(size: 16) } else { PairingCode(code: s.formattedCode) }
                Button(tr("取消", "Cancel"), action: model.cancelPairing).controlSize(.regular)
            }
        case .setup(.microphoneDenied), .localNetworkBlocked:
            HStack(spacing: 8) {
                Button(tr("打开系统设置", "Open System Settings")) {
                    model.openPrivacy(s.status == .localNetworkBlocked ? PermissionList.localNetworkPane : PermissionList.microphonePane)
                }
                Button(tr("重试", "Try Again"), action: model.retry).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }.controlSize(.regular)
        case .setup(.noVirtualMicrophone) where s.offersDriverInstall:
            HStack(spacing: 8) {
                Button(tr("重试", "Try Again"), action: model.retry)
                Button(s.driver.installTitle, action: model.installDriver).buttonStyle(.borderedProminent).disabled(s.installing)
                    .keyboardShortcut(.defaultAction)
                    .help(tr("需要管理员密码", "Needs an administrator password"))
            }.controlSize(.regular)
        case .setup, .problem:
            Button(tr("重试", "Try Again"), action: model.retry).buttonStyle(.borderedProminent).controlSize(.regular)
                .keyboardShortcut(.defaultAction)
        case .ready where s.role == .borrower && !s.defaultInput:
            Button(tr("设为默认麦克风", "Make Default Microphone"), action: model.makeDefaultInput).controlSize(.regular)
                .help(tr("让本机所有应用默认使用\(s.peerName)的麦克风", "Let every app on this Mac use \(s.peerName)’s microphone by default"))
        case .roleConflict:
            Button(s.role == .provider ? tr("改为使用它的麦克风", "Use Its Microphone Instead") : tr("改为提供麦克风", "Share This Mac’s Microphone Instead")) {
                model.setMode(s.role == .provider ? .borrower : .provider)
            }.controlSize(.regular)
        default:
            EmptyView()
        }
    }
}

struct PairingCode: View {
    let code: String
    var body: some View {
        Text(code).font(.system(size: 26, weight: .medium, design: .rounded)).monospacedDigit().tracking(3)
            .padding(.horizontal, 16).padding(.vertical, 4)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityLabel(tr("配对代码 \(code)", "Pairing code \(code)"))
    }
}

/// The provider on the left, the borrower on the right: sound flows left to right.
struct DeviceFlow: View {
    let s: PanelSnapshot
    var animate = true
    var body: some View {
        let local = (name: s.localName, model: s.localModel)
        let peer = (name: s.peerName, model: s.peerModel)
        let provider = s.role == .provider ? local : peer
        let borrower = s.role == .borrower ? local : peer
        HStack(alignment: .top, spacing: 0) {
            glyph(provider.name, provider.model, here: s.role == .provider)
            Connector(s: s, animate: animate).frame(width: 74, height: 26).padding(.top, 9)
            glyph(borrower.name, borrower.model, here: s.role == .borrower)
        }
        .accessibilityElement(children: .combine)
    }
    private func glyph(_ name: String, _ model: String, here: Bool) -> some View {
        let dim = s.status == .paused || s.status == .sleeping
        return VStack(spacing: 5) {
            Image(systemName: DeviceKind(model: model).symbol).font(.system(size: 22, weight: .light))
                .foregroundStyle(.primary.opacity(dim ? 0.35 : 0.85))
                .frame(width: 52, height: 44)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(s.status.isLive ? Palette.live.opacity(0.5) : Color.primary.opacity(0.07)))
            Text(here ? tr("本机", "This Mac") : name).font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(here ? .secondary : .primary).lineLimit(1).truncationMode(.middle)
        }.frame(width: 96)
    }
}

struct Connector: View {
    let s: PanelSnapshot
    var animate = true
    private let count = 11
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !animate || !(s.status.isWaiting || s.micActive))) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                if s.status.isLive && !s.micActive {
                    HStack(spacing: 0) {
                        Capsule().fill(Palette.live.opacity(0.6)).frame(height: 2.5)
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(Palette.live.opacity(0.8))
                    }.padding(.horizontal, 4)
                } else {
                    HStack(spacing: 3.5) {
                        ForEach(0..<count, id: \.self) { i in
                            Capsule().fill(color(i, t)).frame(width: 3, height: height(i, t))
                        }
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityLabel(s.micActive ? tr("正在传输声音", "Sending sound") : s.connected ? tr("已连接", "Connected") : tr("未连接", "Not connected"))
    }
    private func height(_ i: Int, _ t: TimeInterval) -> CGFloat {
        guard s.micActive else { return 3 }
        let wave = 0.55 + 0.45 * sin(t * 9 + Double(i) * 0.8)
        let envelope = sin(Double(i + 1) / Double(count + 1) * .pi)
        return CGFloat(4 + min(1, s.level * 5 + 0.08) * 20 * envelope * wave)
    }
    private func color(_ i: Int, _ t: TimeInterval) -> Color {
        if s.micActive { return Palette.live.opacity(0.9) }
        if s.status.isWaiting {
            // A soft pulse travelling from the provider to the borrower.
            let head = (t * 0.9).truncatingRemainder(dividingBy: 1) * Double(count + 4) - 2
            let glow = max(0, 1 - abs(Double(i) - head) / 2.5)
            return Color.accentColor.opacity(0.15 + 0.6 * glow)
        }
        return Color.secondary.opacity(0.22)
    }
}

// MARK: Devices

struct DeviceSections: View {
    @ObservedObject var model: BridgeUIModel
    var s: PanelSnapshot { model.snapshot }
    var showsNearby: Bool { s.showsNearby }

    var body: some View {
        let rows = s.mine.count + (showsNearby ? s.nearby.count : 0)
        let titles = (s.mine.isEmpty ? 0 : 1) + (showsNearby ? 1 : 0)
        let height = CGFloat(rows) * PanelMetrics.rowHeight + CGFloat(titles) * PanelMetrics.titleHeight
        let content = VStack(alignment: .leading, spacing: 0) {
            if !s.mine.isEmpty {
                SectionTitle(text: tr("我的 Mac", "My Macs"))
                ForEach(s.mine) { DeviceRowView(row: $0, model: model, animate: model.onScreen) }
            }
            if showsNearby {
                SectionTitle(text: tr("附近", "Nearby"), busy: s.browsing && s.nearby.isEmpty && s.enabled)
                if s.nearby.isEmpty {
                    Text(tr("在另一台 Mac 上打开 MicBridge。", "Open MicBridge on your other Mac."))
                        .font(.system(size: 11)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, PanelMetrics.column - PanelMetrics.edge).padding(.vertical, 6)
                } else {
                    ForEach(s.nearby) { DeviceRowView(row: $0, model: model, animate: model.onScreen) }
                }
            }
        }
        .padding(.horizontal, PanelMetrics.edge).padding(.top, 4)
        if height > PanelMetrics.maxListHeight {
            ScrollView { content }.frame(height: PanelMetrics.maxListHeight)
        } else {
            content
        }
    }
}

struct SectionTitle: View {
    let text: String
    var busy = false
    var body: some View {
        HStack(spacing: 6) {
            Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            if busy { Spinner(size: 10) }
            Spacer()
        }
        .padding(.horizontal, PanelMetrics.column - PanelMetrics.edge).padding(.top, 10).padding(.bottom, 3)
        .accessibilityAddTraits(.isHeader)
    }
}

struct DeviceRowView: View {
    let row: DeviceRow
    @ObservedObject var model: BridgeUIModel
    var animate = true
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: DeviceKind(model: row.model).symbol)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(row.isCurrent ? Color.white : Color.primary.opacity(dimmed ? 0.45 : 0.8))
                .frame(width: 30, height: 30)
                .background(row.isCurrent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary.opacity(0.07)), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(row.name).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(dimmed ? .secondary : .primary)
                    if let tag = row.tag {
                        Text(tag).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).layoutPriority(-1)
                            .help(tr("附近有同名的 Mac，用机型或识别码区分", "Another Mac has the same name; this tells them apart"))
                    }
                    if row.isChosen && !row.isCurrent {
                        Image(systemName: "pin.fill").font(.system(size: 8.5)).foregroundStyle(.secondary)
                            .help(tr("可用时优先使用这台 Mac", "Used whenever it’s available"))
                    }
                }
                HStack(spacing: 5) {
                    StateDot(state: row.state, mic: row.micInUse)
                    Text(row.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if row.micInUse { LevelBars(level: model.snapshot.level, animate: animate) }
            trailing
        }
        .padding(.horizontal, PanelMetrics.column - PanelMetrics.edge).frame(height: PanelMetrics.rowHeight)
        .background(background, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .contextMenu { if row.paired { menuItems } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(row.label), \(row.detail)")
    }

    private var dimmed: Bool { [.offline, .asleep, .appClosed, .paused].contains(row.state) && !row.isCurrent }
    private var background: Color {
        if row.isCurrent { return Color.accentColor.opacity(0.12) }
        return hover ? Color.primary.opacity(0.05) : .clear
    }

    @ViewBuilder private var trailing: some View {
        if !row.paired {
            if row.state == .pairing {
                // Pairing is answered on the status card (code, Cancel or
                // Decline / Allow); the row only shows it is under way. Cancel
                // is here only when the card shows something else.
                if model.snapshot.pairingOnCard {
                    Spinner(size: 12).padding(.trailing, 8)
                } else {
                    Button(tr("取消", "Cancel"), action: model.cancelPairing).controlSize(.small)
                }
            } else {
                Button(tr("添加", "Add")) { model.pair(row.id) }.controlSize(.small)
                    .disabled(row.state == .paused || !model.snapshot.enabled || model.snapshot.pairingOnCard)
                    .help(row.state == .paused ? tr("这台 Mac 已暂停 MicBridge", "MicBridge is paused on that Mac")
                                               : tr("与这台 Mac 配对，需要在两台 Mac 上确认", "Pair with this Mac; you confirm on both"))
            }
        } else {
            if row.needsPairing {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.orange).help(tr("移除后重新添加以连接", "Remove it and add it again to connect"))
            } else if row.canUse && !row.isChosen && !row.isCurrent && row.state == .online {
                Button(tr("使用", "Use")) { model.useProvider(row.id) }.controlSize(.small)
                    .help(tr("使用这台 Mac 的麦克风", "Use this Mac’s microphone"))
            } else if row.isCurrent {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.accentColor)
                    .accessibilityLabel(tr("当前连接", "Current"))
            }
            Button(action: showMenu) {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Color.primary.opacity(hover ? 0.07 : 0), in: Circle())
                    .contentShape(Circle())
            }
                .buttonStyle(.plain)
                .opacity(hover || row.isCurrent ? 1 : 0.6)
                .help(tr("更多", "More"))
                .accessibilityLabel(tr("更多", "More"))
        }
    }
    /// A native menu at the pointer (a SwiftUI Menu cannot be restyled to
    /// match the panel).
    private func showMenu() {
        let menu = NSMenu()
        func add(_ title: String, _ action: @escaping () -> Void) {
            let item = ClosureMenuItem(title: title, action: action); menu.addItem(item)
        }
        if row.canUse && !row.isChosen { add(tr("使用这台 Mac 的麦克风", "Use This Mac’s Microphone")) { model.useProvider(row.id) } }
        add(tr("重命名…", "Rename…")) { model.rename(row.id) }
        menu.addItem(.separator())
        add(tr("移除…", "Remove…")) { model.forget(row.id) }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
    @ViewBuilder private var menuItems: some View {
        if row.canUse && !row.isChosen { Button(tr("使用这台 Mac 的麦克风", "Use This Mac’s Microphone")) { model.useProvider(row.id) } }
        Button(tr("重命名…", "Rename…")) { model.rename(row.id) }
        Divider()
        Button(tr("移除…", "Remove…"), role: .destructive) { model.forget(row.id) }
    }
}

/// An NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void
    init(title: String, action: @escaping () -> Void) {
        run = action
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("not used") }
    @objc private func fire() { run() }
}

/// A small indeterminate spinner drawn in SwiftUI (it also renders in
/// previews, unlike the AppKit progress indicator).
struct Spinner: View {
    var size: CGFloat = 12
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Circle().trim(from: 0, to: 0.72)
                .stroke(Color.secondary, style: StrokeStyle(lineWidth: max(1.5, size / 8), lineCap: .round))
                .rotationEffect(.degrees((t * 360).truncatingRemainder(dividingBy: 360)))
        }
        .frame(width: size, height: size)
        .accessibilityLabel(tr("正在进行", "In progress"))
    }
}

struct StateDot: View {
    let state: DeviceRow.State
    var mic = false
    var body: some View {
        if mic {
            Image(systemName: "mic.fill").font(.system(size: 8.5, weight: .semibold)).foregroundStyle(Palette.live)
        } else {
            Circle().fill(fill).frame(width: 7, height: 7)
                .overlay(Circle().strokeBorder(stroke, lineWidth: 1))
        }
    }
    private var fill: Color {
        switch state {
        case .connected, .online: return Palette.live
        case .busy: return .orange
        case .pairing: return .accentColor
        case .paused, .asleep, .appClosed: return Color.secondary.opacity(0.45)
        case .offline: return .clear
        }
    }
    private var stroke: Color { state == .offline ? Color.secondary.opacity(0.6) : .clear }
}

struct LevelBars: View {
    let level: Double
    var animate = true
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: !animate)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    let wave = 0.5 + 0.5 * sin(t * 8 + Double(i) * 1.3)
                    Capsule().fill(Palette.live).frame(width: 2.5, height: 3 + CGFloat(min(1, level * 5 + 0.1) * 11 * wave))
                }
            }.frame(height: 16)
        }
        .accessibilityLabel(tr("麦克风使用中", "Microphone in use"))
    }
}

// MARK: Footer

struct PanelFooter: View {
    @ObservedObject var model: BridgeUIModel
    var body: some View {
        HStack {
            FooterButton(title: tr("设置", "Settings"), symbol: "gearshape", action: { model.openSettings(nil) })
                .keyboardShortcut(",", modifiers: .command)
            Spacer(minLength: 8)
            Text(model.snapshot.localName).font(.system(size: 11)).foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.middle)
                .help(tr("本机名称", "This Mac’s name"))
                .accessibilityLabel(tr("本机：\(model.snapshot.localName)", "This Mac: \(model.snapshot.localName)"))
            Spacer(minLength: 8)
            FooterButton(title: tr("退出 MicBridge", "Quit MicBridge"), symbol: "power", action: model.quit)
                .keyboardShortcut("q", modifiers: .command)
        }
        .padding(.horizontal, PanelMetrics.column - 7.5).padding(.vertical, 5)
    }
}

/// An icon-only button in the panel footer; its name is the tooltip and
/// the accessibility label.
struct FooterButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .regular))
                .frame(width: 28, height: 26)
                .background(hover ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
                .animation(.easeOut(duration: 0.12), value: hover)
        }
        .buttonStyle(.plain).foregroundStyle(hover ? .primary : .secondary)
        .onHover { hover = $0 }
        .help(title)
        .accessibilityLabel(title)
    }
}
