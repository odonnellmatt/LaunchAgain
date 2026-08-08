import Foundation

/// The persistent store. Serialised, atomic, and self-repairing.
///
/// Concurrency, in two layers, because one is not enough:
///
/// 1. **Within a process** a single serial queue orders every read and write.
///
/// 2. **Between processes** every read-modify-write cycle runs under an advisory
///    `flock` on `registry.json.lock`, and re-reads the document from disk *inside*
///    that lock before mutating it. A serial queue alone orders nothing between the
///    GUI and the CLI: both would read the same document, both would mutate their own
///    stale copy, and the second writer would silently erase the first. The lock is
///    released by the kernel when the holding process dies, so a crash cannot wedge it.
///
/// The document is small (kilobytes) so the whole thing is rewritten each time, and
/// being un-clever there is the point.
///
/// Numbers need one thing more than the lock gives. `create` draws a number, then spends
/// seconds cloning and signing, then commits. A second process allocating inside that
/// window would find the number free, because nothing on disk says otherwise yet. So a
/// drawn number is also written to `number-reservations/` and held under its own advisory
/// lock for the whole build — durable, visible to every other process, and released on
/// commit, on failure, or by the kernel if the process dies. See `reserveNumbers`.
public final class Registry: @unchecked Sendable {

    public struct ReconciliationReport: Equatable, Sendable {
        public var recoveredInstanceIDs: [UUID] = []
        public var relocatedInstanceIDs: [UUID] = []
        public var conflicts: [String] = []

        public var changed: Bool {
            !recoveredInstanceIDs.isEmpty || !relocatedInstanceIDs.isEmpty
        }
    }

    public let paths: MALPaths
    private let queue = DispatchQueue(label: "com.mal.registry")
    private var doc: RegistryDocument

    /// Numbers this process has drawn but not yet committed. The value is the open file
    /// descriptor whose advisory lock is what other processes actually observe; closing
    /// it is what releases the reservation.
    private struct ReservationKey: Hashable {
        let appKey: String
        let number: Int
    }
    private var heldReservations: [ReservationKey: Int32] = [:]

    /// Set when the primary registry was unreadable and the `.bak` was used instead.
    public private(set) var recoveredFromBackup = false
    /// Set only when both registry copies were unreadable and were preserved before a
    /// new empty document was created for launcher reconciliation.
    public private(set) var recoveredFromCorruption = false
    public private(set) var preservedCorruptFiles: [String] = []
    /// Modification date of the file as of the last load or save, used to notice writes
    /// by another process.
    private var lastLoadedModification: Date?

    public init(paths: MALPaths, recoverCorrupt: Bool = false) throws {
        self.paths = paths
        try paths.createAll()
        self.doc = RegistryDocument()
        do {
            try load()
        } catch let error as MALError {
            guard recoverCorrupt, case .registryCorrupt = error else { throw error }
            let expectedCopies = [
                paths.registryFile,
                paths.registryFile.appendingPathExtension("bak"),
            ].filter { FileManager.default.fileExists(atPath: $0.path) }.count
            let preserved = preserveUnreadableRegistryCopies()
            guard preserved.count == expectedCopies else { throw error }
            preservedCorruptFiles = preserved
            doc = RegistryDocument()
            recoveredFromCorruption = true
            try persistUnderLock()
        }
    }

    // MARK: - Persistence

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    private func load() throws {
        let url = paths.registryFile
        guard FileManager.default.fileExists(atPath: url.path)
                || FileManager.default.fileExists(atPath: url.appendingPathExtension("bak").path) else {
            doc = RegistryDocument()
            return
        }

        let result = AtomicFile.readWithFallback(url) { data in
            _ = try Registry.decoder().decode(RegistryDocument.self, from: data)
            return true
        }

        guard let result else {
            throw MALError.registryCorrupt("neither registry.json nor registry.json.bak could be parsed")
        }
        recoveredFromBackup = result.usedBackup

        var loaded = try Registry.decoder().decode(RegistryDocument.self, from: result.data)
        guard loaded.schemaVersion <= RegistryDocument.currentSchemaVersion else {
            throw MALError.registrySchemaTooNew(found: loaded.schemaVersion,
                                                supported: RegistryDocument.currentSchemaVersion)
        }

        // Self-repair: a counter restored from an old backup must never re-issue a
        // number that an existing instance already holds.
        for i in loaded.apps.indices {
            loaded.apps[i].nextInstanceNumber = NumberAllocator.reconciledCounter(
                storedCounter: loaded.apps[i].nextInstanceNumber,
                existingNumbers: loaded.apps[i].instances.map(\.number))
        }
        doc = loaded
        lastLoadedModification = modificationDate()

        if recoveredFromBackup {
            try? persistUnderLock()
        }
    }

