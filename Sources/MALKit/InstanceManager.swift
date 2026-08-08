#if canImport(Darwin)
import Foundation
import AppKit
import MALCore

/// The one object the interface and the CLI both talk to.
///
/// It owns the registry and coordinates the scanner, builder and supervisor so that
/// "create three instances" is a single call with a single rollback story, rather than
/// something each caller has to sequence correctly.
///
/// Concurrency: this type is `@unchecked Sendable` on a stated discipline rather than a
/// proof. The registry serialises every read and write on its own queue; the scanner,
/// builder, supervisor and sweeper hold no mutable state of their own; and the two
/// callers — the CLI and the interface — each run long operations on a single serial
/// queue, so two builds never overlap. What the compiler cannot check, that discipline
/// covers.
public final class InstanceManager: @unchecked Sendable {

    public let paths: MALPaths
    public let registry: Registry
    public let scanner: AppScanner
    public let builder: InstanceBuilder
    public let supervisor: LaunchSupervisor
    public let directorySizeCache: DirectorySizeCache
    public let sweeper: OrphanSweeper
    public let diagnostics: Diagnostics
    public let registrar: LaunchServicesRegistrar
    public let launcherReconciler: LauncherReconciler
    public let log: MALLog

    /// Non-nil when this launch moved an installation over from the old product name.
    public let migration: Migration.Report?
    /// Recovery performed before the first UI snapshot is rendered.
    public let initialLauncherReconciliation: LauncherReconciler.Report

    /// - Parameter readOnly: for commands that only report. Measurements are still
    ///   cached in memory for the life of the process, but nothing is written to the
    ///   store — `scan` and `inspect` both measure bundle sizes, and persisting that
    ///   cache is how two commands that read as read-only were modifying the store.
    public init(paths: MALPaths = .standard(),
                verbose: Bool = false,
                readOnly: Bool = false,
                migrateFrom legacy: MALPaths? = nil) throws {
        self.paths = paths

        // Migration runs *before* the new directories are created. Creating them first
        // would turn every move into a merge, which is slower and easier to get wrong —
        // and getting it wrong means moving someone's instances and then not finding
        // their registry.
        var migrationReport: Migration.Report?
        if let legacy, legacy.support.path != paths.support.path {
            let report = Migration.migrateIfNeeded(to: paths, from: legacy)
            migrationReport = report.didAnything ? report : nil
        }
        self.migration = migrationReport

        try paths.createAll()
        let logger = MALLog(fileURL: paths.logsDir.appendingPathComponent("launchagain.log"),
                            minimumLevel: verbose ? .debug : .info,
                            echoToStandardError: verbose)
        logger.rotate()
        self.log = logger
        if let migrationReport {
            logger.info("migrated from the previous installation: moved \(migrationReport.moved.joined(separator: ", ")), repaired \(migrationReport.repairedBundles) bundle(s)")
        }
        let registry = try Registry(paths: paths, recoverCorrupt: true)
        self.registry = registry
        let directorySizeCache = DirectorySizeCache(paths: paths, persistsToDisk: !readOnly)
        self.directorySizeCache = directorySizeCache
        let scanner = AppScanner(log: logger, sizeCache: directorySizeCache)
        self.scanner = scanner
        self.builder = InstanceBuilder(paths: paths, log: logger)
        self.supervisor = LaunchSupervisor(paths: paths, log: logger)
        self.sweeper = OrphanSweeper(paths: paths, log: logger, sizeCache: directorySizeCache)
        self.diagnostics = Diagnostics(paths: paths, log: logger, sizeCache: directorySizeCache)
        self.registrar = LaunchServicesRegistrar(log: logger)
        let launcherReconciler = LauncherReconciler(paths: paths, scanner: scanner, log: logger)
        self.launcherReconciler = launcherReconciler
        Self.resumePendingRemovals(
            paths: paths,
            registry: registry,
            builder: builder,
            supervisor: supervisor,
            reconciler: launcherReconciler,
            sizeCache: directorySizeCache,
            log: logger)
        self.initialLauncherReconciliation = try launcherReconciler.reconcile(registry: registry)

        if registry.recoveredFromBackup {
            logger.warn("registry.json was unreadable; recovered from registry.json.bak")
        }
        if registry.recoveredFromCorruption {
            logger.warn("both registry copies were unreadable; preserved them and rebuilt from installed launchers")
        }
    }

    // MARK: - Discovery

