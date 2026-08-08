#if canImport(Darwin)
import Foundation
import AppKit
import MALCore

/// Generates the numbered icon for an instance.
///
/// Requirements that shaped this:
///   • The number is the primary identifier, so it must stay legible at 16 px, not just
///     look good at 1024. Colour is decoration — it is never the only thing
///     distinguishing two instances, because that would fail for anyone with a
///     colour-vision deficiency.
///   • Multi-digit numbers must not shrink into illegibility, so the badge grows into a
///     pill for 2+ digits rather than cramming digits into a fixed circle.
///   • The original icon must remain recognisable, so the badge occupies a corner and
///     is deliberately not centred.
///   • The source application's own icon file is never modified.
public final class IconFactory {

    /// The sizes an `.iconset` must contain for macOS to render correctly everywhere
    /// from the Cmd-Tab switcher to Finder's gallery view.
    static let iconsetSizes: [(name: String, points: Int, scale: Int)] = [
        ("icon_16x16",      16, 1), ("icon_16x16@2x",    16, 2),
        ("icon_32x32",      32, 1), ("icon_32x32@2x",    32, 2),
        ("icon_128x128",   128, 1), ("icon_128x128@2x", 128, 2),
        ("icon_256x256",   256, 1), ("icon_256x256@2x", 256, 2),
        ("icon_512x512",   512, 1), ("icon_512x512@2x", 512, 2),
    ]

    private let log: MALLog
    private let cacheDir: URL

    public init(cacheDir: URL, log: MALLog = .silent) {
        self.cacheDir = cacheDir
        self.log = log
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    // MARK: - Public API

    /// Loads the best available source icon: the app's own `.icns` if present,
    /// otherwise whatever Launch Services renders for it (which covers apps that ship
    /// only an asset catalogue).
    public static func loadSourceIcon(appBundle: URL) -> NSImage {
        if let icns = AppScanner.sourceIconURL(at: appBundle),
           let img = NSImage(contentsOf: icns) {
            return img
        }
        return NSWorkspace.shared.icon(forFile: appBundle.path)
    }

    /// Renders a single preview bitmap. Used by the badge editor in the UI so the user
    /// sees the real output before committing to a build.
    public func preview(sourceIcon: NSImage, number: Int, badge: BadgeSpec, pixelSize: Int = 256) -> NSImage {
        let rep = render(sourceIcon: sourceIcon, number: number, badge: badge, pixels: pixelSize)
        let img = NSImage(size: NSSize(width: pixelSize, height: pixelSize))
        if let rep { img.addRepresentation(rep) }
        return img
    }

    /// Builds a complete `.icns` at `destination`. Returns the destination on success.
    @discardableResult
    public func buildICNS(sourceIcon: NSImage,
                          number: Int,
                          badge: BadgeSpec,
                          destination: URL) throws -> URL {
        let work = cacheDir.appendingPathComponent("build-\(UUID().uuidString)")
        let iconset = work.appendingPathComponent("icon.iconset")
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        for entry in Self.iconsetSizes {
            let px = entry.points * entry.scale
            guard let rep = render(sourceIcon: sourceIcon, number: number, badge: badge, pixels: px),
                  let png = rep.representation(using: .png, properties: [:]) else {
                throw MALError.iconGenerationFailed("could not render \(entry.name) at \(px)px")
            }
            try png.write(to: iconset.appendingPathComponent("\(entry.name).png"))
        }

        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destination)

        let r = try ProcessRunner.run(.iconutil,
                                      ["-c", "icns", iconset.path, "-o", destination.path],
                                      timeout: 120)
        guard r.succeeded, FileManager.default.fileExists(atPath: destination.path) else {
            throw MALError.iconGenerationFailed("iconutil: \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        log.info("generated numbered icon #\(number) at \(destination.lastPathComponent)")
        return destination
    }

    // MARK: - Drawing

    func render(sourceIcon: NSImage, number: Int, badge: BadgeSpec, pixels: Int) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: pixels, height: pixels)

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high

        let canvas = NSRect(x: 0, y: 0, width: pixels, height: pixels)
        NSColor.clear.setFill()
        canvas.fill()

        // Base icon, preserving transparency and aspect ratio.
        sourceIcon.draw(in: canvas, from: .zero, operation: .sourceOver, fraction: 1.0,
                        respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])