    private func persist() throws {
        let data = try Registry.encoder().encode(doc)
        try AtomicFile.write(data, to: paths.registryFile)
        lastLoadedModification = modificationDate()
    }

    /// `persist()` for the two startup recovery paths, which run before any `mutate`
    /// and therefore hold nothing.
    ///
    /// Both are benign in practice — they happen once, during construction, against a
    /// document that was just rebuilt from an unreadable file — but "benign today"
    /// is not a rule, and every other write in this file goes through the lock. A
    /// recovery write is in fact the one a second process is most likely to be racing,
    /// because a registry that has just been found corrupt is a registry something else
    /// may be repairing at the same moment.
    ///
    /// Deliberately not called from anywhere already inside `withRegistryLock`: `flock`
    /// is held per open file description, so a nested acquisition from the same process
    /// opens a second descriptor and deadlocks against itself.
    private func persistUnderLock() throws {
        try withRegistryLock { try persist() }
    }

    /// Re-reads the file if something else has written to it since we last looked.
    ///
    /// The registry is a document on disk, and this process is not the only thing that
    /// writes it: the command line tool does too, and so would a second window. Holding
    /// an in-memory copy from launch and never checking it is how a window ends up
    /// showing instances that no longer exist — or missing ones that do — and how the
    /// next save silently overwrites whatever the other writer did.
    ///
    /// Returns true when the document was actually reloaded.
    @discardableResult
    public func reloadIfChanged() -> Bool {
        queue.sync {
            (try? withRegistryLock(LOCK_SH) { () -> Bool in
            let current = modificationDate()
            guard current != lastLoadedModification else { return false }

            // Deliberately *not* `load()`: that falls back to registry.json.bak, which is
            // right at startup and wrong here. A file caught mid-write reads as corrupt
            // for an instant, and rolling the user's live list back to the previous
            // saved state would be a worse outcome than simply not refreshing yet.
            guard let data = try? Data(contentsOf: paths.registryFile),
                  var loaded = try? Registry.decoder().decode(RegistryDocument.self, from: data),
                  loaded.schemaVersion <= RegistryDocument.currentSchemaVersion else {
                return false
            }
            for i in loaded.apps.indices {
                loaded.apps[i].nextInstanceNumber = NumberAllocator.reconciledCounter(
                    storedCounter: loaded.apps[i].nextInstanceNumber,
                    existingNumbers: loaded.apps[i].instances.map(\.number))
            }
            doc = loaded
            lastLoadedModification = current
            return true
            }) ?? false
        }
    }

    private func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: paths.registryFile.path))?[.modificationDate] as? Date
    }

    // MARK: - Cross-process locking

    /// Runs `body` while holding an advisory lock on the registry.
    ///
    /// The same discipline `MALLog` uses for the shared log: a sidecar `.lock` file and
    /// `flock`. Two properties matter. The lock is advisory but every writer in this
    /// product goes through here, and the kernel drops it when the holding file
    /// descriptor closes — including when the process dies — so a crash mid-write cannot
    /// leave the registry permanently unwritable.
    private func withRegistryLock<T>(_ operation: Int32 = LOCK_EX, _ body: () throws -> T) throws -> T {
#if canImport(Darwin) || canImport(Glibc)
        let lockURL = paths.registryFile.appendingPathExtension("lock")
        try? FileManager.default.createDirectory(at: paths.support,
                                                 withIntermediateDirectories: true)
        let fd = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw MALError.invalidPath(lockURL.path,
                                       reason: "could not open the registry lock")
        }
        guard flock(fd, operation) == 0 else {
            let reason = String(cString: strerror(errno))
            close(fd)
            throw MALError.invalidPath(lockURL.path,
                                       reason: "could not lock the registry: \(reason)")
        }
        defer {
            _ = flock(fd, LOCK_UN)
            close(fd)
        }
        return try body()
#else
        return try body()
#endif
    }

    /// Re-reads the document from disk. Called at the top of every locked mutation so a
    /// write is applied to what is actually stored rather than to whatever this process
    /// happened to load earlier.
    ///
    /// Deliberately does not fall back to `registry.json.bak`: that is startup recovery.
    /// Here, a file we cannot parse means we keep what we have and let the caller's write
    /// fail or proceed on the last known-good document, rather than silently reverting
    /// the user to an older state.
    private func reloadFromDiskLocked() {
        guard let data = try? Data(contentsOf: paths.registryFile),
              var loaded = try? Registry.decoder().decode(RegistryDocument.self, from: data),
              loaded.schemaVersion <= RegistryDocument.currentSchemaVersion else {
            return
        }
        for i in loaded.apps.indices {
            loaded.apps[i].nextInstanceNumber = NumberAllocator.reconciledCounter(
                storedCounter: loaded.apps[i].nextInstanceNumber,
                existingNumbers: loaded.apps[i].instances.map(\.number))
        }
        doc = loaded
        lastLoadedModification = modificationDate()
    }

    /// One locked read-modify-write. Every mutation below is this shape.
    private func mutate<T>(_ body: () throws -> T) throws -> T {
        try queue.sync {
            try withRegistryLock {
                reloadFromDiskLocked()
                let before = doc
                do {
                    return try body()
                } catch {
                    doc = before
                    throw error
                }
            }
        }
    }

    // MARK: - Durable number reservations

    /// A filename-safe, process-independent key for an app.
    ///
    /// `Hasher` is seeded per process and would give two processes different filenames
    /// for the same app, so this uses FNV-1a, which is stable everywhere.
    private static func reservationPrefix(appKey: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in Array(appKey.utf8) {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(format: "%016llx-", hash)
    }

    private static func reservationFilename(appKey: String, number: Int) -> String {
        "\(reservationPrefix(appKey: appKey))\(number).reservation"
    }

    /// The number encoded in a reservation filename belonging to `appKey`, if it is one.
    private static func reservationNumber(inFilename name: String, appKey: String) -> Int? {
        let prefix = reservationPrefix(appKey: appKey)
        guard name.hasPrefix(prefix), name.hasSuffix(".reservation") else { return nil }
        let middle = name.dropFirst(prefix.count).dropLast(".reservation".count)
        guard let number = Int(middle), number > 0 else { return nil }
        return number
    }

    private func reservationURL(appKey: String, number: Int) -> URL {
        paths.numberReservationsDir.appendingPathComponent(
            Registry.reservationFilename(appKey: appKey, number: number))
    }

    /// Numbers currently reserved by any live process, including this one.
    ///
    /// A reservation whose lock nobody holds is the residue of a process that died
    /// mid-build. It is removed and its number treated as free, which is what stops an
    /// abandoned reservation from burning a number forever.
    private func activeReservedNumbers(appKey: String) -> Set<Int> {
#if canImport(Darwin) || canImport(Glibc)
        var reserved: Set<Int> = []
        try? FileManager.default.createDirectory(at: paths.numberReservationsDir,
                                                 withIntermediateDirectories: true)
        // Enumerated rather than probed over a computed range. A range needs an upper
        // bound, and any bound derived from the committed numbers is wrong precisely
        // when it matters: with #1 committed and eight processes racing, a bound of #3
        // cannot see the reservation for #4 that another process is already holding.
        let names = (try? FileManager.default.contentsOfDirectory(
            atPath: paths.numberReservationsDir.path)) ?? []
        for name in names {
            guard let number = Registry.reservationNumber(inFilename: name, appKey: appKey)
            else { continue }
            let url = paths.numberReservationsDir.appendingPathComponent(name)
            if heldReservations[ReservationKey(appKey: appKey, number: number)] != nil {
                reserved.insert(number)
                continue
            }
            let fd = open(url.path, O_RDWR)
            guard fd >= 0 else { continue }
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                // Nobody holds it: the reserving process is gone.
                _ = flock(fd, LOCK_UN)
                close(fd)
                try? FileManager.default.removeItem(at: url)
            } else {
                close(fd)
                reserved.insert(number)
            }
        }
        return reserved
#else
        return []
#endif
    }

    /// Takes and holds the reservation for one number. Returns false if another process
    /// won the race for it.
    private func claimReservation(appKey: String, number: Int) -> Bool {
#if canImport(Darwin) || canImport(Glibc)
        let url = reservationURL(appKey: appKey, number: number)
        let fd = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { return false }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return false
        }
        let note = "pid=\(getpid()) app=\(appKey) number=\(number) at=\(Date().timeIntervalSince1970)\n"
        _ = ftruncate(fd, 0)
        _ = note.withCString { write(fd, $0, strlen($0)) }
        heldReservations[ReservationKey(appKey: appKey, number: number)] = fd
        return true
