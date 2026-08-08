#if canImport(Darwin)
import Foundation
import MALCore

/// Rebuilds registry entries from launcher bundles that are still installed.
///
/// Scanning is intentionally shallow and bounded: only immediate `.app` children of
/// LaunchAgain's own applications directory are considered, and recovery JSON is capped
/// by `BundleAssembler`. No icons, bundle contents or profile files are retained.
public final class LauncherReconciler: @unchecked Sendable {
    public struct Report: Equatable, Sendable {
        public var launchersFound = 0
        public var legacyLaunchersFound = 0
        public var recoveredInstanceIDs: [UUID] = []
        public var relocatedInstanceIDs: [UUID] = []
        public var conflicts: [String] = []
        public var unreadableLaunchers: [String] = []

        public var changed: Bool {
            !recoveredInstanceIDs.isEmpty || !relocatedInstanceIDs.isEmpty
        }
    }

    private let paths: MALPaths
    private let scanner: AppScanner
    private let log: MALLog

    public init(paths: MALPaths, scanner: AppScanner, log: MALLog = .silent) {
        self.paths = paths
        self.scanner = scanner
        self.log = log
    }

    @discardableResult
    public func reconcile(registry: Registry) throws -> Report {
        var report = Report()
        let scanned = scan(report: &report)
        let grouped = Dictionary(grouping: scanned, by: { $0.instance.id })
        let duplicateIDs = Set(grouped.compactMap { id, rows in rows.count > 1 ? id : nil })
        for id in duplicateIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            let names = grouped[id, default: []]
                .map { URL(fileURLWithPath: $0.instance.bundlePath).lastPathComponent }
                .sorted()
            report.conflicts.append(
                "Multiple verified launchers claim instance \(id.uuidString): \(names.joined(separator: ", ")). None was used.")
        }
        let manifests = scanned.filter { !duplicateIDs.contains($0.instance.id) }
        let tombstones = tombstonedIDs()
        let merged = try registry.reconcile(manifests, excluding: tombstones)
        report.recoveredInstanceIDs = merged.recoveredInstanceIDs
        report.relocatedInstanceIDs = merged.relocatedInstanceIDs
        report.conflicts.append(contentsOf: merged.conflicts)

