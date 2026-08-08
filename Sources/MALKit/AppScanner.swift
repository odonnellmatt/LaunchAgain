#if canImport(Darwin)
import Foundation
import AppKit
import MALCore

/// Discovers installed applications and extracts the facts the compatibility rules
/// need. Read-only: this type never writes to, or inside, a source application.
public final class AppScanner {

    private let log: MALLog
    /// Optional, and shared with the dashboard, Health, diagnostics and the CLI.
    /// `fullFacts` measures the whole source bundle, and a source Electron app is tens
    /// of thousands of files; without this, inspecting or rebuilding the same app walks
    /// it again every time.
    private let sizeCache: DirectorySizeCache?

    public init(log: MALLog = .silent, sizeCache: DirectorySizeCache? = nil) {
        self.log = log
        self.sizeCache = sizeCache
    }

    public static var defaultSearchLocations: [URL] {
        var dirs = [URL(fileURLWithPath: "/Applications"),
                    URL(fileURLWithPath: NSHomeDirectory() + "/Applications")]
        // Common nesting: /Applications/Utilities, /Applications/<Vendor>/…
        dirs.append(URL(fileURLWithPath: "/Applications/Utilities"))
        return dirs.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Enumerates `.app` bundles one and two levels deep. Deeper recursion mostly finds
    /// helper apps nested inside other bundles, which are never valid targets.
    public func discoverBundles(in directories: [URL] = AppScanner.defaultSearchLocations) -> [URL] {
        var found: [URL] = []
        var seen = Set<String>()
        let fm = FileManager.default

        for dir in directories {
            guard let entries = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]) else { continue }

            for entry in entries {
                if entry.pathExtension == "app" {
                    if seen.insert(entry.standardizedFileURL.path).inserted { found.append(entry) }
                } else if (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    guard let sub = try? fm.contentsOfDirectory(
                        at: entry, includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles]) else { continue }
                    for s in sub where s.pathExtension == "app" {
                        if seen.insert(s.standardizedFileURL.path).inserted { found.append(s) }
                    }
                }
            }
        }
        return found.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Cheap pass: enough to render a browse list without running `codesign` on
    /// several hundred apps.
    public func quickFacts(at bundleURL: URL) -> AppFacts? {
        guard let info = Self.infoPlist(at: bundleURL) else { return nil }
        var f = AppFacts()
        f.path = bundleURL.standardizedFileURL.path
        f.bundleIdentifier = info["CFBundleIdentifier"] as? String ?? ""
        f.displayName = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? bundleURL.deletingPathExtension().lastPathComponent
        // OpenAI's current Codex desktop bundle is installed as ChatGPT.app and still
        // carries "ChatGPT" in its display-name keys, but its stable bundle identifier
        // is com.openai.codex. Present the product the user is actually selecting.
        if f.bundleIdentifier == "com.openai.codex" {
            f.displayName = "Codex"
        }
        f.executableName = info["CFBundleExecutable"] as? String ?? ""
        f.shortVersion = info["CFBundleShortVersionString"] as? String ?? ""
        f.bundleVersion = info["CFBundleVersion"] as? String ?? ""
        f.declaresURLSchemes = (info["CFBundleURLTypes"] as? [Any])?.isEmpty == false
        f.runtime = Self.detectRuntime(at: bundleURL)
        f.hasMASReceipt = FileManager.default.fileExists(
            atPath: bundleURL.appendingPathComponent("Contents/_MASReceipt/receipt").path)
        f.updater = Self.detectUpdater(at: bundleURL, info: info)
        return f
    }

    /// Full pass: adds code-signing, entitlements and architecture facts. Slower —
    /// three `codesign`/`lipo` invocations — so it runs only for a selected app.
    public func fullFacts(at bundleURL: URL) throws -> AppFacts {
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            throw MALError.sourceNotFound(bundleURL.path)
        }
        guard bundleURL.pathExtension == "app", Self.infoPlist(at: bundleURL) != nil else {
            throw MALError.sourceNotABundle(bundleURL.path)
        }
        guard var f = quickFacts(at: bundleURL) else {
            throw MALError.sourceNotABundle(bundleURL.path)
        }

        let signing = readSigningInfo(at: bundleURL)
        f.signingInspected = true
        f.isSigned = signing.isSigned
        f.hasHardenedRuntime = signing.hardenedRuntime
        f.teamIdentifier = signing.teamID

        let ents = (try? readEntitlements(at: bundleURL)) ?? [:]
        f.entitlementKeys = ents.keys.sorted()
        f.isSandboxed = (ents["com.apple.security.app-sandbox"] as? Bool) == true

        f.architectures = readArchitectures(at: bundleURL, executableName: f.executableName)

        let contents = bundleURL.appendingPathComponent("Contents")
        f.hasPrivilegedHelper = FileManager.default.fileExists(
            atPath: contents.appendingPathComponent("Library/LaunchServices").path)
        f.hasLoginItem = FileManager.default.fileExists(
            atPath: contents.appendingPathComponent("Library/LoginItems").path)
        f.hasXPCServices = FileManager.default.fileExists(
            atPath: contents.appendingPathComponent("XPCServices").path)

        f.bundleSizeBytes = sizeCache?.size(of: bundleURL) ?? FSOps.directorySize(bundleURL)

        log.debug("scanned \(f.displayName) \(f.version): runtime=\(f.runtime.rawValue) signed=\(f.isSigned) hardened=\(f.hasHardenedRuntime) sandboxed=\(f.isSandboxed)")
        return f
    }

    // MARK: - Detection

    public static func infoPlist(at bundleURL: URL) -> [String: Any]? {
        let url = bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: url),
              let obj = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = obj as? [String: Any] else { return nil }
        return dict
    }

    public static func isLaunchAgainGeneratedBundle(at bundleURL: URL) -> Bool {
        infoPlist(at: bundleURL)?["MALGeneratedBy"] as? String == "LaunchAgain"
    }

    /// Runtime detection is by structure, not by name matching, so it works for apps we
    /// have never heard of — including the ones that rename the Chromium framework.
    ///
    /// The order matters. `app.asar` is checked before the framework shape because
    /// several Electron apps ship a framework named after themselves (ChatGPT's is
    /// "Codex Framework.framework"), and calling those Chromium rather than Electron
    /// would be wrong even though both accept `--user-data-dir`.
    public static func detectRuntime(at bundleURL: URL) -> RuntimeKind {
        let fm = FileManager.default
        let contents = bundleURL.appendingPathComponent("Contents")
        let fw = contents.appendingPathComponent("Frameworks")

        // Chrome's "install as app" shortcuts look like applications and are not: the
        // executable is a loader that asks an installed browser to open one site.
        if let info = infoPlist(at: bundleURL),
           info["CrAppModeShortcutID"] != nil || info["CrAppModeShortcutURL"] != nil
            || (info["CFBundleExecutable"] as? String) == "app_mode_loader" {
            return .webAppShortcut
        }

        if fm.fileExists(atPath: fw.appendingPathComponent("Electron Framework.framework").path) {
            return .electron
        }
        // An asar archive is Electron's application container and nothing else uses it.
        for candidate in ["Resources/app.asar", "Resources/app/package.json", "Resources/electron.asar"] {
            if fm.fileExists(atPath: contents.appendingPathComponent(candidate).path) { return .electron }
        }
        if fm.fileExists(atPath: fw.appendingPathComponent("Chromium Framework.framework").path) {
            return .chromium
        }

        // Chrome, Brave, Edge and every other Chromium fork rename the content framework
        // and nest the helper apps *inside* it, at Versions/<v>/Helpers/. Looking only in
        // Contents/Frameworks — as this used to — missed all of them and reported the
        // browsers as plain native apps.
        if let entries = try? fm.contentsOfDirectory(atPath: fw.path) {
            for entry in entries where entry.hasSuffix(".framework") {
                let framework = fw.appendingPathComponent(entry)
                if frameworkLooksChromium(framework) { return .chromium }
            }
        }

        if fm.fileExists(atPath: contents.appendingPathComponent("MacOS").path) {
            return .native
        }
        return .unknown
    }

    /// A Chromium content framework has two tells that no ordinary framework has: helper
    /// applications for the renderer/GPU processes, and compiled `.pak` resource bundles.
    private static func frameworkLooksChromium(_ framework: URL) -> Bool {
        let fm = FileManager.default
        var versionDirs: [URL] = [framework]
        let versions = framework.appendingPathComponent("Versions")
        if let vs = try? fm.contentsOfDirectory(atPath: versions.path) {
            versionDirs.append(contentsOf: vs.map { versions.appendingPathComponent($0) })
        }
        for dir in versionDirs {
            let helpers = dir.appendingPathComponent("Helpers")
            if let apps = try? fm.contentsOfDirectory(atPath: helpers.path),
               apps.contains(where: { $0.hasSuffix(".app") && $0.localizedCaseInsensitiveContains("helper") }) {
                return true
            }
            let resources = dir.appendingPathComponent("Resources")
            if let res = try? fm.contentsOfDirectory(atPath: resources.path),
               res.contains(where: { $0.hasSuffix(".pak") }) {
                return true
            }
        }
        return false
    }

    static func detectUpdater(at bundleURL: URL, info: [String: Any]) -> UpdaterFramework {
        let fm = FileManager.default
        let fw = bundleURL.appendingPathComponent("Contents/Frameworks")
        if fm.fileExists(atPath: fw.appendingPathComponent("Sparkle.framework").path)
            || info["SUFeedURL"] != nil {
            return .sparkle
        }
        if fm.fileExists(atPath: fw.appendingPathComponent("Squirrel.framework").path)
            || fm.fileExists(atPath: fw.appendingPathComponent("ShipIt").path) {
            return .squirrel
        }
        if let entries = try? fm.contentsOfDirectory(atPath: fw.path),
           entries.contains(where: { $0.localizedCaseInsensitiveContains("squirrel") }) {
            return .squirrel
        }
        return .none
    }

    // MARK: - codesign / lipo

    struct SigningInfo {
        var isSigned = false
        var hardenedRuntime = false
        var teamID: String?
        var isAdHoc = false
    }

    func readSigningInfo(at bundleURL: URL) -> SigningInfo {
        var info = SigningInfo()
        guard let r = try? ProcessRunner.run(.codesign, ["-dvvv", bundleURL.path], timeout: 60) else {
            return info
        }
        let text = r.stderr + r.stdout          // codesign -d writes to stderr
        info.isSigned = r.succeeded && text.contains("Identifier=")
        // `CodeDirectory … flags=0x10000(runtime)` marks Hardened Runtime.
        info.hardenedRuntime = text.contains("(runtime)") || text.contains("runtime)")
        info.isAdHoc = text.contains("Signature=adhoc")
        if let line = text.split(separator: "\n").first(where: { $0.hasPrefix("TeamIdentifier=") }) {
            let v = line.replacingOccurrences(of: "TeamIdentifier=", with: "")
            info.teamID = (v == "not set") ? nil : v
        }
        return info
    }

    public func readEntitlements(at bundleURL: URL) throws -> [String: Any] {
        // `--entitlements :-` writes the raw blob; `--xml` normalises it to a plist.
        let r = try ProcessRunner.run(.codesign,
                                      ["-d", "--entitlements", ":-", "--xml", bundleURL.path],
                                      timeout: 60)
        guard r.succeeded else { return [:] }
        let data = Data(r.stdout.utf8)
        guard !data.isEmpty,
              let obj = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = obj as? [String: Any] else { return [:] }
        return dict
    }

    func readArchitectures(at bundleURL: URL, executableName: String) -> [String] {
        guard !executableName.isEmpty else { return [] }
        let exe = bundleURL.appendingPathComponent("Contents/MacOS/\(executableName)")
        guard FileManager.default.fileExists(atPath: exe.path),
              let r = try? ProcessRunner.run(.lipo, ["-archs", exe.path], timeout: 30),
              r.succeeded else { return [] }
        return r.stdout.split(separator: " ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Icons

    /// Locates the source `.icns`. Returns nil when the app ships an asset catalogue
    /// only, in which case IconFactory falls back to the Workspace icon.
    public static func sourceIconURL(at bundleURL: URL) -> URL? {
        guard let info = infoPlist(at: bundleURL) else { return nil }
        let resources = bundleURL.appendingPathComponent("Contents/Resources")
        if var name = info["CFBundleIconFile"] as? String {
            if !name.hasSuffix(".icns") { name += ".icns" }
            let u = resources.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        // Conventional fallbacks before giving up.
        for candidate in ["AppIcon.icns", "app.icns", "icon.icns", "electron.icns"] {
            let u = resources.appendingPathComponent(candidate)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: resources.path),
           let first = entries.first(where: { $0.hasSuffix(".icns") }) {
            return resources.appendingPathComponent(first)
        }
        return nil
    }
}
#endif