#else
        return true
#endif
    }

    /// Drops a reservation this process holds. Safe to call for one it does not.
    private func releaseReservationLocked(appKey: String, number: Int) {
#if canImport(Darwin) || canImport(Glibc)
        let key = ReservationKey(appKey: appKey, number: number)
        guard let fd = heldReservations.removeValue(forKey: key) else { return }
        try? FileManager.default.removeItem(at: reservationURL(appKey: appKey, number: number))
        _ = flock(fd, LOCK_UN)
        close(fd)
#endif
    }

    /// Releases numbers drawn for a build that failed, so the next attempt reuses them
    /// instead of leaving a permanent hole in the numbering.
    public func releaseReservedNumbers(_ numbers: [Int], appKey: String) {
        queue.sync {
            for number in numbers {
                releaseReservationLocked(appKey: appKey, number: number)
            }
        }
    }

    deinit {
#if canImport(Darwin) || canImport(Glibc)
        for (key, fd) in heldReservations {
            try? FileManager.default.removeItem(
                at: reservationURL(appKey: key.appKey, number: key.number))
            _ = flock(fd, LOCK_UN)
            close(fd)
        }
#endif
    }

    /// Copies rather than moves. Recovery must never make the original bytes harder to
    /// inspect, and filenames include both time and a UUID to avoid collision.
    private func preserveUnreadableRegistryCopies() -> [String] {
        let fm = FileManager.default
        let stamp = Int(Date().timeIntervalSince1970)
        let fragment = UUID().uuidString.prefix(8)
        var preserved: [String] = []
        for source in [paths.registryFile, paths.registryFile.appendingPathExtension("bak")]
        where fm.fileExists(atPath: source.path) {
            let destination = paths.support.appendingPathComponent(
                "\(source.lastPathComponent).corrupt-\(stamp)-\(fragment)")
            do {
                try fm.copyItem(at: source, to: destination)
                preserved.append(destination.path)
            } catch {
                // Failure to archive means we must not overwrite the only copy.
                return []
            }
        }
        return preserved
    }

    // MARK: - Reads

    public var snapshot: RegistryDocument {
        queue.sync { doc }
    }

    public var allApps: [ManagedApp] {
        queue.sync { doc.apps.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending } }
    }

    public func app(_ key: String) -> ManagedApp? {
        queue.sync { doc.apps.first { $0.appKey == key } }
    }

    public func instance(_ id: UUID) -> (app: ManagedApp, instance: Instance)? {
        queue.sync {
            for a in doc.apps {
                if let i = a.instances.first(where: { $0.id == id }) { return (a, i) }
            }
            return nil
        }
    }

    public var allInstances: [(app: ManagedApp, instance: Instance)] {
        queue.sync {
            doc.apps.flatMap { a in a.instances.map { (a, $0) } }
                .sorted {
                    if $0.0.displayName != $1.0.displayName {
                        return $0.0.displayName.localizedCaseInsensitiveCompare($1.0.displayName) == .orderedAscending
                    }
                    return $0.1.number < $1.1.number
                }
        }
    }

    // MARK: - Mutations

    /// Registers an app if unknown, updates its source metadata if known.
    @discardableResult
    public func upsertApp(appKey: String,
                          displayName: String,
                          sourcePath: String,
                          sourceVersion: String,
                          sourceBookmark: Data? = nil) throws -> ManagedApp {
        try mutate {
            if let idx = doc.apps.firstIndex(where: { $0.appKey == appKey }) {
                var updated = doc.apps[idx]
                updated.displayName = displayName
                updated.sourcePath = sourcePath
                updated.sourceVersion = sourceVersion
                if let b = sourceBookmark { updated.sourceBookmark = b }
                // Source-version refreshes and migrations run at launch. Rewriting an
                // identical document here wakes every registry watcher and used to
                // create a self-sustaining refresh/scan loop.
                if updated != doc.apps[idx] {
                    doc.apps[idx] = updated
                    try persist()
                }
                return doc.apps[idx]
            }
            let app = ManagedApp(appKey: appKey,
                                 displayName: displayName,
                                 sourcePath: sourcePath,
                                 sourceBookmark: sourceBookmark,
                                 sourceVersion: sourceVersion,
                                 nextInstanceNumber: 1,
                                 instances: [])
            doc.apps.append(app)
            try persist()
            return app
        }
    }

    /// Draws `count` permanent instance numbers. This is the *only* way a number is
    /// ever created. The counter is advanced and persisted before any bundle is built,
    /// so a crash mid-build can never cause a number to be handed out twice.
    public func reserveNumbers(appKey: String, count: Int) throws -> [Int] {
        try mutate {
            guard let idx = doc.apps.firstIndex(where: { $0.appKey == appKey }) else {
                throw MALError.appNotManaged(appKey)
            }

            // Numbers already committed, plus numbers another live process has drawn and
            // is still building. Without the second set, two processes allocating during
            // each other's build window both see the same number as free — which is how
            // eight concurrent creates all became "#2" and seven launchers became
            // unrecoverable orphans.
            let committed = doc.apps[idx].instances.map(\.number)

            // Allocate, then claim. Allocation happens under the registry lock so no
            // other process can be choosing at the same instant, but a claim can still
            // lose to a reservation file that was reaped as stale between the scan and
            // the claim. Treat that number as taken and go round again rather than
            // failing the user's create.
            var numbers: [Int] = []
            var next = doc.apps[idx].nextInstanceNumber
            var claimed: [Int] = []
            var blocked: Set<Int> = []
            var attempts = 0
            while attempts < 16 {
                attempts += 1
                let reserved = activeReservedNumbers(appKey: appKey)
                let candidate = NumberAllocator.allocate(
                    count: count,
                    from: doc.apps[idx].nextInstanceNumber,
                    existing: committed + Array(reserved) + Array(blocked))
                var ok = true
                for number in candidate.numbers {
                    guard claimReservation(appKey: appKey, number: number) else {
                        blocked.insert(number)
                        ok = false
                        break
                    }
                    claimed.append(number)
                }
                if ok {
                    numbers = candidate.numbers
                    next = candidate.nextCounter
                    break
                }
                for done in claimed { releaseReservationLocked(appKey: appKey, number: done) }
                claimed.removeAll()
            }
            guard !numbers.isEmpty || count == 0 else {
                throw MALError.duplicateInstanceNumber(blocked.min() ?? 0)
            }

            doc.apps[idx].nextInstanceNumber = next
            do {
                try persist()
            } catch {
                for done in claimed {
                    releaseReservationLocked(appKey: appKey, number: done)
                }
                throw error
            }
            return numbers
        }
    }

    public func addInstance(_ instance: Instance, toApp appKey: String) throws {
        try mutate {
            guard let idx = doc.apps.firstIndex(where: { $0.appKey == appKey }) else {
                throw MALError.appNotManaged(appKey)
            }
            guard !doc.apps[idx].instances.contains(where: { $0.number == instance.number }) else {
                throw MALError.duplicateInstanceNumber(instance.number)
            }
            doc.apps[idx].instances.append(instance)
            doc.apps[idx].instances.sort { $0.number < $1.number }
            doc.apps[idx].nextInstanceNumber = NumberAllocator.reconciledCounter(
                storedCounter: doc.apps[idx].nextInstanceNumber,
                existingNumbers: doc.apps[idx].instances.map(\.number))
            try persist()
            // Committed: the number is now visible to every other process in the
            // registry itself, so the reservation that stood in for it is finished.
            releaseReservationLocked(appKey: appKey, number: instance.number)
        }
    }

    /// Merges launcher-owned recovery records into the live registry in one atomic
    /// write. Existing registry values win: the launcher is a recovery copy, not a
    /// second writer. The one exception is `bundlePath`, because a launcher may have
    /// been moved within LaunchAgain's own applications directory while the app was
    /// uninstalled.
    @discardableResult
    public func reconcile(_ manifests: [LauncherRecoveryManifest],
                          excluding tombstonedIDs: Set<UUID> = []) throws -> ReconciliationReport {
        try mutate {
            var report = ReconciliationReport()
            var changed = false

            for manifest in manifests.sorted(by: {
                if $0.appDisplayName != $1.appDisplayName {
                    return $0.appDisplayName.localizedCaseInsensitiveCompare($1.appDisplayName)
                        == .orderedAscending
                }
                return $0.instance.number < $1.instance.number
            }) {
                let recovered = manifest.instance
                guard manifest.schemaVersion <= LauncherRecoveryManifest.currentSchemaVersion,
                      !manifest.appKey.isEmpty,
                      recovered.number > 0,
                      !tombstonedIDs.contains(recovered.id) else { continue }

                var existingLocation: (app: Int, instance: Int)?
                for appIndex in doc.apps.indices {
                    if let instanceIndex = doc.apps[appIndex].instances
                        .firstIndex(where: { $0.id == recovered.id }) {
                        existingLocation = (appIndex, instanceIndex)
                        break
                    }
                }

                if let existingLocation {
                    let oldPath = doc.apps[existingLocation.app]
                        .instances[existingLocation.instance].bundlePath
                    if oldPath != recovered.bundlePath {
                        if Validation.pathsReferToSameLocation(
                            oldPath, recovered.bundlePath) {
                            // `/tmp` and `/private/tmp` are the common case. They are
                            // one installed launcher, not a duplicate or relocation.
                        } else if FileManager.default.fileExists(atPath: oldPath) {
                            report.conflicts.append(
                                "\(manifest.appDisplayName) instance \(recovered.id.uuidString) also exists at \(recovered.bundlePath); kept the registered launcher at \(oldPath).")
                        } else {
                            doc.apps[existingLocation.app]
                                .instances[existingLocation.instance].bundlePath = recovered.bundlePath
                            report.relocatedInstanceIDs.append(recovered.id)
                            changed = true
                        }
                    }
                    continue
                }

                let appIndex: Int
                if let existing = doc.apps.firstIndex(where: { $0.appKey == manifest.appKey }) {
                    appIndex = existing
                } else {
                    doc.apps.append(ManagedApp(
                        appKey: manifest.appKey,
                        displayName: manifest.appDisplayName,
                        sourcePath: manifest.sourcePath,
                        sourceVersion: manifest.sourceVersion))
                    appIndex = doc.apps.count - 1
                    changed = true
                }

                if let collision = doc.apps[appIndex].instances
                    .first(where: { $0.number == recovered.number }) {
                    report.conflicts.append(
                        "\(manifest.appDisplayName) #\(recovered.number) is already assigned to \(collision.id.uuidString).")
                    continue
                }

                doc.apps[appIndex].instances.append(recovered)
                doc.apps[appIndex].instances.sort { $0.number < $1.number }
                doc.apps[appIndex].nextInstanceNumber = NumberAllocator.reconciledCounter(
                    storedCounter: doc.apps[appIndex].nextInstanceNumber,
                    existingNumbers: doc.apps[appIndex].instances.map(\.number))
                report.recoveredInstanceIDs.append(recovered.id)
                changed = true
            }

            if changed {
                try persist()
            }
            return report
        }
    }

    public func updateInstance(_ id: UUID, _ change: (inout Instance) -> Void) throws {
        try mutate {
            for ai in doc.apps.indices {
                if let ii = doc.apps[ai].instances.firstIndex(where: { $0.id == id }) {
                    change(&doc.apps[ai].instances[ii])
                    try persist()
                    return
                }
            }
            throw MALError.instanceNotFound(id)
        }
    }

    /// Commits a rebuilt launcher's sealed identity and its source-app metadata in one
    /// registry write. `InstanceBuilder` keeps the previous bundle retired until this
    /// closure returns, so a failed write restores both sides of the pair.
    public func commitRebuild(
        originalID: UUID,
        rebuilt: Instance,
        appKey: String,
        displayName: String,
        sourcePath: String,
        sourceVersion: String
    ) throws {
        try mutate {
            guard let ai = doc.apps.firstIndex(where: { $0.appKey == appKey }),
                  let ii = doc.apps[ai].instances.firstIndex(where: { $0.id == originalID }) else {
                throw MALError.instanceNotFound(originalID)
            }
            guard rebuilt.id == originalID else {
                throw MALError.invalidName(
                    rebuilt.id.uuidString,
                    reason: "a rebuild cannot change an instance UUID")
            }
            guard !doc.apps[ai].instances.enumerated().contains(where: { index, candidate in
                index != ii && candidate.number == rebuilt.number
            }) else {
                throw MALError.duplicateInstanceNumber(rebuilt.number)
            }

            doc.apps[ai].displayName = displayName
            doc.apps[ai].sourcePath = sourcePath
            doc.apps[ai].sourceVersion = sourceVersion
            doc.apps[ai].instances[ii] = rebuilt
            doc.apps[ai].instances.sort { $0.number < $1.number }
            doc.apps[ai].nextInstanceNumber = NumberAllocator.reconciledCounter(
                storedCounter: doc.apps[ai].nextInstanceNumber,
                existingNumbers: doc.apps[ai].instances.map(\.number))
            try persist()
        }
    }

    /// Removes the registry record only. Deleting files on disk is the caller's job,
    /// and is deliberately a separate, confirmable step.
    public func removeInstance(_ id: UUID) throws {
        try mutate {
            for ai in doc.apps.indices {
                if let ii = doc.apps[ai].instances.firstIndex(where: { $0.id == id }) {
                    doc.apps[ai].instances.remove(at: ii)
                    // A record with no instances has no dashboard meaning and retained
                    // a stale high-water mark. Rediscovery creates a fresh record whose
                    // first ordinary instance is correctly numbered #1.
                    if doc.apps[ai].instances.isEmpty {
                        doc.apps.remove(at: ai)
                    }
                    try persist()
                    return
                }
            }
            throw MALError.instanceNotFound(id)
        }
    }

    public func removeApp(_ appKey: String) throws {
        try mutate {
            doc.apps.removeAll { $0.appKey == appKey }
            try persist()
        }
    }

    /// Explicit, user-initiated renumbering. Returns the plan so the caller can
    /// rebuild the affected bundles and icons in one transaction.
    public func renumber(appKey: String, startingAt start: Int = 1) throws -> [Int: Int] {
        try mutate {
            guard let idx = doc.apps.firstIndex(where: { $0.appKey == appKey }) else {
                throw MALError.appNotManaged(appKey)
            }
            let existing = doc.apps[idx].instances.map(\.number)
            let plan = NumberAllocator.renumberPlan(existingNumbers: existing, startingAt: start)
            guard !plan.isEmpty else { return [:] }

            var rebuilt: [Instance] = []
            for inst in doc.apps[idx].instances.sorted(by: { $0.number < $1.number }) {
                let newNumber = plan[inst.number] ?? inst.number
                rebuilt.append(Instance(id: inst.id,
                                        number: newNumber,
                                        name: inst.name,
                                        accountLabel: inst.accountLabel,
                                        mode: inst.mode,
                                        bundlePath: inst.bundlePath,
                                        dataPath: inst.dataPath,
                                        badge: inst.badge,
                                        builtFromSourceVersion: inst.builtFromSourceVersion,
                                        clonedBundleIdentifier: inst.clonedBundleIdentifier,
                                        extraArguments: inst.extraArguments,
                                        extraEnvironment: inst.extraEnvironment,
                                        createdAt: inst.createdAt,
                                        lastLaunchedAt: inst.lastLaunchedAt,
                                        buildNotes: inst.buildNotes))
            }
            doc.apps[idx].instances = rebuilt.sorted { $0.number < $1.number }
            doc.apps[idx].nextInstanceNumber = NumberAllocator.reconciledCounter(
                storedCounter: 1, existingNumbers: rebuilt.map(\.number))
            try persist()
            return plan
        }
    }
}
