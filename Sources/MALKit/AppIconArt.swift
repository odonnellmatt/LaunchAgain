#if canImport(Darwin)
import Foundation
import AppKit
import MALCore

/// Draws the launcher's own icon.
///
/// It is generated rather than shipped as a binary asset for two reasons: the repository
/// stays free of opaque blobs, and the icon is drawn by the same Core Graphics path the
/// product uses for instance badges — so if badge rendering breaks, the app's own icon
/// breaks too and someone notices immediately.
///
/// The image is three stacked app tiles carrying 1, 2 and 3: the product in one picture.
public enum AppIconArt {

    public static func render(pixels: Int) -> NSBitmapImageRep? {
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

        let side = CGFloat(pixels)
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: side, height: side).fill()

        // A white rounded tile, not transparency.
        //
        // Transparent art reads as grey in the Dock, because what shows through is the
        // Dock's own background — so the icon changed shade with the wallpaper and never
        // looked like a finished application. macOS's own convention is an opaque
        // rounded-rectangle tile, and this is that tile, inset by the standard amount so
        // it lines up with its neighbours in the Dock rather than overflowing them.
        let plateInset = side * 0.055
        let plate = NSRect(x: plateInset, y: plateInset,
                           width: side - plateInset * 2, height: side - plateInset * 2)
        let plateRadius = plate.width * 0.225
        let platePath = NSBezierPath(roundedRect: plate,
                                     xRadius: plateRadius, yRadius: plateRadius)

