import Cocoa
import SwiftUI
import ServiceManagement

/// A borderless panel that can take keyboard focus (for the code buttons
/// and Esc) without being a regular window.
final class StatusPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// The menu bar item: a click opens the panel under it, a right-click (or
/// Control-click) shows a short menu.
final class MenuBarController: NSObject {
    let item: NSStatusItem
    let panel: StatusPanel
    let menu: NSMenu
    private var outsideClicks: Any?
    private var height: CGFloat = 300
    var onVisibilityChange: ((Bool) -> Void)?
    /// A click that would open the panel; the app decides what opens.
    var onOpen: (() -> Void)?
    var isOpen: Bool { panel.isVisible }

    init(model: BridgeUIModel, menu: NSMenu) {
        self.menu = menu
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        panel = StatusPanel(contentRect: NSRect(x: 0, y: 0, width: PanelMetrics.width, height: height),
                            styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: true)
        super.init()
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
        panel.onCancel = { [weak self] in self?.close() }
        let root = PanelView(model: model)
            .background(VisualEffect(material: .popover))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { proxy in Color.clear.preference(key: PanelHeight.self, value: proxy.size.height) })
            .onPreferenceChange(PanelHeight.self) { [weak self] in self?.fit(height: $0) }
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        panel.contentView = hosting
        NotificationCenter.default.addObserver(self, selector: #selector(resigned), name: NSWindow.didResignKeyNotification, object: panel)

        if let button = item.button {
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            close()
            if let button = item.button { menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button) }
        } else {
            if isOpen { close() } else if let onOpen { onOpen() } else { open() }
        }
    }

    func open() {
        guard !isOpen else { panel.makeKeyAndOrderFront(nil); return }
        position()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        item.button?.highlight(true)
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.close() }
        onVisibilityChange?(true)
    }
    func close() {
        guard isOpen else { return }
        panel.orderOut(nil)
        item.button?.highlight(false)
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        outsideClicks = nil
        onVisibilityChange?(false)
    }
    @objc private func resigned() {
        // An alert opened from the panel (rename, remove) keeps it open.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.panel.isKeyWindow, NSApp.modalWindow == nil else { return }
            self.close()
        }
    }

    /// Grows and shrinks downwards from the menu bar.
    private func fit(height newHeight: CGFloat) {
        guard newHeight > 0, abs(newHeight - height) > 0.5 else { return }
        height = newHeight
        guard isOpen else { return }
        let top = panel.frame.maxY
        panel.setFrame(NSRect(x: panel.frame.minX, y: top - height, width: PanelMetrics.width, height: height), display: true)
        panel.invalidateShadow()
    }
    private func position() {
        let screen = item.button?.window?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        var x = visible.maxX - PanelMetrics.width - 8, top = visible.maxY - 5
        // Under the menu bar item once it has a place in the menu bar;
        // right after launch it may not yet, so use the top-right corner.
        if let button = item.button, let window = button.window {
            let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
            if anchor.width > 0, anchor.minY >= visible.maxY - 2 {
                x = anchor.midX - PanelMetrics.width / 2
                top = min(anchor.minY - 5, visible.maxY)
            }
        }
        x = min(max(x, visible.minX + 8), visible.maxX - PanelMetrics.width - 8)
        panel.setFrame(NSRect(x: x, y: top - height, width: PanelMetrics.width, height: height), display: false)
    }
}

private struct PanelHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The translucent menu material behind the panel.
struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material; view.blendingMode = .behindWindow; view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) { view.material = material }
}

/// Open at login, through the system's login items (System Settings ›
/// General › Login Items). Never turned on without the user's choice.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static var state: LoginItemState {
        switch SMAppService.mainApp.status {
        case .enabled: return .on
        case .requiresApproval: return .needsApproval
        default: return .off
        }
    }
    static func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
    @discardableResult static func set(_ on: Bool) -> Bool {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return true
        } catch { return false }
    }
}
