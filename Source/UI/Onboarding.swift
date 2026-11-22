import SwiftUI

/// First launch, in two short steps: what this Mac does and what it needs.
/// Pairing happens in the panel, which opens when this is done; everything
/// can be changed later there and in Settings › Permissions.
struct OnboardingView: View {
    @ObservedObject var model: BridgeUIModel
    /// The role suggested for this Mac (no built-in microphone: use one).
    let suggested: Role
    @State private var launchAtLogin = true
    var s: PanelSnapshot { model.snapshot }
    static let steps = 2
    static let size = CGSize(width: 520, height: 440)

    /// The step lives in the model, so the panel, previews and the
    /// preview build's walkthrough can show any of them.
    private var step: Int {
        get { model.onboardingStep }
        nonmutating set { withAnimation(.easeInOut(duration: 0.2)) { model.onboardingStep = newValue } }
    }
    init(model: BridgeUIModel, suggested: Role, step: Int? = nil) {
        self.model = model; self.suggested = suggested
        if let step { model.onboardingStep = step; model.onboardingRole = nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: welcome
                default: permissions
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: step == 0 ? .center : .top)
            .padding(.horizontal, 36).padding(.top, step == 0 ? 20 : 36)
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    ForEach(0..<Self.steps, id: \.self) { i in
                        Circle().fill(i == step ? Color.accentColor : Color.secondary.opacity(0.3)).frame(width: 6, height: 6)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(tr("第 \(step + 1) 步，共 \(Self.steps) 步", "Step \(step + 1) of \(Self.steps)"))
                Spacer()
                if step > 0 { Button(tr("上一步", "Back")) { step -= 1 } }
                Button(step == Self.steps - 1 ? tr("完成", "Done") : tr("继续", "Continue"), action: next)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(.horizontal, 24).padding(.bottom, 20).padding(.top, 12)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .overlay(alignment: .bottom) {
            if !model.toast.isEmpty { Toast(text: model.toast).padding(.bottom, 74) }
        }
        .animation(.easeOut(duration: 0.18), value: model.toast)
    }

    private var chosen: Role { model.onboardingRole ?? suggested }

    private func next() {
        switch step {
        case 0:
            // Starting here lets macOS ask about Local Network while the
            // next step explains it.
            model.setMode(chosen == .provider ? .provider : .borrower)
            step += 1
        case Self.steps - 1:
            model.finishOnboarding(launchAtLogin)
        default:
            step += 1
        }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 0) {
            AppIconView(size: 76)
            Text(tr("借用另一台 Mac 的麦克风", "Borrow another Mac’s microphone"))
                .font(.system(size: 22, weight: .semibold)).padding(.top, 10)
            HStack(spacing: 12) {
                RoleCard(role: .provider, selected: chosen == .provider, recommended: suggested == .provider) { model.onboardingRole = .provider }
                RoleCard(role: .borrower, selected: chosen == .borrower, recommended: suggested == .borrower) { model.onboardingRole = .borrower }
            }
            .padding(.top, 26)
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepTitle(title: chosen == .borrower ? tr("需要的驱动与权限", "Driver and permissions") : tr("需要的权限", "What MicBridge needs"))
            VStack(spacing: 0) {
                let items = PermissionList.essentials(role: chosen, facts: s.permissions, driver: s.driver)
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider().padding(.leading, 37) }
                    PermissionRow(item: item, busy: s.installing, perform: model.perform).padding(.vertical, 7)
                }
                Divider().padding(.leading, 37)
                HStack(spacing: 11) {
                    Image(systemName: "power").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 26, height: 26).background(Color.gray, in: RoundedRectangle(cornerRadius: 6.5, style: .continuous))
                        .accessibilityHidden(true)
                    Text(tr("登录时打开", "Open at Login")).font(.system(size: 13))
                    Spacer()
                    Toggle(tr("登录时打开", "Open at Login"), isOn: $launchAtLogin).toggleStyle(.switch).labelsHidden().controlSize(.small)
                }
                .padding(.vertical, 9)
            }
            .padding(.horizontal, 14).padding(.vertical, 4)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

struct StepTitle: View {
    let title: String
    var text = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 20, weight: .semibold))
            if !text.isEmpty {
                Text(text).font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct RoleCard: View {
    let role: Role
    let selected: Bool
    let recommended: Bool
    let choose: () -> Void
    var body: some View {
        Button(action: choose) {
            VStack(spacing: 12) {
                Image(systemName: role == .provider ? "mic.fill" : "headphones").font(.system(size: 19))
                    .foregroundStyle(selected ? Color.white : Color.accentColor)
                    .frame(width: 40, height: 40)
                    .background(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.accentColor.opacity(0.12)), in: Circle())
                Text(role == .provider ? tr("提供本机的麦克风", "Share this Mac’s microphone") : tr("使用另一台 Mac 的麦克风", "Use another Mac’s microphone"))
                    .font(.system(size: 13, weight: .semibold)).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            .padding(14).frame(width: 216, height: 112)
            .overlay(alignment: .topTrailing) {
                if recommended {
                    Text(tr("推荐", "Suggested")).font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 7).padding(.vertical, 2).background(Color.accentColor.opacity(0.12), in: Capsule())
                        .padding(10)
                }
            }
            .background(Color.primary.opacity(selected ? 0.06 : 0.03), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: selected ? 2 : 1))
            .animation(.easeOut(duration: 0.15), value: selected)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