    /// Installed GUI applications that can become instances. Command-line tools are
    /// intentionally excluded: LaunchAgain creates and opens macOS app bundles only.
    public func browseInstalledApps() -> [AppFacts] {
        let apps = scanner.discoverBundles()
            .filter { !AppScanner.isLaunchAgainGeneratedBundle(at: $0) }
            .compactMap { scanner.quickFacts(at: $0) }
            .filter { !$0.bundleIdentifier.isEmpty }
        return apps
    }

    /// Full inspection of one candidate. LaunchAgain's product boundary is a GUI `.app`;
    /// binaries and generated launchers are rejected rather than converted to terminals.
    public func inspect(_ url: URL) throws -> (facts: AppFacts, verdict: CompatibilityVerdict) {
        guard url.pathExtension.lowercased() == "app" else {
            throw MALError.notSupported(
                reason: "LaunchAgain creates GUI application instances only. Choose a macOS .app bundle, not a command-line executable.")
        }
        guard !AppScanner.isLaunchAgainGeneratedBundle(at: url) else {
            throw MALError.notSupported(
                reason: "Choose the original application, not an instance LaunchAgain already generated.")
        }
        let facts = try scanner.fullFacts(at: url)
        return (facts, Compatibility.evaluate(facts))
    }

    // MARK: - Creation

    public struct CreationPlan: Sendable {
        public var facts: AppFacts
        public var verdict: CompatibilityVerdict
        public var numbers: [Int]
        public var names: [String]
        public var accountLabels: [String]
        public var badges: [BadgeSpec]
        public var totalEstimatedBytes: Int64
        public var destinationDirectory: String
    }

    /// Reserves numbers and produces the review-screen data. Numbers are committed to
    /// disk here, before any bundle is built, so a crash during a build can never cause
    /// the same number to be issued twice.
    public func plan(sourceBundle: URL,
                     count: Int,
                     names: [String],
                     accountLabels: [String] = []) throws -> CreationPlan {
        guard count >= 1, count <= 64 else {
            throw MALError.notSupported(reason: "Choose between 1 and 64 instances.")
        }
        let (facts, verdict) = try inspect(sourceBundle)
        guard verdict.canCreate else {
            throw MALError.notSupported(reason: verdict.headline)
        }

        try registry.upsertApp(appKey: facts.bundleIdentifier,
                               displayName: facts.displayName,
                               sourcePath: facts.path,
                               sourceVersion: facts.version,
                               sourceBookmark: try? bookmark(for: sourceBundle))

        let numbers = try registry.reserveNumbers(appKey: facts.bundleIdentifier, count: count)
        let resolvedNames = (0..<count).map { i -> String in
            i < names.count ? Validation.sanitizeInstanceName(names[i]) : ""
        }
        let resolvedAccountLabels = (0..<count).map { i -> String in
            i < accountLabels.count
                ? Validation.sanitizeAccountLabel(accountLabels[i])
                : ""
        }
        let badges = numbers.map { BadgeSpec(colorHex: BadgeSpec.suggestedColor(forNumber: $0)) }

        return CreationPlan(facts: facts,
                            verdict: verdict,
                            numbers: numbers,
                            names: resolvedNames,
                            accountLabels: resolvedAccountLabels,
                            badges: badges,
                            totalEstimatedBytes: verdict.estimatedBytesPerInstance(
                                mode: verdict.recommendedMode,
                                sourceBundleBytes: facts.bundleSizeBytes) * Int64(count),
                            destinationDirectory: verdict.systemApplicationsRequirement == nil
                            ? paths.bundlesDir.path
                            : paths.systemBundlesDir.path)
    }

    public struct CreationOutcome: Sendable {
        public var created: [Instance]
        public var failures: [(number: Int, error: String)]
        /// Instances that asked for Full mode and were built as Lite instead.
        public var degraded: [Int]
        public var notes: [String]

        public init(created: [Instance] = [],
                    failures: [(number: Int, error: String)] = [],
                    degraded: [Int] = [],
                    notes: [String] = []) {
            self.created = created
            self.failures = failures
            self.degraded = degraded
            self.notes = notes
        }
    }

