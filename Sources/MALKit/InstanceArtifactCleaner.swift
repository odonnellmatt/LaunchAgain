#if canImport(Darwin)
import Foundation
import MALCore

/// Removes macOS support files keyed to one generated clone identity.
///
/// Electron and macOS may create preferences, updater caches, HTTP storage and saved
/// state outside `--user-data-dir`. Targets are an allow-list of exact paths derived
/// from a cryptographically random LaunchAgain identifier. No source-app identifier,
/// display-name glob, vendor directory or arbitrary registry string is accepted.
///
/// **What this deliberately will not remove**, measured against a real ChatGPT clone:
///
/// · `~/Library/Logs/com.openai.codex/` — written under the *vendor's* identifier, not
///   the clone's, and shared with the original application and every other instance.
///   Removing it when one instance is uninstalled would delete the original's logs.
///
/// · `~/.codex` and other home-directory configuration — the same store the original
///   reads, which is exactly why an instance of such an app is not a separate account
///   (`Compatibility.sharedCredentialStores`). Deleting it on uninstall would sign the
///   user out of every copy of the app, which is the failure this release exists to stop.
///
/// · `~/Library/Group Containers/<TEAMID>.<vendor>` — shared between the vendor's own
///   binaries. Only a group container keyed to the *generated* identifier is a candidate.
///
/// Those are stated in LIMITATIONS.md rather than quietly cleaned, because an
/// uninstaller that removes files it cannot prove it owns is a worse product than one
/// that leaves something behind and says so.
public final class InstanceArtifactCleaner: @unchecked Sendable {
    public struct Report: Sendable, Equatable {
        public var removedPaths: [String] = []
        public var wentToTrash = false
    }

    private let paths: MALPaths
    private let log: MALLog
    private let temporaryDirectory: URL?

    public init(paths: MALPaths,
                log: MALLog = .silent,
                temporaryDirectory: URL? = nil) {
        self.paths = paths
        self.log = log
        let realLibrary = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library").standardizedFileURL
        if let temporaryDirectory {
            self.temporaryDirectory = temporaryDirectory.standardizedFileURL
        } else if paths.userLibrary.standardizedFileURL == realLibrary {
            self.temporaryDirectory = FileManager.default.temporaryDirectory.standardizedFileURL
        } else {
            // An injected/rooted store must never reach into the real user's temp tree.
            self.temporaryDirectory = nil
        }
    }

