#if canImport(Darwin)
import Foundation
import MALCore

/// Finds inconsistencies between the registry and what is actually on disk.
///
/// It reports and never deletes. Anything it finds is either the result of a crash or
/// of the user moving things around by hand, and in both cases silently removing files
/// would be the wrong response — an "orphan" data directory is somebody's signed-in
/// profile.
public final class OrphanSweeper {

    public struct Finding: Identifiable, Sendable {
        public enum Kind: Sendable, Equatable {
            case missingBundle          // registry says it exists; it does not
            case unregisteredBundle     // a launcher bundle with no registry entry
            case orphanDataDirectory    // a profile with no registry entry
            case staleStaging           // leftovers in .staging from an interrupted build
            case sourceMissing          // the original app has moved or been deleted
            case sourceUpdated          // the original app is a newer version than the instance
            case migrationConflict      // same profile UUID exists in legacy and current roots
            case orphanPreferenceDomain // a clone's preferences plist with no instance
            case staleRemovalMarker     // a removal marker nothing can act on any more
        }
        public let id = UUID()
        public let kind: Kind
        public let path: String
        public let detail: String
        public let sizeBytes: Int64
        /// Safe to remove without losing anything a user would miss.
        public let safeToClean: Bool

        /// A few words naming what this is, for a list row.
        ///
        /// `detail` is the full explanation and stays exactly as it was — it becomes the
        /// row's tooltip. Most findings here are informational, and a wall of sentences
        /// made the ones that need action impossible to pick out.
        public var summary: String {
            switch kind {
            case .missingBundle:          return "Launcher missing from disk"
            case .unregisteredBundle:
                return safeToClean ? "Leftover launcher, safe to remove"
                                   : "Unregistered launcher, kept"
            case .orphanDataDirectory:    return "Leftover profile — may hold a sign-in"
            case .staleStaging:           return "Old staging item"
            case .sourceMissing:          return "Source application moved or deleted"
            case .sourceUpdated:          return "Source application has an update"
            case .migrationConflict:      return "Profile exists in two stores"
            case .orphanPreferenceDomain: return "Stranded preference domain"
            case .staleRemovalMarker:     return "Removal marker nothing can act on"
            }
        }

        /// Whether this finding names something on disk the user can ask us to delete.
        /// A missing bundle or an updated source app is a *report*, not a thing to remove.
        public var isRemovable: Bool {
            switch kind {
            case .unregisteredBundle: return safeToClean
            case .orphanDataDirectory: return true
            case .staleStaging: return false
            case .staleRemovalMarker: return true
            case .missingBundle, .sourceMissing, .sourceUpdated, .migrationConflict,
                    .orphanPreferenceDomain:
                return false
            }
        }
    }

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

