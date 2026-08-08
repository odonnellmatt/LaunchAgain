#if canImport(Darwin)
import Foundation
import MALCore

/// Filesystem mechanics of producing a launcher bundle. Split out from
/// `InstanceBuilder` so the orchestration reads as a list of steps rather than a wall
/// of file operations.
public enum BundleAssembler {

    // MARK: - Locating our own shim

    /// The `mal-shim` executable ships inside this application. It is looked up
    /// relative to whatever is running us, so it works identically from the .app, from
    /// the `launchagain` CLI, and from a `swift build` output directory during development.
    public static func locateShimBinary() throws -> URL {
        var candidates: [URL] = []

        // An explicit override, for development and for anyone relocating the tools.
        if let override = ProcessInfo.processInfo.environment["MAL_SHIM_PATH"], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override))
        }
        // Inside the shipped .app.
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appendingPathComponent("mal-shim"))
        }
        // Next to the `launchagain` CLI, which is how a `swift build` tree is laid out.
        let exeDir = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
        candidates.append(exeDir.appendingPathComponent("mal-shim"))
        candidates.append(exeDir.appendingPathComponent("../Resources/mal-shim").standardizedFileURL)

        // Running inside a test bundle: argv[0] is the xctest runner from the toolchain,
        // not our build directory. The products directory is the .xctest bundle's parent.
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            candidates.append(bundle.bundleURL.deletingLastPathComponent()
                .appendingPathComponent("mal-shim"))
        }

        for c in candidates where FileManager.default.isExecutableFile(atPath: c.path) {
            return c.standardizedFileURL
        }
        throw MALError.toolMissing("mal-shim (searched: \(candidates.map(\.path).joined(separator: ", ")))")
    }

    // MARK: - Cloning

    /// Copies a source `.app` using APFS copy-on-write where the filesystem supports it.
    ///
    /// `cp -c` asks for `clonefile(2)`: the clone shares its data blocks with the
    /// original until one of them is written to. On APFS this makes a 700 MB Electron
    /// app clone in well under a second and consume almost no additional space. If the
    /// volume is not APFS, `cp` falls back to a real copy on its own — but we detect
    /// that case first so the UI can warn about the disk cost honestly.
    public static func cloneBundle(from source: URL, to destination: URL, useCloneFile: Bool) throws {
        try FSOps.removeIfExists(destination)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        // -R recursive, -p preserve attributes, -c clonefile, -n never overwrite.
        let flags = useCloneFile ? "-Rpc" : "-Rp"
        let r = try ProcessRunner.run(.cp, [flags, source.path, destination.path], timeout: 900)
        guard r.succeeded else {
            try? FSOps.removeIfExists(destination)
            throw MALError.buildFailed(step: "clone",
                                       underlying: r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard FileManager.default.fileExists(atPath: destination.path) else {
            throw MALError.buildFailed(step: "clone", underlying: "destination missing after copy")
        }
    }

    /// True when both paths live on the same APFS volume, which is what makes
    /// `clonefile` and atomic `rename` possible.
    public static func supportsCloneFile(source: URL, destination: URL) -> Bool {
        let fm = FileManager.default
        let dstDir = destination.deletingLastPathComponent()
        try? fm.createDirectory(at: dstDir, withIntermediateDirectories: true)
        guard let a = try? source.resourceValues(forKeys: [.volumeIdentifierKey]),
              let b = try? dstDir.resourceValues(forKeys: [.volumeIdentifierKey]),
              let va = a.volumeIdentifier, let vb = b.volumeIdentifier else { return false }
        guard va.isEqual(vb) else { return false }
        let fsType = (try? dstDir.resourceValues(forKeys: [.volumeSupportsFileCloningKey]))?
            .volumeSupportsFileCloning
        return fsType ?? false
    }

    // MARK: - Info.plist

    public static func readInfoPlist(bundle: URL) throws -> [String: Any] {
        let url = bundle.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: url),
              let obj = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = obj as? [String: Any] else {
            throw MALError.sourceNotABundle(bundle.path)
        }
        return dict
    }

    public static func writeInfoPlist(_ dict: [String: Any], bundle: URL) throws {
        let url = bundle.appendingPathComponent("Contents/Info.plist")
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try AtomicFile.write(data, to: url, keepBackup: false)
    }

    // MARK: - Recovery metadata

    /// Writes the launcher's durable identity before signing. Because this file lives
    /// inside `Contents/Resources`, codesign seals it along with the launcher.
    public static func writeRecoveryManifest(_ manifest: LauncherRecoveryManifest,
                                             into bundle: URL) throws {
        let resources = bundle.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try AtomicFile.write(
            data,
            to: resources.appendingPathComponent(LauncherRecoveryManifest.filename),
            keepBackup: false)
    }

    /// Reads a recovery record without loading anything else from the app bundle.
    public static func readRecoveryManifest(from bundle: URL) throws -> LauncherRecoveryManifest {
        let url = bundle.appendingPathComponent(
            "Contents/Resources/\(LauncherRecoveryManifest.filename)")
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count <= 256 * 1_024 else {
            throw MALError.registryCorrupt("launcher recovery record is unexpectedly large")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(LauncherRecoveryManifest.self, from: data)
        guard manifest.schemaVersion <= LauncherRecoveryManifest.currentSchemaVersion else {
            throw MALError.registryCorrupt(
                "launcher recovery schema v\(manifest.schemaVersion) is newer than this build")
        }
        return manifest
    }

    /// True when this bundle contains helper applications named after its `CFBundleName`.
    ///
    /// Chromium builds the path to its own child processes by concatenating
    /// `CFBundleName` with " Helper", " Helper (Renderer)" and so on. When that is how an
    /// app is laid out, renaming `CFBundleName` in a clone makes the app fail at startup
    /// with `Unable to find helper app` — so the clone keeps the original name and takes
    /// its visible identity from `CFBundleDisplayName` instead.
    ///
    /// This is checked structurally rather than by assuming "Electron implies helpers":
    /// some apps ship no helpers at all, and those can safely be renamed outright.
    public static func helpersAreNamedAfterBundleName(bundle: URL, info: [String: Any]) -> Bool {
        guard let name = info["CFBundleName"] as? String, !name.isEmpty else { return false }
        let fm = FileManager.default
        let frameworks = bundle.appendingPathComponent("Contents/Frameworks")

        var directories = [frameworks]
        if let entries = try? fm.contentsOfDirectory(atPath: frameworks.path) {
            for e in entries where e.hasSuffix(".framework") {
                let versions = frameworks.appendingPathComponent("\(e)/Versions")
                if let vs = try? fm.contentsOfDirectory(atPath: versions.path) {
                    directories.append(contentsOf: vs.map {
                        versions.appendingPathComponent("\($0)/Helpers")
                    })
                }
            }
        }
        for dir in directories {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            if entries.contains(where: { $0.hasPrefix("\(name) Helper") && $0.hasSuffix(".app") }) {
                return true
            }
        }
        return false
    }

    // MARK: - Shim installation

    /// Renames the real executable aside and puts the shim in its place.
    public static func installShim(into bundle: URL,
                                   shimBinary: URL,
                                   originalExecutableName: String,
                                   shimName: String,
                                   config: InstanceConfig) throws {
        let macOS = bundle.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)

        if !originalExecutableName.isEmpty {
            let original = macOS.appendingPathComponent(originalExecutableName)
            let renamed = macOS.appendingPathComponent(config.realExecutableName)
            guard FileManager.default.fileExists(atPath: original.path) else {
                throw MALError.buildFailed(step: "shim",
                                           underlying: "original executable \(originalExecutableName) not found in the clone")
            }
            try FSOps.removeIfExists(renamed)
            try FileManager.default.moveItem(at: original, to: renamed)
        }

        let shimDestination = macOS.appendingPathComponent(shimName)
        try FSOps.removeIfExists(shimDestination)
        try FileManager.default.copyItem(at: shimBinary, to: shimDestination)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: shimDestination.path)

        try writeInstanceConfig(config, into: bundle)
    }

    public static func writeInstanceConfig(_ config: InstanceConfig, into bundle: URL) throws {
        let resources = bundle.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let text = try config.serialized()
        try AtomicFile.write(Data(text.utf8),
                             to: resources.appendingPathComponent("MALInstance.conf"),
                             keepBackup: false)
    }

    public static func readInstanceConfig(from bundle: URL) throws -> InstanceConfig {
        let url = bundle.appendingPathComponent("Contents/Resources/MALInstance.conf")
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count <= 256 * 1_024,
              let text = String(data: data, encoding: .utf8) else {
            throw MALError.registryCorrupt("launcher instance configuration is unreadable or unexpectedly large")
        }
        return try InstanceConfig.parse(text)
    }

    // MARK: - Lite launcher bundle

    /// Builds a minimal `.app` that contains none of the target application's code —
    /// only our shim, an Info.plist, a numbered icon and the instance config.
    public static func createLiteLauncher(at bundle: URL,
                                          shimBinary: URL,
                                          shimName: String,
                                          infoPlist: [String: Any],
                                          config: InstanceConfig) throws {
        let fm = FileManager.default
        try FSOps.removeIfExists(bundle)
        let contents = bundle.appendingPathComponent("Contents")
        try fm.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)

        let shimDestination = contents.appendingPathComponent("MacOS/\(shimName)")
        try fm.copyItem(at: shimBinary, to: shimDestination)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shimDestination.path)

        try writeInfoPlist(infoPlist, bundle: bundle)
        try writeInstanceConfig(config, into: bundle)

        // Classic four-plus-four type/creator file. Harmless, and some older code paths
        // in Launch Services still look for it.
        try Data("APPL????".utf8).write(to: contents.appendingPathComponent("PkgInfo"))
    }

    // MARK: - Integrity

    /// Fingerprint of the parts of a bundle we promise never to modify. Compared before
    /// and after every build so the "the original application is untouched" claim is
    /// enforced by the code rather than asserted in a README.
    public static func sourceFingerprint(bundle: URL) -> String {
        var parts: [String] = []
        let fm = FileManager.default
        for rel in ["Contents/Info.plist", "Contents/_CodeSignature/CodeResources"] {
            let u = bundle.appendingPathComponent(rel)
            if let d = try? Data(contentsOf: u) {
                parts.append("\(rel):\(d.count):\(simpleDigest(d))")
            } else {
                parts.append("\(rel):absent")
            }
        }
        if let attrs = try? fm.attributesOfItem(atPath: bundle.path),
           let m = attrs[.modificationDate] as? Date {
            parts.append("mtime:\(Int(m.timeIntervalSince1970))")
        }
        return parts.joined(separator: "|")
    }

    /// FNV-1a. Not cryptographic — this detects accidental modification, which is the
    /// actual risk here, and avoids pulling in CryptoKit for a self-check.
    static func simpleDigest(_ data: Data) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}
#endif
