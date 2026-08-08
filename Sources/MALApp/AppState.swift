//
//  AppState — the single object the interface observes.
//
//  Everything the UI needs to render is a published value here, and every operation
//  that touches the filesystem runs on one serial background queue. That is deliberate:
//  builds, rebuilds and deletes must not interleave, and the simplest way to guarantee
//  that is to give them one lane rather than a lock per component.
//
//  The rule the whole file follows: published state is only ever mutated on the main
//  thread, and the engine is only ever called off it.
//

#if canImport(AppKit)
import Foundation
import SwiftUI
import AppKit
import MALCore
import MALKit

/// Owns AppKit/Dispatch registrations whose cleanup must not depend on actor-isolated
/// deinitialization. Swift 6.0 treats a global-actor class's `deinit` as nonisolated,
/// while newer compilers offer `isolated deinit`; keeping the handles in a small locked
/// owner works on both toolchains and still guarantees cancellation on release.
private final class AppServiceHandles: @unchecked Sendable {
    private let lock = NSLock()
    private var timer: Timer?
    private var watchers: [DispatchSourceFileSystemObject] = []
    private var observer: NSObjectProtocol?

    func install(timer newTimer: Timer) {
        lock.lock()
        let previous = timer
        timer = newTimer
        lock.unlock()
        previous?.invalidate()
    }

    func install(observer newObserver: NSObjectProtocol) {
        lock.lock()
        let previous = observer
        observer = newObserver
        lock.unlock()
        if let previous { NotificationCenter.default.removeObserver(previous) }
    }

    func append(watcher: DispatchSourceFileSystemObject) {
        lock.lock()
        watchers.append(watcher)
        lock.unlock()
    }

    func cancelAll() {
        lock.lock()
        let timer = timer
        let watchers = watchers
        let observer = observer
        self.timer = nil
        self.watchers.removeAll()
        self.observer = nil
        lock.unlock()

        timer?.invalidate()
        for watcher in watchers { watcher.cancel() }
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    deinit { cancelAll() }
}

@MainActor
final class AppState: ObservableObject {

    // MARK: Published state

    @Published private(set) var running: Set<UUID> = []
    @Published private(set) var profileSizes: [UUID: Int64] = [:]
    @Published private(set) var findings: [OrphanSweeper.Finding] = []
    /// When the orphan sweep last ran. Nil means it has not run, which is a different
    /// thing from "it ran and found nothing" — and the interface must not conflate them.
    @Published private(set) var lastSweptAt: Date?

    /// Non-nil while a long operation is in flight. The interface disables destructive
    /// actions rather than trying to queue them.
    @Published var activity: Activity?
    @Published var banner: Banner?
    /// Whether the sidebar column is shown. Persisted, because a window that forgets
    /// how the user left it is a worse default than either state.
    @Published var sidebarVisible: Bool = AppState.storedSidebarVisible {
        didSet {
            guard sidebarVisible != oldValue else { return }
            UserDefaults.standard.set(sidebarVisible, forKey: AppState.sidebarVisibleKey)
        }
    }
    /// Set when the engine could not start at all; the window shows this instead.
    @Published private(set) var startupError: String?

    private static let sidebarVisibleKey = "com.launchagain.sidebarVisible"
    private static var storedSidebarVisible: Bool {
        UserDefaults.standard.object(forKey: sidebarVisibleKey) as? Bool ?? true
    }

    /// The sheet currently being presented, if any.
    ///
    /// One property, one `.sheet` modifier. Two `.sheet`s attached to the same view is
    /// not supported on macOS: it presents unreliably and, when one is dismissed, can
    /// leave the window behind it blank — which is exactly what "I deleted one and
    /// everything disappeared" looked like.
    @Published var presentation: Presentation?

    enum Presentation: Identifiable {
        case create
        case confirmDelete(Instance)

        var id: String {
            switch self {
            case .create: return "create"
            case .confirmDelete(let instance): return "delete-\(instance.id.uuidString)"
            }
        }
    }

    /// Every route into deletion — the trash button on a row, the right-click menu, the
    /// instance screen — comes through here, so there is one confirmation dialog and one
    /// code path behind it.
    func requestDelete(_ instance: Instance) {
        presentation = .confirmDelete(instance)
    }
    struct Activity: Equatable {
        var title: String
        var detail: String
        var fraction: Double?
    }

    struct Banner: Identifiable, Equatable {
        enum Kind { case info, success, warning, failure }
        let id = UUID()
        var kind: Kind
        var title: String
        var message: String
        var details: [String] = []
    }

    enum Selection: Hashable {
        case allInstances
        case app(String)
        case health
    }

    /// Values that must agree are published as one snapshot. Publishing `apps` first
    /// and repairing selection afterwards briefly exposed an impossible combination to
    /// SwiftUI's view graph: a selected row that was no longer present.
    private struct DashboardSnapshot: Equatable {
        var apps: [ManagedApp] = []
        var selection: Selection = .allInstances
        var selectedInstance: UUID?
        var missingLaunchers: Set<UUID> = []
    }

    @Published private var dashboard = DashboardSnapshot()

    var apps: [ManagedApp] { dashboard.apps }
    var selection: Selection {
        get { dashboard.selection }
        set {
            guard dashboard.selection != newValue else { return }
            var updated = dashboard
            updated.selection = newValue
            dashboard = updated
        }
    }
    var selectedInstance: UUID? {
        get { dashboard.selectedInstance }
        set {
            guard dashboard.selectedInstance != newValue else { return }
            var updated = dashboard
            updated.selectedInstance = newValue
            dashboard = updated
        }
    }
    private(set) var missingLaunchers: Set<UUID> {
        get { dashboard.missingLaunchers }
        set {
            guard dashboard.missingLaunchers != newValue else { return }
            var updated = dashboard
            updated.missingLaunchers = newValue
            dashboard = updated
        }
    }

    // MARK: Engine

    private(set) var manager: InstanceManager?
    /// One factory for the whole session: it owns a cache directory, and the badge
    /// previews redraw on every keystroke in the badge editor.
    private(set) var iconFactory: IconFactory?
    private let work = DispatchQueue(label: "com.launchagain.ui.work", qos: .userInitiated)
    private let serviceHandles = AppServiceHandles()
    private var registryRefreshWorkItem: DispatchWorkItem?
    private var scheduledRefreshNeedsLauncherScan = false
    private var runningWorkKey: [UUID]?
    private var pendingRunningInstances: [Instance]?
    private struct SizeWorkKey: Hashable {
        let id: UUID
        let path: String
    }
    private var sizeWorkKey: [SizeWorkKey]?
    private var pendingSizeInstances: [Instance]?
    private var healthCheckPending = false

    init(paths explicitPaths: MALPaths? = nil, startServices: Bool = true) {
        do {
            let environmentRoot = ProcessInfo.processInfo.environment["LAUNCHAGAIN_ROOT"]
                .map { MALPaths.rooted(at: URL(fileURLWithPath: $0)) }
            let paths = explicitPaths ?? environmentRoot ?? .standard()
            let shouldMigrateRealStore = explicitPaths == nil && environmentRoot == nil
            let m = try InstanceManager(paths: paths,
                                        migrateFrom: shouldMigrateRealStore ? .legacy() : nil)
            manager = m
            iconFactory = IconFactory(cacheDir: m.paths.iconCacheDir, log: .silent)
            let recovered = m.initialLauncherReconciliation.recoveredInstanceIDs.count
            let legacyTerminalCount = m.registry.allInstances.reduce(into: 0) { count, pair in
                if pair.instance.mechanism == .configEnvironment { count += 1 }
            }
            if legacyTerminalCount > 0 {
                var details = [
                    "LaunchAgain now creates and opens GUI applications only.",
                    "For Codex, choose New Instances and select /Applications/ChatGPT.app; it is shown as Codex.",
                    "The source application and the legacy session remain untouched until you confirm Uninstall Instance.",
                ]
                if recovered > 0 {
                    details.append("Also recovered \(recovered) installed launcher\(recovered == 1 ? "" : "s") from disk.")
                }
                banner = Banner(
                    kind: .warning,
                    title: "Legacy Terminal launcher disabled",
                    message: "\(legacyTerminalCount) older Terminal-based instance\(legacyTerminalCount == 1 ? "" : "s") can no longer be launched.",
                    details: details)
            } else if recovered > 0 {
                banner = Banner(
                    kind: .success,
                    title: "Recovered installed launchers",
                    message: "Restored \(recovered) instance\(recovered == 1 ? "" : "s") from the launcher apps already on this Mac.")
            } else if m.registry.recoveredFromCorruption {
                banner = Banner(
                    kind: .warning,
                    title: "The registry needed repair",
                    message: "Unreadable registry files were preserved. No recoverable launcher was missing from the rebuilt list.",
                    details: m.registry.preservedCorruptFiles)
            }
        } catch {
            startupError = "\(error)"
        }
        refresh(scheduleDerivedWork: startServices)
        if startServices {
            startPolling()
            // Sweep once at startup so the Health badge means something before anyone
            // clicks anything. Quiet: no spinner, no modal.
            runHealthCheck(showActivity: false)
        }
    }

    // MARK: Derived views of the data

    var allInstances: [(app: ManagedApp, instance: Instance)] {
        var flat: [(app: ManagedApp, instance: Instance)] = []
        for a in apps {
            for i in a.instances { flat.append((app: a, instance: i)) }
        }
        return flat.sorted { lhs, rhs in
            let l = lhs.app.displayName
            let r = rhs.app.displayName
            if l == r { return lhs.instance.number < rhs.instance.number }
            return l.localizedCaseInsensitiveCompare(r) == .orderedAscending
        }
    }

    var visibleInstances: [(app: ManagedApp, instance: Instance)] {
        switch selection {
        case .allInstances, .health: return allInstances
        case .app(let key):          return allInstances.filter { $0.app.appKey == key }
        }
    }

    func instance(_ id: UUID?) -> (app: ManagedApp, instance: Instance)? {
        guard let id else { return nil }
        return allInstances.first { $0.instance.id == id }
    }

    func isRunning(_ i: Instance) -> Bool { running.contains(i.id) }

    func isStale(_ pair: (app: ManagedApp, instance: Instance)) -> Bool {
        let i = pair.instance
        return i.mode == .full
            && !i.builtFromSourceVersion.isEmpty
            && !pair.app.sourceVersion.isEmpty
            && i.builtFromSourceVersion != pair.app.sourceVersion
    }

    var busy: Bool { activity != nil }

    // MARK: Refresh

    func refresh() {
        refresh(scheduleDerivedWork: true)
    }

    /// User-facing refresh: checks both the registry and the installed launcher apps.
    /// Unlike the four-second running-state poll, this performs filesystem recovery and
    /// therefore runs on the serial work queue.
    func refreshFromDisk(showActivity: Bool = true) {
        guard let manager, !busy else { return }
        if showActivity {
            setActivity("Refreshing", "Scanning installed LaunchAgain apps and the registry…")
        }
        work.async { [weak self] in
            let result = Result { try manager.reconcileInstalledLaunchers() }
            Task { @MainActor in
                guard let self else { return }
                if showActivity { self.activity = nil }
                self.refresh()
                switch result {
                case .success(let report):
                    if !report.recoveredInstanceIDs.isEmpty {
                        let count = report.recoveredInstanceIDs.count
                        self.banner = Banner(
                            kind: .success,
                            title: "Recovered installed launchers",
                            message: "Restored \(count) instance\(count == 1 ? "" : "s") from launcher apps on disk.")
                    } else if !report.conflicts.isEmpty {
                        self.banner = Banner(
                            kind: .warning,
                            title: "Refresh found conflicts",
                            message: "No registry entries were replaced.",
                            details: report.conflicts)
                    } else if !report.unreadableLaunchers.isEmpty {
                        self.banner = Banner(
                            kind: .warning,
                            title: "Some launcher apps could not be verified",
                            message: "They were left untouched and no registry entry was replaced.",
                            details: report.unreadableLaunchers)
                    } else if showActivity {
                        self.banner = Banner(
                            kind: .success,
                            title: "Up to date",
                            message: "Every installed launcher is present in the registry.")
                    }
                case .failure(let error):
                    self.banner = Banner(
                        kind: .failure,
                        title: "Refresh failed",
                        message: "\(error)")
                }
            }
        }
    }

    private func refresh(scheduleDerivedWork: Bool) {
        guard let manager else { return }
        // Pick up anything written by the command line tool or another window before
        // rendering, so the list always describes the registry as it is now.
        manager.registry.reloadIfChanged()
        // Empty records are filtered defensively even though Registry now prunes them.
        let loadedApps = manager.registry.allApps.filter { !$0.instances.isEmpty }
        let validInstanceIDs = Set(loadedApps.flatMap { $0.instances.map(\.id) })
        let missing = Set(manager.instancesMissingTheirLauncher().map(\.id))

        var repaired = dashboard
        repaired.apps = loadedApps
        repaired.missingLaunchers = missing
        if let selected = repaired.selectedInstance, !validInstanceIDs.contains(selected) {
            repaired.selectedInstance = nil
        }
        if case .app(let key) = repaired.selection,
           !loadedApps.contains(where: { $0.appKey == key }) {
            repaired.selection = .allInstances
        }
        if dashboard != repaired { dashboard = repaired }

        if scheduleDerivedWork {
            refreshRunning()
            recomputeSizes()
        }
    }

    func isMissingLauncher(_ instance: Instance) -> Bool {
        missingLaunchers.contains(instance.id)
    }

    /// Finishes removing an instance whose launcher is already gone from disk.
    func forget(_ instance: Instance) {
        perform("Removing", "Tidying up #\(instance.number)…") { manager in
            try manager.forget(instance, alsoDeleteData: true)
        } success: { [weak self] report in
            self?.selectedInstance = nil
            var details = ["Every LaunchAgain-owned file for this instance was removed."]
            let count = report.removedAssociatedArtifacts.count
            if count > 0 {
                details.append("Also removed \(count) macOS support item\(count == 1 ? "" : "s") keyed only to this instance's generated identifier.")
            }
            if let kept = report.keptDataPath, let why = report.keptReason {
                details.append("\(why) It is at \(kept).")
            }
            self?.banner = Banner(
                kind: .success,
                title: "Uninstalled #\(instance.number)",
                message: report.keptDataPath == nil
                    ? "Its launcher was already gone; its complete LaunchAgain-owned instance directory was moved to the Trash."
                    : "Its launcher was already gone. LaunchAgain-owned files were removed and the external profile was kept.",
                details: details)
        }
    }

    private func startPolling() {
        // Running state is the only thing that changes without us doing it.
        let t = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshRunning() }
        }
        t.tolerance = 1.0
        serviceHandles.install(timer: t)

        // The registry can also change underneath a running window — the CLI writes
        // the same file, and a second window would too. Re-reading it whenever the app is
        // brought to the front is cheap and means the dashboard is never quietly stale.
        let observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main) { [weak self] _ in
                Task { @MainActor in self?.scheduleRegistryRefresh() }
            }
        serviceHandles.install(observer: observer)

        startWatchingBundlesDirectory()
    }

    /// Watches the two directories that describe what exists: the folder the launchers
    /// live in, so dragging one to the Trash in Finder is reflected here within a moment
    /// instead of leaving a row that opens nothing; and the support folder, so a change
    /// made by the command line tool shows up without a restart.
    private func startWatchingBundlesDirectory() {
        guard let paths = manager?.paths else { return }
        // Every launcher root, not just the default one: a launcher dragged out of
        // /Applications/LaunchAgain in Finder has to disappear from the list too.
        for dir in paths.bundleRoots + [paths.support] {
            let fd = Darwin.open(dir.path, O_EVTONLY)
            guard fd >= 0 else { continue }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .delete, .rename],
                queue: DispatchQueue.main)
            source.setEventHandler { [weak self] in
                let shouldScan = dir != paths.support
                Task { @MainActor in
                    self?.scheduleRegistryRefresh(reconcileLaunchers: shouldScan)
                }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            serviceHandles.append(watcher: source)
        }
    }

    /// A registry write is atomic but creates several vnode notifications. Coalescing
    /// them prevents ten identical refreshes and their derived work from piling up.
    private func scheduleRegistryRefresh(reconcileLaunchers: Bool = false) {
        scheduledRefreshNeedsLauncherScan =
            scheduledRefreshNeedsLauncherScan || reconcileLaunchers
        registryRefreshWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.registryRefreshWorkItem = nil
                let needsScan = self.scheduledRefreshNeedsLauncherScan
                self.scheduledRefreshNeedsLauncherScan = false
                if needsScan {
                    self.refreshFromDisk(showActivity: false)
                } else {
                    self.refresh()
                }
            }
        }
        registryRefreshWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(175), execute: item)
    }

    private func refreshRunning() {
        let instances = allInstances.map(\.instance)
        let key = instances.map(\.id).sorted { $0.uuidString < $1.uuidString }
        if runningWorkKey != nil {
            if runningWorkKey != key { pendingRunningInstances = instances }
            return
        }
        startRunningRefresh(instances, key: key)
    }

    private func startRunningRefresh(_ instances: [Instance], key: [UUID]) {
        guard let manager else { return }
        runningWorkKey = key
        work.async { [weak self] in
            var live: Set<UUID> = []
            for i in instances where manager.supervisor.isRunning(i) { live.insert(i.id) }
            Task { @MainActor in
                guard let self else { return }
                self.runningWorkKey = nil
                if self.running != live { self.running = live }
                if let pending = self.pendingRunningInstances {
                    self.pendingRunningInstances = nil
                    let pendingKey = pending.map(\.id).sorted { $0.uuidString < $1.uuidString }
                    self.startRunningRefresh(pending, key: pendingKey)
                }
            }
        }
    }

    private func recomputeSizes() {
        let instances = allInstances.map(\.instance)
        let key = instances.map { SizeWorkKey(id: $0.id, path: $0.dataPath) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        if sizeWorkKey != nil {
            if sizeWorkKey != key { pendingSizeInstances = instances }
            return
        }
        startSizeRefresh(instances, key: key)
    }

    private func startSizeRefresh(_ instances: [Instance], key: [SizeWorkKey]) {
        guard let manager else { return }
        sizeWorkKey = key
        work.async { [weak self] in
            var sizes: [UUID: Int64] = [:]
            for i in instances {
                sizes[i.id] = manager.directorySizeCache.size(
                    of: URL(fileURLWithPath: i.dataPath))
            }
            Task { @MainActor in
                guard let self else { return }
                self.sizeWorkKey = nil
                let currentIDs = Set(self.allInstances.map(\.instance.id))
                if currentIDs == Set(sizes.keys), self.profileSizes != sizes {
                    self.profileSizes = sizes
                }
                if let pending = self.pendingSizeInstances {
                    self.pendingSizeInstances = nil
                    let pendingKey = pending.map { SizeWorkKey(id: $0.id, path: $0.dataPath) }
                        .sorted { $0.id.uuidString < $1.id.uuidString }
                    self.startSizeRefresh(pending, key: pendingKey)
                }
            }
        }
    }

    /// `showActivity` is false for the sweep that runs at startup: it should keep the
    /// badge honest without putting a modal spinner in front of someone who just opened
    /// the window.
    func runHealthCheck(showActivity: Bool = true) {
        guard let manager else { return }
        guard !healthCheckPending else { return }
        healthCheckPending = true
        if showActivity {
            setActivity("Checking", "Looking for orphans, stale builds and source updates…")
        }
        work.async { [weak self] in
            manager.refreshSourceVersions()
            let f = manager.sweep()
            Task { @MainActor in
                guard let self else { return }
                self.healthCheckPending = false
                self.findings = f
                self.lastSweptAt = Date()
                if showActivity { self.activity = nil }
                self.refresh()
            }
        }
    }

    /// Deletes one thing the health check found, because the user asked for that one
    /// thing. Used for leftover profiles, which are never removed automatically.
    func removeFinding(_ finding: OrphanSweeper.Finding) {
        guard let manager else { return }
        setActivity("Deleting", "Removing \(finding.path)…")
        work.async { [weak self] in
            let result = Result { try manager.sweeper.remove(finding) }
            let after = manager.sweep()
            Task { @MainActor in
                guard let self else { return }
                self.findings = after
                self.activity = nil
                switch result {
                case .success(let freed):
                    self.banner = Banner(kind: .success, title: "Deleted",
                                         message: "Freed \(FSOps.humanBytes(freed)).",
                                         details: [finding.path])
                case .failure(let error):
                    self.banner = Banner(kind: .failure, title: "Could not delete", message: "\(error)")
                }
            }
        }
    }

    func cleanFindings() {
        guard let manager else { return }
        let cleanable = findings.filter(\.safeToClean)
        guard !cleanable.isEmpty else { return }
        setActivity("Cleaning", "Removing \(cleanable.count) leftover item(s)…")
        work.async { [weak self] in
            let (n, freed) = manager.sweeper.clean(cleanable)
            let f = manager.sweep()
            Task { @MainActor in
                guard let self else { return }
                self.findings = f
                self.activity = nil
                self.banner = Banner(
                    kind: .success, title: "Cleaned up",
                    message: "Moved \(n) item(s) to the Trash, freeing \(FSOps.humanBytes(freed)). "
                        + "You can put them back until the Trash is emptied.")
                self.refresh()
            }
        }
    }

    // MARK: Creating

    /// Verdicts for source applications the dashboard already knows about, keyed by app.
    ///
    /// The instance detail screen needs one thing from a verdict — whether this
    /// application keeps its session outside the redirected profile — before it can let
    /// anyone switch an instance to Lite mode. Inspecting runs `codesign`, so it happens
    /// once per application on a background queue and the answer is kept.
    @Published private(set) var verdictsByAppKey: [String: CompatibilityVerdict] = [:]

    /// The verdict for the application this instance was built from, if it has been
    /// inspected. Requests an inspection when it has not, so the caller can simply read
    /// it again on the next render.
    func verdict(forAppKey appKey: String) -> CompatibilityVerdict? {
        if let cached = verdictsByAppKey[appKey] { return cached }
        guard let app = apps.first(where: { $0.appKey == appKey }),
              FileManager.default.fileExists(atPath: app.sourcePath) else { return nil }
        guard !inspectionsInFlight.contains(appKey) else { return nil }
        inspectionsInFlight.insert(appKey)
        inspect(URL(fileURLWithPath: app.sourcePath)) { [weak self] result in
            guard let self else { return }
            self.inspectionsInFlight.remove(appKey)
            if case .success(let (_, verdict)) = result {
                self.verdictsByAppKey[appKey] = verdict
            }
        }
        return nil
    }

    private var inspectionsInFlight: Set<String> = []

    /// Inspects an application off the main thread and hands back the facts and verdict.
    func inspect(_ url: URL,
                 completion: @escaping @MainActor @Sendable
                    (Result<(AppFacts, CompatibilityVerdict), Error>) -> Void) {
        guard let manager else { return }
        work.async {
            let result = Result { try manager.inspect(url) }
            Task { @MainActor in
                completion(result.map { ($0.facts, $0.verdict) })
            }
        }
    }

    func browseInstalledApps(
        completion: @escaping @MainActor @Sendable ([AppFacts]) -> Void
    ) {
        guard let manager else { return completion([]) }
        work.async {
            let list = manager.browseInstalledApps()
            Task { @MainActor in completion(list) }
        }
    }

    struct CreateSpec: Sendable {
        var source: URL
        var count: Int
        var names: [String]
        var accountLabels: [String]
        var badges: [BadgeSpec]
        var forceLite: Bool
        var stripURLSchemes: Bool
        /// The user was shown `Compatibility.sharedCredentialLiteRefusal` for this app
        /// and accepted it. Only meaningful with `forceLite`; without it a Lite build of
        /// such an app is refused by the engine.
        var acknowledgedSharedCredentialStore: Bool = false
        /// Advanced, off by default: leave the clone's own updater working.
        var allowEmbeddedUpdater: Bool = false
    }

    func create(_ spec: CreateSpec,
                completion: @escaping @MainActor @Sendable
                    (InstanceManager.CreationOutcome) -> Void) {
        guard let manager else { return }
        setActivity("Creating instances", "Reserving numbers…")
        let updateProgress: @Sendable (String, Double?) -> Void = { [weak self] message, fraction in
            Task { @MainActor in
                self?.setActivity("Creating instances", message, fraction: fraction)
            }
        }
        work.async { [weak self] in
            do {
                let plan = try manager.plan(sourceBundle: spec.source,
                                            count: spec.count,
                                            names: spec.names,
                                            accountLabels: spec.accountLabels)
                var adjusted = plan
                if !spec.badges.isEmpty { adjusted.badges = spec.badges }
                let outcome = manager.create(plan: adjusted,
                                             requestedMode: spec.forceLite ? .lite : .full,
                                             acknowledgedSharedCredentialStore:
                                                spec.acknowledgedSharedCredentialStore,
                                             allowEmbeddedUpdater: spec.allowEmbeddedUpdater,
                                             detailedProgress: updateProgress)
                Task { @MainActor in
                    guard let self else { return }
                    self.activity = nil
                    self.refresh()
                    if let first = outcome.created.first { self.selectedInstance = first.id }
                    completion(outcome)
                }
            } catch {
                Task { @MainActor in
                    guard let self else { return }
                    self.activity = nil
                    self.banner = Banner(kind: .failure, title: "Could not create instances",
                                         message: "\(error)")
                    completion(InstanceManager.CreationOutcome(created: [], failures: [], degraded: [], notes: []))
                }
            }
        }
    }

    // MARK: Lifecycle actions

    func launch(_ instance: Instance) {
        guard let manager else { return }
        Task {
            do {
                _ = try await manager.launch(instance)
                refreshRunning()
            } catch {
                banner = Banner(kind: .failure, title: "Could not launch #\(instance.number)",
                                message: "\(error)")
            }
        }
    }

    func quit(_ instance: Instance) {
        guard let manager else { return }
        Task {
            let ok = await manager.quit(instance)
            refreshRunning()
            if !ok {
                banner = Banner(kind: .warning,
                                title: "#\(instance.number) did not quit",
                                message: "The app did not respond within ten seconds. You can force it to quit, which risks losing unsaved work in that instance.")
            }
        }
    }

    func forceQuit(_ instance: Instance) {
        guard let manager else { return }
        work.async { [weak self] in
            _ = manager.supervisor.forceQuit(instance)
            Task { @MainActor in self?.refreshRunning() }
        }
    }

    func rename(_ instance: Instance, to name: String) {
        perform("Renaming", "Rebuilding #\(instance.number) with its new name…") { manager in
            try manager.rename(instance, to: name, rebuildBundle: true)
        } success: { [weak self] in
            self?.banner = Banner(kind: .success, title: "Renamed",
                                  message: "Instance #\(instance.number) is now “\(Validation.sanitizeInstanceName(name))”. Its number, profile and sign-in are unchanged.")
        }
    }

    func setAccountLabel(_ instance: Instance, to label: String) {
        guard let manager else { return }
        try? manager.setAccountLabel(instance, to: label)
        refresh()
    }

    func setBadge(_ instance: Instance, to badge: BadgeSpec) {
        perform("Updating icon", "Regenerating the numbered icon for #\(instance.number)…") { manager in
            try manager.setBadge(instance, to: badge, rebuild: true)
        } success: { [weak self] in
            self?.banner = Banner(kind: .success, title: "Icon updated",
                                  message: "The Dock may take a moment to pick up the new icon.")
        }
    }

    func rebuild(_ instance: Instance) {
        perform("Rebuilding", "Rebuilding #\(instance.number) from the current source app…") { manager in
            _ = try manager.rebuild(instance) { step, total, label in
                Task { @MainActor in
                    // Progress from the builder's own transaction steps.
                    self.setActivity("Rebuilding", "\(label) (\(step + 1)/\(total))",
                                     fraction: Double(step) / Double(max(total, 1)))
                }
            }
        } success: { [weak self] in
            self?.banner = Banner(kind: .success, title: "Rebuilt #\(instance.number)",
                                  message: "The bundle was regenerated from the current version of the source app. Your data directory was not touched.")
        }
    }

    func duplicate(_ instance: Instance) {
        perform("Duplicating", "Creating a new instance with the same settings…") { manager in
            _ = try manager.duplicate(instance)
        } success: { [weak self] in
            self?.banner = Banner(kind: .success, title: "Duplicated",
                                  message: "The new instance has its own number and an empty profile. Copying a profile would copy a signed-in session, which is the opposite of what instances are for.")
        }
    }

    func remove(_ instance: Instance) {
        perform("Deleting", "Removing instance #\(instance.number)…") { manager in
            try manager.remove(instance, scope: .launcherAndData)
        } success: { [weak self] report in
            self?.selectedInstance = nil
            var details = ["Numbering is unchanged — the other instances keep the numbers they had."]
            if let kept = report.keptDataPath, let why = report.keptReason {
                details.insert("\(why) It is at \(kept).", at: 0)
            }
            let count = report.removedAssociatedArtifacts.count
            if count > 0 {
                details.append("Removed \(count) macOS support item\(count == 1 ? "" : "s") keyed only to this instance's generated identifier.")
            }
            let removedData = report.removedData
            if report.wentToTrash {
                details.insert("Everything removed went to the Trash, so you can put it back if this was a mistake.", at: 0)
            }
            self?.banner = Banner(
                kind: .success,
                title: "Uninstalled #\(instance.number)",
                message: removedData
                    ? "The launcher and its complete LaunchAgain-owned instance directory are gone."
                    : "The launcher and all LaunchAgain-owned files are gone. The external profile is kept at \(instance.dataPath).",
                details: details)
        }
    }

    func renumber(appKey: String) {
        perform("Renumbering", "Rebuilding every instance of this app…") { manager in
            _ = try manager.renumber(appKey: appKey) { message in
                Task { @MainActor in self.setActivity("Renumbering", message) }
            }
        } success: { [weak self] in
            self?.banner = Banner(kind: .success, title: "Renumbered",
                                  message: "Instances were renumbered from 1 and every bundle and icon was rebuilt.")
        }
    }

    func claimURLSchemes(_ instance: Instance) {
        perform("Claiming URL schemes", "Re-registering #\(instance.number) with Launch Services…") { manager in
            try manager.claimURLSchemes(instance)
        } success: { [weak self] in
            self?.banner = Banner(kind: .success, title: "URL schemes claimed",
                                  message: "Sign-in links will now come back to this instance. Sign in before claiming them for another one.")
        }
    }

    func applyAdvanced(_ instance: Instance,
                       arguments: [String],
                       environment: [String: String],
                       forceLite: Bool,
                       acknowledgedSharedCredentialStore: Bool = false,
                       dataPath: String? = nil) {
        perform("Applying settings", "Rebuilding #\(instance.number) with the new settings…") { manager in
            try manager.updateAdvancedSettings(instance,
                                               arguments: arguments,
                                               environment: environment,
                                               forceLite: forceLite,
                                               acknowledgedSharedCredentialStore:
                                                acknowledgedSharedCredentialStore,
                                               dataPath: dataPath)
        } success: { [weak self] in
            self?.banner = Banner(
                kind: .success,
                title: "Settings applied",
                message: "The instance was rebuilt.",
                details: dataPath == nil
                    ? ["Your profile was not touched."]
                    : ["This instance now uses \(dataPath!). The previous profile is still at its old location — nothing was moved or deleted."])
        }
    }

    func exportDiagnostics(to url: URL) {
        perform("Exporting diagnostics", "Collecting logs and signature information…") { manager in
            _ = try manager.exportDiagnostics(to: url)
        } success: { [weak self] in
            self?.banner = Banner(kind: .success, title: "Diagnostics written",
                                  message: url.path,
                                  details: ["The file contains no cookies, tokens or anything else from an instance profile."])
        }
    }

    // MARK: Plumbing

    private func setActivity(_ title: String, _ detail: String, fraction: Double? = nil) {
        activity = Activity(title: title, detail: detail, fraction: fraction)
    }

    /// Runs `body` on the work queue, showing an activity indicator, then either the
    /// caller's success banner or a failure banner carrying the engine's own message.
    private func perform(_ title: String,
                         _ detail: String,
                         _ body: @escaping @Sendable (InstanceManager) throws -> Void,
                         success: @escaping @MainActor @Sendable () -> Void) {
        guard let manager else { return }
        setActivity(title, detail)
        work.async { [weak self] in
            do {
                try body(manager)
                Task { @MainActor in
                    guard let self else { return }
                    self.activity = nil
                    self.refresh()
                    success()
                }
            } catch {
                Task { @MainActor in
                    guard let self else { return }
                    self.activity = nil
                    self.refresh()
                    self.banner = Banner(kind: .failure, title: title + " failed", message: "\(error)")
                }
            }
        }
    }

    /// Result-carrying form used by deletion. Returning the report across the queue
    /// boundary avoids a mutable local captured by both queues, which was a genuine data
    /// race even though the serial work queue usually hid it.
    private func perform<Result: Sendable>(
        _ title: String,
        _ detail: String,
        _ body: @escaping @Sendable (InstanceManager) throws -> Result,
        success: @escaping @MainActor @Sendable (Result) -> Void
    ) {
        guard let manager else { return }
        setActivity(title, detail)
        work.async { [weak self] in
            do {
                let result = try body(manager)
                Task { @MainActor in
                    guard let self else { return }
                    self.activity = nil
                    self.refresh()
                    success(result)
                }
            } catch {
                Task { @MainActor in
                    guard let self else { return }
                    self.activity = nil
                    self.refresh()
                    self.banner = Banner(
                        kind: .failure, title: title + " failed", message: "\(error)")
                }
            }
        }
    }
}

