#if canImport(Darwin)
import Foundation
import AppKit
import MALCore

/// What an instance inherits from the original application, and what it cannot.
///
/// Two different things get called "permissions" and they behave very differently:
///
///  · **File permissions and entitlements** are properties of the files. A clone copies
///    the bundle with `cp -Rp`, so modes, ownership and timestamps come across intact,
///    and each nested executable is re-signed with the patched version of its own
///    entitlements. `verifyFilePermissionsMatch` checks the first of those for real
///    rather than trusting the flag we passed to `cp`.
///
///  · **Privacy permissions** — camera, microphone, screen recording, Accessibility,
///    Files and Folders — are held by macOS in a protected database, keyed to an app's
///    identity. An instance is a different identity, so it starts with none and asks for
///    its own. That is not an oversight to route around: copying those records would mean
///    granting an app permissions the user never gave it, and the database is protected
///    precisely so that software cannot do that. What this type does instead is show what
///    the app will ask for, using the app's own explanations, and take the user to the
///    place where they decide.
public enum PermissionsInspector {

    public struct DeclaredPermission: Identifiable, Hashable {
        public let id: String
        public let name: String
        /// The app's own explanation, shown verbatim in the macOS prompt.
        public let purpose: String
    }

    /// Privacy usage-description keys, in the order a user is likely to meet them.
    private static let usageKeys: [(key: String, name: String)] = [
        ("NSCameraUsageDescription", "Camera"),
        ("NSMicrophoneUsageDescription", "Microphone"),
        ("NSScreenCaptureUsageDescription", "Screen Recording"),
        ("NSDesktopFolderUsageDescription", "Desktop folder"),
        ("NSDocumentsFolderUsageDescription", "Documents folder"),
        ("NSDownloadsFolderUsageDescription", "Downloads folder"),
        ("NSRemovableVolumesUsageDescription", "Removable volumes"),
        ("NSNetworkVolumesUsageDescription", "Network volumes"),
        ("NSFileProviderDomainUsageDescription", "File provider"),
        ("NSLocationWhenInUseUsageDescription", "Location"),
        ("NSLocationAlwaysAndWhenInUseUsageDescription", "Location"),
        ("NSContactsUsageDescription", "Contacts"),
        ("NSCalendarsUsageDescription", "Calendar"),
        ("NSRemindersUsageDescription", "Reminders"),
        ("NSPhotoLibraryUsageDescription", "Photos"),
        ("NSAppleEventsUsageDescription", "Controlling other apps"),
        ("NSSystemAdministrationUsageDescription", "System administration"),
        ("NSBluetoothAlwaysUsageDescription", "Bluetooth"),
        ("NSSpeechRecognitionUsageDescription", "Speech recognition"),
        ("NSMotionUsageDescription", "Motion"),
        ("NSLocalNetworkUsageDescription", "Local network"),
    ]

    /// The privacy permissions a bundle declares it may ask for, with the app's own
    /// wording. An instance inherits these verbatim, so its prompts read identically to
    /// the original's — only the app doing the asking is different.
    public static func declared(in bundle: URL) -> [DeclaredPermission] {
        guard let info = AppScanner.infoPlist(at: bundle) else { return [] }
        var seen = Set<String>()
        var result: [DeclaredPermission] = []
        for (key, name) in usageKeys {
            guard let purpose = info[key] as? String, !purpose.isEmpty else { continue }
            guard seen.insert(name).inserted else { continue }
            result.append(DeclaredPermission(id: key, name: name, purpose: purpose))
        }
        return result
    }

    /// Compares the POSIX mode of the source bundle and a clone, top level and a sample
    /// of the executables inside it.
    ///
    /// Used by the tests, and available to diagnostics, so "the instance has the same
    /// permissions as the original" is a checked claim rather than an assumption about
    /// what `cp -Rp` did.
    public static func filePermissionsMatch(source: URL, clone: URL) -> (matches: Bool, differences: [String]) {
        let fm = FileManager.default
        var differences: [String] = []

        func mode(_ url: URL) -> Int? {
            (try? fm.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
        }

        if let a = mode(source), let b = mode(clone), a != b {
            differences.append("bundle: \(String(a, radix: 8)) → \(String(b, radix: 8))")
        }

        // Everything the clone kept from the original, by relative path. The shim and the
        // renamed executable are ours and are expected to differ in name, not in mode.
        guard let walker = fm.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return (differences.isEmpty, differences)
        }
        let sourceRoot = source.standardizedFileURL.path
        var checked = 0
        for case let url as URL in walker {
            guard checked < 400 else { break }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(sourceRoot) else { continue }
            let relative = String(path.dropFirst(sourceRoot.count))
            let counterpart = URL(fileURLWithPath: clone.standardizedFileURL.path + relative)
            guard fm.fileExists(atPath: counterpart.path) else { continue }
            checked += 1
            if let a = mode(url), let b = mode(counterpart), a != b {
                differences.append("\(relative): \(String(a, radix: 8)) → \(String(b, radix: 8))")
            }
        }
        return (differences.isEmpty, differences)
    }

    /// Opens the pane where privacy permissions are granted, since that decision is the
    /// user's to make and nowhere else.
    public static func openPrivacySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!
        NSWorkspace.shared.open(url)
    }
}
#endif
