import Cocoa

/// What the menu bar glyph shows. Every state is the same bridge; only
/// the cable changes, so the icon never jumps around in the bar.
enum MenuIconState: CaseIterable {
    /// Cable open in the middle: not linked yet (setting up, a permission
    /// or a pairing request to answer, searching, connecting, nothing paired).
    case idle
    /// Whole bridge, faint: switched off.
    case paused
    /// Whole bridge: linked to the other Mac.
    case connected

    init(_ status: BridgeStatus) {
        switch status {
        case .paused: self = .paused
        case .ready, .inUse: self = .connected
        default: self = .idle
        }
    }
}

/// Menu bar glyph: the MicBridge bridge redrawn for the bar. Two towers
/// joined by a rounded deck, a main cable slung between them, and the
/// microphone resting in the cable, never above the tower tops. 1.5 pt
/// strokes on an 18 pt template image, so macOS tints it for the bar.
/// While sound flows, macOS shows its own microphone indicator, so the
/// glyph doesn't repeat it.
enum MenuIcon {
    static let size = NSSize(width: 18, height: 18)
    static let line: CGFloat = 1.5
    static let pausedAlpha: CGFloat = 0.4
    /// Tower tops (stroke centre), in points (y up).
    static let towerTop: CGFloat = 14
    /// The microphone capsule, filled (y up). Its top sits at the tower tops.
    static let capsule = CGRect(x: 7.5, y: 9, width: 3, height: 5)
    /// The cable runs from both towers and dips below the capsule.
    static let cableStart = CGPoint(x: 3, y: 12.4), cableEnd = CGPoint(x: 15, y: 12.4), cableControl = CGPoint(x: 9, y: -0.2)
    /// Share of the cable left open in the middle while not linked.
    static let gap: CGFloat = 0.4

    private static var cache: [MenuIconState: NSImage] = [:]
    static func image(_ state: MenuIconState) -> NSImage {
        if let image = cache[state] { return image }
        let image = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            draw(state, in: ctx)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "MicBridge"
        cache[state] = image
        return image
    }

    static func cablePoint(_ t: CGFloat) -> CGPoint {
        let a = (1 - t) * (1 - t), b = 2 * t * (1 - t), c = t * t
        return CGPoint(x: a * cableStart.x + b * cableControl.x + c * cableEnd.x,
                       y: a * cableStart.y + b * cableControl.y + c * cableEnd.y)
    }

    static func draw(_ state: MenuIconState, in ctx: CGContext) {
        ctx.saveGState()
        ctx.setAlpha(state == .paused ? pausedAlpha : 1)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setLineWidth(line); ctx.setLineCap(.round); ctx.setLineJoin(.round)
        ctx.setStrokeColor(.black); ctx.setFillColor(.black)
        // Towers and deck: one stroke with rounded corners.
        let frame = CGMutablePath()
        frame.move(to: CGPoint(x: 3, y: towerTop)); frame.addLine(to: CGPoint(x: 3, y: 5.4))
        frame.addQuadCurve(to: CGPoint(x: 4.9, y: 3.5), control: CGPoint(x: 3, y: 3.5))
        frame.addLine(to: CGPoint(x: 13.1, y: 3.5))
        frame.addQuadCurve(to: CGPoint(x: 15, y: 5.4), control: CGPoint(x: 15, y: 3.5))
        frame.addLine(to: CGPoint(x: 15, y: towerTop))
        // Main cable, open in the middle until the Macs are linked.
        let spans: [ClosedRange<CGFloat>] = state == .idle ? [0...(0.5 - gap / 2), (0.5 + gap / 2)...1] : [0...1]
        for span in spans {
            let steps = 24
            frame.move(to: cablePoint(span.lowerBound))
            for i in 1...steps { frame.addLine(to: cablePoint(span.lowerBound + (span.upperBound - span.lowerBound) * CGFloat(i) / CGFloat(steps))) }
        }
        ctx.addPath(frame); ctx.strokePath()
        ctx.addPath(CGPath(roundedRect: capsule, cornerWidth: capsule.width / 2, cornerHeight: capsule.width / 2, transform: nil)); ctx.fillPath()
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }
}