    /// Executes a plan. Each instance is built independently: one failing does not undo
    /// the ones that already succeeded, because a user who asked for three and got two
    /// is better served by keeping the two than by losing everything.
    /// - Parameter acknowledgedSharedCredentialStore: the caller has shown the user
    ///   `Compatibility.sharedCredentialLiteRefusal` for this app and they accepted it.
    ///   Without it, a Lite build of an app whose session lives outside the profile is
    ///   refused rather than created.
    public func create(plan: CreationPlan,
                       requestedMode: InstanceMode = .full,
                       acknowledgedSharedCredentialStore: Bool = false,
                       allowEmbeddedUpdater: Bool = false,
                       progress: ((String) -> Void)? = nil,
                       detailedProgress: (@Sendable (String, Double?) -> Void)? = nil) -> CreationOutcome {
        var created: [Instance] = []
        var failures: [(Int, String)] = []
        var degraded: [Int] = []
        var notes: [String] = []

        let source = URL(fileURLWithPath: plan.facts.path)

        for (i, number) in plan.numbers.enumerated() {
            let name = i < plan.names.count ? plan.names[i] : ""
            let accountLabel = i < plan.accountLabels.count ? plan.accountLabels[i] : ""
            let starting = "Building instance #\(number)\(name.isEmpty ? "" : " – \(name)")…"
            let startingFraction = Double(i) / Double(max(plan.numbers.count, 1))
            progress?(starting)
            detailedProgress?(starting, startingFraction)

            let request = BuildRequest(sourceBundle: source,
                                       facts: plan.facts,
                                       number: number,
                                       name: name,
                                       accountLabel: accountLabel,
                                       badge: i < plan.badges.count ? plan.badges[i] : nil,
                                       requestedMode: requestedMode,
                                       allowEmbeddedUpdater: allowEmbeddedUpdater,
                                       acknowledgedSharedCredentialStore:
                                        acknowledgedSharedCredentialStore)
            do {
                let result = try builder.build(request) { step, total, label in
                    let message = "#\(number): \(label) (\(step + 1)/\(total))"
                    let local = Double(step + 1) / Double(max(total, 1))
                    let overall = (Double(i) + local)
                        / Double(max(plan.numbers.count, 1))
                    progress?(message)
                    detailedProgress?(message, overall)
                }
                do {
                    try registry.addInstance(result.instance, toApp: plan.facts.bundleIdentifier)
                } catch {
                    do {
                        _ = try builder.remove(
                            instance: result.instance,
                            scope: .launcherAndData)
                    } catch let rollbackError {
                        throw MALError.rollbackIncomplete(
                            original: "registry commit: \(error)",
                            rollbackFailures: ["remove unregistered launcher/profile: \(rollbackError)"])
                    }
                    throw error
                }
                created.append(result.instance)
                if result.degradedToLite { degraded.append(number) }
                notes.append(contentsOf: result.notes)
            } catch {
                log.error("instance #\(number) failed: \(error)")
                failures.append((number, "\(error)"))
                // The build is over, so the number this attempt was holding goes back.
                // Leaving the reservation would burn the number until this process
                // exits, and a losing racer must leave nothing behind at all.
                registry.releaseReservedNumbers([number],
                                                appKey: plan.facts.bundleIdentifier)
            }
        }

        return CreationOutcome(created: created,
                               failures: failures.map { (number: $0.0, error: $0.1) },
                               degraded: degraded,
                               notes: Array(Set(notes)).sorted())
    }

    // MARK: - Lifecycle

    @discardableResult
    public func launch(_ instance: Instance) async throws -> pid_t {
        guard let pair = registry.instance(instance.id) else {
            throw MALError.instanceNotFound(instance.id)
        }
        guard pair.instance.mechanism != .configEnvironment else {
            throw MALError.notSupported(
                reason: "Terminal launchers are no longer supported. Create a GUI instance from the installed macOS application instead.")
        }
        let pid = try await supervisor.launch(pair.instance)
        try? registry.updateInstance(pair.instance.id) { $0.lastLaunchedAt = Date() }
        return pid
    }

    public func quit(_ instance: Instance) async -> Bool {
        guard let pair = registry.instance(instance.id) else { return true }
        return await supervisor.quit(pair.instance)
    }

    public func rename(_ instance: Instance, to newName: String, rebuildBundle: Bool = false) throws {
        guard let pair = registry.instance(instance.id) else {
            throw MALError.instanceNotFound(instance.id)
        }
        if rebuildBundle, pair.instance.mechanism == .configEnvironment {
            throw MALError.notSupported(
                reason: "Legacy terminal launchers cannot be rebuilt. Create a GUI application instance instead.")
        }
        let clean = Validation.sanitizeInstanceName(newName)
        guard rebuildBundle else {
            try registry.updateInstance(pair.instance.id) { $0.name = clean }
            return
        }
        var proposed = pair.instance
        proposed.name = clean
        _ = try rebuildProposed(proposed, app: pair.app)
    }

    public func setAccountLabel(_ instance: Instance, to label: String) throws {
        try registry.updateInstance(instance.id) { $0.accountLabel = Validation.sanitizeAccountLabel(label) }
    }

