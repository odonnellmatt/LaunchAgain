import Foundation

/// A rectangle in Electron's global display coordinate space: origin at the top-left of
/// the main display, with positive Y extending down. Core Graphics display bounds use the
/// same convention on macOS.
public struct MALScreenRect: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }

    fileprivate var isValid: Bool {
        x.isFinite && y.isFinite && width.isFinite && height.isFinite
            && width > 0 && height > 0
    }

    fileprivate func intersection(with other: MALScreenRect) -> MALScreenRect? {
        let left = max(x, other.x)
        let top = max(y, other.y)
        let right = min(maxX, other.maxX)
        let bottom = min(maxY, other.maxY)
        guard right > left, bottom > top else { return nil }
        return MALScreenRect(x: left, y: top, width: right - left, height: bottom - top)
    }
}

/// Full and usable bounds for one active display. `bounds` is written back to Electron's
/// `displayBounds`; `visibleFrame` excludes the menu bar and Dock and is used to position
/// the rescued window. The first value supplied to the repairer is treated as the main
/// display when the saved display no longer exists.
public struct MALDisplayGeometry: Equatable, Sendable {
    public var bounds: MALScreenRect
    public var visibleFrame: MALScreenRect

    public init(bounds: MALScreenRect, visibleFrame: MALScreenRect) {
        self.bounds = bounds
        self.visibleFrame = visibleFrame
    }
}

public enum WindowStateRepairOutcome: Equatable, Sendable {
    case fileAbsent
    case unchanged
    case repaired
    case unsupported
}

/// Repairs the small, top-level `window-state.json` schema used by Electron applications
/// such as Claude Desktop. Unknown keys are preserved. Files with another shape, files
/// larger than one MiB, and symbolic links are left untouched.
///
/// This is intentionally narrow: LaunchAgain does not edit arbitrary vendor preferences.
/// It acts only when the saved title bar is unreachable on every active display, and it
/// keeps the first original file beside it as `window-state.json.launchagain-backup`.
public enum ElectronWindowStateRepairer {
    public static let filename = "window-state.json"
    public static let backupFilename = "window-state.json.launchagain-backup"
    private static let maximumFileSize = 1_048_576

    public static func repairIfNeeded(profileDirectory: URL,
                                      displays: [MALDisplayGeometry]) throws
        -> WindowStateRepairOutcome {
        let file = profileDirectory.appendingPathComponent(filename, isDirectory: false)
        let manager = FileManager.default
        guard manager.fileExists(atPath: file.path) else { return .fileAbsent }

        let values = try file.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              fileSize <= maximumFileSize,
              !displays.isEmpty,
              displays.allSatisfy({ $0.bounds.isValid && $0.visibleFrame.isValid }) else {
            return .unsupported
        }

        let original = try Data(contentsOf: file, options: [.mappedIfSafe])
        let originalPermissions = try manager.attributesOfItem(atPath: file.path)[.posixPermissions]
        guard var state = (try? JSONSerialization.jsonObject(with: original)) as? [String: Any],
              let savedWindow = rect(from: state),
              let savedDisplay = (state["displayBounds"] as? [String: Any]).flatMap(rect(from:)),
              savedWindow.isValid,
              savedDisplay.isValid else {
            return .unsupported
        }

        guard !hasReachableTitleBar(savedWindow, displays: displays) else {
            return .unchanged
        }

        let target = bestTarget(for: savedDisplay, displays: displays)
        let corrected = centredWindow(savedWindow, in: target.visibleFrame)
        state["x"] = jsonNumber(corrected.x)
        state["y"] = jsonNumber(corrected.y)
        state["width"] = jsonNumber(corrected.width)
        state["height"] = jsonNumber(corrected.height)
        state["displayBounds"] = dictionary(from: target.bounds)

        let backup = profileDirectory.appendingPathComponent(backupFilename, isDirectory: false)
        if !manager.fileExists(atPath: backup.path) {
            try original.write(to: backup, options: .withoutOverwriting)
            try copyPermissions(from: file, to: backup)
        }

        let repaired = try JSONSerialization.data(
            withJSONObject: state,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try repaired.write(to: file, options: .atomic)
        if let originalPermissions {
            try manager.setAttributes(
                [.posixPermissions: originalPermissions], ofItemAtPath: file.path)
        }
        return .repaired
    }

    /// A draggable portion of the title bar must be present. Content merely grazing a
    /// screen edge is not enough: that is the thin, immovable visual remnant users see
    /// after disconnecting a larger display.
    private static func hasReachableTitleBar(_ window: MALScreenRect,
                                             displays: [MALDisplayGeometry]) -> Bool {
        let titleHeight = min(window.height, 44)
        let titleBar = MALScreenRect(x: window.x, y: window.y,
                                     width: window.width, height: titleHeight)
        let requiredWidth = min(window.width, 160)
        let requiredHeight = min(titleHeight, 28)
        return displays.contains { display in
            guard let visible = titleBar.intersection(with: display.visibleFrame) else {
                return false
            }
            return visible.width >= requiredWidth && visible.height >= requiredHeight
        }
    }

    private static func bestTarget(for savedDisplay: MALScreenRect,
                                   displays: [MALDisplayGeometry]) -> MALDisplayGeometry {
        var best: (area: Double, display: MALDisplayGeometry)?
        for display in displays {
            let overlap = savedDisplay.intersection(with: display.bounds)
            let area = (overlap?.width ?? 0) * (overlap?.height ?? 0)
            if area > (best?.area ?? 0) { best = (area, display) }
        }
        return best?.display ?? displays[0]
    }

    private static func centredWindow(_ saved: MALScreenRect,
                                      in visible: MALScreenRect) -> MALScreenRect {
        let horizontalMargin = min(24, visible.width * 0.05)
        let verticalMargin = min(24, visible.height * 0.05)
        let width = min(saved.width, max(1, visible.width - 2 * horizontalMargin))
        let height = min(saved.height, max(1, visible.height - 2 * verticalMargin))
        return MALScreenRect(
            x: visible.x + (visible.width - width) / 2,
            y: visible.y + (visible.height - height) / 2,
            width: width,
            height: height)
    }

    private static func rect(from object: [String: Any]) -> MALScreenRect? {
        guard let x = number(object["x"]),
              let y = number(object["y"]),
              let width = number(object["width"]),
              let height = number(object["height"]) else { return nil }
        return MALScreenRect(x: x, y: y, width: width, height: height)
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let result = number.doubleValue
        return result.isFinite ? result : nil
    }

    private static func jsonNumber(_ value: Double) -> NSNumber {
        let rounded = value.rounded()
        if abs(value - rounded) < 0.000_001 { return NSNumber(value: Int64(rounded)) }
        return NSNumber(value: value)
    }

    private static func dictionary(from rect: MALScreenRect) -> [String: NSNumber] {
        [
            "x": jsonNumber(rect.x),
            "y": jsonNumber(rect.y),
            "width": jsonNumber(rect.width),
            "height": jsonNumber(rect.height),
        ]
    }

    private static func copyPermissions(from source: URL, to destination: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        if let permissions = attributes[.posixPermissions] {
            try FileManager.default.setAttributes(
                [.posixPermissions: permissions], ofItemAtPath: destination.path)
        }
    }
}