// MARK: - Small shared helpers

extension AppState {
    var supportDirectory: URL? { manager?.paths.support }
    var bundlesDirectory: URL? { manager?.paths.bundlesDir }
    /// `/Applications/LaunchAgain`, used only by applications that refuse to run from
    /// anywhere else. See `MALPaths.systemBundlesDir`.
    var systemBundlesDirectory: URL? { manager?.paths.systemBundlesDir }
    var runningFromDiskImage: Bool {
        Bundle.main.bundleURL.standardizedFileURL.path.hasPrefix("/Volumes/")
    }
    var installedApplicationURL: URL? {
        let candidates = [
            URL(fileURLWithPath: "/Applications/LaunchAgain.app"),
            URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Applications/LaunchAgain.app"),
        ]
        return candidates.first {
            FileManager.default.fileExists(atPath: $0.path)
                && $0.standardizedFileURL != Bundle.main.bundleURL.standardizedFileURL
        }
    }

    func logsDirectory(for instance: Instance) -> URL? {
        manager?.paths.instanceLogsDir(instance.id)
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func openInstalledApplication() {
        guard let url = installedApplicationURL else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            guard error == nil else { return }
            Task { @MainActor in NSApplication.shared.terminate(nil) }
        }
    }
}

/// Index-safe array access for the create flow's fixed-length name and label arrays.
extension Array where Element == String {
    subscript(safe index: Int) -> String {
        get { indices.contains(index) ? self[index] : "" }
        set {
            while count <= index { append("") }
            self[index] = newValue
        }
    }
}
#endif