    public func setBadge(_ instance: Instance, to badge: BadgeSpec, rebuild doRebuild: Bool = true) throws {
        guard let pair = registry.instance(instance.id) else {
            throw MALError.instanceNotFound(instance.id)
        }
        if doRebuild, pair.instance.mechanism == .configEnvironment {
            throw MALError.notSupported(
                reason: "Legacy terminal launchers cannot be rebuilt. Create a GUI application instance instead.")
        }
        guard doRebuild else {
            try registry.updateInstance(pair.instance.id) { $0.badge = badge }
            return
        }
        var proposed = pair.instance
        proposed.badge = badge
        _ = try rebuildProposed(proposed, app: pair.app)
    }

    @discardableResult
    public func rebuild(_ instance: Instance,
                        progress: ((Int, Int, String) -> Void)? = nil) throws -> BuildResult {
        guard instance.mechanism != .configEnvironment else {
            throw MALError.notSupported(
                reason: "This is a legacy terminal launcher. Create a new instance from a macOS .app instead.")
        }
        guard let pair = registry.instance(instance.id) else {
            throw MALError.instanceNotFound(instance.id)
        }
        if supervisor.isRunning(pair.instance) {
            throw MALError.alreadyRunning(dataPath: pair.instance.dataPath)
        }
        return try rebuildProposed(pair.instance, app: pair.app, progress: progress)
    }

    /// Duplicates an instance's *configuration* under a new number. The new instance
    /// starts with an empty profile — copying a profile would copy a signed-in session
    /// into a second place, which is exactly what the user is trying to avoid.
    @discardableResult
    public func duplicate(_ instance: Instance) throws -> Instance {
        guard instance.mechanism != .configEnvironment else {
            throw MALError.notSupported(
                reason: "Legacy terminal launchers cannot be duplicated. Choose the installed GUI application in New Instances.")
        }
        guard let pair = registry.instance(instance.id) else {
            throw MALError.instanceNotFound(instance.id)
        }
        let source = URL(fileURLWithPath: pair.app.sourcePath)
        let facts = try scanner.fullFacts(at: source)
        let numbers = try registry.reserveNumbers(appKey: pair.app.appKey, count: 1)
        let number = numbers[0]

        let request = BuildRequest(sourceBundle: source,
                                   facts: facts,
                                   number: number,
                                   name: pair.instance.name.isEmpty ? "" : "\(pair.instance.name) copy",
                                   badge: BadgeSpec(scale: pair.instance.badge.scale,
                                                    position: pair.instance.badge.position,
                                                    shape: pair.instance.badge.shape,
                                                    colorHex: BadgeSpec.suggestedColor(forNumber: number),
                                                    outlined: pair.instance.badge.outlined),
                                   requestedMode: pair.instance.mode,
                                   extraArguments: pair.instance.extraArguments,
                                   extraEnvironment: pair.instance.extraEnvironment,
                                   // Carried over from the *stored* record, via the same
                                   // helper the rebuild path uses — and that record is
                                   // now the acknowledgement itself, not the mode.
                                   //
                                   // Duplicate is a bare one-click menu item with no
                                   // card in front of it, and it mints a *new* launcher.
                                   // If the original carries a real acknowledgement this
                                   // is a copy of a decision the user made; if it does
                                   // not — a pre-gate instance, a hand-edited registry —
                                   // there is no decision to copy, and the builder
                                   // refuses with the same message creation would give.
                                   acknowledgedSharedCredentialStore:
                                    acknowledgementAlreadyGiven(for: instance.id),
                                   acknowledgedSharedCredentialStoreAt:
                                    pair.instance.acknowledgedSharedCredentialStoreAt)
        let result: BuildResult
        do {
            result = try builder.build(request)
        } catch {
            registry.releaseReservedNumbers([number], appKey: pair.app.appKey)
            throw error
        }
        do {
            try registry.addInstance(result.instance, toApp: pair.app.appKey)
        } catch {
            registry.releaseReservedNumbers([number], appKey: pair.app.appKey)
            do {
                _ = try builder.remove(instance: result.instance, scope: .launcherAndData)
            } catch let rollbackError {
                throw MALError.rollbackIncomplete(
                    original: "registry commit: \(error)",
                    rollbackFailures: ["remove unregistered duplicate: \(rollbackError)"])
            }
            throw error
        }
        return result.instance
    }

    @discardableResult
    public func remove(_ instance: Instance,
                       scope: InstanceBuilder.RemovalScope) throws -> InstanceBuilder.RemovalReport {
        guard let pair = registry.instance(instance.id) else {
            throw MALError.instanceNotFound(instance.id)
        }
        let authoritative = pair.instance
        if supervisor.isRunning(authoritative) {
            throw MALError.alreadyRunning(dataPath: authoritative.dataPath)
        }
        try builder.validateRemoval(instance: authoritative, scope: scope)
        try launcherReconciler.markRemoved(
            authoritative,
            deleteData: scope == .launcherAndData)
        let report = try builder.remove(instance: authoritative, scope: scope)
        try registry.removeInstance(authoritative.id)
        directorySizeCache.invalidate([
            paths.instanceDir(authoritative.id),
            URL(fileURLWithPath: authoritative.dataPath),
        ])
        try launcherReconciler.clearRemoved(authoritative.id)
        return report
    }

    /// Explicit renumbering. Rebuilds every affected bundle so the icons and names match
    /// the new numbers, and refuses to run while any instance is open.
    public func renumber(appKey: String, progress: ((String) -> Void)? = nil) throws -> [Int: Int] {
        guard let app = registry.app(appKey) else { throw MALError.appNotManaged(appKey) }
        guard !app.instances.contains(where: { $0.mechanism == .configEnvironment }) else {
            throw MALError.notSupported(
                reason: "Legacy terminal launchers cannot be renumbered or rebuilt.")
        }
        for i in app.instances where supervisor.isRunning(i) {
            throw MALError.alreadyRunning(dataPath: i.dataPath)
        }
        let plan = NumberAllocator.renumberPlan(
            existingNumbers: app.instances.map(\.number),
            startingAt: 1)
        guard !plan.isEmpty else { return [:] }

        var completed: [Instance] = []
        do {
            for original in app.instances.sorted(by: { $0.number < $1.number }) {
                guard let newNumber = plan[original.number],
                      newNumber != original.number else { continue }
                var proposed = original
                proposed = Instance(
                    id: original.id,
                    number: newNumber,
                    name: original.name,
                    accountLabel: original.accountLabel,
                    mode: original.mode,
                    mechanism: original.mechanism,
                    bundlePath: original.bundlePath,
                    dataPath: original.dataPath,
                    badge: original.badge,
                    builtFromSourceVersion: original.builtFromSourceVersion,
                    clonedBundleIdentifier: original.clonedBundleIdentifier,
                    extraArguments: original.extraArguments,
                    extraEnvironment: original.extraEnvironment,
                    createdAt: original.createdAt,
                    lastLaunchedAt: original.lastLaunchedAt,
                    // Carried explicitly, because this rebuilds the row field by field
                    // and omitting it does not preserve it — it re-dates it. The
                    // acknowledgement still reads `true` from the registry, so the build
                    // fell through to `?? createdAt` and stamped the moment of the
                    // renumber as the moment the user accepted. "When did I agree to
                    // this" is the question the record exists to answer.
                    acknowledgedSharedCredentialStoreAt:
                        original.acknowledgedSharedCredentialStoreAt,
                    buildNotes: original.buildNotes)
                progress?("Rebuilding instance #\(newNumber)…")
                _ = try rebuildProposed(proposed, app: app)
                completed.append(original)
            }
        } catch {
            var rollbackFailures: [String] = []
            for original in completed.reversed() {
                guard let current = registry.instance(original.id) else { continue }
                do {
                    _ = try rebuildProposed(original, app: current.app)
                } catch {
                    rollbackFailures.append(
                        "restore instance \(original.id.uuidString): \(error)")
                }
            }
            if !rollbackFailures.isEmpty {
                throw MALError.rollbackIncomplete(
                    original: "\(error)",
                    rollbackFailures: rollbackFailures)
            }
            throw error
        }
        return plan
    }

    /// Re-registers an instance's bundle so it becomes the current owner of the source
    /// app's custom URL schemes.
    ///
    /// Only one bundle can win `claude://`-style registration at a time, so a deep-link
    /// sign-in returns to whichever instance registered last. This is the button the
    /// guided first-login flow tells the user to press before signing in to instance N.
    public func claimURLSchemes(_ instance: Instance) throws {
        guard let pair = registry.instance(instance.id) else {
            throw MALError.instanceNotFound(instance.id)
        }
        let authoritative = pair.instance
        guard authoritative.mechanism != .configEnvironment else {
            throw MALError.notSupported(
                reason: "Legacy terminal launchers do not own GUI URL schemes.")
        }
        guard authoritative.mode == .full else {
            throw MALError.notSupported(
                reason: "Lite launchers open the vendor-signed original application and do not declare its URL schemes. Use an in-app, device-code or password sign-in when available.")
        }
        let bundle = URL(fileURLWithPath: authoritative.bundlePath)
        guard FileManager.default.fileExists(atPath: bundle.path) else {
            throw MALError.launchFailed("the launcher for instance #\(authoritative.number) is missing. Rebuild it.")
        }
        _ = try LauncherIdentityVerifier.verify(
            bundle: bundle,
            paths: paths,
            expected: authoritative)
        registrar.register(bundle: bundle)
        log.info(
            "re-registered #\(authoritative.number) "
                + "[instance=\(authoritative.id.uuidString)] as the URL scheme owner")
    }

