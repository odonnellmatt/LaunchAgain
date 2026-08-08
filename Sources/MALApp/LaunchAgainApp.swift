//
//  LaunchAgain — application entry point and the dashboard screen.
//
//  One window, three screens, as specified: the dashboard (here), the create flow
//  (CreateFlowView) and the instance detail (InstanceDetailView).
//

#if canImport(AppKit)
import SwiftUI
import AppKit
import MALCore
import MALKit

@main
struct LaunchAgainApp: App {

    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup("LaunchAgain") {
            RootView()
                .environmentObject(state)
                .frame(minWidth: 960, minHeight: 600)
        }
        .defaultSize(width: 1100, height: 720)
        // Keep the system title visible on every supported macOS release. Earlier builds
        // tried to move identity between the title bar and sidebar by mutating NSWindow
        // from a representable; older SwiftUI hosts can overwrite that state.
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Instances…") { NotificationCenter.default.post(name: .malStartCreateFlow, object: nil) }
                    .keyboardShortcut("n")
            }
            CommandGroup(after: .toolbar) {
                Button(state.sidebarVisible ? "Hide Sidebar" : "Show Sidebar") {
                    state.sidebarVisible.toggle()
                }
                .keyboardShortcut("s", modifiers: [.control, .command])
                Divider()
                Button("Refresh Installed Launchers") { state.refreshFromDisk() }
                    .keyboardShortcut("r")
                Button("Check for Problems") { state.runHealthCheck() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Divider()
                Button("Delete Selected Instance…") {
                    if let pair = state.instance(state.selectedInstance) {
                        state.requestDelete(pair.instance)
                    }
                }
                .keyboardShortcut(.delete, modifiers: [.command])
                .disabled(state.selectedInstance == nil || state.busy)
            }
            CommandGroup(replacing: .help) {
                Button("Read the Limitations") { openDoc("LIMITATIONS.md") }
                Button("Read the Security Notes") { openDoc("SECURITY.md") }
                Button("Read the Privacy Notes") { openDoc("PRIVACY.md") }
            }
        }
    }

    private func openDoc(_ name: String) {
        // The docs ship inside the app bundle; fall back to the repository copy during
        // development so the menu item is never a dead end.
        if let u = Bundle.main.url(forResource: name.replacingOccurrences(of: ".md", with: ""),
                                   withExtension: "md") {
            NSWorkspace.shared.open(u)
            return
        }
        let dev = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: dev.path) { NSWorkspace.shared.open(dev) }
    }
}

extension Notification.Name {
    static let malStartCreateFlow = Notification.Name("com.launchagain.startCreateFlow")
}

// MARK: - Root

struct RootView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Group {
            if let error = state.startupError {
                StartupErrorView(message: error)
            } else {
                ZStack(alignment: .topLeading) {
                    // Three explicitly mounted columns rather than NavigationSplitView.
                    // See LIMITATIONS.md §13 for the reproduction and the measurement
                    // behind that choice. The sidebar is the one column whose presence
                    // is under the user's control, so hiding it is the only structural
                    // change this container ever makes.
                    VStack(spacing: 0) {
                        if state.runningFromDiskImage {
                            DiskImageWarning()
                        }
                        HSplitView {
                            if state.sidebarVisible {
                                SidebarView()
                                    .frame(minWidth: 190, idealWidth: 220, maxWidth: 300,
                                           maxHeight: .infinity)
                                    .transition(.identity)
                            }
                            ContentColumn()
                                .frame(minWidth: 330, idealWidth: 400, maxWidth: 620,
                                       maxHeight: .infinity)
                            DetailColumn()
                                .frame(minWidth: 430, maxWidth: .infinity,
                                       maxHeight: .infinity)
                        }
                    }
                    PresentationHost()
                        .frame(width: 1, height: 1)
                }
            }
        }
        // The progress overlay is an overlay on RootView, not a sibling inside the
        // split container, and it carries its own transition. Both of those matter: an
        // overlay does not change the container's child list when it appears, and the
        // transition keeps the fade local to the overlay instead of implicitly
        // animating the columns underneath it.
        //
        // What actually caused the blank window was neither of those, and neither was
        // the choice of container: it was presenting `.sheet` from a view whose identity
        // belonged to the dynamic part of the navigation tree. When the presenting
        // view's identity changed while a dismissal was in flight — deleting the
        // selected row — the sidebar and content subtrees were torn down and not
        // rebuilt. `PresentationHost` above owns every sheet from a 1×1 sibling whose
        // identity never changes, which is the fix.
        .overlay {
            if let activity = state.activity {
                ZStack {
                    Color.black.opacity(0.08).ignoresSafeArea()
                    ActivityOverlay(activity: activity)
                }
                .transition(.opacity.animation(.easeInOut(duration: 0.15)))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .malStartCreateFlow)) { _ in
            if !state.busy { state.presentation = .create }
        }
    }
}

private struct DiskImageWarning: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .foregroundStyle(.orange)
            Text("LaunchAgain is running from the disk image. Install and open the Applications copy so updates and restarts use one stable version.")
                .font(.caption)
            Spacer()
            if state.installedApplicationURL != nil {
                Button("Open Applications Copy") { state.openInstalledApplication() }
            } else {
                Text("Drag LaunchAgain to Applications")
                    .font(.caption.weight(.medium))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.orange.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// A presentation anchor independent of every dashboard column. Its identity never
/// changes when a row or app disappears, so dismissing a create/delete sheet cannot
/// dismantle the navigation UI behind it.
private struct PresentationHost: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Color.clear
            .sheet(item: $state.presentation) { presentation in
                switch presentation {
                case .create:
                    CreateFlowView().environmentObject(state)
                case .confirmDelete(let instance):
                    DeleteInstanceSheet(instance: instance).environmentObject(state)
                }
            }
    }
}

struct StartupErrorView: View {
    var message: String
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text("The launcher could not open its data store")
                .font(.title3).fontWeight(.semibold)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 460)
            Text("Nothing has been changed. Your instances and their data are where they were.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("INSTANCES")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 12)

            sidebarRow(
                selection: .allInstances,
                title: "All instances",
                systemImage: "square.stack.3d.up",
                count: state.allInstances.count)

            ScrollView {
                LazyVStack(spacing: 4) {
                ForEach(state.apps) { app in
                        appRow(app)
                    }
                }
                .padding(.horizontal, 6)
            }

            Divider().padding(.horizontal, 8)
            Text("MAINTENANCE")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
            sidebarRow(
                selection: .health,
                title: "Health",
                systemImage: "stethoscope",
                count: state.findings.count)
                .padding(.bottom, 8)
        }
        .background(.ultraThinMaterial)
        .accessibilityIdentifier("stable-sidebar")
    }

    private func sidebarRow(selection: AppState.Selection,
                            title: String,
                            systemImage: String,
                            count: Int) -> some View {
        Button {
            state.selection = selection
        } label: {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .frame(width: 18)
                Text(title).lineLimit(1)
                Spacer(minLength: 4)
                countBadge(count)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(
                state.selection == selection
                    ? Color.accentColor.opacity(0.18)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
    }

    private func appRow(_ app: ManagedApp) -> some View {
        let selection = AppState.Selection.app(app.appKey)
        return Button {
            state.selection = selection
        } label: {
            HStack(spacing: 8) {
                SourceIcon(app: app)
                Text(app.displayName).lineLimit(1)
                Spacer(minLength: 4)
                countBadge(app.instances.count)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(
                state.selection == selection
                    ? Color.accentColor.opacity(0.18)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    private func countBadge(_ count: Int) -> some View {
        Text("\(count)")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.12), in: Capsule())
    }
}

// MARK: - Content column (the dashboard list)

struct ContentColumn: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Group {
            switch state.selection {
            case .health:
                HealthView()
            case .allInstances, .app:
                InstanceListView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    state.sidebarVisible.toggle()
                } label: {
                    Label(state.sidebarVisible ? "Hide Sidebar" : "Show Sidebar",
                          systemImage: "sidebar.leading")
                }
                .help(state.sidebarVisible ? "Hide the sidebar" : "Show the sidebar")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    state.presentation = .create
                } label: {
                    Label("New Instances", systemImage: "plus")
                }
                .disabled(state.busy)
                .help("Create isolated, numbered instances of an installed GUI application")
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    state.refreshFromDisk()
                } label: {
                    Label("Refresh Installed Launchers", systemImage: "arrow.clockwise")
                }
                .disabled(state.busy)
                .help("Scan installed launcher apps and restore any missing registry entries")
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    state.runHealthCheck()
                } label: {
                    Label("Check for Problems", systemImage: "stethoscope")
                }
                .disabled(state.busy)
                .help("Look for orphans, stale builds and source app updates")
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    if let pair = state.instance(state.selectedInstance) {
                        state.requestDelete(pair.instance)
                    }
                } label: {
                    Label("Delete Selected Instance", systemImage: "trash")
                }
                .disabled(state.selectedInstance == nil || state.busy)
                .help("Delete the selected instance…")
            }
        }
    }
}

struct InstanceListView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            if let banner = state.banner {
                BannerView(banner: banner) { state.banner = nil }
                    .padding(10)
            }

            if state.visibleInstances.isEmpty {
                EmptyDashboardView()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4,
                                   pinnedViews: [.sectionHeaders]) {
                            ForEach(groupedInstances(), id: \.key) { group in
                                Section {
                                    ForEach(group.value, id: \.instance.id) { pair in
                                        InstanceRow(pair: pair)
                                            .id(pair.instance.id)
                                            .contextMenu { InstanceMenu(pair: pair) }
                                    }
                                } header: {
                                    AppSectionHeader(app: group.value.first!.app)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(.bar)
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                    }
                    .accessibilityIdentifier("instance-dashboard")
                    .onMoveCommand { direction in
                        if let id = moveSelection(direction) {
                            withAnimation(.easeOut(duration: 0.12)) {
                                proxy.scrollTo(id, anchor: .center)
                            }
                        }
                    }
                    .onChange(of: state.selectedInstance) { id in
                        guard let id else { return }
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    @discardableResult
    private func moveSelection(_ direction: MoveCommandDirection) -> UUID? {
        let ids = state.visibleInstances.map(\.instance.id)
        guard !ids.isEmpty, direction == .up || direction == .down else { return nil }
        let current = state.selectedInstance.flatMap { ids.firstIndex(of: $0) }
        let index: Int
        if let current {
            index = direction == .up ? max(0, current - 1) : min(ids.count - 1, current + 1)
        } else {
            index = direction == .up ? ids.count - 1 : 0
        }
        state.selectedInstance = ids[index]
        return ids[index]
    }

    private func groupedInstances() -> [(key: String, value: [(app: ManagedApp, instance: Instance)])] {
        let grouped = Dictionary(grouping: state.visibleInstances) { $0.app.appKey }
        return grouped
            .map { (key: $0.key, value: $0.value.sorted { $0.instance.number < $1.instance.number }) }
            .sorted { ($0.value.first?.app.displayName ?? "") < ($1.value.first?.app.displayName ?? "") }
    }
}

struct AppSectionHeader: View {
    @EnvironmentObject private var state: AppState
    var app: ManagedApp

    var body: some View {
        HStack {
            Text(app.displayName)
            if !app.sourceVersion.isEmpty {
                Text(app.sourceVersion).foregroundStyle(.tertiary)
            }
            Spacer()
            Menu {
                Button("Renumber to 1…\(app.instances.count)…") { state.renumber(appKey: app.appKey) }
                    .disabled(state.busy)
                Divider()
                Button("Reveal Source App in Finder") { state.reveal(app.sourcePath) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }
}

struct InstanceRow: View {
    @EnvironmentObject private var state: AppState
    var pair: (app: ManagedApp, instance: Instance)
    @State private var hovering = false

    private var instance: Instance { pair.instance }
    private var selected: Bool { state.selectedInstance == instance.id }

    var body: some View {
        let singleClick = TapGesture(count: 1).onEnded {
            state.selectedInstance = instance.id
        }
        let doubleClick = TapGesture(count: 2).onEnded {
            if instance.mechanism != .configEnvironment {
                state.launch(instance)
            }
        }

        HStack(spacing: 10) {
            // A real button provides keyboard focus and activation. Its mouse gesture
            // waits to distinguish one click from two, so a double-click launches
            // without first firing the single-click selection action. The launch and
            // trash controls are siblings outside this hit target.
            Button {
                state.selectedInstance = instance.id
            } label: {
                selectableContent
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .highPriorityGesture(doubleClick.exclusively(before: singleClick))
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(selected ? "Selected" : "Not selected")
            .accessibilityHint("Press to select. Double-click to launch.")
            .accessibilityIdentifier("instance-row-\(instance.id.uuidString)")

            launchButton
            deleteButton
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 7)
                .fill(selected
                      ? Color.accentColor.opacity(0.20)
                      : (hovering ? Color.primary.opacity(0.06) : Color.clear))
        }
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Color.accentColor.opacity(0.55), lineWidth: 1)
            }
        }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
    }

    private var accessibilityLabel: String {
        let name = instance.name.isEmpty ? "Unnamed" : instance.name
        let status = state.isRunning(instance) ? "running" : "not running"
        return "\(pair.app.displayName) instance \(instance.number), \(name), \(status)"
    }

    private var selectableContent: some View {
        HStack(spacing: 10) {
            FileIcon(path: instance.bundlePath, size: 34)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("#\(instance.number)")
                        .font(.system(.body, design: .rounded))
                        .fontWeight(.bold)
                        .monospacedDigit()
                    Text(instance.name.isEmpty ? "Unnamed" : instance.name)
                        .fontWeight(.medium)
                        .foregroundStyle(instance.name.isEmpty ? .secondary : .primary)
                }
                HStack(spacing: 6) {
                    if !instance.accountLabel.isEmpty {
                        Text(instance.accountLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if instance.mechanism == .configEnvironment {
                        Chip(text: "Legacy terminal — disabled", style: .bad,
                             systemImage: "terminal.fill")
                            .help("LaunchAgain now creates and launches GUI applications only.")
                    } else if instance.mode == .lite {
                        Chip(text: "Lite", style: .caution)
                            .help("Separate Chromium profile; shared original-app Dock, Keychain, privacy and URL-scheme identity.")
                    }
                    if state.isStale(pair) {
                        Chip(text: "Rebuild available", style: .accent, systemImage: "arrow.triangle.2.circlepath")
                            .help("\(pair.app.displayName) has been updated to \(pair.app.sourceVersion). Rebuilding keeps your data.")
                    }
                    if state.isMissingLauncher(instance) {
                        Chip(text: "Removed in Finder", style: .bad, systemImage: "trash")
                            .help("This instance's app is no longer on disk. Delete it here to tidy up, or rebuild it.")
                    }
                }
            }

            Spacer(minLength: 6)

            if let size = state.profileSizes[instance.id], size > 0 {
                Text(FSOps.humanBytes(size))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            RunningIndicator(running: state.isRunning(instance))
        }
    }

    // `.borderless` here made the *whole row* unselectable: on macOS that style takes
    // over hit-testing for the row it sits in. `.plain` with an explicit content shape
    // keeps each button to its own 22 points.
    private var launchButton: some View {
            Button {
                if instance.mechanism == .configEnvironment {
                    return
                } else if state.isRunning(instance) {
                    state.quit(instance)
                } else {
                    state.launch(instance)
                }
            } label: {
                Image(systemName: instance.mechanism == .configEnvironment
                      ? "nosign"
                      : (state.isRunning(instance) ? "stop.fill" : "play.fill"))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(instance.mechanism == .configEnvironment
                                ? "Legacy terminal launcher disabled"
                                : (state.isRunning(instance)
                                   ? "Quit instance \(instance.number)"
                                   : "Launch instance \(instance.number)"))
            .accessibilityIdentifier("launch-instance-\(instance.id.uuidString)")
            .disabled(instance.mechanism == .configEnvironment)
            .help(instance.mechanism == .configEnvironment
                  ? "Terminal launchers are disabled. Create a GUI instance from the installed application."
                  : (state.isRunning(instance) ? "Quit this instance" : "Launch this instance"))
    }

    private var deleteButton: some View {
        Button {
            state.requestDelete(instance)
        } label: {
            Image(systemName: "trash")
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel("Delete instance \(instance.number)")
        .accessibilityIdentifier("delete-instance-\(instance.id.uuidString)")
        .disabled(state.busy || state.isRunning(instance))
        .help(state.isRunning(instance)
              ? "Quit this instance before deleting it"
              : "Delete this instance…")
    }
}

struct InstanceMenu: View {
    @EnvironmentObject private var state: AppState
    var pair: (app: ManagedApp, instance: Instance)

    var body: some View {
        let i = pair.instance
        if i.mechanism == .configEnvironment {
            Text("Legacy terminal launcher — launching disabled")
        } else if state.isRunning(i) {
            Button("Quit") { state.quit(i) }
            Button("Force Quit") { state.forceQuit(i) }
        } else {
            Button("Launch") { state.launch(i) }
        }
        Divider()
        Button("Reveal in Finder") { state.reveal(i.bundlePath) }
        Button("Open Data Folder") { state.open(URL(fileURLWithPath: i.dataPath)) }
        Button("View Logs") {
            if let dir = state.logsDirectory(for: i) { state.open(dir) }
        }
        Divider()
        Button("Rebuild") { state.rebuild(i) }
            .disabled(state.busy || state.isRunning(i) || i.mechanism == .configEnvironment)
        Button("Duplicate") { state.duplicate(i) }
            .disabled(state.busy || i.mechanism == .configEnvironment)
        Button("Claim URL Schemes") { state.claimURLSchemes(i) }
            .disabled(state.busy
                      || i.mechanism == .configEnvironment
                      || i.mode != .full)
        Divider()
        Button("Delete…", role: .destructive) { state.requestDelete(i) }
            .disabled(state.busy || state.isRunning(i))
    }
}

struct EmptyDashboardView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text("No instances yet")
                .font(.title3).fontWeight(.medium)
            Text("Pick an installed app and choose how many numbered, separately signed-in copies you want.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            Button("New Instances…") { state.presentation = .create }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            Button("Refresh Installed Launchers") { state.refreshFromDisk() }
                .buttonStyle(.link)
                .disabled(state.busy)
                .help("Recover launchers that remain installed after a reinstall")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }
}

// MARK: - Detail column

struct DetailColumn: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        if state.selection == .health {
            HealthDetailView()
        } else if let pair = state.instance(state.selectedInstance) {
            InstanceDetailView(pair: pair)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 28))
                    .foregroundStyle(.tertiary)
                Text("Select an instance")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Health

struct HealthView: View {
    @EnvironmentObject private var state: AppState
    @State private var pendingDeletion: OrphanSweeper.Finding?
    @State private var confirmingCleanAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Health").font(.headline)
                Spacer()
                Button("Check Now") { state.runHealthCheck() }.disabled(state.busy)
            }
            .padding(12)

            if state.findings.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: state.lastSweptAt == nil ? "questionmark.circle" : "checkmark.seal")
                        .font(.system(size: 30))
                        .foregroundStyle(state.lastSweptAt == nil ? Color.secondary : Color.green)
                    Text(state.lastSweptAt == nil ? "Not checked yet" : "Everything is consistent")
                        .font(.callout).fontWeight(.medium)
                    Text(state.lastSweptAt == nil
                         ? "Nothing has been examined, so there is nothing to report either way."
                         : "The registry, the launcher bundles on disk and the instance profiles all agree.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                    if let at = state.lastSweptAt {
                        Text("Checked \(at.formatted(date: .omitted, time: .shortened))")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(state.findings) { f in
                        findingRow(f)
                    }
                }
                .listStyle(.inset)

                if state.findings.contains(where: \.safeToClean) {
                    HStack(spacing: 10) {
                        Text(safeToCleanSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        // Never acts immediately, and never widens what "safe" means.
                        // This used to delete everything it considered cleanable on one
                        // click, without confirmation and without the Trash. The sheet
                        // still lists every item before anything moves, leftover
                        // profiles are still excluded because they may hold a sign-in,
                        // and so is a launcher that is the last record of one.
                        Button("Delete All Safe Items…") { confirmingCleanAll = true }
                            .disabled(state.busy)
                            // The middle column is narrow at the default width and the
                            // label clipped to "Delete All Safe Item…".
                            .fixedSize()
                    }
                    .padding(12)
                }
            }
        }
        .sheet(item: $pendingDeletion) { finding in
            DeleteFindingSheet(finding: finding).environmentObject(state)
        }
        .sheet(isPresented: $confirmingCleanAll) {
            CleanAllFindingsSheet(findings: state.findings.filter(\.safeToClean))
                .environmentObject(state)
        }
    }

    private var safeToCleanSummary: String {
        let safe = state.findings.filter(\.safeToClean)
        let bytes = safe.reduce(Int64(0)) { $0 + $1.sizeBytes }
        return "\(safe.count) item\(safe.count == 1 ? "" : "s") can be removed safely"
            + (bytes > 0 ? " — \(FSOps.humanBytes(bytes))" : "")
    }

    /// One line per finding: what it is, how big, and the one action that resolves it.
    ///
    /// Most findings here are informational, and every row previously carried two or
    /// three sentences of explanation plus a full path, so the handful that needed
    /// action were impossible to pick out. The explanation is still there in full, as
    /// the row's tooltip; the path is secondary text.
    @ViewBuilder
    private func findingRow(_ f: OrphanSweeper.Finding) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: f.safeToClean ? "arrow.up.bin" : "exclamationmark.triangle")
                .foregroundStyle(f.safeToClean ? Color.secondary : Color.orange)
                .frame(width: 16)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(f.summary).font(.callout)
                Text(f.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 8)

            if f.sizeBytes > 0 {
                Text(FSOps.humanBytes(f.sizeBytes))
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            resolveButton(f)
        }
        .padding(.vertical, 3)
        .help(f.detail)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(f.summary). \(f.detail)")
    }

    /// The single action that resolves this row.
    ///
    /// Deleting anything that may hold a signed-in session still opens the confirmation
    /// sheet that names it; the one-click actions here are the ones that destroy nothing.
    @ViewBuilder
    private func resolveButton(_ f: OrphanSweeper.Finding) -> some View {
        switch f.kind {
        case .orphanDataDirectory, .unregisteredBundle, .staleRemovalMarker:
            if f.isRemovable {
                Button("Delete…") { pendingDeletion = f }
                    .disabled(state.busy)
            } else {
                Button("Reveal") { revealInFinder(f.path) }
                    .buttonStyle(.link)
            }
        case .missingBundle, .sourceUpdated:
            // The resolution for both is the same: regenerate the bundle from the source
            // application, which never touches the profile.
            Button("Rebuild") { rebuildInstances(for: f) }
                .disabled(state.busy)
        case .orphanPreferenceDomain:
            // Reported, never removed — the filename shows LaunchAgain generated it but
            // not which instance owned it. The resolution we can offer is the exact
            // command, on the clipboard, rather than a delete we cannot justify.
            Button("Copy Command") { copyDefaultsCommand(for: f) }
                .buttonStyle(.link)
                .help("Copies the exact `defaults delete` command for this domain")
        case .sourceMissing, .migrationConflict, .staleStaging:
            Button("Reveal") { revealInFinder(f.path) }
                .buttonStyle(.link)
        }
    }

    private func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func copyDefaultsCommand(for f: OrphanSweeper.Finding) {
        let identifier = URL(fileURLWithPath: f.path)
            .deletingPathExtension().lastPathComponent
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("defaults delete \(identifier)", forType: .string)
        state.banner = AppState.Banner(
            kind: .info,
            title: "Copied",
            message: "defaults delete \(identifier)")
    }

    private func rebuildInstances(for f: OrphanSweeper.Finding) {
        // A missing-bundle finding names one instance; a source-updated finding names an
        // application whose instances are stale. Rebuild what the finding is about, and
        // nothing else.
        let stale = state.allInstances.filter { pair in
            pair.instance.bundlePath == f.path || pair.app.sourcePath == f.path
        }
        for pair in stale where pair.instance.mode == .full {
            state.rebuild(pair.instance)
        }
    }
}