        if report.changed {
            log.info("launcher reconciliation recovered \(report.recoveredInstanceIDs.count) and relocated \(report.relocatedInstanceIDs.count) instance(s)")
        }
        for conflict in report.conflicts {
            log.warn("launcher reconciliation conflict: \(conflict)")
        }
        return report
    }

    /// Marks an ID before its registry row is removed. Each tombstone is its own tiny
    /// atomic file so one damaged document can never forget all prior deletions.
    public func markRemoved(_ instance: Instance, deleteData: Bool) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicFile.write(
            try encoder.encode(RemovalJournalRecord(
                instance: instance,
                deleteData: deleteData)),
            to: paths.removalTombstoneFile(instance.id),
            keepBackup: false)
    }

    /// Compatibility helper used by old tests/migrations. New uninstall paths always
    /// call `markRemoved(_ instance:)` so restart recovery has a complete identity.
    public func markRemoved(_ id: UUID) throws {
        try AtomicFile.write(
            Data("removed \(Date().timeIntervalSince1970)\n".utf8),
            to: paths.removalTombstoneFile(id),
            keepBackup: false)
    }

    /// Clears the short-lived deletion marker once the launcher and registry row are
    /// both gone. Interrupted removals keep their marker; completed uninstalls leave no
    /// per-instance recovery metadata behind.
    public func clearRemoved(_ id: UUID) throws {
        let marker = paths.removalTombstoneFile(id)
        try paths.assertRemovalTombstone(marker.path, for: id)
        try FSOps.removeIfExists(marker)
    }

    public func pendingRemovalRecords() -> [(id: UUID, record: RemovalJournalRecord?)] {
        let names = (try? FileManager.default.contentsOfDirectory(
            atPath: paths.removalTombstonesDir.path)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return names.compactMap { name in
            guard name.hasSuffix(".removed"),
                  let id = UUID(uuidString: String(name.dropLast(".removed".count))) else {
                return nil
            }
            let url = paths.removalTombstonesDir.appendingPathComponent(name)
            let record = (try? Data(contentsOf: url)).flatMap {
                try? decoder.decode(RemovalJournalRecord.self, from: $0)
            }
            guard (record?.schemaVersion ?? 0) <= RemovalJournalRecord.currentSchemaVersion,
                  record?.instance.id == id || record == nil else {
                return (id, nil)
            }
            return (id, record)
        }.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    private func scan(report: inout Report) -> [LauncherRecoveryManifest] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        // Both launcher roots. An instance that had to be installed in
        // /Applications/LaunchAgain must be recoverable from its own bundle exactly like
        // one in the user's Applications folder; scanning only the default root would
        // leave it permanently unrecoverable after a lost registry.
        let entries = paths.bundleRoots.flatMap { root in
            (try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles])) ?? []
        }
        guard !entries.isEmpty else { return [] }

        var manifests: [LauncherRecoveryManifest] = []
        var legacySourceCache: [String: (path: String, name: String, version: String)]?

        for bundle in entries where bundle.pathExtension.lowercased() == "app" {
            autoreleasepool {
                let values = try? bundle.resourceValues(forKeys: keys)
                guard values?.isDirectory == true, values?.isSymbolicLink != true,
                      paths.bundleRoot(containing: bundle.standardizedFileURL.path) != nil else {
                    return
                }

                if var manifest = try? BundleAssembler.readRecoveryManifest(from: bundle),
                   (try? LauncherIdentityVerifier.verify(
                    bundle: bundle,
                    paths: paths,
                    requireManifest: true)) != nil {
                    manifest.instance.bundlePath = bundle.standardizedFileURL.path
                    manifests.append(manifest)
                    report.launchersFound += 1
                    return
                }

                if let legacy = legacyManifest(
                    at: bundle,
                    sourceCache: &legacySourceCache) {
                    manifests.append(legacy)
                    report.launchersFound += 1
                    report.legacyLaunchersFound += 1
                } else {
                    report.unreadableLaunchers.append(bundle.lastPathComponent)
                }
            }
        }
        return manifests
    }

    /// Compatibility path for launchers produced before recovery manifests shipped.
    /// It reconstructs identity from the existing sealed Info.plist and shim config.
    private func legacyManifest(
        at bundle: URL,
        sourceCache: inout [String: (path: String, name: String, version: String)]?
    ) -> LauncherRecoveryManifest? {
        guard let info = try? BundleAssembler.readInfoPlist(bundle: bundle),
              info["MALGeneratedBy"] as? String == "LaunchAgain",
              let config = readConfig(bundle: bundle),
              let id = instanceID(fromDataPath: config.dataPath),
              let clonedID = info["CFBundleIdentifier"] as? String,
              let number = instanceNumber(fromCloneIdentifier: clonedID),
              Validation.isCloneBundleIdentifier(
                clonedID, forNumber: number, instanceID: id) else {
            return nil
        }

        let source: (appKey: String, name: String, path: String, version: String)
        if config.kind == .tool {
            // A launcher built by a release that predates the GUI-only boundary. Its
            // registry key is encoded in the generated bundle identifier, so it is
            // recovered without consulting a table of tools we no longer support, and
            // without looking for the tool on disk — the entry exists to be shown,
            // refused and uninstalled, not launched.
            guard let appKey = LegacyTerminalTool.appKey(fromClonedBundleIdentifier: clonedID) else {
                return nil
            }
            source = (appKey, LegacyTerminalTool.displayName(forAppKey: appKey) ?? appKey, "", "")
        } else if config.mode == .lite, !config.targetAppPath.isEmpty,
                  let original = scanner.quickFacts(at: URL(fileURLWithPath: config.targetAppPath)) {
            source = (original.bundleIdentifier, original.displayName,
                      original.path, original.version)
        } else {
            guard let originalID = info["MALOriginalBundleIdentifier"] as? String,
                  !originalID.isEmpty else { return nil }
            if sourceCache == nil {
                var discovered: [String: (path: String, name: String, version: String)] = [:]
                for url in scanner.discoverBundles() {
                    guard let facts = scanner.quickFacts(at: url),
                          facts.bundleIdentifier != originalID
                            || facts.path != bundle.path else { continue }
                    discovered[facts.bundleIdentifier] = (
                        facts.path, facts.displayName, facts.version)
                }
                sourceCache = discovered
            }
            let found = sourceCache?[originalID]
            let fallbackName = legacySourceName(
                displayTitle: info["CFBundleDisplayName"] as? String ?? bundle.deletingPathExtension().lastPathComponent,
                number: number)
            source = (originalID, found?.name ?? fallbackName,
                      found?.path ?? "", found?.version ?? "")
        }

        let displayTitle = info["CFBundleDisplayName"] as? String
            ?? bundle.deletingPathExtension().lastPathComponent
        let name = legacyInstanceName(
            displayTitle: displayTitle,
            sourceName: source.name,
            number: number)
        let attributes = try? FileManager.default.attributesOfItem(atPath: bundle.path)
        let createdAt = attributes?[.creationDate] as? Date ?? Date()
        let mechanism: IsolationMechanism =
            config.kind == .tool ? .configEnvironment : .userDataDir
        let instance = Instance(
            id: id,
            number: number,
            name: name,
            mode: config.mode,
            mechanism: mechanism,
            bundlePath: bundle.standardizedFileURL.path,
            dataPath: config.dataPath,
            badge: BadgeSpec(colorHex: BadgeSpec.suggestedColor(forNumber: number)),
            builtFromSourceVersion: source.version,
            clonedBundleIdentifier: clonedID,
            extraArguments: config.extraArguments,
            extraEnvironment: config.extraEnvironment,
            createdAt: createdAt,
            buildNotes: ["Recovered from an installed launcher created by an earlier version of LaunchAgain."])
        return LauncherRecoveryManifest(
            appKey: source.appKey,
            appDisplayName: source.name,
            sourcePath: source.path,
            sourceVersion: source.version,
            instance: instance)
    }

    private func readConfig(bundle: URL) -> InstanceConfig? {
        try? BundleAssembler.readInstanceConfig(from: bundle)
    }

    private func tombstonedIDs() -> Set<UUID> {
        let names = (try? FileManager.default.contentsOfDirectory(
            atPath: paths.removalTombstonesDir.path)) ?? []
        return Set(names.compactMap { name in
            guard name.hasSuffix(".removed") else { return nil }
            return UUID(uuidString: String(name.dropLast(".removed".count)))
        })
    }

    private func instanceID(fromDataPath path: String) -> UUID? {
        let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        guard let index = components.lastIndex(of: "instances"),
              components.indices.contains(index + 1) else { return nil }
        return UUID(uuidString: components[index + 1])
    }

    private func instanceNumber(fromCloneIdentifier identifier: String) -> Int? {
        guard let range = identifier.range(
            of: #"\.mal([0-9]+)-[0-9a-fA-F]{8}$"#,
            options: .regularExpression) else { return nil }
        let match = String(identifier[range])
        guard let digits = match.range(of: #"[0-9]+"#, options: .regularExpression) else {
            return nil
        }
        return Int(match[digits])
    }

    private func legacySourceName(displayTitle: String, number: Int) -> String {
        let suffix = " \(number)"
        if let range = displayTitle.range(of: suffix) {
            return String(displayTitle[..<range.lowerBound])
        }
        return displayTitle
    }

    private func legacyInstanceName(displayTitle: String,
                                    sourceName: String,
                                    number: Int) -> String {
        let prefix = "\(sourceName) \(number)"
        guard displayTitle.hasPrefix(prefix) else { return "" }
        var remainder = String(displayTitle.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if remainder.hasPrefix("–") || remainder.hasPrefix("-") {
            remainder.removeFirst()
        }
        return remainder.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif
