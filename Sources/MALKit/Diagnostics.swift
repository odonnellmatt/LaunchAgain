#if canImport(Darwin)
import Foundation
import MALCore

/// Builds a diagnostics bundle the user can attach to a bug report.
///
/// What it deliberately excludes: the contents of any instance data directory. That is
/// where cookies, tokens and session state live. The export records the *size* and
/// *path* of a profile, never a byte of its contents.
public final class Diagnostics {

    private let paths: MALPaths
    private let log: MALLog
    private let sizeCache: DirectorySizeCache

    public init(paths: MALPaths,
                log: MALLog = .silent,
                sizeCache: DirectorySizeCache? = nil) {
        self.paths = paths
        self.log = log
        self.sizeCache = sizeCache ?? DirectorySizeCache(paths: paths)
    }

    public static let excludedFromExport = [
        "instance data directories (cookies, tokens, local storage, caches)",
        "Keychain contents",
        "account labels are included only if you leave them in — review the file before sharing",
    ]

    public func generateReport(registry: Registry, scanner: AppScanner) -> String {
        var out: [String] = []
        func section(_ t: String) { out.append(""); out.append("## \(t)"); out.append("") }

        out.append("# LaunchAgain — diagnostics")
        out.append("Generated \(ISO8601DateFormatter().string(from: Date()))")
        out.append("")
        out.append("This file contains no instance data, no credentials and no cookies.")
        out.append("Excluded: " + Diagnostics.excludedFromExport.joined(separator: "; ") + ".")

        section("System")
        let pi = ProcessInfo.processInfo
        out.append("- macOS: \(pi.operatingSystemVersionString)")
        out.append("- Machine: \(Self.hardwareModel()) (\(Self.currentArchitecture()))")
        out.append("- Rosetta translated: \(Self.isTranslated() ? "yes" : "no")")
        out.append("- Physical memory: \(FSOps.humanBytes(Int64(pi.physicalMemory)))")

        section("Launcher")
        out.append("- Support directory: \(paths.support.path)")
        out.append("- Bundles directory: \(paths.bundlesDir.path)")
        out.append("- System bundles directory: \(paths.systemBundlesDir.path)"
                   + (FileManager.default.fileExists(atPath: paths.systemBundlesDir.path)
                      ? "" : " (not created — no instance has needed it)"))
        out.append("- Registry recovered from backup: \(registry.recoveredFromBackup ? "yes" : "no")")
        for tool in [ProcessRunner.Tool.codesign, .iconutil, .cp, .lipo, .spctl] {
            out.append("- \(tool.rawValue): \(tool.exists ? "present" : "MISSING")")
        }
        if let shim = try? BundleAssembler.locateShimBinary() {
            out.append("- mal-shim: \(shim.path)")
        } else {
            out.append("- mal-shim: NOT FOUND — instances cannot be built")
        }

        section("Managed applications")
        for app in registry.allApps {
            out.append("### \(app.displayName) (\(app.appKey))")
            out.append("- Source: \(app.sourcePath)")
            out.append("- Source version: \(app.sourceVersion)")
            out.append("- Next instance number: \(app.nextInstanceNumber)")
            if let facts = try? scanner.fullFacts(at: URL(fileURLWithPath: app.sourcePath)) {
                let v = Compatibility.evaluate(facts)
                out.append("- Runtime: \(facts.runtime.rawValue), signed: \(facts.isSigned), hardened: \(facts.hasHardenedRuntime), sandboxed: \(facts.isSandboxed)")
                out.append("- Architectures: \(facts.architectures.joined(separator: ", "))")
                out.append("- Updater: \(facts.updater.rawValue)")
                out.append("- Tier: \(v.tier.rawValue)")
            } else {
                out.append("- (could not rescan source)")
            }
            for i in app.instances {
                out.append("")
                out.append("  Instance #\(i.number) — \(i.name.isEmpty ? "(unnamed)" : i.name)")
                out.append("  - id: \(i.id.uuidString)")
                out.append("  - mode: \(i.mode.rawValue)")
                out.append("  - bundle: \(i.bundlePath) (\(FileManager.default.fileExists(atPath: i.bundlePath) ? "present" : "MISSING"))")
                out.append("  - cloned bundle id: \(i.clonedBundleIdentifier)")
                out.append("  - built from version: \(i.builtFromSourceVersion)")
                let size = sizeCache.size(of: URL(fileURLWithPath: i.dataPath))
                out.append("  - profile size: \(FSOps.humanBytes(size))")
                if !i.buildNotes.isEmpty {
                    out.append("  - notes:")
                    for n in i.buildNotes { out.append("      · \(n)") }
                }
                if FileManager.default.fileExists(atPath: i.bundlePath) {
                    let signer = CodeSigner(log: .silent)
                    let verify = (try? signer.verify(bundle: URL(fileURLWithPath: i.bundlePath))) ?? "FAILED"
                    out.append("  - signature: \(verify.replacingOccurrences(of: "\n", with: " / "))")
                }
            }
            out.append("")
        }

        section("Recent log")
        let logFile = paths.logsDir.appendingPathComponent("launchagain.log")
        if let d = try? Data(contentsOf: logFile) {
            out.append("```")
            out.append(String(decoding: d.suffix(32 * 1024), as: UTF8.self))
            out.append("```")
        } else {
            out.append("(no log file)")
        }

        return out.joined(separator: "\n")
    }

    @discardableResult
    public func export(registry: Registry, scanner: AppScanner, to url: URL) throws -> URL {
        let text = generateReport(registry: registry, scanner: scanner)
        try AtomicFile.write(Data(text.utf8), to: url, keepBackup: false)
        log.info("exported diagnostics to \(url.path)")
        return url
    }

    // MARK: - Hardware facts

    public static func currentArchitecture() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    /// True when this process is running under Rosetta 2.
    public static func isTranslated() -> Bool {
        var ret: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("sysctl.proc_translated", &ret, &size, nil, 0) == -1 { return false }
        return ret == 1
    }

    public static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        return String(cString: buf)
    }
}
#endif
