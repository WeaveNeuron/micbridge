import Cocoa
import SwiftUI

/// The panel's on/off switch must show what `enabled` says. The original
/// fault only appeared after the value changed in a window that was not on
/// screen, so these build the header paused, switch it on and off again
/// while the window is never shown, and read the pixels each time.
@MainActor
func runSwitchTests() throws {
    var count = 0
    func check(_ condition: Bool, _ description: String) throws {
        guard condition else { throw BridgeError("FAIL: \(description)") }
        count += 1; print("PASS: \(description)")
    }

    struct Probe: View {
        @ObservedObject var model: BridgeUIModel
        let background: Color
        var body: some View {
            PanelHeader(s: model.snapshot, setMode: { _ in })
                .frame(width: Probe.width)
                .background(background)
        }
        static let width: CGFloat = 320
    }
    /// The switch's part of the header: where its knob is (0 = left end,
    /// 1 = right end) and the mean colour around it.
    struct Reading { var knob: Double; var mean: [Double] }

    for (name, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
        let model = BridgeUIModel()
        model.snapshot = PanelSnapshot(status: .paused, role: .borrower, enabled: false)
        let shade = scheme == .dark ? 0.16 : 0.95
        let hosting = NSHostingView(rootView: Probe(model: model, background: Color(white: shade)).environment(\.colorScheme, scheme))
        hosting.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        // Like the menu bar panel: built before it is ever shown, and never key here.
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = hosting.appearance
        window.contentView = hosting

        func read() throws -> Reading {
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            hosting.layoutSubtreeIfNeeded()
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw BridgeError("FAIL: header renders") }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            let scale = Double(rep.pixelsWide) / Double(hosting.bounds.width)
            // The switch: right-aligned on the title row, inset by the text column.
            let inset = Double(PanelMetrics.column - PanelMetrics.edge), w = Double(PanelSwitch.size.width)
            let right = (Double(Probe.width) - inset) * scale, left = right - w * scale
            let rows = Int(Double(PanelSwitch.size.height + 6) * scale)
            var knobX = 0.0, knobN = 0.0, sum = [0.0, 0.0, 0.0], n = 0.0
            for y in 0..<min(rows, rep.pixelsHigh) {
                for x in Int(left)..<min(Int(right), rep.pixelsWide) {
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    let rgb = [Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent)]
                    for i in 0..<3 { sum[i] += rgb[i] }; n += 1
                    if rgb.allSatisfy({ $0 > 0.985 }) { knobX += Double(x); knobN += 1 }
                }
            }
            guard knobN > 0, n > 0 else { throw BridgeError("FAIL: \(name) switch knob is visible") }
            return Reading(knob: (knobX / knobN - left) / (right - left), mean: sum.map { $0 / n })
        }

        let off = try read()
        model.snapshot.enabled = true; model.snapshot.status = .setup(.noVirtualMicrophone)
        model.snapshot.driver = .notInstalled
        let on = try read()
        model.snapshot.enabled = false; model.snapshot.status = .paused
        let offAgain = try read()

        try check(off.knob < 0.4, "\(name): built paused, the knob is on the left (\(String(format: "%.2f", off.knob)))")
        try check(on.knob > 0.6, "\(name): waiting for a driver off screen, the on knob stays right (\(String(format: "%.2f", on.knob)))")
        try check(offAgain.knob < 0.4, "\(name): paused again, the knob is back on the left (\(String(format: "%.2f", offAgain.knob)))")
        let difference = zip(on.mean, off.mean).map { abs($0 - $1) }.max() ?? 0
        try check(difference > 0.08, "\(name): on and off differ in colour too, in a window that isn't key (\(String(format: "%.2f", difference)))")
        try check(zip(off.mean, offAgain.mean).allSatisfy { abs($0 - $1) < 0.02 }, "\(name): off looks the same both times")
        window.contentView = nil
    }
    print("Switch: \(count) checks passed")
}
