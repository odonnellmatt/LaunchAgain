#if canImport(Darwin)
import Foundation
import MALCore

/// Moves an installation from the old "Multiple Apps Launcher" locations to the
/// "LaunchAgain" ones.
///
/// A rename looks cosmetic and is not: every instance bundle contains a config file with
/// **absolute paths** in it, and those paths are sealed inside a code signature. Moving
/// the directories without fixing the configs would leave instances pointing at profiles
/// that no longer exist — the app would start, find nothing, and look freshly signed out.
/// Rewriting the config breaks the seal, so each touched bundle has to be re-signed.
///
/// The order is chosen so that an interruption is survivable: the directories move first
/// (a rename, effectively atomic), then the registry is rewritten, then each bundle is
/// repaired. If the process dies after step one, re-running finishes the job; if a single
/// bundle cannot be repaired it is recorded as needing a rebuild rather than silently
/// left broken.
public enum Migration {

    public struct ConflictRecord: Codable, Hashable, Sendable {
        public let instanceID: UUID
        public let legacyPath: String
        public let currentPath: String
        public let detectedAt: Date
    }

    public struct Report {
        public var moved: [String] = []
        public var repairedBundles: Int = 0
        public var bundlesNeedingRebuild: [String] = []
        public var profileConflicts: [ConflictRecord] = []
        public var didAnything: Bool { !moved.isEmpty || repairedBundles > 0 || !bundlesNeedingRebuild.isEmpty }
    }

    @discardableResult
    public static func migrateIfNeeded(to paths: MALPaths,
                                       from legacy: MALPaths,
                                       log: MALLog = .silent) -> Report {
        var report = Report()
        let fm = FileManager.default

        guard legacy.support.path != paths.support.path else { return report }

        // A UUID on both sides is not a merge opportunity: each directory may contain a
        // different signed-in Chromium profile. Record the conflict durably, then leave
        // both trees byte-for-byte where they are.
        report.profileConflicts = recordProfileConflicts(in: paths, legacy: legacy, log: log)

        // Nothing to do unless the old location holds an actual installation. An empty
        // directory left behind by a previous run is not one, and treating it as one
        // would announce a migration that moved nothing.
        let legacySupportExists = fm.fileExists(atPath: legacy.support.path)
        let legacyBundlesExist = fm.fileExists(atPath: legacy.bundlesDir.path)
        guard legacySupportExists || legacyBundlesExist else { return report }
        guard hasContent(legacy) else {
            // Deliberately left in place. These directories are outside both roots this
            // product is allowed to delete inside, and removing them silently - which is
            // what happened here until this pass, logged at .debug and therefore below
            // the configured level, so there was no record of it at all - contradicts the
            // promise that nothing goes without being asked. `doctor` reports them and
            // `doctor --retire-legacy-store` removes them on an explicit confirmation.
            for old in [legacy.support, legacy.bundlesDir]
            where fm.fileExists(atPath: old.path) && isEffectivelyEmpty(old) {
                log.info("the pre-rename directory at \(old.path) holds nothing worth migrating; leaving it in place — `launchagain doctor --retire-legacy-store` removes it on request")
            }
            return report
        }

        // 1. The support directory: registry, profiles, logs.
        if legacySupportExists {
            if fm.fileExists(atPath: paths.support.path) {
                // Both exist — a partially completed migration, or a new install that has
                // already created its directories. Merge every entry, not just the
                // profiles: leaving registry.json behind would move a user's instances
                // across and then show them an empty list, which is what happened the
                // first time this ran.
                let moved = mergeDirectory(legacy.support, into: paths.support, log: log)
                if moved > 0 { report.moved.append("merged \(legacy.support.path)") }
            } else if move(legacy.support, to: paths.support, log: log) {
                report.moved.append(legacy.support.path)
            }
        }

        // 2. The launcher bundles.
        if legacyBundlesExist {
            if fm.fileExists(atPath: paths.bundlesDir.path) {
                let moved = mergeDirectory(legacy.bundlesDir, into: paths.bundlesDir, log: log)
                if moved > 0 { report.moved.append("merged launchers from \(legacy.bundlesDir.path)") }
            } else if move(legacy.bundlesDir, to: paths.bundlesDir, log: log) {
                report.moved.append(legacy.bundlesDir.path)
            }
        }

        // 3. Rewrite the paths stored in the registry.
        rewriteRegistry(at: paths.registryFile, from: legacy, to: paths, log: log)

        // 4. Repair each bundle's instance config, and re-sign what we touched.
        let repaired = repairBundles(in: paths, legacy: legacy, log: log)
        report.repairedBundles = repaired.repaired
        report.bundlesNeedingRebuild = repaired.failed

        // 5. What is left of the old locations stays there. See the note above: these
        // paths are outside the two roots this product deletes inside, so retiring them
        // is the user's explicit decision, not a side effect of starting the app.
        for old in [legacy.support, legacy.bundlesDir]
        where fm.fileExists(atPath: old.path) && isEffectivelyEmpty(old) {
            log.info("migration left an empty \(old.lastPathComponent) at \(old.path); `launchagain doctor --retire-legacy-store` removes it on request")
        }

        if report.didAnything {
            log.info("migration complete: moved \(report.moved.count), repaired \(report.repairedBundles), needing rebuild \(report.bundlesNeedingRebuild.count)")
        }
        return report
    }

