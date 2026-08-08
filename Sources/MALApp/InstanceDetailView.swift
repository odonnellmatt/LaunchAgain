//
//  Instance detail — the third screen.
//
//  Everything from the dashboard row, plus the advanced settings, plus the facts a user
//  needs when something has gone wrong: which bundle identifier this instance actually
//  has, which version it was built from, where its profile is, and what the build had to
//  change to make it work.
//
//  Deleting is the only irreversible action in the product, so it is the one place that
//  asks the user to type something.
//

#if canImport(AppKit)
import SwiftUI
import AppKit
import MALCore
import MALKit

struct InstanceDetailView: View {
    @EnvironmentObject private var state: AppState
    var pair: (app: ManagedApp, instance: Instance)

    @State private var name = ""
    @State private var accountLabel = ""
    @State private var badge = BadgeSpec()
    @State private var showingBadgeEditor = false
    @State private var showAdvanced = false

    // Advanced, staged locally until applied.
    @State private var argumentsText = ""
    @State private var environmentText = ""
    @State private var dataPathText = ""
    @State private var forceLite = false
    @State private var acknowledgedSharedCredentials = false

    /// The application's verdict, but only when this change actually needs it: the
    /// proposed mode is Lite and this application keeps its session outside the profile.
    ///
    /// The rule itself lives on `CompatibilityVerdict` and is the same expression the
    /// create flow, the command line and the builder all evaluate. Nothing here restates
    /// it.
    private var sharedCredentialVerdict: CompatibilityVerdict? {
        guard let pair = state.instance(instance.id) else { return nil }
        guard let verdict = state.verdict(forAppKey: pair.app.appKey) else { return nil }
        // What the build will *produce*, not what is being asked for. Reading the stored
        // mode here predicted Full for an application whose source has since gained a
        // privileged helper, while the builder resolved the same request to Lite — so no
        // checkbox appeared, Apply stayed enabled, and the build refused.
        let proposedMode = verdict.effectiveMode(requesting: forceLite ? .lite : instance.mode)
        return verdict.requiresSharedCredentialAcknowledgement(mode: proposedMode)
            ? verdict : nil
    }

    /// True while the application has not been inspected yet.
    ///
    /// `state.verdict(forAppKey:)` returns `nil` on the first call and inspects on a
    /// background queue, so "no verdict" means "not known yet", not "nothing to
    /// acknowledge". Treating the two the same left Apply enabled during the window for
    /// an application that turns out to need the acknowledgement. It fails closed now:
    /// the destructive controls wait for the answer, which is one `codesign` away.
    private var verdictIsPending: Bool {
        guard let pair = state.instance(instance.id) else { return false }
        return state.verdict(forAppKey: pair.app.appKey) == nil
    }

    /// Blocks Apply until the consequence has been accepted — unless this instance is
    /// already Lite in the store, in which case applying introduces no sharing that is
    /// not already on disk and the engine permits the rebuild on that ground.
    ///
    /// The condition matches the engine's rather than restating a different one: it is
    /// `mode != .lite` here and `onDiskMode == .lite && proposed.mode == .lite` in
    /// `rebuildProposed`. The two agree for every instance whose launcher matches its
    /// record; where they diverge the engine refuses, which is the safe direction, and
    /// the divergence needs a hand-edited registry. It deliberately does not read the
    /// stored acknowledgement — a stored-Full instance never carries one, because only
    /// the Lite build path writes it.
    private var needsSharedCredentialAcknowledgement: Bool {
        if verdictIsPending { return true }
        return sharedCredentialVerdict != nil
            && instance.mode != .lite
            && !acknowledgedSharedCredentials
    }

    /// Whether `Rebuild from Source App` would be refused by the engine.
    ///
    /// That button rebuilds at the stored mode and offers no acknowledgement, so for an
    /// application that has become Lite-only since the instance was built it threw "Lite
    /// mode cannot isolate X" at a user who never asked for Lite. It is disabled instead,
    /// and says where the decision is made.
    private var rebuildWouldBeRefused: Bool {
        guard let pair = state.instance(instance.id),
              let verdict = state.verdict(forAppKey: pair.app.appKey) else { return false }
        guard verdict.requiresSharedCredentialAcknowledgement(
                mode: verdict.effectiveMode(requesting: instance.mode)) else { return false }
        return instance.mode != .lite && instance.acknowledgedSharedCredentialStoreAt == nil
    }