    /// Applies advanced settings and rebuilds the bundle so the shim's config matches.
    ///
    /// A new `dataPath` points the instance at a different profile; it does **not** move
    /// the existing one. Moving a signed-in profile behind the user's back is exactly the
    /// kind of surprise this product exists to avoid, so the old directory is left where
    /// it is and the UI says so.
    /// - Parameter acknowledgedSharedCredentialStore: required when `forceLite` would
    ///   convert an instance of a shared-credential-store application from Full to Lite.
    ///   Without it that conversion is refused, exactly as creating one would be — this
    ///   used to be the one route into Lite mode that asked nobody anything.
    public func updateAdvancedSettings(_ instance: Instance,
                                       arguments: [String],
                                       environment: [String: String],
                                       forceLite: Bool,
                                       acknowledgedSharedCredentialStore: Bool = false,
                                       dataPath: String? = nil) throws {
        guard let pair = registry.instance(instance.id) else {
            throw MALError.instanceNotFound(instance.id)
        }
        guard pair.instance.mechanism != .configEnvironment else {
            throw MALError.notSupported(
                reason: "Legacy terminal launchers cannot be rebuilt. Create a GUI application instance instead.")
        }
        let args = try ArgumentBuilder.sanitizeExtraArguments(arguments)
        let env = try ArgumentBuilder.sanitizeEnvironment(environment)
        if let dataPath {
            try Validation.validateAbsolutePath(dataPath, label: "data directory")
            try validateProfilePath(dataPath, for: pair.instance)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: dataPath, isDirectory: &isDir), !isDir.boolValue {
                throw MALError.invalidPath(dataPath, reason: "a file already exists at this path")
            }
        }
        if supervisor.isRunning(pair.instance) {
            throw MALError.alreadyRunning(dataPath: pair.instance.dataPath)
        }
        var proposed = pair.instance
        proposed.extraArguments = args
        proposed.extraEnvironment = env
        if forceLite { proposed.mode = .lite }
        if let dataPath { proposed.dataPath = dataPath }
        _ = try rebuildProposed(
            proposed,
            app: pair.app,
            acknowledgedSharedCredentialStore: acknowledgedSharedCredentialStore)
    }

    /// Instances the registry knows about whose launcher is no longer on disk.
    ///
    /// Removing an app by dragging it to the Trash is a completely normal thing to do on
    /// a Mac, and the launcher has to cope with it rather than showing a row that opens
    /// nothing. These are surfaced in the interface as "removed in Finder" with an
    /// action to finish the job.
    public func instancesMissingTheirLauncher() -> [Instance] {
        registry.allInstances
            .map(\.instance)
            .filter { !FileManager.default.fileExists(atPath: $0.bundlePath) }
    }

    /// Drops an instance from the registry when its launcher is already gone.
    ///
    /// Deliberately separate from `remove`: there is no bundle left to delete, the
    /// instance may not be recoverable, and the profile is a decision of its own.
    @discardableResult
    public func forget(_ instance: Instance, alsoDeleteData: Bool) throws -> InstanceBuilder.RemovalReport {
        guard let pair = registry.instance(instance.id) else {
            throw MALError.instanceNotFound(instance.id)
        }
        let authoritative = pair.instance
        if supervisor.isRunning(authoritative) {
            throw MALError.alreadyRunning(dataPath: authoritative.dataPath)
        }
        let scope: InstanceBuilder.RemovalScope =
            alsoDeleteData ? .launcherAndData : .launcherOnly
        try builder.validateRemoval(instance: authoritative, scope: scope)
        try launcherReconciler.markRemoved(
            authoritative,
            deleteData: scope == .launcherAndData)
        let report = try builder.remove(
            instance: authoritative,
            scope: scope)
        try registry.removeInstance(authoritative.id)
        directorySizeCache.invalidate([
            paths.instanceDir(authoritative.id),
            URL(fileURLWithPath: authoritative.dataPath),
        ])
        try launcherReconciler.clearRemoved(authoritative.id)
        log.info("forgot instance #\(authoritative.number); its launcher was already gone")
        return report
    }

    // MARK: - Housekeeping

    public func refreshSourceVersions() {
        for app in registry.allApps {
            let url = URL(fileURLWithPath: app.sourcePath)
            guard let facts = try? scanner.fullFacts(at: url) else { continue }
            _ = try? registry.upsertApp(appKey: app.appKey,
                                        displayName: facts.displayName,
                                        sourcePath: facts.path,
                                        sourceVersion: facts.version)
        }
    }

    /// Scans LaunchAgain's launcher directory and restores any valid launcher that is
    /// absent from the registry. This is cheap and bounded, but deliberately explicit
    /// rather than part of the four-second running-state poll.
    @discardableResult
    public func reconcileInstalledLaunchers() throws -> LauncherReconciler.Report {
        try launcherReconciler.reconcile(registry: registry)
    }

    public func sweep(onSizeScan: ((String) -> Void)? = nil) -> [OrphanSweeper.Finding] {
        sweeper.sweep(registry: registry, onSizeScan: onSizeScan)
    }

    public func exportDiagnostics(to url: URL) throws -> URL {
        try diagnostics.export(registry: registry, scanner: scanner, to: url)
    }

    /// Whether the shared-session consequence has already been accepted for this
    /// instance, read from **the registry** rather than from anything a caller proposes.
    ///
    /// The question is answered from the recorded acknowledgement itself
    /// (`acknowledgedSharedCredentialStoreAt`), not from `mode == .lite`. Being Lite is
    /// a state that has several origins — an instance created before this field existed,
    /// one that a hand-edited registry says is Lite — and only one of them is "the user
    /// was shown the disclosure and accepted it". An instance with no recorded
    /// acknowledgement is un-acknowledged; one that has it is not re-asked, so a rebuild
    /// of an acknowledged instance goes through silently.
    ///
    /// What happens to an un-acknowledged instance depends on what is being asked for,
    /// and this answer is only half of it. `duplicate` mints a new launcher and is
    /// refused. A rebuild of one that is *already* Lite in the store is allowed anyway,
    /// on the separate ground that it introduces no sharing — it is not treated as
    /// acknowledged, and records nothing. See `rebuildProposed`.
    private func acknowledgementAlreadyGiven(for id: UUID) -> Bool {
        registry.instance(id)?.instance.acknowledgedSharedCredentialStoreAt != nil
    }

    /// - Parameter acknowledgedSharedCredentialStore: an acknowledgement the *caller*
    ///   obtained from the user for this specific change. It is OR-ed with what the
    ///   stored record already implies; `proposed` is never consulted, because a caller
    ///   that sets `proposed.mode = .lite` would otherwise be answering its own question.
    private func rebuildProposed(
        _ proposed: Instance,
        app: ManagedApp,
        acknowledgedSharedCredentialStore: Bool = false,
        progress: ((Int, Int, String) -> Void)? = nil
    ) throws -> BuildResult {
        if let current = registry.instance(proposed.id)?.instance,
           supervisor.isRunning(current) {
            throw MALError.alreadyRunning(dataPath: current.dataPath)
        }
        let source = URL(fileURLWithPath: app.sourcePath)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw MALError.sourceNotFound(app.sourcePath)
        }
        let facts = try scanner.fullFacts(at: source)
        let acknowledged = acknowledgedSharedCredentialStore
            || acknowledgementAlreadyGiven(for: proposed.id)
        // Read from the **launcher on disk**, not from `proposed` and not from the
        // registry row.
        //
        // Not from `proposed`, because on the Advanced path that is the proposal and
        // `forceLite` has already set its mode. Comparing the two is the whole point —
        // Full ▸ Force Lite introduces a shared session and is gated, while Lite ▸ rebuild
        // (or rename, which changes only the name) does not and is not. Such an instance
        // has no *command-line* route to supply an acknowledgement, since
        // `--acknowledge-shared-credentials` is a `create` flag; Advanced ▸ Apply does
        // offer one.
        //
        // Not from the registry row, because the allowance's justification — "this
        // launcher is already Lite, so the rebuild introduces no sharing" — is a claim
        // about the disk, and a row is a record that can disagree with the bundle it
        // describes. A row edited to say Lite over a Full clone would otherwise convert a
        // clone that has its own ad-hoc identity, and genuinely cannot read the vendor's
        // Keychain items, into a launcher that runs the vendor-signed original and shares
        // them outright. That is exactly the sharing the gate exists to prevent, so the
        // gate reads the same physical fact `LauncherReconciler` does.
        //
        // Unreadable or absent config fails closed. A stored-Lite instance whose launcher
        // is gone is not "already Lite on disk" — rebuilding it would put a shared session
        // somewhere there currently is none — so it is gated, and the acknowledgement is
        // given the way any other instance gives one: Advanced ▸ tick ▸ Apply.
        let storedBundlePath = registry.instance(proposed.id)?.instance.bundlePath
        let onDiskMode = storedBundlePath.flatMap { path in
            try? BundleAssembler.readInstanceConfig(from: URL(fileURLWithPath: path)).mode
        }
        let rebuildsExistingLiteLauncher = onDiskMode == .lite && proposed.mode == .lite
        return try builder.rebuild(
            instance: proposed,
            sourceBundle: source,
            facts: facts,
            acknowledgedSharedCredentialStore: acknowledged,
            rebuildsExistingLiteLauncher: rebuildsExistingLiteLauncher,
            progress: progress) { result in
                try self.registry.commitRebuild(
                    originalID: proposed.id,
                    rebuilt: result.instance,
                    appKey: app.appKey,
                    displayName: facts.displayName,
                    sourcePath: facts.path,
                    sourceVersion: facts.version)
            }
    }

    /// A profile may be the instance's exact default or a genuinely external custom
    /// directory. It may never overlap another instance or occupy an internal
    /// LaunchAgain support path.
    private func validateProfilePath(_ rawPath: String, for instance: Instance) throws {
        let candidate = URL(fileURLWithPath: rawPath).standardizedFileURL.path
        let ownDefault = paths.instanceDataDir(instance.id).standardizedFileURL.path
        if candidate == ownDefault { return }

        if Validation.isPath(candidate, within: paths.support.standardizedFileURL.path) {
            throw MALError.invalidPath(
                rawPath,
                reason: "custom profiles cannot use LaunchAgain's internal support directory")
        }

        for pair in registry.allInstances where pair.instance.id != instance.id {
            let other = URL(fileURLWithPath: pair.instance.dataPath)
                .standardizedFileURL.path
            if candidate == other
                || Validation.isPath(candidate, within: other)
                || Validation.isPath(other, within: candidate) {
                throw MALError.invalidPath(
                    rawPath,
                    reason: "this directory overlaps instance #\(pair.instance.number)'s profile")
            }
        }
    }

    /// Completes only user-confirmed operations represented by durable journal files.
    /// A legacy text tombstone is resumed only while its registry row still supplies an
    /// authoritative identity; otherwise it is retained for explicit review.
    private static func resumePendingRemovals(
        paths: MALPaths,
        registry: Registry,
        builder: InstanceBuilder,
        supervisor: LaunchSupervisor,
        reconciler: LauncherReconciler,
        sizeCache: DirectorySizeCache,
        log: MALLog
    ) {
        for pending in reconciler.pendingRemovalRecords() {
            guard let record = pending.record else {
                // Retained, because without a recorded deletion scope there is nothing
                // safe to finish. This used to warn on every single process start with
                // no way to clear it; `doctor` and Health now report it as a
                // `staleRemovalMarker` finding with an explicit Delete action, so the
                // repetition here is noise rather than news.
                log.debug("retained legacy removal marker \(pending.id.uuidString): its original deletion scope is unknown; reported by the health check")
                continue
            }
            let registered = registry.instance(pending.id)?.instance
            let instance = registered ?? record.instance
            guard !supervisor.isRunning(instance) else {
                log.warn("deferred removal resume for running instance \(pending.id.uuidString)")
                continue
            }
            let scope: InstanceBuilder.RemovalScope =
                record.deleteData ? .launcherAndData : .launcherOnly
            do {
                log.info(
                    "resuming confirmed uninstall "
                        + "[instance=\(instance.id.uuidString)]")
                try builder.validateRemoval(instance: instance, scope: scope)
                _ = try builder.remove(instance: instance, scope: scope)
                if registered != nil {
                    try registry.removeInstance(instance.id)
                }
                sizeCache.invalidate([
                    paths.instanceDir(instance.id),
                    URL(fileURLWithPath: instance.dataPath),
                ])
                try reconciler.clearRemoved(instance.id)
                log.info("resumed and completed uninstall for instance #\(instance.number)")
            } catch {
                // If builder removal reached its scrub stage, the log's persisted
                // suppression fingerprint also prevents this failure report from
                // putting the deleted UUID back. The number remains useful to a human.
                log.warn("could not resume uninstall for instance #\(instance.number): \(error)")
            }
        }
    }

    private func bookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: [.withSecurityScope],
                             includingResourceValuesForKeys: nil,
                             relativeTo: nil)
    }
}
#endif