    public static func unresolvedConflicts(in paths: MALPaths) -> [ConflictRecord] {
        let fm = FileManager.default
        let directory = conflictDirectory(in: paths)
        guard let markers = try? fm.contentsOfDirectory(at: directory,
                                                        includingPropertiesForKeys: nil,
                                                        options: [.skipsHiddenFiles]) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return markers.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let record = try? decoder.decode(ConflictRecord.self, from: data) else {
                return nil
            }
            // A marker naming a path that no longer exists describes a collision that
            // cannot happen again. It was previously filtered out of the report but never
            // removed, so it sat in the support directory for good. This is one of our
            // own markers inside our own root, and it is removed rather than retained.
            guard fm.fileExists(atPath: record.legacyPath),
                  fm.fileExists(atPath: record.currentPath) else {
                try? fm.removeItem(at: url)
                return nil
            }
            return record
        }.sorted { $0.instanceID.uuidString < $1.instanceID.uuidString }
    }

    /// True when the old location holds something worth moving: a registry, a launcher,
    /// or an instance profile.
    private static func hasContent(_ legacy: MALPaths) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: legacy.registryFile.path) { return true }
        if let bundles = try? fm.contentsOfDirectory(atPath: legacy.bundlesDir.path),
           bundles.contains(where: { $0.hasSuffix(".app") }) { return true }
        if let instances = try? fm.contentsOfDirectory(atPath: legacy.instancesDir.path),
           instances.contains(where: { UUID(uuidString: $0) != nil }) { return true }
        return false
    }

    private static func isEffectivelyEmpty(_ dir: URL) -> Bool {
        let fm = FileManager.default
        guard let entries = try? fm.subpathsOfDirectory(atPath: dir.path) else { return false }
        // Directories we create ourselves, plus dotfiles, do not count as content.
        let meaningful = entries.filter { path in
            let name = (path as NSString).lastPathComponent
            if name.hasPrefix(".") { return false }
            var isDir: ObjCBool = false
            _ = fm.fileExists(atPath: dir.appendingPathComponent(path).path, isDirectory: &isDir)
            return !isDir.boolValue
        }
        return meaningful.isEmpty
    }

    // MARK: - Steps

    private static func move(_ src: URL, to dst: URL, log: MALLog) -> Bool {
        do {
            try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try FSOps.atomicMove(src, to: dst)
            log.info("moved \(src.lastPathComponent) → \(dst.path)")
            return true
        } catch {
            log.error("could not move \(src.path): \(error)")
            return false
        }
    }

    /// Moves every entry across, recursing into directories that exist on both sides so
    /// that "the destination already has a folder of that name" never means "leave the
    /// contents behind". Anything already present at the destination wins: a newer
    /// installation's data is never overwritten by an older one's.
    @discardableResult
    private static func mergeDirectory(_ src: URL,
                                       into dst: URL,
                                       log: MALLog,
                                       depth: Int = 0) -> Int {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: src.path) else { return 0 }
        try? fm.createDirectory(at: dst, withIntermediateDirectories: true)
        var movedCount = 0

        for entry in entries where entry != ".DS_Store" {
            let from = src.appendingPathComponent(entry)
            let to = dst.appendingPathComponent(entry)

            if !fm.fileExists(atPath: to.path) {
                do {
                    try fm.moveItem(at: from, to: to)
                    log.debug("merged \(entry)")
                    movedCount += 1
                } catch {
                    log.error("could not merge \(entry): \(error)")
                }
                continue
            }

            var fromIsDir: ObjCBool = false
            var toIsDir: ObjCBool = false
            _ = fm.fileExists(atPath: from.path, isDirectory: &fromIsDir)
            _ = fm.fileExists(atPath: to.path, isDirectory: &toIsDir)

            // Recurse only through the launcher's own scaffolding — the support
            // directory itself and the folders inside it. Below that sits an instance's
            // profile, and interleaving the contents of two profiles that happen to
            // share a UUID would produce a directory that is neither one. When both
            // sides have one, the destination wins and the old one is left untouched
            // for the user to look at.
            if fromIsDir.boolValue && toIsDir.boolValue && depth < 1 {
                movedCount += mergeDirectory(from, into: to, log: log, depth: depth + 1)
            } else {
                log.debug("kept the existing \(entry); the old one was left in place")
            }
        }
        return movedCount
    }

    private static func conflictDirectory(in paths: MALPaths) -> URL {
        paths.support.appendingPathComponent("migration-conflicts")
    }

    private static func recordProfileConflicts(in paths: MALPaths,
                                               legacy: MALPaths,
                                               log: MALLog) -> [ConflictRecord] {
        let fm = FileManager.default
        guard let legacyNames = try? fm.contentsOfDirectory(atPath: legacy.instancesDir.path),
              let currentNames = try? fm.contentsOfDirectory(atPath: paths.instancesDir.path) else {
            return unresolvedConflicts(in: paths)
        }

        let collisions = Set(legacyNames.compactMap(UUID.init(uuidString:)))
            .intersection(Set(currentNames.compactMap(UUID.init(uuidString:))))
        guard !collisions.isEmpty else { return unresolvedConflicts(in: paths) }

        let directory = conflictDirectory(in: paths)
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        for id in collisions {
            let marker = directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
            guard !fm.fileExists(atPath: marker.path) else { continue }
            let record = ConflictRecord(instanceID: id,
                                        legacyPath: legacy.instanceDir(id).path,
                                        currentPath: paths.instanceDir(id).path,
                                        detectedAt: Date())
            if let data = try? encoder.encode(record),
               (try? AtomicFile.write(data, to: marker, keepBackup: false)) != nil {
                log.warn("profile migration conflict for \(id.uuidString); both copies were left in place")
            }
        }
        return unresolvedConflicts(in: paths)
    }

    /// Swaps old path prefixes for new ones inside registry.json, leaving everything else
    /// — numbers above all — exactly as it was.
    ///
    /// This decodes and re-encodes rather than editing the text. The first version did a
    /// string replacement and silently did nothing, because Foundation writes `/` as
    /// `\/` in JSON: the paths in the file never matched the paths being searched for,
    /// so instances were moved and then pointed at directories that no longer held them.
    private static func rewriteRegistry(at url: URL, from legacy: MALPaths, to paths: MALPaths, log: MALLog) {
        guard let data = try? Data(contentsOf: url) else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var doc = try? decoder.decode(RegistryDocument.self, from: data) else {
            log.error("could not parse registry.json while migrating; leaving it alone")
            return
        }

        func moved(_ path: String) -> String {
            for (old, new) in [(legacy.support.path, paths.support.path),
                               (legacy.bundlesDir.path, paths.bundlesDir.path)] {
                if path == old { return new }
                if path.hasPrefix(old + "/") { return new + String(path.dropFirst(old.count)) }
            }
            return path
        }

        var changed = false
        for appIndex in doc.apps.indices {
            for instanceIndex in doc.apps[appIndex].instances.indices {
                let instance = doc.apps[appIndex].instances[instanceIndex]
                let bundle = moved(instance.bundlePath)
                let data = moved(instance.dataPath)
                if bundle != instance.bundlePath {
                    doc.apps[appIndex].instances[instanceIndex].bundlePath = bundle
                    changed = true
                }
                if data != instance.dataPath {
                    doc.apps[appIndex].instances[instanceIndex].dataPath = data
                    changed = true
                }
            }
        }
        guard changed else { return }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try AtomicFile.write(try encoder.encode(doc), to: url)
            log.info("rewrote stored paths in registry.json")
        } catch {
            log.error("could not rewrite registry.json: \(error)")
        }
    }

    /// Fixes the absolute paths inside each launcher bundle's instance config and
    /// re-signs the bundle, because editing a file inside it breaks the seal.
    private static func repairBundles(in paths: MALPaths,
                                      legacy: MALPaths,
                                      log: MALLog) -> (repaired: Int, failed: [String]) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: paths.bundlesDir.path) else {
            return (0, [])
        }
        let signer = CodeSigner(log: log)
        var repaired = 0
        var failed: [String] = []

        for entry in entries where entry.hasSuffix(".app") {
            let bundle = paths.bundlesDir.appendingPathComponent(entry)
            let configURL = bundle.appendingPathComponent("Contents/Resources/MALInstance.conf")
            guard let text = try? String(contentsOf: configURL, encoding: .utf8) else { continue }

            var updated = text
            for (old, new) in [(legacy.support.path, paths.support.path),
                               (legacy.bundlesDir.path, paths.bundlesDir.path)] {
                updated = updated.replacingOccurrences(of: old, with: new)
            }
            guard updated != text else { continue }

            do {
                try AtomicFile.write(Data(updated.utf8), to: configURL, keepBackup: false)
                // The nested code is untouched and still validly signed; only the outer
                // bundle's resource seal needs redoing, and it keeps the entitlements it
                // already has.
                try signer.reseal(bundle: bundle)
                repaired += 1
                log.info("repaired and re-sealed \(entry)")
            } catch {
                failed.append(entry)
                log.error("could not repair \(entry): \(error) — it will need a rebuild")
            }
        }
        return (repaired, failed)
    }

    // MARK: - Retiring the legacy store

    /// What a legacy installation still has on disk after migration.
    public struct LegacyResidue: Sendable {
        public var supportPath: String?
        public var bundlesPath: String?
        public var profileIdentifiers: [String] = []
        public var totalBytes: Int64 = 0
        public var isEmpty: Bool { supportPath == nil && bundlesPath == nil }
    }

    /// Reports what remains under the pre-rename locations. Read-only.
    ///
    /// Migration deliberately refuses to merge a profile that exists on both sides,
    /// because each copy may hold a different signed-in session. The consequence is that
    /// a duplicated profile stays in the old directory forever and `doctor` reports it on
    /// every run. This is the read half of the route out of that state.
    public static func legacyResidue(paths: MALPaths,
                                     legacy: MALPaths,
                                     sizeCache: DirectorySizeCache? = nil) -> LegacyResidue {
        var residue = LegacyResidue()
        guard legacy.support.path != paths.support.path else { return residue }
        let fm = FileManager.default

        if fm.fileExists(atPath: legacy.support.path) {
            residue.supportPath = legacy.support.path
            residue.totalBytes += sizeCache?.size(of: legacy.support)
                ?? FSOps.directorySize(legacy.support)
            let instances = legacy.instancesDir
            if let entries = try? fm.contentsOfDirectory(atPath: instances.path) {
                residue.profileIdentifiers = entries
                    .filter { UUID(uuidString: $0) != nil }
                    .sorted()
            }
        }
        if fm.fileExists(atPath: legacy.bundlesDir.path) {
            residue.bundlesPath = legacy.bundlesDir.path
            residue.totalBytes += sizeCache?.size(of: legacy.bundlesDir)
                ?? FSOps.directorySize(legacy.bundlesDir)
        }
        return residue
    }

    /// Moves the legacy store to the Trash, after the caller has confirmed it.
    ///
    /// Three deliberate constraints, because this is the one place the product touches a
    /// directory outside its current two roots:
    ///
    /// 1. The targets are the exact paths `MALPaths.legacy()` names. They are compared
    ///    against the argument rather than derived from it, so no registry value, display
    ///    name or user string can ever redirect this. Nothing is globbed or matched by name.
    /// 2. Items go to the **Trash**, not `unlink`. A legacy profile may contain a live
    ///    signed-in session; the user must be able to get it back.
    /// 3. It refuses to run while the current store still points at the legacy location,
    ///    which would mean this is the live installation rather than a leftover.
    ///
    /// The caller is responsible for obtaining explicit confirmation first. Nothing in
    /// LaunchAgain calls this automatically, and no startup or health path reaches it.
    @discardableResult
    public static func trashLegacyStore(paths: MALPaths,
                                        legacy: MALPaths,
                                        log: MALLog = .silent) throws -> [String] {
        guard !Validation.pathsReferToSameLocation(legacy.support.path, paths.support.path),
              !Validation.pathsReferToSameLocation(legacy.bundlesDir.path,
                                                   paths.bundlesDir.path) else {
            throw MALError.invalidPath(
                legacy.support.path,
                reason: "the legacy store is the store currently in use")
        }
        let canonicalLegacy = MALPaths.legacy()
        guard Validation.pathsReferToSameLocation(legacy.support.path,
                                                  canonicalLegacy.support.path),
              Validation.pathsReferToSameLocation(legacy.bundlesDir.path,
                                                  canonicalLegacy.bundlesDir.path) else {
            throw MALError.invalidPath(
                legacy.support.path,
                reason: "only the exact pre-rename LaunchAgain directories can be retired")
        }

        var trashed: [String] = []
        for url in [legacy.support, legacy.bundlesDir] {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            if try FSOps.moveToTrash(url) {
                trashed.append(url.path)
                log.info("moved the legacy store at \(url.path) to the Trash on explicit request")
            } else {
                trashed.append(url.path)
                log.warn("removed the legacy store at \(url.path); this volume has no Trash")
            }
        }
        return trashed
    }
}
#endif