/// Deleting a leftover profile is the one thing here that can lose a signed-in session,
/// so it asks for the same deliberate confirmation as deleting an instance's data.
/// Confirmation for the bulk cleanup.
///
/// The button behind this used to remove everything it considered cleanable on a single
/// click: no confirmation, no Trash, and no check on whether a launcher was the last
/// record of a profile still on disk. On a store with nine launchers and nine profiles
/// that left two launchers and nine profiles — seven hard-deleted, and their profiles
/// permanently unattributable. Every item is now named before anything moves.
struct CleanAllFindingsSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    var findings: [OrphanSweeper.Finding]

    private var total: Int64 { findings.reduce(0) { $0 + $1.sizeBytes } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(findings.count == 1
                 ? "Remove this leftover item?"
                 : "Remove these \(findings.count) leftover items?")
                .font(.headline)

            Text("Everything listed goes to the Trash, so you can put it back if this was a mistake.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(findings) { finding in
                        VStack(alignment: .leading, spacing: 2) {
                            Text((finding.path as NSString).lastPathComponent)
                                .font(.system(.caption, design: .monospaced))
                            Text(finding.sizeBytes > 0
                                 ? "\(finding.path) — \(FSOps.humanBytes(finding.sizeBytes))"
                                 : finding.path)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)

            InlineNote(
                kind: .caution,
                text: "This frees about \(FSOps.humanBytes(total)). Leftover instance profiles are never included here — they may hold a signed-in session, so each one is deleted individually and by name. Nor is a launcher whose profile is still on disk: that launcher is the only record of which instance the profile belongs to.")

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Move to Trash", role: .destructive) {
                    state.cleanFindings()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(state.busy || findings.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

struct DeleteFindingSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    var finding: OrphanSweeper.Finding

    @State private var typed = ""

    private var isProfile: Bool { finding.kind == .orphanDataDirectory }
    private var confirmed: Bool { !isProfile || typed == "delete" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isProfile ? "Delete this leftover profile?" : "Delete this item?")
                .font(.headline)

            Text(finding.path)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if isProfile {
                InlineNote(kind: .bad,
                           text: "This is an instance profile — \(FSOps.humanBytes(finding.sizeBytes)) that probably contains a signed-in session. It was left behind when an instance was removed without its data. Deleting it cannot be undone from here.")
                Text("Type “delete” to confirm:").font(.caption)
                TextField("", text: $typed).textFieldStyle(.roundedBorder)
            } else {
                InlineNote(kind: .caution,
                           text: "This is a leftover the launcher created. Removing it frees \(FSOps.humanBytes(finding.sizeBytes)) and affects nothing else.")
            }

            Text("Only files inside the launcher's own folders can be deleted here. Your applications are never touched.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Delete", role: .destructive) {
                    state.removeFinding(finding)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!confirmed)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

struct HealthDetailView: View {
    @EnvironmentObject private var state: AppState
    @State private var exporting = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Maintenance")
                    .font(.title3).fontWeight(.semibold)

                Text("Nothing here is deleted without you asking. An “orphan” profile is somebody's signed-in session, so the sweep reports and never removes it on its own.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                GroupBox("Where things live") {
                    VStack(alignment: .leading, spacing: 6) {
                        KeyValueRow(key: "Launchers", value: state.bundlesDirectory?.path ?? "—", monospaced: true)
                        KeyValueRow(key: "Profiles & registry", value: state.supportDirectory?.path ?? "—", monospaced: true)
                    }
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Diagnostics") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Writes a report with your logs, the registry and signature checks. It never includes the contents of an instance profile — no cookies, no tokens.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Export Diagnostics…") { exportDiagnostics() }
                            .disabled(state.busy)
                    }
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer()
            }
            .padding(20)
        }
    }

    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "launchagain-diagnostics.md"
        panel.canCreateDirectories = true
        panel.title = "Export diagnostics"
        if panel.runModal() == .OK, let url = panel.url {
            state.exportDiagnostics(to: url)
        }
    }
}
#endif