    public func candidates(for instance: Instance) throws -> [URL] {
        let identifier = instance.clonedBundleIdentifier
        guard Validation.isCloneBundleIdentifier(
            identifier, forNumber: instance.number, instanceID: instance.id) else {
            if identifier.isEmpty { return [] }
            throw MALError.invalidName(
                identifier,
                reason: "refusing associated-file cleanup because this is not the generated identifier for instance #\(instance.number)")
        }

        let library = paths.userLibrary.standardizedFileURL
        var targets = [
            library.appendingPathComponent("Preferences/\(identifier).plist"),
            library.appendingPathComponent("Preferences/\(identifier).plist.lockfile"),
            library.appendingPathComponent("SyncedPreferences/\(identifier).plist"),
            library.appendingPathComponent("Caches/\(identifier)"),
            library.appendingPathComponent("Caches/\(identifier).ShipIt"),
            library.appendingPathComponent(
                "Caches/com.apple.nsurlsessiond/Downloads/\(identifier)"),
            library.appendingPathComponent("Application Support/\(identifier)"),
            library.appendingPathComponent("Saved Application State/\(identifier).savedState"),
            library.appendingPathComponent("HTTPStorages/\(identifier)"),
            library.appendingPathComponent("HTTPStorages/\(identifier).binarycookies"),
            library.appendingPathComponent("WebKit/\(identifier)"),
            library.appendingPathComponent("Cookies/\(identifier).binarycookies"),
            library.appendingPathComponent("Logs/\(identifier)"),
            library.appendingPathComponent("Containers/\(identifier)"),
            library.appendingPathComponent("Application Scripts/\(identifier)"),
            library.appendingPathComponent("LaunchAgents/\(identifier).plist"),
            // An App Group container. A Full clone's entitlements are stripped, so macOS
            // vends it nothing — but the directory is an ordinary one and an unsandboxed
            // app can create it by path. Keyed to the generated identifier and nothing
            // else: the *vendor's* group container is shared with the original
            // application and with every other copy of it, and deleting that would
            // destroy data this instance does not own. See LIMITATIONS.md.
            library.appendingPathComponent("Group Containers/\(identifier)"),
            library.appendingPathComponent("Application Support/CrashReporter/\(identifier)"),
            library.appendingPathComponent("WebKit/WebsiteData/\(identifier)"),
            library.appendingPathComponent("Caches/com.apple.helpd/\(identifier)"),
            library.appendingPathComponent("Preferences/\(identifier).plist.new"),
            library.appendingPathComponent("Autosave Information/\(identifier).plist"),
            // Chromium mirrors an Application Support profile into the same relative
            // path under Caches, independently of its bundle identifier.
            library.appendingPathComponent(
                "Caches/LaunchAgain/instances/\(instance.id.uuidString)"),
        ]

        // CFPreferences may place host-specific domains under Preferences/ByHost.
        let byHost = library.appendingPathComponent("Preferences/ByHost")
        if let names = try? FileManager.default.contentsOfDirectory(atPath: byHost.path) {
            targets.append(contentsOf: names.compactMap { name in
                guard name.hasPrefix(identifier + "."),
                      name.hasSuffix(".plist"),
                      !name.contains("/") else { return nil }
                return byHost.appendingPathComponent(name)
            })
        }

        if let temp = temporaryDirectory {
            // Foundation's per-user caches directory beside T is where some Chromium
            // networking stacks create an exact bundle-ID cache.
            let darwinCache = temp.deletingLastPathComponent().appendingPathComponent("C")
            targets.append(darwinCache.appendingPathComponent(identifier))

            // Singleton sockets/cookies use `<clone-id>.<random>` immediate children of
            // T. The random component is tightly bounded; no recursive prefix scan is
            // permitted.
            if let names = try? FileManager.default.contentsOfDirectory(atPath: temp.path) {
                let prefix = identifier + "."
                targets.append(contentsOf: names.compactMap { name in
                    guard name.hasPrefix(prefix) else { return nil }
                    let suffix = String(name.dropFirst(prefix.count))
                    guard (6...64).contains(suffix.count),
                          suffix.unicodeScalars.allSatisfy({
                              CharacterSet.alphanumerics.contains($0)
                                  || $0 == "_" || $0 == "-"
                          }) else { return nil }
                    return temp.appendingPathComponent(name)
                })
            }
        }

        let libraryTargets = targets.map(\.standardizedFileURL).filter {
            Validation.isPath($0.path, within: library.path)
                && $0.path != library.path
        }
        let temporaryTargets = targets.map(\.standardizedFileURL).filter { candidate in
            guard let temp = temporaryDirectory else { return false }
            let parent = candidate.deletingLastPathComponent().standardizedFileURL
            let darwinCache = temp.deletingLastPathComponent()
                .appendingPathComponent("C").standardizedFileURL
            return parent.path == temp.path || parent.path == darwinCache.path
        }

        return Array(Set(libraryTargets + temporaryTargets))
            .sorted { $0.path < $1.path }
    }

    @discardableResult
    public func removeArtifacts(for instance: Instance) throws -> Report {
        var report = Report()
        let targets = try candidates(for: instance)
        let identifier = instance.clonedBundleIdentifier

        // Removing a preferences plist behind cfprefsd can let its in-memory copy write
        // the file back. For the actual user's Library, ask the system preferences tool
        // to delete this exact, already-validated clone domain first. Rooted tests and
        // alternate stores never invoke a tool against the user's real preferences.
        let realLibrary = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library").standardizedFileURL
        if paths.userLibrary.standardizedFileURL == realLibrary {
            let output = try? ProcessRunner.run(
                executable: "/usr/bin/defaults",
                ["delete", identifier],
                timeout: 10)
            if output?.succeeded == true {
                let preference = realLibrary
                    .appendingPathComponent("Preferences/\(identifier).plist").path
                report.removedPaths.append(preference)
                log.info("cleared associated preference domain: \(identifier)")
            }
        }

        for target in targets {
            // `fileExists` follows symlinks; resource values also let us remove a broken
            // symlink itself without ever following it to its destination.
            let exists = FileManager.default.fileExists(atPath: target.path)
                || (try? target.resourceValues(forKeys: [.isSymbolicLinkKey])
                    .isSymbolicLink) == true
            guard exists else { continue }
            report.wentToTrash = try FSOps.moveToTrash(target) || report.wentToTrash
            if !report.removedPaths.contains(target.path) {
                report.removedPaths.append(target.path)
            }
            log.info("removed associated instance artifact: \(target.path)")
        }
        return report
    }
}
#endif