    private var appDisplayName: String {
        state.instance(instance.id)?.app.displayName ?? "the original app"
    }

    private var instance: Instance { pair.instance }
    private var running: Bool { state.isRunning(instance) }
    private var bundleExists: Bool { FileManager.default.fileExists(atPath: instance.bundlePath) }
    private var isTool: Bool { instance.mechanism.isLegacyTerminal }
    /// The variable that isolated a legacy Terminal instance, shown so the user can see
    /// what the entry they are about to uninstall actually was. `nil` for every instance
    /// this release can create.
    private var legacyEnvironmentVariable: String? {
        guard isTool else { return nil }
        return LegacyTerminalTool.environmentVariable(forAppKey: pair.app.appKey)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                actions
                identity
                if !instance.buildNotes.isEmpty { buildNotes }
                if !isTool {
                    permissions
                    advanced
                }
                dangerZone
            }
            .padding(20)
            .frame(maxWidth: 620, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear(perform: loadFromInstance)
        .onChange(of: instance.id) { _ in loadFromInstance() }
        .sheet(isPresented: $showingBadgeEditor) { badgeSheet }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            FileIcon(path: instance.bundlePath, size: 64)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("#\(instance.number)")
                        .font(.system(.title2, design: .rounded))
                        .fontWeight(.bold)
                        .monospacedDigit()
                    Text(instance.name.isEmpty ? "Unnamed" : instance.name)
                        .font(.title2)
                        .foregroundStyle(instance.name.isEmpty ? .secondary : .primary)
                }
                HStack(spacing: 6) {
                    if isTool {
                        Chip(text: "Legacy terminal — disabled", style: .bad,
                             systemImage: "nosign")
                    } else {
                        Chip(text: instance.mode == .full ? "Full" : "Lite",
                             style: instance.mode == .full ? .good : .caution)
                    }
                    Chip(text: running ? "Running" : "Not running",
                         style: running ? .good : .neutral)
                    if state.isStale(pair) {
                        Chip(text: "Built from \(instance.builtFromSourceVersion)", style: .accent)
                    }
                    if !bundleExists {
                        Chip(text: "Launcher missing", style: .bad)
                    }
                }
                Text(pair.app.displayName + (pair.app.sourceVersion.isEmpty ? "" : " \(pair.app.sourceVersion)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: Actions

    private var actions: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if isTool {
                    Button { state.presentation = .create } label: {
                        Label("Create GUI Instance…", systemImage: "plus.app")
                    }
                    .buttonStyle(.borderedProminent)
                } else if running {
                    Button { state.quit(instance) } label: { Label("Quit", systemImage: "stop.fill") }
                    Button { state.forceQuit(instance) } label: { Label("Force Quit", systemImage: "bolt.fill") }
                } else {
                    Button { state.launch(instance) } label: { Label("Launch", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent)
                        .disabled(!bundleExists)
                }
                Button {
                    state.requestDelete(instance)
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(state.busy || running)
                .help(running ? "Quit this instance before deleting it" : "Delete this instance…")

                Menu {
                    Button("Reveal in Finder") { state.reveal(instance.bundlePath) }
                    Button("Open Data Folder") { state.open(URL(fileURLWithPath: instance.dataPath)) }
                    Button("View Logs") { if let d = state.logsDirectory(for: instance) { state.open(d) } }
                    Divider()
                    Button("Rebuild from Source App") { state.rebuild(instance) }
                        .disabled(state.busy || running || isTool || rebuildWouldBeRefused)
                        .help(rebuildWouldBeRefused
                              ? "\(appDisplayName) can only be run in Lite mode now, and a Lite instance of it shares the original's signed-in session. Accept that under Advanced to rebuild this instance."
                              : "Regenerate this launcher from the current version of the source app")
                    Button("Duplicate") { state.duplicate(instance) }
                        .disabled(state.busy || isTool)
                    Button("Edit Badge…") { showingBadgeEditor = true }
                        .disabled(isTool)
                    Divider()
                    Button("Claim URL Schemes") { state.claimURLSchemes(instance) }
                        .disabled(state.busy || isTool || instance.mode != .full)
                        .help(instance.mode == .lite
                              ? "Lite launchers use the original app's URL-scheme identity and cannot claim schemes separately."
                              : "Make this Full launcher the current owner of the app's custom URL schemes.")
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .fixedSize()
                Spacer()
            }

            if state.isStale(pair) {
                InlineNote(kind: .accent,
                           text: "\(pair.app.displayName) has been updated to \(pair.app.sourceVersion). Rebuilding regenerates this launcher from the new version and keeps your data and sign-in exactly as they are.")
            }
            if isTool {
                InlineNote(
                    kind: .bad,
                    text: "This older launcher opens Terminal, so LaunchAgain has disabled it. Choose New Instances and select the installed Codex GUI application (normally /Applications/ChatGPT.app), then uninstall this legacy instance when you are ready.")
            } else if instance.mode == .lite {
                InlineNote(kind: .caution,
                           text: "This instance runs in Lite mode. Its Chromium profile is separate, but it opens the vendor-signed original app and therefore shares that app's Dock, Keychain, privacy-permission and URL-scheme identity. URL-scheme claiming is unavailable.")
            }
            if !bundleExists {
                InlineNote(
                    kind: .bad,
                    text: isTool
                        ? "The legacy launcher is already missing. Uninstall this entry to remove the LaunchAgain-owned session directory as well."
                        : "The launcher bundle is missing from disk. Rebuild it — your profile at the path below is untouched.")
            }
        }
    }

    // MARK: Identity and fields

    private var identity: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                FieldRow(label: "Name") {
                    HStack {
                        TextField("Unnamed", text: $name)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(commitName)
                        Button("Rename", action: commitName)
                            .disabled(state.busy || running || isTool
                                      || Validation.sanitizeInstanceName(name) == instance.name)
                    }
                }
                FieldRow(label: "Account",
                         help: "A label to remind you which account this instance is signed in to. It is never used to sign in, and never leaves this Mac.") {
                    HStack {
                        TextField("you@example.com", text: $accountLabel)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(commitAccountLabel)
                        Button("Save", action: commitAccountLabel)
                            .disabled(Validation.sanitizeAccountLabel(accountLabel) == instance.accountLabel)
                    }
                }
                Divider()
                KeyValueRow(key: "Number", value: "\(instance.number) — fixed for this instance; deleting another one never changes it")
                if let variable = legacyEnvironmentVariable {
                    KeyValueRow(key: "Isolated by",
                                value: "\(variable) — legacy Terminal launcher; this release does not create these",
                                monospaced: false)
                }
                KeyValueRow(key: "Bundle id", value: instance.clonedBundleIdentifier.isEmpty ? "—" : instance.clonedBundleIdentifier, monospaced: true)
                KeyValueRow(key: "Launcher", value: instance.bundlePath, monospaced: true)
                KeyValueRow(key: isTool ? "Session directory" : "Profile", value: instance.dataPath, monospaced: true)
                if let size = state.profileSizes[instance.id] {
                    KeyValueRow(key: "Profile size", value: FSOps.humanBytes(size))
                }
                KeyValueRow(key: "Built from", value: instance.builtFromSourceVersion.isEmpty ? "—" : instance.builtFromSourceVersion)
                KeyValueRow(key: "Created", value: Self.dateFormatter.string(from: instance.createdAt))
                KeyValueRow(key: "Last launched",
                            value: instance.lastLaunchedAt.map { Self.dateFormatter.string(from: $0) } ?? "never")
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var buildNotes: some View {
        GroupBox("What the build had to change") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(instance.buildNotes, id: \.self) { note in
                    Label(note, systemImage: "wrench.and.screwdriver")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .labelStyle(BulletLabelStyle())
                }
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Permissions

    private var declaredPermissions: [PermissionsInspector.DeclaredPermission] {
        let inspectedPath = instance.mode == .lite
            ? pair.app.sourcePath
            : instance.bundlePath
        guard FileManager.default.fileExists(atPath: inspectedPath) else { return [] }
        return PermissionsInspector.declared(in: URL(fileURLWithPath: inspectedPath))
    }

    private var permissions: some View {
        GroupBox("Permissions") {
            VStack(alignment: .leading, spacing: 10) {
                if instance.mode == .lite {
                    Label {
                        Text("Lite mode launches the original vendor-signed \(pair.app.displayName) application with this instance's separate Chromium profile. Its file access, entitlements, Keychain identity and macOS privacy permissions are the original app's.")
                    } icon: {
                        Image(systemName: "person.2").foregroundStyle(.orange)
                    }
                    .font(.caption)
                    .labelStyle(BulletLabelStyle())
                } else {
                    Label {
                        Text("File permissions and the app's settings are copied from \(pair.app.displayName). Entitlements are preserved except for the signing-required additions and Team-ID removals disclosed for this instance.")
                    } icon: {
                        Image(systemName: "checkmark.circle").foregroundStyle(.green)
                    }
                    .font(.caption)
                    .labelStyle(BulletLabelStyle())

                    Label {
                        Text("Privacy permissions are held by macOS against an app's identity, and this Full instance has its own. It starts with none and asks the first time it needs one — using \(pair.app.displayName)'s own wording.")
                    } icon: {
                        Image(systemName: "hand.raised").foregroundStyle(.orange)
                    }
                    .font(.caption)
                    .labelStyle(BulletLabelStyle())
                }

                if !declaredPermissions.isEmpty {
                    Divider()
                    Text("What this app may ask for")
                        .font(.caption).fontWeight(.semibold)
                    ForEach(declaredPermissions) { permission in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(permission.name).font(.caption).fontWeight(.medium)
                            Text(permission.purpose)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                HStack {
                    Button("Open Privacy & Security Settings") {
                        PermissionsInspector.openPrivacySettings()
                    }
                    Spacer()
                }
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Advanced

    private var advanced: some View {
        DisclosureGroup(isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 12) {
                InlineNote(kind: .caution,
                           text: "These settings are passed straight to the application. A wrong flag can stop it launching; if that happens, clear the field and rebuild. Applying any change here rebuilds the launcher and never touches your profile.")

                VStack(alignment: .leading, spacing: 4) {
                    Text("Extra command line arguments").font(.caption).fontWeight(.medium)
                    TextEditor(text: $argumentsText)
                        .font(.system(.caption, design: .monospaced))
                        .frame(height: 54)
                        .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.12)) }
                    Text("One per line. `--user-data-dir` and `--profile-directory` are managed by the launcher and will be rejected.")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Extra environment variables").font(.caption).fontWeight(.medium)
                    TextEditor(text: $environmentText)
                        .font(.system(.caption, design: .monospaced))
                        .frame(height: 54)
                        .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.12)) }
                    Text("KEY=value, one per line. HOME is refused: redirecting it breaks Keychain, privacy permissions and sandbox lookups.")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Profile directory").font(.caption).fontWeight(.medium)
                    HStack {
                        TextField("", text: $dataPathText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption, design: .monospaced))
                        Button("Choose…") { chooseDataDirectory() }
                    }
                    Text("Points this instance at a different profile. It does not move the existing one — the old directory stays where it is, and this instance will be signed out until you sign in again.")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                if !isTool {
                    Toggle("Force Lite mode", isOn: $forceLite)
                        .help("Stops cloning. The Chromium profile stays separate, but Dock, Keychain, privacy permissions and URL schemes use the original app's identity.")
                    if forceLite && instance.mode == .full {
                        // The old text offered "use Rebuild after turning this off", which
                        // does not work: `rebuild` builds at the *stored* mode, and by
                        // then the stored mode is Lite. Nothing in the product converts
                        // Lite back to Full, so the only honest instruction is the one
                        // that works.
                        Text("Switching to Lite mode cannot be undone from here, or by rebuilding. To get a Full clone back you have to delete this instance and create a new one, which starts with an empty profile.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }

                    // The same gate the create flow applies, from the same rule.
                    //
                    // This route used to have no gate at all: turning this on set the
                    // proposed mode to Lite, and the engine then read that back as the
                    // acknowledgement. Three clicks converted a Full instance of a
                    // shared-credential-store app to Lite with no warning shown and none
                    // required.
                    if let verdict = sharedCredentialVerdict {
                        VStack(alignment: .leading, spacing: 10) {
                            SharedCredentialWarning(stores: verdict.sharedCredentialStores)
                            Toggle(isOn: $acknowledgedSharedCredentials) {
                                Text("I accept that this instance will share one signed-in session with \(appDisplayName), and that signing out of it signs out every copy including the original.")
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .toggleStyle(.checkbox)
                        }
                        .padding(.top, 4)
                    }
                }

                HStack {
                    Spacer()
                    Button("Revert", action: loadFromInstance)
                    Button("Apply and Rebuild", action: applyAdvanced)
                        .buttonStyle(.borderedProminent)
                        .disabled(state.busy || running || needsSharedCredentialAcknowledgement)
                }
            }
            .padding(.top, 8)
        } label: {
            Text("Advanced").font(.headline)
        }
    }

    // MARK: Danger

    private var dangerZone: some View {
        GroupBox {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Delete this instance").font(.callout).fontWeight(.medium)
                    Text("Removes the launcher and every profile, log and lock file LaunchAgain owns for this instance.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(role: .destructive) {
                    state.requestDelete(instance)
                } label: {
                    Label("Delete…", systemImage: "trash")
                }
                .disabled(state.busy || running)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: Badge sheet

    private var badgeSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Badge for instance #\(instance.number)").font(.headline)
            if let icon = sourceIcon, let factory = state.iconFactory {
                BadgeEditor(badge: $badge, number: instance.number, sourceIcon: icon, factory: factory)
            } else {
                Text("The source application could not be read, so a preview is not available.")
                    .foregroundStyle(.secondary)
            }
            Text("The number is what identifies an instance. Colour is decoration — it is never the only difference between two icons.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { showingBadgeEditor = false }
                Button("Apply and Rebuild") {
                    showingBadgeEditor = false
                    state.setBadge(instance, to: badge)
                }
                .buttonStyle(.borderedProminent)
                .disabled(running)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private var sourceIcon: NSImage? {
        let url = URL(fileURLWithPath: pair.app.sourcePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return IconFactory.loadSourceIcon(appBundle: url)
    }

    // MARK: Actions

    private func loadFromInstance() {
        name = instance.name
        accountLabel = instance.accountLabel
        badge = instance.badge
        argumentsText = instance.extraArguments.joined(separator: "\n")
        environmentText = instance.extraEnvironment.keys.sorted()
            .map { "\($0)=\(instance.extraEnvironment[$0]!)" }
            .joined(separator: "\n")
        dataPathText = instance.dataPath
        forceLite = instance.mode == .lite
        // Revert, and selecting a different instance, must both drop an acknowledgement
        // given for something else. The same `@State`-outlives-its-subject mistake in the
        // create flow is Mi-1.
        acknowledgedSharedCredentials = false
    }

    private func commitName() {
        let clean = Validation.sanitizeInstanceName(name)
        guard clean != instance.name else { return }
        state.rename(instance, to: clean)
    }

    private func commitAccountLabel() {
        state.setAccountLabel(instance, to: accountLabel)
    }

    private func chooseDataDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"
        if panel.runModal() == .OK, let url = panel.url {
            dataPathText = url.path
        }
    }

    private func applyAdvanced() {
        let args = argumentsText.split(separator: "\n").map(String.init)
        var env: [String: String] = [:]
        for line in environmentText.split(separator: "\n") {
            let s = String(line)
            guard let eq = s.firstIndex(of: "=") else { continue }
            env[String(s[s.startIndex..<eq]).trimmingCharacters(in: .whitespaces)] =
                String(s[s.index(after: eq)...])
        }
        let newPath = dataPathText.trimmingCharacters(in: .whitespaces)
        state.applyAdvanced(instance,
                            arguments: args,
                            environment: env,
                            forceLite: forceLite,
                            acknowledgedSharedCredentialStore: acknowledgedSharedCredentials,
                            dataPath: newPath == instance.dataPath ? nil : newPath)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}

// MARK: - Inline note

struct InlineNote: View {
    var kind: Chip.Style
    var text: String

    private var tint: Color {
        switch kind {
        case .good: return .green
        case .caution: return .orange
        case .bad: return .red
        case .accent: return .accentColor
        case .neutral: return .secondary
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: kind == .bad ? "exclamationmark.octagon" : "info.circle")
                .foregroundStyle(tint)
                .imageScale(.small)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Delete

struct DeleteInstanceSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    var instance: Instance

    @State private var typed = ""

    private var appName: String {
        state.instance(instance.id)?.app.displayName ?? "this app"
    }
    private var title: String {
        instance.displayTitle(sourceName: appName)
    }
    private var launcherGone: Bool { state.isMissingLauncher(instance) }
    private var confirmed: Bool {
        typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "delete"
    }
    private var hasExternalProfile: Bool {
        guard let support = state.supportDirectory?.path, !instance.dataPath.isEmpty else {
            return false
        }
        return !Validation.isPath(instance.dataPath, within: support)
            && FileManager.default.fileExists(atPath: instance.dataPath)
    }

    /// The last thing someone sees before losing a signed-in session and, on this
    /// machine, twelve gigabytes.
    ///
    /// It used to be a dense red block of body text above a bare field and a disabled
    /// button — every fact present and none of them findable. The facts are unchanged
    /// and the typed confirmation is unchanged; what changed is that the two questions
    /// a person actually has ("what goes?" and "can I undo it?") are answerable at a
    /// glance, and the reassurance about what is untouched is not competing with the
    /// warning for the same attention.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.vertical, 20)
            whatGoes
            if hasExternalProfile {
                InlineNote(
                    kind: .caution,
                    text: "This instance points at the external profile \(instance.dataPath). That folder is one you chose, it is outside LaunchAgain, and it will be kept — only files LaunchAgain installed and owns are removed.")
                    .padding(.top, 16)
            }
            recoverability.padding(.top, 16)
            whatStays.padding(.top, 20)
            Divider().padding(.vertical, 20)
            confirmation
            footer.padding(.top, 20)
        }
        .padding(20)
        .frame(width: 560)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "trash.circle.fill")
                .font(.system(size: 38, weight: .regular))
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Uninstall “\(title)”?")
                    .font(.title3).fontWeight(.semibold)
                    .fixedSize(horizontal: false, vertical: true)
                Text(launcherGone
                     ? "Its application has already been removed in Finder. This tidies up what is left of instance #\(instance.number)."
                     : "Instance #\(instance.number) of \(appName).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Three lines, each naming one thing and its size, instead of one sentence
    /// containing all of them.
    private var whatGoes: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What this removes")
                .font(.callout).fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 8) {
                removalRow(
                    symbol: "app.badge.checkmark",
                    title: "The numbered launcher",
                    detail: URL(fileURLWithPath: instance.bundlePath).lastPathComponent,
                    trailing: nil)
                removalRow(
                    symbol: "person.crop.circle.badge.xmark",
                    title: "The signed-in session and everything in its profile",
                    detail: "Cookies, local storage, caches, logs and lock files. You will have to sign in again.",
                    trailing: state.profileSizes[instance.id].map(FSOps.humanBytes))
                removalRow(
                    symbol: "gearshape",
                    title: "Its own macOS support files",
                    detail: "The preference domain and caches keyed to this instance's generated identifier, and nothing keyed to \(appName)'s.",
                    trailing: nil)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func removalRow(symbol: String,
                            title: String,
                            detail: String,
                            trailing: String?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if let trailing {
                Text(trailing)
                    .font(.callout).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var recoverability: some View {
        Label {
            Text("Everything goes to the Trash, so you can put it back until you empty it.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "arrow.uturn.backward.circle")
                .foregroundStyle(.blue)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var whatStays: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What stays exactly as it is")
                .font(.callout).fontWeight(.semibold)
            ForEach([
                "\(appName) itself, and the account you are signed into there.",
                "Every other instance, and the profile inside each one.",
                "Number \(instance.number) becomes free again for the next instance you create.",
            ], id: \.self) { line in
                Label(line, systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .labelStyle(BulletLabelStyle())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Unchanged in substance: destroying a signed-in session still takes a typed word.
    private var confirmation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Type **delete** to confirm")
                .font(.callout)
            TextField("delete", text: $typed)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .frame(maxWidth: 220)
                .onSubmit { if confirmed { performDelete() } }
                .accessibilityLabel("Type delete to confirm")
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .controlSize(.large)
            Button("Uninstall Instance", role: .destructive) {
                performDelete()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!confirmed)
        }
    }

    private func performDelete() {
        if launcherGone {
            state.forget(instance)
        } else {
            state.remove(instance)
        }
        dismiss()
    }
}
#endif