    public func sweep(registry: Registry,
                      onSizeScan: ((String) -> Void)? = nil) -> [Finding] {
        var findings: [Finding] = []
        let fm = FileManager.default
        let all = registry.allInstances

        let knownBundlePaths = Set(all.map { URL(fileURLWithPath: $0.instance.bundlePath).standardizedFileURL.path })
        let knownInstanceIDs = Set(all.map { $0.instance.id.uuidString })

        // 1. Registry entries whose bundle has vanished.
        for (_, inst) in all where !fm.fileExists(atPath: inst.bundlePath) {
            findings.append(Finding(kind: .missingBundle,
                                    path: inst.bundlePath,
                                    detail: "Instance #\(inst.number) \"\(inst.name)\" has no launcher on disk. Rebuild it, or remove it from the list. Its data is untouched.",
                                    sizeBytes: 0,
                                    safeToClean: false))
        }

        // 2. Bundles in our directories that the registry does not know about.
        // Both launcher roots: an instance installed in /Applications/LaunchAgain is as
        // capable of being stranded as one in ~/Applications/LaunchAgain, and a sweep
        // that only looked at one would report the other's launchers as missing while
        // never noticing the launchers themselves.
        let bundleEntries = paths.bundleRoots.flatMap { root in
            (try? fm.contentsOfDirectory(at: root,
                                         includingPropertiesForKeys: nil,
                                         options: [.skipsHiddenFiles])) ?? []
        }
        do {
            let entries = bundleEntries
            for e in entries where e.pathExtension == "app" {
                let p = e.standardizedFileURL.path
                if !knownBundlePaths.contains(p) {
                    let verified = try? LauncherIdentityVerifier.verify(
                        bundle: e,
                        paths: paths,
                        requireManifest: true)

                    // Ownership is necessary but not sufficient. A verified launcher is
                    // only disposable when removing it cannot orphan a profile.
                    //
                    // It can, and only can, when the profile is still on disk *and* the
                    // registry no longer knows the instance — because then this launcher's
                    // recovery manifest is the one remaining thing that can reattach that
                    // profile to a name, a number and an account. Deleting it turns a
                    // recoverable instance into an anonymous directory.
                    //
                    // A duplicate of a launcher whose instance is still registered is a
                    // different case entirely: the registry is the record, so the copy is
                    // disposable. Checking only for the profile conflated the two.
                    var strandedProfile: URL?
                    if let id = verified.flatMap({ Self.instanceID(of: $0) }),
                       !knownInstanceIDs.contains(id.uuidString) {
                        let profile = paths.instanceDir(id)
                        if FileManager.default.fileExists(atPath: profile.path) {
                            strandedProfile = profile
                        }
                    }

                    let detail: String
                    if verified == nil {
                        detail = "An unregistered application is present, but LaunchAgain cannot prove that it created it. It will not be deleted."
                    } else if let strandedProfile {
                        detail = "A verified LaunchAgain launcher that no instance refers to — but its profile is still on disk at "
                            + strandedProfile.lastPathComponent
                            + ", and this launcher is the only remaining record of which instance that profile belongs to. Use Refresh Installed Launchers to recover it, or uninstall the instance once it is back."
                    } else {
                        detail = "A verified LaunchAgain launcher exists that no instance refers to, and its profile is already gone. It can be removed safely."
                    }

                    findings.append(Finding(kind: .unregisteredBundle,
                                            path: p,
                                            detail: detail,
                                            sizeBytes: sizeCache.size(of: e, onScanStart: onSizeScan),
                                            safeToClean: verified != nil && strandedProfile == nil))
                }
            }
        }

        // 3. Profiles with no owning instance.
        if let entries = try? fm.contentsOfDirectory(at: paths.instancesDir,
                                                     includingPropertiesForKeys: nil,
                                                     options: [.skipsHiddenFiles]) {
            for e in entries {
                let name = e.lastPathComponent
                guard UUID(uuidString: name) != nil else { continue }
                if !knownInstanceIDs.contains(name) {
                    findings.append(Finding(kind: .orphanDataDirectory,
                                            path: e.path,
                                            detail: "An instance profile with no matching entry. This may contain a signed-in session — review before deleting.",
                                            sizeBytes: sizeCache.size(of: e, onScanStart: onSizeScan),
                                            safeToClean: false))
                }
            }
        }

        // 4. Interrupted builds, in the staging directory of every launcher root.
        let stagingEntries = paths.bundleRoots.flatMap { root in
            (try? fm.contentsOfDirectory(at: paths.stagingDir(in: root),
                                         includingPropertiesForKeys: [.contentModificationDateKey],
                                         options: [.skipsHiddenFiles])) ?? []
        }
        do {
            let entries = stagingEntries
            for e in entries {
                // Ask FileManager directly rather than relying only on URL resource
                // value caching. A URL may have cached its metadata before a builder
                // updated the directory, which made an old staging item look new.
                let attributes = try? fm.attributesOfItem(atPath: e.path)
                let modified = attributes?[.modificationDate] as? Date
                    ?? (try? e.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate
                let age = -(modified?.timeIntervalSinceNow ?? 0)
                guard age > 300 else { continue }   // ignore anything a live build may own
                findings.append(Finding(kind: .staleStaging,
                                        path: e.path,
                                        detail: "An old staging item is present. It is report-only because age alone cannot prove that another slow build is not using it.",
                                        sizeBytes: sizeCache.size(of: e, onScanStart: onSizeScan),
                                        safeToClean: false))
            }
        }

        // 5. Source applications that moved, or moved on.
        for app in registry.allApps {
            if !fm.fileExists(atPath: app.sourcePath) {
                findings.append(Finding(kind: .sourceMissing,
                                        path: app.sourcePath,
                                        detail: "\(app.displayName) is no longer at this path. Instances still run, but they cannot be rebuilt until you point the launcher at it again.",
                                        sizeBytes: 0,
                                        safeToClean: false))
                continue
            }
            let stale = app.staleInstances
            if !stale.isEmpty {
                findings.append(Finding(kind: .sourceUpdated,
                                        path: app.sourcePath,
                                        detail: "\(app.displayName) is now \(app.sourceVersion); \(stale.count) instance\(stale.count == 1 ? "" : "s") were built from an older version. Rebuild to pick up the update — your data is preserved.",
                                        sizeBytes: 0,
                                        safeToClean: false))
            }
        }

        // 6. A profile UUID found in both the previous and current support roots.
        // Migration writes these markers once and never merges either profile.
        for conflict in Migration.unresolvedConflicts(in: paths) {
            findings.append(Finding(
                kind: .migrationConflict,
                path: conflict.legacyPath,
                detail: "Profile \(conflict.instanceID.uuidString) exists in both the legacy and current support directories. Both copies were preserved. Review them manually; LaunchAgain will not merge, replace, move or delete either profile.",
                sizeBytes: 0,
                safeToClean: false))
        }

        // 7. A clone's preferences plist whose instance no longer exists.
        //
        // This is the residue a disk cleaner finds after an instance is gone, and it has
        // three real causes: a launcher dragged to the Trash instead of uninstalled, an
        // instance created against an alternate `--root` store (whose artifact cleanup is
        // scoped to that root's library, not this one), and a removal interrupted before
        // the preference domain was cleared.
        //
        // Report only. The name pattern proves the file was generated by LaunchAgain,
        // but it does not prove which instance owned it, and that is not enough authority
        // to delete: the finding carries the exact `defaults delete` command instead.
        findings.append(contentsOf: orphanPreferenceDomains(registry: registry))

        // 8. A removal marker written by an earlier version, in plain text rather than as
        // a journal record. `resumePendingRemovals` cannot act on one — it has no
        // recorded deletion scope — so it warned on every process start forever, while
        // permanently excluding its instance id from reconciliation. Report it with an
        // action instead of logging about it indefinitely.
        findings.append(contentsOf: staleRemovalMarkers(registry: registry))

        sizeCache.pruneMissingPaths()
        log.info("orphan sweep: \(findings.count) finding(s)")
        return findings
    }

    private func staleRemovalMarkers(registry: Registry) -> [Finding] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let names = (try? FileManager.default.contentsOfDirectory(
            atPath: paths.removalTombstonesDir.path)) ?? []

        return names.compactMap { name -> Finding? in
            guard name.hasSuffix(".removed"), !name.contains("/"),
                  let id = UUID(uuidString: String(name.dropLast(".removed".count)))
            else { return nil }
            let url = paths.removalTombstonesDir.appendingPathComponent(name)

            // A marker carrying a usable journal record is live work, not residue:
            // `resumePendingRemovals` will finish it on the next start.
            let record = (try? Data(contentsOf: url)).flatMap {
                try? decoder.decode(RemovalJournalRecord.self, from: $0)
            }
            if let record, record.instance.id == id,
               record.schemaVersion <= RemovalJournalRecord.currentSchemaVersion {
                return nil
            }
            // Nor is it residue while its instance is still registered — the marker is
            // then protecting a deletion that is still in progress.
            guard registry.instance(id) == nil else { return nil }

            // Deliberately "any launcher at all", and named so. This marker carries no
            // instance identity beyond its UUID, so there is nothing to match a
            // particular bundle against; what the wording below needs to know is only
            // whether the store is empty, which changes "nothing else refers to it" from
            // true to merely likely.
            let anyLauncherExists = paths.bundleRoots.contains { root in
                ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
                    .contains { $0.hasSuffix(".app") }
            }
            let profileExists = FileManager.default.fileExists(
                atPath: paths.instanceDir(id).path)
            let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size]
                        as? NSNumber)?.int64Value ?? 0

