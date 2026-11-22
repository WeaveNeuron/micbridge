import Cocoa
import SwiftUI

/// MicBridge's mark: a suspension bridge whose two towers are the two
/// Macs, with a small microphone resting in the dip of its cable. The
/// bridge is the shape; the microphone is the detail. Drawn from code at
/// every size, for the app icon and the windows (the menu bar uses a plain
/// microphone, `MenuIcon`, which stays legible at 18 pt).
enum BrandMark {
    struct Style {
        /// Stroke width, in a 100-unit box.
        var line: CGFloat = 6.5
        /// Microphone width, in a 100-unit box.
        var capsule: CGFloat = 15
    }

    /// Draws the mark into `rect` (y up).
    static func draw(in ctx: CGContext, rect: CGRect, color: CGColor, style: Style = Style()) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.minY)
        ctx.scaleBy(x: rect.width / 100, y: rect.height / 100)
        ctx.setFillColor(color); ctx.setStrokeColor(color)
        ctx.setLineWidth(style.line); ctx.setLineCap(.round); ctx.setLineJoin(.round)

        let half = style.line / 2, deck: CGFloat = 14, top: CGFloat = 86, dip: CGFloat = 28
        // The cable leaves exactly from the tower tops, so their round caps coincide.
        let attach = top - half
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 14, y: deck)); path.addLine(to: CGPoint(x: 14, y: top - half))
        path.move(to: CGPoint(x: 86, y: deck)); path.addLine(to: CGPoint(x: 86, y: top - half))
        path.move(to: CGPoint(x: 5 + half, y: deck)); path.addLine(to: CGPoint(x: 95 - half, y: deck))
        let knee = dip + (attach - dip) * 0.3
        path.move(to: CGPoint(x: 14, y: attach))
        path.addCurve(to: CGPoint(x: 50, y: dip), control1: CGPoint(x: 21, y: knee), control2: CGPoint(x: 33, y: dip))
        path.addCurve(to: CGPoint(x: 86, y: attach), control1: CGPoint(x: 67, y: dip), control2: CGPoint(x: 79, y: knee))
        ctx.addPath(path); ctx.strokePath()

        let w = style.capsule
        let capsule = CGRect(x: 50 - w / 2, y: 40, width: w, height: 74 - 40)
        ctx.addPath(CGPath(roundedRect: capsule, cornerWidth: w / 2, cornerHeight: w / 2, transform: nil)); ctx.fillPath()
        ctx.restoreGState()
    }
}

enum BrandArt {
    static let tileTop = CGColor(srgbRed: 0.21, green: 0.48, blue: 0.96, alpha: 1)
    static let tileBottom = CGColor(srgbRed: 0.14, green: 0.39, blue: 0.88, alpha: 1)

    private static func context(_ px: Int) -> CGContext {
        CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    /// The app icon at `px` pixels, on the macOS icon grid: an 824/1024
    /// rounded square (continuous corners) with the system's soft shadow.
    /// Small sizes get heavier strokes so the mark stays clear.
    static func appIcon(pixels px: Int, shadow: Bool = true) -> CGImage {
        let n = CGFloat(px), ctx = context(px)
        let unit = n / 1024
        let body = CGRect(x: 100 * unit, y: 100 * unit, width: 824 * unit, height: 824 * unit)
        let tile = RoundedRectangle(cornerRadius: 185 * unit, style: .continuous).path(in: body).cgPath
        if shadow {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -10 * unit), blur: 22 * unit, color: CGColor(gray: 0, alpha: 0.28))
            ctx.addPath(tile); ctx.setFillColor(tileBottom); ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.saveGState()
        ctx.addPath(tile); ctx.clip()
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [tileTop, tileBottom] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
        ctx.restoreGState()
        ctx.addPath(tile); ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.12)); ctx.setLineWidth(max(1, 2 * unit)); ctx.strokePath()

        let small = px <= 32, medium = px <= 64
        let glyph = body.insetBy(dx: body.width * (small ? 0.15 : 0.19), dy: body.width * (small ? 0.15 : 0.19))
        let style = BrandMark.Style(line: small ? 9.5 : medium ? 8 : 6.5, capsule: small ? 19 : 15)
        BrandMark.draw(in: ctx, rect: glyph, color: CGColor(gray: 1, alpha: 1), style: style)
        return ctx.makeImage()!
    }

    private static var images: [CGFloat: NSImage] = [:]
    static func appIconImage(points: CGFloat = 128) -> NSImage {
        if let image = images[points] { return image }
        let image = NSImage(size: NSSize(width: points, height: points))
        for scale in [1, 2] {
            let px = Int(points) * scale
            let rep = NSBitmapImageRep(cgImage: appIcon(pixels: px)); rep.size = image.size
            image.addRepresentation(rep)
        }
        images[points] = image
        return image
    }

    /// `MicBridge --render-icons <dir>`: AppIcon.iconset plus enlarged
    /// menu bar glyphs for checking. The checked-in Resources/AppIcon.icns
    /// is made from the iconset with `iconutil -c icns`.
    static func renderIcons(to directory: URL) throws {
        let iconset = directory.appendingPathComponent("AppIcon.iconset")
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
                try png(appIcon(pixels: points * scale)).write(to: iconset.appendingPathComponent(name))
            }
        }
        for state in MenuIconState.allCases {
            for scale in [1, 2] {
                let px = 18 * scale
                guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                                 hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
                rep.size = NSSize(width: 18, height: 18)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                MenuIcon.image(state).draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
                NSGraphicsContext.restoreGraphicsState()
                try rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("menubar-\(state)-\(scale)x.png"))
            }
        }
    }
    private static func png(_ image: CGImage) -> Data {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) ?? Data()
    }
}

/// The app icon in a window (panel header, onboarding, About).
struct AppIconView: View {
    var size: CGFloat = 32
    var body: some View {
        Image(nsImage: BrandArt.appIconImage(points: max(16, (size * 1.0).rounded())))
            .resizable().interpolation(.high).frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