        drawBadge(number: number, badge: badge, in: canvas)
        return rep
    }

    private func drawBadge(number: Int, badge: BadgeSpec, in canvas: NSRect) {
        let text = "\(number)"
        let side = canvas.width
        let digits = text.count

        // Small sizes need a proportionally *bigger* badge, not the same fraction.
        //
        // At 512 px a badge at 0.36 of the edge is a generous disc. At 32 px — which is
        // roughly what the Dock draws — the same fraction is 11 px, and after the inset,
        // the ring and the rounding there are about six pixels left for the digit. It
        // reads as a coloured dot, which fails the one thing the badge is for. So the
        // scale, the inset and the decoration are all a function of the pixel size, and
        // the badge is allowed to take more of a small icon than a large one.
        let scale: CGFloat
        switch side {
        case ..<24:  scale = max(BadgeSpec.clampScale(badge.scale), 0.58)
        case ..<40:  scale = max(BadgeSpec.clampScale(badge.scale), 0.50)
        case ..<80:  scale = max(BadgeSpec.clampScale(badge.scale), 0.44)
        default:     scale = BadgeSpec.clampScale(badge.scale)
        }

        // Height is a fixed fraction of the icon; width grows with digit count so the
        // number never has to shrink to fit. This is what keeps "10" and "100" as
        // readable as "1".
        let badgeHeight = side * scale
        let extraPerDigit = badgeHeight * 0.42
        let badgeWidth = digits <= 1 ? badgeHeight : badgeHeight + extraPerDigit * CGFloat(digits - 1)

        // Inset far enough that the badge is not clipped by the Dock's own rounding,
        // but not so far that it wastes pixels that the digit needs at 16 and 32.
        let inset = side < 80 ? side * 0.015 : side * 0.045
        let origin: NSPoint
        switch badge.position {
        case .bottomTrailing: origin = NSPoint(x: canvas.maxX - badgeWidth - inset, y: canvas.minY + inset)
        case .bottomLeading:  origin = NSPoint(x: canvas.minX + inset,              y: canvas.minY + inset)
        case .topTrailing:    origin = NSPoint(x: canvas.maxX - badgeWidth - inset, y: canvas.maxY - badgeHeight - inset)
        case .topLeading:     origin = NSPoint(x: canvas.minX + inset,              y: canvas.maxY - badgeHeight - inset)
        }
        let rect = NSRect(origin: origin, size: NSSize(width: badgeWidth, height: badgeHeight))

        let (r, g, b) = badge.rgb
        let fill = NSColor(srgbRed: r, green: g, blue: b, alpha: 1.0)

        let radius = badge.shape == .circle ? badgeHeight / 2 : badgeHeight * 0.28
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

        // A soft drop shadow keeps the badge readable against a light icon; the ring
        // keeps it readable against an icon of the same hue. Below about 48 px both
        // become mush that eats the pixels the digit needs, so the shadow is dropped and
        // the ring is reduced to a single hard pixel.
        let wantsShadow = side >= 48
        NSGraphicsContext.saveGraphicsState()
        if wantsShadow {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowBlurRadius = side * 0.02
            shadow.shadowOffset = NSSize(width: 0, height: -side * 0.006)
            shadow.set()
        }
        fill.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        if badge.outlined {
            let ringWidth = side < 48 ? 1.0 : max(1.0, side * 0.014)
            let ring = NSBezierPath(roundedRect: rect.insetBy(dx: ringWidth / 2, dy: ringWidth / 2),
                                    xRadius: radius, yRadius: radius)
            ring.lineWidth = ringWidth
            NSColor.white.withAlphaComponent(side < 48 ? 1.0 : 0.92).setStroke()
            ring.stroke()
        }

        drawNumber(text, in: rect, iconSide: side, onFill: fill)
    }

    private func drawNumber(_ text: String, in rect: NSRect, iconSide: CGFloat, onFill fill: NSColor) {
        // Pick black or white text by luminance so the number stays high-contrast
        // whatever badge colour the user chose.
        let (r, g, b) = (fill.redComponent, fill.greenComponent, fill.blueComponent)
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let textColor: NSColor = luminance > 0.62 ? .black : .white

        // Start from a size proportional to badge height, then shrink until it fits
        // the badge's inner box. The loop matters at 16 px, where rounding dominates.
        //
        // Small icons get a heavier weight and a larger share of the badge: at Dock size
        // a semibold digit at 70% of the badge disappears into the fill, and the extra
        // stroke weight is what makes it read at all.
        let small = iconSide < 48
        var fontSize = rect.height * (small ? 0.82 : 0.70)
        let weight: NSFont.Weight = small ? .heavy : .bold
        let innerWidth = rect.width * (small ? 0.94 : 0.86)
        var attrs: [NSAttributedString.Key: Any] = [:]
        var size = NSSize.zero

        while fontSize > 1 {
            let font = NSFont.systemFont(ofSize: fontSize, weight: weight)
            attrs = [.font: font, .foregroundColor: textColor]
            size = (text as NSString).size(withAttributes: attrs)
            if size.width <= innerWidth && size.height <= rect.height * 1.02 { break }
            fontSize -= max(0.5, fontSize * 0.06)
        }

        let point = NSPoint(x: rect.midX - size.width / 2,
                            y: rect.midY - size.height / 2)
        (text as NSString).draw(at: point, withAttributes: attrs)
    }
}
#endif