            var detail = "A removal marker left by an earlier version, with no recorded "
                + "deletion scope, so LaunchAgain cannot finish or undo anything from it. "
                + "It is not doing any work — but while it exists, instance "
                + "\(id.uuidString) can never be recovered from an installed launcher."
            if profileExists {
                detail += " That instance's profile is still on disk; removing this marker "
                    + "lets Refresh Installed Launchers recover it."
            } else if !anyLauncherExists {
                detail += " Nothing else on disk refers to it."
            }
            return Finding(kind: .staleRemovalMarker,
                           path: url.path,
                           detail: detail,
                           sizeBytes: size,
                           safeToClean: false)
        }
        .sorted { $0.path < $1.path }
    }

    private func orphanPreferenceDomains(registry: Registry) -> [Finding] {
        let preferences = paths.userLibrary.appendingPathComponent("Preferences")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: preferences.path)
        else { return [] }

        let live = Set(registry.allInstances.map { $0.instance.clonedBundleIdentifier }
            .filter { !$0.isEmpty })

        return names.compactMap { name -> Finding? in
            guard name.hasSuffix(".plist"), !name.contains("/") else { return nil }
            let identifier = String(name.dropLast(".plist".count))
            guard Validation.looksLikeCloneBundleIdentifier(identifier),
                  !live.contains(identifier) else { return nil }
            let url = preferences.appendingPathComponent(name)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))
                .flatMap { $0.fileSize }.map(Int64.init) ?? 0
            return Finding(
                kind: .orphanPreferenceDomain,
                path: url.path,
                detail: "Preferences for a generated instance that no longer exists. "
                    + "LaunchAgain will not delete this: the filename shows it was generated "
                    + "here, but not which instance owned it. To remove it yourself, run  "
                    + "defaults delete \(identifier)",
                sizeBytes: size,
                safeToClean: false)
        }
        .sorted { $0.path < $1.path }
    }

    /// Removes one finding that the user has explicitly asked to remove.
    ///
    /// This is the counterpart to `clean`, which only touches things nobody would miss.
    /// A leftover profile is somebody's signed-in session, so it is never swept up
    /// automatically — but leaving the user no way to delete it at all was worse: the
    /// health check would report it forever and the only remedy was Finder.
    ///
    /// The guard that matters is unchanged: `assertDeletable` refuses anything that is
    /// not inside the launcher's own two directories, so this can only ever remove
    /// something this program created.
    @discardableResult
    public func remove(_ finding: Finding) throws -> Int64 {
        let url = URL(fileURLWithPath: finding.path)
        switch finding.kind {
        case .unregisteredBundle:
            guard finding.safeToClean else {
                throw MALError.invalidPath(
                    finding.path,
                    reason: "ownership of this application has not been proven")
            }
            _ = try LauncherIdentityVerifier.verify(
                bundle: url,
                paths: paths,
                requireManifest: true)
        case .orphanDataDirectory:
            let standardized = url.standardizedFileURL
            guard standardized.deletingLastPathComponent().path
                    == paths.instancesDir.standardizedFileURL.path,
                  UUID(uuidString: standardized.lastPathComponent) != nil else {
                throw MALError.invalidPath(
                    finding.path,
                    reason: "an orphan profile must be one immediate UUID child of the instances directory")
            }
        case .staleStaging:
            throw MALError.notSupported(
                reason: "Staging cleanup is disabled without a live cross-process lease.")
        case .missingBundle, .sourceMissing, .sourceUpdated, .migrationConflict:
            throw MALError.invalidPath(
                finding.path,
                reason: "this health finding is a report, not an owned filesystem object")
        case .staleRemovalMarker:
            let standardized = url.standardizedFileURL
            guard standardized.pathExtension == "removed",
                  let id = UUID(uuidString: standardized.deletingPathExtension().lastPathComponent)
            else {
                throw MALError.invalidPath(
                    finding.path,
                    reason: "a removal marker must be a UUID-named .removed file")
            }
            try paths.assertRemovalTombstone(standardized.path, for: id)
        case .orphanPreferenceDomain:
            // Reported, never removed. The filename shows LaunchAgain generated it, but
            // not which instance owned it, and a name pattern is not ownership. It also
            // lives outside both directories `assertDeletable` permits, so this refusal
            // is belt and braces rather than the only guard.
            throw MALError.invalidPath(
                finding.path,
                reason: "an orphaned preference domain is reported, not removed; use the defaults command in the finding")
        }
        try paths.assertDeletable(finding.path)
        let size = finding.sizeBytes > 0 ? finding.sizeBytes : sizeCache.size(of: url)
        // The Trash, like every other removal in this product. The uninstall banner
        // already promises "you can put it back if this was a mistake"; a health-check
        // cleanup that quietly unlinked instead was the one path that broke that promise.
        let trashed = (try? FSOps.moveToTrash(url)) ?? false
        if !trashed {
            try FSOps.removeIfExists(url)
        }
        log.info("removed \(finding.kind) at \(finding.path) on explicit request "
                 + "(\(FSOps.humanBytes(size)), \(trashed ? "moved to the Trash" : "deleted; this volume has no Trash"))")
        return size
    }

    /// The instance a verified launcher belongs to, from its manifest or its sealed
    /// config's profile path.
    private static func instanceID(of verified: LauncherIdentityVerifier.Verified) -> UUID? {
        if let manifest = verified.manifest { return manifest.instance.id }
        let components = URL(fileURLWithPath: verified.config.dataPath).pathComponents
        for component in components.reversed() {
            if let id = UUID(uuidString: component) { return id }
        }
        return nil
    }

    /// Removes only findings explicitly marked safe, and only inside our own directories.
    @discardableResult
    public func clean(_ findings: [Finding]) -> (removed: Int, freedBytes: Int64) {
        var count = 0
        var freed: Int64 = 0
        for f in findings where f.safeToClean {
            if (try? remove(f)) != nil {
                count += 1
                freed += f.sizeBytes
            }
        }
        log.info("cleaned \(count) item(s), freed \(FSOps.humanBytes(freed))")
        return (count, freed)
    }
}
#endif