        NSGraphicsContext.saveGraphicsState()
        let plateShadow = NSShadow()
        plateShadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
        plateShadow.shadowBlurRadius = side * 0.02
        plateShadow.shadowOffset = NSSize(width: 0, height: -side * 0.006)
        plateShadow.set()
        // Very slightly off-white at the bottom so the tile has some depth without
        // reading as grey.
        let plateGradient = NSGradient(colors: [
            NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0),
            NSColor(srgbRed: 0.945, green: 0.949, blue: 0.957, alpha: 1.0),
        ])
        plateGradient?.draw(in: platePath, angle: -90)
        NSGraphicsContext.restoreGraphicsState()

        // A hairline so the white tile still has an edge on a white wallpaper.
        NSColor.black.withAlphaComponent(0.07).setStroke()
        platePath.lineWidth = max(1, side * 0.004)
        platePath.stroke()

        // The art sits inside the plate rather than inside the whole canvas.
        let margin = side * 0.155
        let content = NSRect(x: margin, y: margin, width: side - margin * 2, height: side - margin * 2)

        // Noticeably larger tiles: 0.62 of the content box left the three of them
        // looking like a diagram of the product rather than an icon of it.
        let tileSide = content.width * 0.74
        let step = (content.width - tileSide) / 2
        let colors = [1, 2, 3].map { BadgeSpec.suggestedColor(forNumber: $0) }

        // Back to front, so the front tile overlaps the ones behind it.
        for (i, hex) in colors.enumerated().reversed() {
            let origin = NSPoint(x: content.minX + step * CGFloat(i),
                                 y: content.maxY - tileSide - step * CGFloat(i))
            let rect = NSRect(origin: origin, size: NSSize(width: tileSide, height: tileSide))
            // The tiles behind the front one are only visible along their bottom and
            // right edges, so their numbers go there. Centred, they would be hidden and
            // the icon would show one numeral instead of three.
            drawTile(rect, hex: hex, number: i + 1, iconSide: side, dimmed: i > 0,
                     numberInVisibleCorner: i > 0, visibleWidth: step)
        }
        return rep
    }

    private static func drawTile(_ rect: NSRect,
                                 hex: String,
                                 number: Int,
                                 iconSide: CGFloat,
                                 dimmed: Bool,
                                 numberInVisibleCorner: Bool = false,
                                 visibleWidth: CGFloat = 0) {
        let radius = rect.width * 0.22
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

        let spec = BadgeSpec(colorHex: hex)
        let (r, g, b) = spec.rgb
        let base = NSColor(srgbRed: r, green: g, blue: b, alpha: 1.0)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
        shadow.shadowBlurRadius = iconSide * 0.022
        shadow.shadowOffset = NSSize(width: 0, height: -iconSide * 0.008)
        shadow.set()

        let gradient = NSGradient(colors: [
            base.blended(withFraction: 0.22, of: .white) ?? base,
            base.blended(withFraction: 0.14, of: .black) ?? base,
        ])
        gradient?.draw(in: path, angle: -90)
        NSGraphicsContext.restoreGraphicsState()

        // A hairline keeps the tiles separated when they overlap.
        NSColor.white.withAlphaComponent(dimmed ? 0.45 : 0.75).setStroke()
        path.lineWidth = max(1, iconSide * 0.006)
        path.stroke()

        // The number, in the same weight the instance badges use.
        //
        // A `repeat`, not a `while`, and this is the whole of Ma-3. At 16 px the back
        // tiles' starting size was about 0.89, so `while size > 1` never entered the
        // body: `attrs` stayed empty and `measured` stayed `.zero`, and
        // `draw(at:withAttributes: [:])` then fell back to the system 12 pt **black**
        // font, drawn from an origin computed off a zero size — sixteen opaque near-black
        // pixels of 256, in the icon the application ships. The loop must choose a font
        // at least once, and the numeral must be skipped rather than drawn unstyled when
        // the tile genuinely cannot carry it.
        let text = "\(number)" as NSString
        let budget = numberInVisibleCorner ? visibleWidth : rect.width
        let startingSize = max(numberInVisibleCorner ? budget * 0.62 : rect.height * 0.52,
                               minimumNumeralPointSize)
        var size = startingSize
        var attrs: [NSAttributedString.Key: Any] = [:]
        var measured = NSSize.zero
        repeat {
            let font = NSFont.systemFont(ofSize: size, weight: .bold)
            attrs = [.font: font, .foregroundColor: NSColor.white.withAlphaComponent(0.96)]
            measured = text.size(withAttributes: attrs)
            if measured.width <= budget * 0.6 { break }
            size -= max(0.5, size * 0.06)
        } while size > minimumNumeralPointSize

        // Below this the glyph is a smudge rather than a number, and a smudge in the
        // wrong colour is what shipped. Leave the tile clean instead: at 16 px the icon
        // reads as three stacked tiles, which is the right thing for it to read as.
        guard measured.width <= budget, measured.height <= rect.height else { return }

        let origin: NSPoint
        if numberInVisibleCorner {
            // Centred in the strip of this tile the tile in front does not cover.
            origin = NSPoint(x: rect.maxX - visibleWidth / 2 - measured.width / 2,
                             y: rect.minY + visibleWidth / 2 - measured.height / 2)
        } else {
            origin = NSPoint(x: rect.midX - measured.width / 2,
                             y: rect.midY - measured.height / 2)
        }
        text.draw(at: origin, withAttributes: attrs)
    }

    /// The smallest point size worth drawing a numeral at. Below this the shrink loop
    /// stops and the caller declines to draw rather than emitting something illegible.
    private static let minimumNumeralPointSize: CGFloat = 4

    /// Writes a complete `.icns` at `destination`, via an iconset and `iconutil`.
    @discardableResult
    public static func writeICNS(to destination: URL) throws -> URL {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("mal-appicon-\(UUID().uuidString.prefix(8))")
        let iconset = work.appendingPathComponent("icon.iconset")
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        for entry in IconFactory.iconsetSizes {
            let px = entry.points * entry.scale
            guard let rep = render(pixels: px),
                  let png = rep.representation(using: .png, properties: [:]) else {
                throw MALError.iconGenerationFailed("could not render \(entry.name)")
            }
            try png.write(to: iconset.appendingPathComponent("\(entry.name).png"))
        }

        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destination)
        let r = try ProcessRunner.run(.iconutil, ["-c", "icns", iconset.path, "-o", destination.path],
                                      timeout: 120)
        guard r.succeeded, FileManager.default.fileExists(atPath: destination.path) else {
            throw MALError.iconGenerationFailed("iconutil: \(r.stderr)")
        }
        return destination
    }
}
#endif
