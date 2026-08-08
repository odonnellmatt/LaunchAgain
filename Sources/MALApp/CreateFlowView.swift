//
//  Create flow — the second screen.
//
//  Pick an app → read what it will and will not do → choose how many and name them →
//  review exactly what is about to happen → build → read the first-login instructions.
//
//  The review step exists because this is the moment a user is committing disk space and
//  a set of permanent numbers. It states the numbers that will be assigned, the estimated
//  disk cost, where the launchers will be written, and — just as importantly — what will
//  *not* be touched.
//

#if canImport(AppKit)
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MALCore
import MALKit

struct CreateFlowView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    enum Step: Int, CaseIterable { case pick, compatibility, configure, review, done }

    @State private var step: Step = .pick

    // Step 1
    @State private var installed: [Candidate] = []
    @State private var loadingApps = true
    @State private var search = ""
    @State private var chosen: URL?

    // Step 2
    @State private var facts: AppFacts?
    @State private var verdict: CompatibilityVerdict?
    @State private var inspectError: String?
    @State private var inspecting = false

    // Step 3
    // One. Creating two by default meant every user who wanted one instance had to
    // notice the control and change it, and anyone who did not read it carefully got a
    // second numbered app and a second profile they never asked for.
    @State private var count = 1
    @State private var customCount = false
    @State private var names: [String] = Array(repeating: "", count: 8)
    @State private var accounts: [String] = Array(repeating: "", count: 8)
    @State private var badges: [BadgeSpec] = []
    @State private var forceLite = false
    @State private var acknowledgedSharedCredentials = false
    @State private var allowEmbeddedUpdater = false
    @State private var editingBadgeIndex: Int?
    @State private var isBuilding = false

    // Step 5
    @State private var outcome: InstanceManager.CreationOutcome?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if isBuilding {
                    buildProgress
                } else {
                    content
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 660, height: 560)
        .onAppear(perform: loadApps)
        .interactiveDismissDisabled(isBuilding)
    }

    // MARK: Chrome

    private var header: some View {
        HStack(spacing: 10) {
            Text(title).font(.headline)
            Spacer()
            ForEach(Step.allCases, id: \.rawValue) { s in
                Circle()
                    .fill(s.rawValue <= step.rawValue ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: 6, height: 6)
            }
        }
        .padding(14)
    }

    private var title: String {
        switch step {
        case .pick: return "Choose an application"
        case .compatibility: return "What this will do"
        case .configure: return "Name your instances"
        case .review: return "Review"
        case .done: return "Done"
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .pick: pickStep
        case .compatibility: compatibilityStep
        case .configure: configureStep
        case .review: reviewStep
        case .done: doneStep
        }
    }

    private var footer: some View {
        HStack {
            if isBuilding {
                ProgressView().controlSize(.small)
                Text("Creating safely—please keep LaunchAgain open.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            } else if step == .done {
                Button("Close") { dismiss() }
                Spacer()
                Button("Show Me") { dismiss() }.buttonStyle(.borderedProminent)
            } else {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if step != .pick {
                    Button("Back") { back() }
                }
                Button(step == .review ? "Create \(count) Instance\(count == 1 ? "" : "s")" : "Continue") {
                    forward()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canAdvance)
            }
        }
        .padding(14)
    }

    private var buildProgress: some View {
        VStack(spacing: 16) {
            if let fraction = state.activity?.fraction {
                ProgressView(value: fraction)
                    .frame(width: 300)
            } else {
                ProgressView()
                    .controlSize(.large)
            }
            Text(state.activity?.title ?? "Creating instances")
                .font(.title3.weight(.semibold))
            Text(state.activity?.detail ?? "Preparing the launcher…")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
                .id(state.activity?.detail)
            Text("Full app clones must be patched and every nested component must be re-signed. This can take a little while for large apps; your source app and existing profiles are not modified.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
        }
        .padding(40)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("instance-build-progress")
    }

    private var canAdvance: Bool {
        switch step {
        case .pick: return chosen != nil && !inspecting
        case .compatibility: return verdict?.canCreate == true
        case .configure: return count >= 1 && !needsSharedCredentialAcknowledgement
        case .review: return !state.busy && !needsSharedCredentialAcknowledgement
        case .done: return true
        }
    }

    /// True when this build would run in Lite mode, whether the user asked for it or the
    /// compatibility verdict did.
    private var liteRequested: Bool {
        forceLite || verdict?.recommendedMode == .lite
    }

    /// Blocks Next until the shared-session consequence has actually been accepted,
    /// rather than letting the user reach the build and be refused there.
    private var needsSharedCredentialAcknowledgement: Bool {
        liteRequested
            && verdict?.sharesCredentialStore == true
            && !acknowledgedSharedCredentials
    }

    // MARK: Step 1 — pick

    private var pickStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search installed applications", text: $search)
                    .textFieldStyle(.plain)
                Button("Choose…") { chooseWithPanel() }
            }
            .padding(8)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))

            if loadingApps {
                HStack { ProgressView().controlSize(.small); Text("Looking for installed apps…").foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                    if !appCandidates.isEmpty {
                            candidateSectionTitle("GUI applications")
                            ForEach(appCandidates) { candidate in
                                candidateRow(candidate)
                            }
                        }
                    }
                    .padding(6)
                }
                .background(
                    Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 7))
                .accessibilityIdentifier("create-candidate-list")
            }

            Text("Installed GUI applications are listed. You can also drag a macOS .app here, or use Choose… to pick one anywhere on disk.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.pathExtension == "app" else { return }
                DispatchQueue.main.async { select(url) }
            }
            return true
        }
    }

    private func candidateSectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.top, 7)
    }

    private func candidateRow(_ candidate: Candidate) -> some View {
        Button {
            select(URL(fileURLWithPath: candidate.facts.path))
        } label: {
            HStack(spacing: 8) {
                CandidateIcon(facts: candidate.facts, size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(candidate.facts.displayName)
                    Text(candidate.subtitle)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Chip(text: candidate.verdict.tierLabel, style: candidate.verdict.tier.chipStyle)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(
                chosen?.standardizedFileURL.path == candidate.facts.path
                    ? Color.accentColor.opacity(0.18)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    /// One row's worth of precomputed state.
    ///
    /// Compatibility is precomputed rather than reevaluated on every search keystroke.
    /// Icons are deliberately not retained here: the lazy list asks macOS only for the
    /// handful of rows currently visible.
    struct Candidate: Identifiable {
        let facts: AppFacts
        let verdict: CompatibilityVerdict
        var id: String { facts.path }
        var subtitle: String {
            "\(facts.version.isEmpty ? "—" : facts.version) · \(facts.runtime.displayName)"
        }
        var searchKey: String { facts.displayName.lowercased() }
    }

    private var filteredApps: [Candidate] {
        guard !search.isEmpty else { return installed.filter { $0.verdict.canCreate } }
        let needle = search.lowercased()
        return installed.filter { $0.searchKey.contains(needle) }
    }

    private var appCandidates: [Candidate] { filteredApps }

    // MARK: Step 2 — compatibility

    @ViewBuilder private var compatibilityStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if inspecting {
                    HStack { ProgressView().controlSize(.small); Text("Inspecting…") }
                } else if let inspectError {
                    InlineNote(kind: .bad, text: inspectError)
                } else if let facts, let verdict {
                    CompatibilityCard(facts: facts, verdict: verdict)

                    if !verdict.canCreate {
                        InlineNote(kind: .bad,
                                   text: "This app can't be isolated safely, so the launcher will not pretend otherwise. Nothing has been created.")
                    } else if verdict.recommendedMode == .lite {
                        InlineNote(kind: .caution,
                                   text: "Instances of this app will run in Lite mode. Their Chromium profiles are separate, but they share the vendor app's Dock, Keychain, privacy-permission and URL-scheme identity.")
                    }
                }
            }
            .padding(14)
        }
    }

    // MARK: Step 3 — configure

    private var configureStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                howManyCard

                ForEach(0..<count, id: \.self) { i in
                    instanceCard(index: i)
                }

                Toggle("Force Lite mode for all of these", isOn: $forceLite)
                    .help("Skips cloning. Chromium profiles stay separate; Dock, Keychain, privacy permissions and URL schemes use the original app's identity.")

                // Lite runs the vendor-signed original, so for an app whose session
                // lives in the Keychain, an App Group container or a home-directory
                // configuration it separates nothing that matters. The engine refuses it
                // outright; this is the only thing that unlocks it, and it has to name
                // the consequence rather than say "I understand".
                if liteRequested, let verdict, verdict.sharesCredentialStore {
                    VStack(alignment: .leading, spacing: 10) {
                        SharedCredentialWarning(stores: verdict.sharedCredentialStores)
                        Toggle(isOn: $acknowledgedSharedCredentials) {
                            Text("I accept that these Lite instances will share one signed-in session with \(facts?.displayName ?? "the original app"), and that signing out of any of them signs out all of them.")
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
            .padding(14)
        }
        .sheet(item: Binding(get: { editingBadgeIndex.map { IndexBox(value: $0) } },
                             set: { editingBadgeIndex = $0?.value })) { box in
            badgeSheet(index: box.value)
        }
    }

    private struct IndexBox: Identifiable { let value: Int; var id: Int { value } }

    // MARK: How many

    /// 1, 2, 3 or a number you choose — and, for the number you choose, what it will
    /// actually cost.
    ///
    /// The disk estimate already existed on the review step, one screen after the
    /// decision it informs. A stepper with no context is not a choice, it is a guess, so
    /// the free space on the destination volume and the estimated cost of the current
    /// count are shown here, next to the control that changes them.
    private var howManyCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("How many?")
                    .font(.callout)
                Picker("", selection: Binding(
                    get: { customCount ? -1 : count },
                    set: { newValue in
                        if newValue == -1 {
                            customCount = true
                        } else {
                            customCount = false
                            count = newValue
                        }
                    })) {
                        Text("1").tag(1)
                        Text("2").tag(2)
                        Text("3").tag(3)
                        Text("Custom").tag(-1)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                    .labelsHidden()
                Spacer()
            }

            if customCount {
                HStack(spacing: 10) {
                    Stepper(value: $count, in: 1...64) {
                        Text("\(count) instance\(count == 1 ? "" : "s")")
                            .monospacedDigit()
                    }
                    .fixedSize()
                    Spacer()
                }
            }

            Divider()

            HStack(alignment: .firstTextBaseline, spacing: 24) {
                LabeledContent("Estimated") {
                    Text(estimatedTotal.map(FSOps.humanBytes) ?? "—")
                        .monospacedDigit()
                }
                LabeledContent("Free on \(destinationVolumeName)") {
                    Text(freeSpace.map(FSOps.humanBytes) ?? "—")
                        .monospacedDigit()
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            if !liteRequested {
                Text("A Full instance is a copy of the application as well as a profile. APFS shares unchanged blocks with the original, so the space actually used is usually less than this — but not on a volume without cloning, and sharing decays as either copy changes.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let warning = spaceWarning {
                InlineNote(kind: .caution, text: warning)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08))
        }
    }

    /// Where the launchers will go, which is not always the user's own Applications
    /// folder and is not always on the same volume as anything else.
    private var destinationDirectory: URL {
        if let verdict, verdict.systemApplicationsRequirement != nil,
           let system = state.systemBundlesDirectory {
            return system
        }
        return state.bundlesDirectory ?? URL(fileURLWithPath: NSHomeDirectory())
    }

    private var destinationVolumeName: String {
        (try? destinationDirectory.resourceValues(forKeys: [.volumeNameKey]).volumeName)
            .flatMap { $0 } ?? "disk"
    }

    private var freeSpace: Int64? {
        // The *available* capacity for important usage, not the raw free blocks: it is
        // what the user will actually be able to write.
        let values = try? destinationDirectory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    private var estimatedTotal: Int64? {
        guard let verdict, let facts else { return nil }
        return verdict.estimatedBytesPerInstance(
            mode: liteRequested ? .lite : .full,
            sourceBundleBytes: facts.bundleSizeBytes) * Int64(max(count, 0))
    }

    /// Warns *before* the choice rather than after the build fails.
    private var spaceWarning: String? {
        guard let estimatedTotal, let freeSpace else { return nil }
        if estimatedTotal >= freeSpace {
            return "\(count) instance\(count == 1 ? "" : "s") could need about \(FSOps.humanBytes(estimatedTotal)) after first run, and there is \(FSOps.humanBytes(freeSpace)) free on \(destinationVolumeName). Choose fewer, or make room first."
        }
        // A tenth of the volume left is the point at which macOS itself starts
        // complaining, so say something before then rather than after.
        if freeSpace - estimatedTotal < estimatedTotal / 2 {
            return "This would leave about \(FSOps.humanBytes(freeSpace - estimatedTotal)) free on \(destinationVolumeName). Profiles grow as you use them."
        }
        return nil
    }

    private func instanceCard(index i: Int) -> some View {
        let number = number(at: i)
        return HStack(alignment: .top, spacing: 12) {
            Button {
                editingBadgeIndex = i
            } label: {
                if let icon = sourceIcon {
                    BadgePreview(sourceIcon: icon, number: number,
                                 badge: badge(at: i), size: 52,
                                 factory: state.iconFactory ?? IconFactory(cacheDir: FileManager.default.temporaryDirectory))
                } else {
                    Image(systemName: "app.dashed").font(.system(size: 34))
                }
            }
            .buttonStyle(.plain)
            .help("Edit this badge")

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("#\(number)")
                        .font(.system(.body, design: .rounded)).fontWeight(.bold).monospacedDigit()
                    TextField("Name (optional) — e.g. Work",
                              text: Binding(get: { names[safe: i] }, set: { names[safe: i] = $0 }))
                        .textFieldStyle(.roundedBorder)
                }
                TextField("Account label (optional) — e.g. you@company.com",
                          text: Binding(get: { accounts[safe: i] }, set: { accounts[safe: i] = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func badgeSheet(index i: Int) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Badge for instance #\(number(at: i))").font(.headline)
            if let icon = sourceIcon, let factory = state.iconFactory {
                BadgeEditor(badge: Binding(get: { badge(at: i) },
                                           set: { setBadge($0, at: i) }),
                            number: number(at: i),
                            sourceIcon: icon,
                            factory: factory)
            }
            HStack {
                Spacer()
                Button("Done") { editingBadgeIndex = nil }.buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    // MARK: Step 4 — review

    private var reviewStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let facts, let verdict {
                    GroupBox("About to create") {
                        VStack(alignment: .leading, spacing: 7) {
                            KeyValueRow(key: "Application", value: "\(facts.displayName) \(facts.version)")
                            KeyValueRow(key: "Source", value: facts.path, monospaced: true)
                            KeyValueRow(key: "Numbers", value: numbersPreview)
                            KeyValueRow(key: "Isolation",
                                        value: forceLite || verdict.recommendedMode == .lite
                                        ? "Lite — separate profile; shared macOS app identity"
                                        : "Full — separate profile and numbered Dock icon")
                            KeyValueRow(key: "Install to", value: destinationDirectory.path, monospaced: true)
                            KeyValueRow(key: "Disk (estimate)",
                                        value: "\(FSOps.humanBytes(estimatedTotal ?? 0)) total after first run\(liteRequested ? "" : ", including a copy of the application")")
                        }
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // The trade-off is stated where the decision is made, not only in a
                    // document: this is the one behaviour of an instance that differs
                    // from the application the user already knows.
                    if !(forceLite || verdict.recommendedMode == .lite) {
                        GroupBox("Updates") {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(updatesExplanation(facts))
                                    .font(.callout)
                                    .fixedSize(horizontal: false, vertical: true)
                                Toggle("Let these instances update themselves (advanced)",
                                       isOn: $allowEmbeddedUpdater)
                                    .help("Restores the application's own Squirrel or Sparkle updater inside each clone. An update will overwrite the numbered identity this build creates.")
                            }
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    GroupBox("What stays exactly as it is") {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(unchangedList, id: \.self) { item in
                                Label(item, systemImage: "lock")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .labelStyle(BulletLabelStyle())
                            }
                        }
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    GroupBox("Limitations you are accepting") {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(verdict.limitations, id: \.self) { l in
                                Label(l, systemImage: "exclamationmark.circle")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .labelStyle(BulletLabelStyle())
                            }
                        }
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(14)
        }
    }

    /// What the Updates box says, from what will actually be done to *this* application
    /// rather than from a promise made in advance.
    ///
    /// The unconditional version — "These instances will not update themselves" — was
    /// false for ChatGPT, where none of the keys the patcher looks for are declared and
    /// nothing was neutralised. An honest "we could not find one" is more useful than a
    /// guarantee the build cannot keep.
    private func updatesExplanation(_ facts: AppFacts) -> String {
        if allowEmbeddedUpdater {
            return "These instances keep \(facts.displayName)'s own updater. If it applies an update it replaces the instance's identity, numbered icon and signature, and the instance rejoins the original's Dock tile. Your profile and sign-in are not affected — rebuild to restore the numbering."
        }
        let planned = UpdaterNeutraliser.plannedNeutralisations(
            forSource: URL(fileURLWithPath: facts.path))
        guard !planned.isEmpty else {
            return "LaunchAgain could not find an updater to disable in \(facts.displayName). Automatic update checks are switched off in the copy, but some applications set their update feed from their own code rather than from Info.plist, and that cannot be reached from outside. If an update does replace an instance's numbered identity, rebuild it — the profile and the sign-in inside it are not affected."
        }
        let list = ListFormatter.localizedString(byJoining: planned)
        return "These instances will not update themselves: \(list) will be removed from each copy. Each one stays at \(facts.version) until you rebuild it, and rebuilding regenerates the bundle from the current \(facts.displayName) while keeping the profile and the sign-in inside it. The original application updates normally and is never touched."
    }

    private var unchangedList: [String] {
        var l = [
            "The original application at \(facts?.path ?? "") is opened read-only. It is never written to, moved, renamed or re-signed, and the build checks its fingerprint before and after to prove it.",
            "Your existing sign-in in the original app is untouched.",
            "No system setting changes: no SIP, no Gatekeeper, no root, no helper tool, no login item.",
            "Nothing is sent anywhere. This app makes no network requests.",
        ]
        if count > 0, let v = verdict, v.recommendedMode == .full, !forceLite {
            l.append("Each instance gets a fresh, empty profile — profiles are never copied between instances, because that would copy a signed-in session.")
        }
        return l
    }

    // MARK: Step 5 — done

    private var doneStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let outcome {
                    if !outcome.created.isEmpty {
                        GroupBox("Created") {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(outcome.created, id: \.id) { i in
                                    HStack(spacing: 8) {
                                        FileIcon(path: i.bundlePath, size: 28)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text("#\(i.number) \(i.name.isEmpty ? "Unnamed" : i.name)")
                                            Text(i.bundlePath)
                                                .font(.system(.caption2, design: .monospaced))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1).truncationMode(.middle)
                                        }
                                        Spacer()
                                        Chip(text: i.mode == .full ? "Full" : "Lite",
                                             style: i.mode == .full ? .good : .caution)
                                    }
                                }
                            }
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    if !outcome.failures.isEmpty {
                        GroupBox("Did not get created") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(outcome.failures, id: \.number) { f in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("#\(f.number)").fontWeight(.medium)
                                        Text(f.error).font(.caption).foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                Text("Nothing was left behind for these — no bundle, no profile, no registry entry.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    if !outcome.degraded.isEmpty {
                        InlineNote(kind: .caution,
                                   text: "Instance\(outcome.degraded.count == 1 ? "" : "s") \(outcome.degraded.map(String.init).joined(separator: ", ")) fell back to Lite mode because the clone could not be signed or verified. Their Chromium profiles remain separate, but they share the original app's Dock, Keychain, privacy-permission and URL-scheme identity.")
                    }

                    if signInGuidanceNeeded {
                        GroupBox("Sign in one at a time") {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(signInGuidanceIntroduction)
                                    .font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                ForEach(Array(signInSteps.enumerated()), id: \.offset) { i, s in
                                    Text("\(i + 1). \(s)")
                                        .font(.caption)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Text("Once an instance has signed in, its session lives in its own profile and the collision stops mattering.")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    if !outcome.notes.isEmpty {
                        GroupBox("Notes from the build") {
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(outcome.notes, id: \.self) { n in
                                    Label(n, systemImage: "wrench.and.screwdriver")
                                        .font(.caption).foregroundStyle(.secondary)
                                        .labelStyle(BulletLabelStyle())
                                }
                            }
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    InlineNote(kind: .neutral,
                               text: permissionGuidance)
                }
            }
            .padding(14)
        }
    }

    private var signInGuidanceNeeded: Bool {
        facts?.declaresURLSchemes == true && !(outcome?.created.isEmpty ?? true)
    }

    private var signInSteps: [String] {
        guard let created = outcome?.created, !created.isEmpty else { return [] }
        var steps = created.map { instance in
            let label = "#\(instance.number)\(instance.name.isEmpty ? "" : " – \(instance.name)")"
            if instance.mode == .lite {
                return "Launch \(label) on its own. Prefer an in-app, device-code or password sign-in; a browser URL callback cannot be claimed by a Lite launcher."
            }
            return "Launch \(label) on its own, sign in, then quit it."
        }
        if created.contains(where: { $0.mode == .full }) {
            steps.append("For a Full instance only, if a sign-in link opens the wrong instance, select it and use “Claim URL Schemes”, then try again.")
        }
        return steps
    }

    private var signInGuidanceIntroduction: String {
        guard let created = outcome?.created else { return "" }
        if created.allSatisfy({ $0.mode == .lite }) {
            return "This app signs in through a custom URL scheme. Lite launchers do not declare the source app's schemes, so a browser callback may open the original/default app rather than the intended profile."
        }
        if created.contains(where: { $0.mode == .lite }) {
            return "This app signs in through a custom URL scheme. Full launchers can claim it one at a time; Lite launchers cannot and may receive a callback in the original/default app."
        }
        return "This app signs in through a custom URL scheme, and only one Full launcher on a Mac can own a scheme at a time. If you open all instances at once, the sign-in link returns to whichever one registered last."
    }

    private var permissionGuidance: String {
        guard let created = outcome?.created, !created.isEmpty else {
            return "Full clones get a new macOS privacy identity; Lite launchers share the original app's privacy identity."
        }
        if created.allSatisfy({ $0.mode == .lite }) {
            return "These Lite instances share the original app's macOS privacy-permission identity. Their Chromium profiles remain separate."
        }
        if created.contains(where: { $0.mode == .lite }) {
            return "Full instances have a new macOS privacy identity; Lite instances share the original app's. The interface labels each mode."
        }
        return "Each Full instance is a new app to macOS, so expect fresh permission prompts the first time it uses notifications, microphone, screen recording or similar features."
    }

    // MARK: Plumbing

    /// The numbers these instances will actually get — the lowest ones free right now,
    /// so a gap left by a deleted instance is filled rather than skipped.
    private var plannedNumbers: [Int] {
        guard let facts else { return Array(1...max(count, 1)) }
        guard let app = state.apps.first(where: { $0.appKey == facts.bundleIdentifier }) else {
            return Array(1...max(count, 1))
        }
        return app.nextAvailableNumbers(count: max(count, 1))
    }

    private func number(at index: Int) -> Int {
        let planned = plannedNumbers
        return index < planned.count ? planned[index] : (planned.last ?? 0) + (index - planned.count + 1)
    }

    private var numbersPreview: String {
        plannedNumbers.prefix(count).map { "#\($0)" }.joined(separator: ", ")
            + " — the lowest numbers free right now"
    }

    private var sourceIcon: NSImage? {
        guard let facts else { return nil }
        let url = URL(fileURLWithPath: facts.path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return IconFactory.loadSourceIcon(appBundle: url)
    }

    private func badge(at i: Int) -> BadgeSpec {
        if i < badges.count { return badges[i] }
        return BadgeSpec(colorHex: BadgeSpec.suggestedColor(forNumber: number(at: i)))
    }

    private func setBadge(_ b: BadgeSpec, at i: Int) {
        while badges.count <= i {
            badges.append(BadgeSpec(colorHex: BadgeSpec.suggestedColor(forNumber: number(at: badges.count))))
        }
        badges[i] = b
    }

    private func loadApps() {
        guard installed.isEmpty else { return }
        loadingApps = true
        state.browseInstalledApps { list in
            // Compatibility is evaluated once. Icons are loaded lazily only for rows
            // SwiftUI has on screen, rather than retaining a full NSImage for every
            // application installed on the Mac.
            installed = list
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
                .map { facts in
                    Candidate(facts: facts,
                              verdict: Compatibility.evaluate(facts))
                }
            loadingApps = false
        }
    }

    private func chooseWithPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [UTType.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { select(url) }
    }

    private func select(_ url: URL) {
        chosen = url
        facts = nil
        verdict = nil
        inspectError = nil
        // Choices that belonged to the *previous* application, reset with it.
        //
        // These are `@State` and outlived the thing they were about: tick the
        // shared-session acknowledgement for app A, press Back, choose app B, and B
        // arrived pre-acknowledged — with the warning card never shown for it. Force
        // Lite and the self-update opt-out had the same shape.
        forceLite = false
        acknowledgedSharedCredentials = false
        allowEmbeddedUpdater = false
        inspecting = true
        state.inspect(url) { result in
            inspecting = false
            switch result {
            case .success(let (f, v)):
                facts = f
                verdict = v
                badges = (0..<8).map { BadgeSpec(colorHex: BadgeSpec.suggestedColor(forNumber: number(at: $0))) }
            case .failure(let e):
                inspectError = "\(e)"
            }
        }
    }

    private func forward() {
        switch step {
        case .pick: step = .compatibility
        case .compatibility: step = .configure
        case .configure: step = .review
        case .review: build()
        case .done: dismiss()
        }
    }

    private func back() {
        switch step {
        case .compatibility: step = .pick
        case .configure: step = .compatibility
        case .review: step = .configure
        default: break
        }
    }

    private func build() {
        guard let facts else { return }
        isBuilding = true
        let spec = AppState.CreateSpec(
            source: URL(fileURLWithPath: facts.path),
            count: count,
            names: Array(names.prefix(count)),
            accountLabels: Array(accounts.prefix(count)),
            badges: (0..<count).map { badge(at: $0) },
            forceLite: forceLite,
            stripURLSchemes: false,
            acknowledgedSharedCredentialStore: acknowledgedSharedCredentials,
            allowEmbeddedUpdater: allowEmbeddedUpdater)
        state.create(spec) { result in
            outcome = result
            isBuilding = false
            step = .done
        }
    }
}
#endif
