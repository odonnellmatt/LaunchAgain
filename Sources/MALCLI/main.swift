//
//  launchagain — headless harness for LaunchAgain.
//
//  This exists so the engine can be driven, scripted and tested without the UI. It is
//  the fastest way to reproduce a production-engine bug report.
//
//  No third-party argument parser: the command set is small and a dependency-free
//  build is a product requirement.
//

#if canImport(Darwin)
import Foundation
import AppKit
import MALCore
import MALKit

// MARK: - Output helpers

let stdoutIsTTY = isatty(fileno(stdout)) == 1
func colour(_ s: String, _ code: String) -> String { stdoutIsTTY ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s }
func bold(_ s: String) -> String { colour(s, "1") }
func dim(_ s: String) -> String { colour(s, "2") }
func green(_ s: String) -> String { colour(s, "32") }
func yellow(_ s: String) -> String { colour(s, "33") }
func red(_ s: String) -> String { colour(s, "31") }

func note(_ s: String) { print(s) }
func warn(_ s: String) { print(yellow("! ") + s) }
func fail(_ s: String) -> Never { FileHandle.standardError.write(Data((red("error: ") + s + "\n").utf8)); exit(1) }

/// A one-line reason from an error, without the `NSError` UserInfo dump.
///
/// `doctor --purge-profiles` printed the whole thing — NSFilePath, NSURL,
/// NSUserStringVariant, the nested NSPOSIXErrorDomain — across five lines per failure.
/// The behaviour was right and the message was unreadable.
func tidyReason(_ error: Error) -> String {
    if let mal = error as? MALError { return mal.description }
    let ns = error as NSError
    if let reason = ns.localizedFailureReason, !reason.isEmpty { return reason }
    return ns.localizedDescription
}

func tierBadge(_ t: CompatibilityTier) -> String {
    switch t {
    case .supported:    return green("● supported")
    case .limited:      return yellow("● limited")
    case .notSupported: return red("● not supported")
    }
}

// MARK: - Argument handling

var argv = Array(CommandLine.arguments.dropFirst())

func takeFlag(_ name: String, from argv: inout [String]) -> Bool {
    if let i = argv.firstIndex(of: name) { argv.remove(at: i); return true }
    return false
}
func takeOption(_ name: String, from argv: inout [String]) -> String? {
    if let i = argv.firstIndex(of: name), i + 1 < argv.count {
        let v = argv[i + 1]
        argv.removeSubrange(i...(i + 1))
        return v
    }
    for (i, a) in argv.enumerated() where a.hasPrefix(name + "=") {
        let v = String(a.dropFirst(name.count + 1))
        argv.remove(at: i)
        return v
    }
    return nil
}

let verbose = takeFlag("--verbose", from: &argv) || takeFlag("-v", from: &argv)
let rootOverride = takeOption("--root", from: &argv)
let jsonOutput = takeFlag("--json", from: &argv)

// A testing facility, in the same spirit as --root and deliberately narrower: it is only
// accepted *with* --root, so it can never change where the shipping configuration
// installs anything. It exists so the /Applications behaviour can be exercised
// end-to-end without writing into the user's real store.
let systemBundlesOverride = takeOption("--system-bundles-dir", from: &argv)
if systemBundlesOverride != nil && rootOverride == nil {
    fail("--system-bundles-dir is a testing facility and only applies with --root.")
}

// The other half of the same facility. A rooted store scopes InstanceArtifactCleaner to
// `<root>/user-library`, which is right for a hermetic test and means the real cleanup
// path — the one that removes ~/Library/Caches/<clone-id> and friends — is never
// exercised by one. Pointing the library at the real one, while support and bundles stay
// in a throwaway root, is what makes that measurable without touching the user's store.
// Still bounded: the cleaner's allow-list is keyed to the cryptographically random
// identifier of the clone under test and validated against it before anything is removed.
let userLibraryOverride = takeOption("--user-library", from: &argv)
if userLibraryOverride != nil && rootOverride == nil {
    fail("--user-library is a testing facility and only applies with --root.")
}

let paths: MALPaths = rootOverride.map { root in
    let rooted = MALPaths.rooted(at: URL(fileURLWithPath: root))
    guard systemBundlesOverride != nil || userLibraryOverride != nil else { return rooted }
    return MALPaths(
        support: rooted.support,
        bundlesDir: rooted.bundlesDir,
        systemBundlesDir: systemBundlesOverride
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? rooted.systemBundlesDir,
        userLibrary: userLibraryOverride
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? rooted.userLibrary)
} ?? .standard()

/// - Parameter readOnly: passed `true` by the commands that only report — `scan`,
///   `inspect`, `list` and `doctor`. Until they did, measuring bundle sizes persisted
///   `icon-cache/directory-sizes.json` on every run, so merely looking at the store
///   changed it.
///
///   This is deliberately an argument at each call site rather than a table of command
///   names checked here: there was such a table, nothing ever read it, and a list that
///   claims to decide something it does not decide is worse than no list.
func makeManager(readOnly: Bool = false) -> InstanceManager {
    do {
        return try InstanceManager(paths: paths,
                                   verbose: verbose,
                                   readOnly: readOnly,
                                   migrateFrom: rootOverride == nil ? .legacy() : nil)
    }
    catch { fail("could not open the launcher's data store: \(error)") }
}

func resolveAppPath(_ raw: String) -> URL {
    // Accept a path or a bare GUI application name.
    let direct = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
    if FileManager.default.fileExists(atPath: direct.path) { return direct.standardizedFileURL }

    let name = raw.hasSuffix(".app") ? raw : raw + ".app"
    for dir in AppScanner.defaultSearchLocations {
        let c = dir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: c.path) { return c.standardizedFileURL }
    }

    // Last resort: a case-insensitive match against what is actually installed.
    // This also maps "Codex" to ChatGPT.app through com.openai.codex's display override.
    let needle = raw.lowercased()
    let scanner = AppScanner(log: .silent)
    if let match = scanner.discoverBundles().first(where: {
        $0.deletingPathExtension().lastPathComponent.lowercased() == needle
            || scanner.quickFacts(at: $0)?.displayName.lowercased() == needle
    }) {
        return match
    }
    fail("could not find a macOS GUI application matching \"\(raw)\"")
}

func findInstance(_ manager: InstanceManager, _ selector: String) -> (app: ManagedApp, instance: Instance) {
    if let uuid = UUID(uuidString: selector), let p = manager.registry.instance(uuid) { return p }
    let all = manager.registry.allInstances
    // "Claude#2" or just "2" when unambiguous.
    if let hash = selector.firstIndex(of: "#") {
        let appPart = String(selector[selector.startIndex..<hash]).lowercased()
        let numPart = Int(selector[selector.index(after: hash)...]) ?? -1
        if let m = all.first(where: {
            $0.app.displayName.lowercased().contains(appPart) && $0.instance.number == numPart
        }) { return m }
    }
    if let n = Int(selector) {
        let matches = all.filter { $0.instance.number == n }
        if matches.count == 1 { return matches[0] }
        if matches.count > 1 { fail("instance number \(n) is ambiguous — use \"AppName#\(n)\"") }
    }
    let byName = all.filter { $0.instance.name.lowercased() == selector.lowercased() }
    if byName.count == 1 { return byName[0] }
    fail("no instance matching \"\(selector)\"")
}

// MARK: - Usage

let usage = """
\(bold("launchagain")) — LaunchAgain command line

\(bold("USAGE"))
  launchagain <command> [options]

\(bold("COMMANDS"))
  scan                        List installed applications and their compatibility tier
  inspect <app>               Full compatibility report for one application
  create <app> --count N      Create N isolated instances
                              [--names "A,B,C"] [--lite]
                              [--acknowledge-shared-credentials]
                              [--allow-self-update]
  list                        Show all managed instances
  launch <selector>           Launch an instance
  quit <selector>             Ask an instance to quit
  rebuild <selector>          Rebuild an instance's bundle from the current source app
  rename <selector> <name>    Rename an instance (number is preserved)
  duplicate <selector>        Create a new instance with the same settings, empty profile
  delete <selector>           Remove one instance and its LaunchAgain-owned data
  renumber <app>              Explicitly renumber an app's instances to 1..n
  doctor                      Check for orphans, stale builds and source updates
                              [--clean] [--purge-profiles] [--retire-legacy-store]
                              [--clear-stale-markers]
  diagnostics [path]          Write a diagnostics report (contains no credentials)
  icon <path.icns>            Render the launcher's own application icon

\(bold("SELECTORS"))
  A UUID, an instance number ("2"), or "AppName#2".

\(bold("CREATE OPTIONS"))
  --lite         Skip cloning; run the original app with a separate profile
  --acknowledge-shared-credentials
                 Required for a Lite instance of an app whose signed-in session
                 lives outside the profile. Accepts that signing out of one
                 instance signs out every copy, including the original.
  --allow-self-update
                 Advanced. Leave the clone's own Squirrel/Sparkle updater
                 working. Off by default: an update replaces the instance's
                 identity, icon and signature, and rejoins it to the original's
                 Dock tile. Rebuild is the supported update path.

\(bold("GLOBAL OPTIONS"))
  --root <dir>   Use an isolated data store (for testing)
  --system-bundles-dir <dir>
                 Testing only, and only with --root: stand in for
                 /Applications/LaunchAgain, the second launcher directory used by
                 applications that refuse to run from anywhere but /Applications.
  --user-library <dir>
                 Testing only, and only with --root: which Library the associated-
                 file cleanup operates in. Its targets are exact paths derived from
                 the instance's own generated identifier.
  --verbose      Echo the log to stderr
  --json         Machine-readable output where supported
"""

guard let command = argv.first else { print(usage); exit(0) }
argv.removeFirst()

// MARK: - Commands

switch command {

case "help", "--help", "-h":
    print(usage)

case "scan":
    let showAll = takeFlag("--all", from: &argv)
    let m = makeManager(readOnly: true)
    let candidates = m.browseInstalledApps()
    // Quick facts are enough for a first pass: runtime and MAS receipt are
    // what decide "not supported". Signing is not inspected here, so these verdicts are
    // marked provisional rather than presented as final.
    let rows = candidates.map { (facts: $0, verdict: Compatibility.evaluate($0)) }
    let usable = rows.filter { $0.verdict.canCreate }

    print(bold("\(usable.count) of \(rows.count) candidates can be isolated\n"))
    for row in (showAll ? rows : usable).sorted(by: { $0.verdict.tier < $1.verdict.tier }) {
        let label = row.verdict.provisional ? dim("likely ") + tierBadge(row.verdict.tier)
                                            : tierBadge(row.verdict.tier)
        print("  \(label)  \(bold(row.facts.displayName))  \(dim(row.facts.version))  \(dim(row.facts.runtime.displayName))")
    }
    if !showAll {
        let refused = rows.count - usable.count
        print("\n" + dim("\(refused) other application\(refused == 1 ? "" : "s") cannot be isolated — run  launchagain scan --all  to see them, or  launchagain inspect \"<name>\"  for the reason."))
    }
    print(dim("A browse list reads Info.plist only; `launchagain inspect` runs codesign and gives the final verdict."))

case "inspect":
    // Read before the positional argument is taken, so `inspect <app> --lite` estimates
    // what a Lite instance would cost rather than what a Full one would.
    let inspectLite = takeFlag("--lite", from: &argv)
    guard let target = argv.first else { fail("usage: launchagain inspect <app> [--lite]") }
    let m = makeManager(readOnly: true)
    let url = resolveAppPath(target)
    do {
        let (facts, verdict) = try m.inspect(url)
        print("")
        print(bold(facts.displayName) + "  " + dim(facts.version))
        print(dim(facts.path))
        print("")
        print("  \(tierBadge(verdict.tier))  \(verdict.headline)")
        print("")
        print(bold("  Facts"))
        print("    bundle id      \(facts.bundleIdentifier)")
        print("    runtime        \(facts.runtime.displayName)")
        print("    architectures  \(facts.architectures.isEmpty ? "unknown" : facts.architectures.joined(separator: ", "))")
        print("    signed         \(facts.isSigned ? "yes" : "no")\(facts.teamIdentifier.map { " (team \($0))" } ?? "")")
        print("    hardened       \(facts.hasHardenedRuntime ? "yes" : "no")")
        print("    sandboxed      \(facts.isSandboxed ? "yes" : "no")")
        print("    updater        \(facts.updater.rawValue)")
        print("    size           \(FSOps.humanBytes(facts.bundleSizeBytes))")
        print("")
        print(bold("  Why"))
        for r in verdict.reasons { print("    · \(r)") }
        print("")
        print(bold("  What will not work"))
        for l in verdict.limitations { print("    · \(l)") }
        print("")
        if verdict.canCreate {
            // The same definition the create sheet and the create command use.
            // `estimatedFirstRunBytes` is the profile alone; a Full instance is also a
            // copy of the application, and printing the profile figure under the words
            // "per instance" understated ChatGPT by about a gigabyte.
            let mode: InstanceMode = inspectLite ? .lite : .full
            let perInstance = verdict.estimatedBytesPerInstance(
                mode: mode, sourceBundleBytes: facts.bundleSizeBytes)
            print(dim("  Estimated first-run disk use per \(mode == .lite ? "Lite " : "Full ")instance: \(FSOps.humanBytes(perInstance))"))
            print("")
        }
    } catch { fail("\(error)") }

case "create":
    guard let target = argv.first else { fail("usage: launchagain create <app> --count N [--names \"A,B\"]") }
    argv.removeFirst()
    let count = Int(takeOption("--count", from: &argv) ?? "1") ?? 1
    let namesRaw = takeOption("--names", from: &argv) ?? ""
    let names = namesRaw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    let liteMode = takeFlag("--lite", from: &argv)
    let acknowledgedSharedCredentials = takeFlag(
        "--acknowledge-shared-credentials", from: &argv)
    let allowEmbeddedUpdater = takeFlag("--allow-self-update", from: &argv)

    let m = makeManager()
    let url = resolveAppPath(target)
    do {
        let plan = try m.plan(sourceBundle: url, count: count, names: names)

        // Stated before the review block, not buried in the limitations list, because
        // for these apps it is the answer to "will this give me a second account".
        if plan.verdict.sharesCredentialStore {
            print("")
            print(red(bold("  This app does not keep its session in the profile.")))
            for store in plan.verdict.sharedCredentialStores {
                print("    · \(store.evidence) — \(store.consequence)")
            }
            if let variable = plan.verdict.sharedCredentialStores
                .compactMap(\.relocationVariable).first {
                print("    " + dim("Set \(variable) on the instance to give it a session of its own."))
            }
        }
        print("")
        print(bold("Review"))
        print("  application     \(plan.facts.displayName) \(plan.facts.version)")
        print("  source          \(plan.facts.path)")
        print("  instances       \(plan.numbers.map(String.init).joined(separator: ", "))")
        for (i, n) in plan.numbers.enumerated() {
            let nm = i < plan.names.count && !plan.names[i].isEmpty ? plan.names[i] : "(unnamed)"
            print("      #\(n)         \(nm)")
        }
        print("  isolation       \(liteMode ? "Lite (shared Dock icon)" : plan.verdict.recommendedMode.displayName)")
        print("  install to      \(plan.destinationDirectory)")
        print("  disk (est.)     \(FSOps.humanBytes(plan.totalEstimatedBytes)) after first run")
        print("")
        print(bold("  Limitations"))
        for l in plan.verdict.limitations { print("    · \(l)") }
        print("")

        // Refuse here as well as in the builder, so the user is told before ten seconds
        // of cloning rather than after, and told which flag says "yes, I understand".
        if liteMode, plan.verdict.sharesCredentialStore, !acknowledgedSharedCredentials {
            fail(Compatibility.sharedCredentialLiteRefusal(
                appName: plan.facts.displayName,
                stores: plan.verdict.sharedCredentialStores)
                 + "\n\nCreate it in Full mode instead, or pass --acknowledge-shared-credentials to accept that consequence.")
        }

        let outcome = m.create(
            plan: plan,
            requestedMode: liteMode ? .lite : .full,
            acknowledgedSharedCredentialStore: acknowledgedSharedCredentials,
            allowEmbeddedUpdater: allowEmbeddedUpdater
        ) { msg in
            print(dim("  " + msg))
        }
        print("")
        for i in outcome.created {
            let tag = i.mode == .lite ? yellow("[lite]") : green("[full]")
            print("  \(green("✓")) #\(i.number) \(i.name.isEmpty ? "(unnamed)" : i.name) \(tag)")
            print("    \(dim(i.bundlePath))")
        }
        for f in outcome.failures {
            print("  \(red("✗")) #\(f.number): \(f.error)")
        }
        if !outcome.degraded.isEmpty {
            warn("Instances \(outcome.degraded.map(String.init).joined(separator: ", ")) fell back to Lite mode. Their Chromium profiles remain separate, but they share the original app's Dock, Keychain, privacy-permission and URL-scheme identity.")
        }
        if plan.verdict.limitations.contains(where: { $0.contains("URL scheme") }) {
            print("")
            print(bold("  Sign in one at a time."))
            if !outcome.created.isEmpty
                && outcome.created.allSatisfy({ $0.mode == .lite }) {
                print("  Lite launchers cannot claim the source app's URL schemes. Prefer an in-app,")
                print("  device-code or password sign-in; a browser callback may open the original")
                print("  or default app instead of the intended profile.")
            } else {
                print("  A Full launcher can own a custom scheme one instance at a time. Launch one,")
                print("  claim its schemes if needed, sign in, quit it, then do the next. Lite")
                print("  launchers cannot claim schemes separately.")
            }
        }
        print("")

        // A `create` that printed nothing but ✗ used to exit 0, so a script could not
        // tell it apart from a success. Every other refusal path exits non-zero; this
        // one now does too.
        //
        // Two codes rather than one, because "none of them worked" and "some of them
        // worked" are different situations for a caller: 1 is total failure, 2 is
        // partial. Zero remains "everything asked for was created".
        if outcome.created.isEmpty && !outcome.failures.isEmpty {
            exit(1)
        }
        if !outcome.failures.isEmpty {
            exit(2)
        }
    } catch { fail("\(error)") }

case "list":
    let m = makeManager(readOnly: true)
    m.refreshSourceVersions()
    let all = m.registry.allInstances
    if all.isEmpty { print("No instances yet. Try:  launchagain create \"Claude\" --count 2"); break }

    if jsonOutput {
        let payload = all.map { pair -> [String: Any] in
            ["app": pair.app.displayName, "number": pair.instance.number,
             "name": pair.instance.name, "mode": pair.instance.mode.rawValue,
             "bundle": pair.instance.bundlePath, "data": pair.instance.dataPath,
             "running": m.supervisor.isRunning(pair.instance)]
        }
        let d = try! JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: d, as: UTF8.self))
        break
    }

    var lastApp = ""
    for (app, inst) in all {
        if app.displayName != lastApp {
            print("")
            print(bold(app.displayName) + "  " + dim(app.sourceVersion))
            lastApp = app.displayName
        }
        let running = m.supervisor.isRunning(inst)
        let dot = running ? green("●") : dim("○")
        let mode = inst.mode == .lite ? yellow("lite") : dim("full")
        let stale = !inst.builtFromSourceVersion.isEmpty
            && inst.builtFromSourceVersion != app.sourceVersion
            && inst.mode == .full
        // Through the shared cache, like the dashboard, Health and diagnostics. A direct
        // walk here re-measured every profile on every `list`, and a Claude profile is
        // gigabytes of small files.
        let size = FSOps.humanBytes(
            m.directorySizeCache.size(of: URL(fileURLWithPath: inst.dataPath)))
        var line = "  \(dot) #\(inst.number)  \(inst.name.isEmpty ? dim("(unnamed)") : inst.name)"
        if !inst.accountLabel.isEmpty { line += "  \(dim(inst.accountLabel))" }
        line += "  \(mode)  \(dim(size))"
        if stale { line += "  " + yellow("update available") }
        print(line)
    }
    print("")

case "launch":
    guard let sel = argv.first else { fail("usage: launchagain launch <selector>") }
    let m = makeManager()
    let (_, inst) = findInstance(m, sel)
    let sem = DispatchSemaphore(value: 0)
    // Top-level CLI code is main-actor isolated in Swift 6. A child `Task` inherits that
    // actor, so blocking this thread on the semaphore also prevented the task from ever
    // starting. Run the asynchronous Launch Services call on an independent executor.
    Task.detached {
        do {
            let pid = try await m.launch(inst)
            print("\(green("✓")) launched #\(inst.number) \(inst.name) (pid \(pid))")
        } catch {
            // This command is commonly scripted. A printed error paired with status 0
            // made a refused legacy Terminal launcher look like a successful GUI launch.
            fail("\(error)")
        }
        sem.signal()
    }
    sem.wait()

case "quit":
    guard let sel = argv.first else { fail("usage: launchagain quit <selector>") }
    let m = makeManager()
    let (_, inst) = findInstance(m, sel)
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        let ok = await m.quit(inst)
        print(ok ? "\(green("✓")) #\(inst.number) quit" : yellow("#\(inst.number) did not quit within 10s"))
        sem.signal()
    }
    sem.wait()

case "rebuild":
    guard let sel = argv.first else { fail("usage: launchagain rebuild <selector>") }
    let m = makeManager()
    let (_, inst) = findInstance(m, sel)
    do {
        let r = try m.rebuild(inst) { i, total, label in print(dim("  \(label) (\(i + 1)/\(total))")) }
        print("\(green("✓")) rebuilt #\(inst.number) as \(r.instance.mode.rawValue); data preserved at \(dim(inst.dataPath))")
    } catch { fail("\(error)") }

case "rename":
    guard argv.count >= 2 else { fail("usage: launchagain rename <selector> <new name>") }
    let m = makeManager()
    let (_, inst) = findInstance(m, argv[0])
    let newName = argv.dropFirst().joined(separator: " ")
    do {
        try m.rename(inst, to: newName, rebuildBundle: true)
        print("\(green("✓")) #\(inst.number) is now \"\(Validation.sanitizeInstanceName(newName))\" (number unchanged)")
    } catch { fail("\(error)") }

case "duplicate":
    guard let sel = argv.first else { fail("usage: launchagain duplicate <selector>") }
    let m = makeManager()
    let (_, inst) = findInstance(m, sel)
    do {
        let new = try m.duplicate(inst)
        print("\(green("✓")) created #\(new.number) with an empty profile")
    } catch { fail("\(error)") }

case "delete":
    guard let sel = argv.first else { fail("usage: launchagain delete <selector>") }
    argv.removeFirst()
    // Accepted for compatibility with older scripts; full cleanup is now always the
    // deletion contract and there is no command-line switch that leaves residual data.
    _ = takeFlag("--with-data", from: &argv)
    let m = makeManager()
    let (_, inst) = findInstance(m, sel)
    print(yellow("This completely uninstalls instance #\(inst.number), including every profile, log and lock file LaunchAgain owns for it."))
    print("The source application, other instances and external profile folders are not touched.")
    print("Type \"delete\" to confirm: ", terminator: "")
    guard (readLine() ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "delete"
    else { fail("cancelled") }
    do {
        let report = try m.remove(inst, scope: .launcherAndData)
        if let kept = report.keptDataPath {
            print("\(green("✓")) uninstalled #\(inst.number); external profile kept at \(kept)")
        } else {
            print("\(green("✓")) uninstalled #\(inst.number) and all LaunchAgain-owned data")
        }
        print(dim("Numbering is unchanged: remaining instances keep their numbers."))
    } catch { fail("\(error)") }

case "renumber":
    guard let target = argv.first else { fail("usage: launchagain renumber <app>") }
    let m = makeManager()
    guard let app = m.registry.allApps.first(where: {
        $0.displayName.lowercased().contains(target.lowercased()) || $0.appKey == target
    }) else { fail("no managed app matching \"\(target)\"") }
    do {
        let plan = try m.renumber(appKey: app.appKey) { print(dim("  " + $0)) }
        if plan.isEmpty { print("Numbers are already sequential; nothing to do.") }
        else {
            for (old, new) in plan.sorted(by: { $0.key < $1.key }) { print("  #\(old) → #\(new)") }
        }
    } catch { fail("\(error)") }

case "doctor":
    let doClean = takeFlag("--clean", from: &argv)
    let purgeProfiles = takeFlag("--purge-profiles", from: &argv)
    let purgeLegacy = takeFlag("--retire-legacy-store", from: &argv)
    let clearMarkers = takeFlag("--clear-stale-markers", from: &argv)
    FileHandle.standardError.write(Data("Checking LaunchAgain state…\n".utf8))
    // A `doctor` with no action flag is a report, and a report must not write to the
    // store — measuring profile sizes otherwise persisted icon-cache/directory-sizes.json
    // on every run, which is exactly the check Mi-11 asks a reviewer to make.
    let doctorIsReadOnly = !doClean && !purgeProfiles && !purgeLegacy && !clearMarkers
    let m = makeManager(readOnly: doctorIsReadOnly)
    let findings = m.sweep { path in
        FileHandle.standardError.write(Data("Measuring size: \(path)\n".utf8))
    }
    if findings.isEmpty { print("\(green("✓")) Everything is consistent."); break }
    print(bold("\(findings.count) finding(s)\n"))
    for f in findings {
        let mark = f.safeToClean ? yellow("cleanable") : red("needs attention")
        print("  [\(mark)] \(f.detail)")
        print("    \(dim(f.path))\(f.sizeBytes > 0 ? dim(" — \(FSOps.humanBytes(f.sizeBytes))") : "")")
    }
    // A destructive command must not report success for work that did not happen, and
    // must not exit 0 when it did nothing. Set by each removal block below; the command
    // exits on it at the end so that `--clean --purge-profiles` still runs both halves.
    var removalFailedEntirely = false
    var removalPartiallyFailed = false

    if doClean {
        let requested = findings.filter(\.safeToClean).count
        let (n, freed) = m.sweeper.clean(findings)
        print("")
        if requested == 0 {
            print("\(green("✓")) there was nothing cleanable to remove.")
        } else if n == 0 {
            print(red("✗") + " nothing was removed: all \(requested) cleanable item(s) failed.")
            removalFailedEntirely = true
        } else if n < requested {
            print(yellow("!") + " removed \(n) of \(requested) item(s), freed \(FSOps.humanBytes(freed)); \(requested - n) failed.")
            removalPartiallyFailed = true
        } else {
            print("\(green("✓")) removed \(n) item(s), freed \(FSOps.humanBytes(freed))")
        }
    }
    // Leftover profiles are never swept up automatically — each one may be a signed-in
    // session — but the user must be able to delete them without resorting to Finder.
    let orphanProfiles = findings.filter { $0.kind == .orphanDataDirectory }
    if purgeProfiles, !orphanProfiles.isEmpty {
        let total = orphanProfiles.reduce(Int64(0)) { $0 + $1.sizeBytes }
        print("")
        print(yellow("This moves \(orphanProfiles.count) leftover profile(s) to the Trash, \(FSOps.humanBytes(total)), including any signed-in session inside them. It is recoverable until you empty the Trash."))
        print("Type \"delete\" to confirm: ", terminator: "")
        guard (readLine() ?? "") == "delete" else { fail("cancelled") }
        var freed: Int64 = 0
        var removed = 0
        var failed = 0
        for f in orphanProfiles {
            do {
                freed += try m.sweeper.remove(f)
                removed += 1
            } catch {
                failed += 1
                print(red("  ✗ ") + "\(f.path): \(tidyReason(error))")
            }
        }
        // The previous summary was an unconditional green tick over a byte count of the
        // successes only, so a run in which *every* removal was refused still printed
        // "✓ freed Zero KB" directly beneath its own red refusals — and exited 0, which
        // is what a script reads.
        print("")
        if removed == 0 {
            print(red("✗") + " nothing was removed: all \(failed) profile(s) failed. Nothing was freed.")
            removalFailedEntirely = true
        } else if failed > 0 {
            print(yellow("!") + " removed \(removed) of \(orphanProfiles.count) profile(s), freed \(FSOps.humanBytes(freed)); \(failed) failed and are listed above.")
            removalPartiallyFailed = true
        } else {
            print("\(green("✓")) removed \(removed) profile(s), freed \(FSOps.humanBytes(freed))")
        }
    }

    // A removal marker an earlier version left behind, which nothing can finish or undo.
    // `Finding.isRemovable` has been true for these and `OrphanSweeper.remove` has
    // handled them since v1.1; the command line simply had no verb for it, so the only
    // route out was the interface.
    let staleMarkers = findings.filter { $0.kind == .staleRemovalMarker }
    if clearMarkers, !staleMarkers.isEmpty {
        print("")
        print(yellow("This moves \(staleMarkers.count) stale removal marker(s) to the Trash. Each one is a tombstone with no recorded deletion scope; while it exists, its instance can never be recovered from an installed launcher. No profile or launcher is touched."))
        for marker in staleMarkers { print("  \(dim(marker.path))") }
        print("Type \"clear\" to confirm: ", terminator: "")
        guard (readLine() ?? "") == "clear" else { fail("cancelled") }
        var cleared = 0
        for marker in staleMarkers {
            do { _ = try m.sweeper.remove(marker); cleared += 1 }
            catch { print(red("  ✗ ") + "\(marker.path): \(tidyReason(error))") }
        }
        print("")
        if cleared == 0 {
            print(red("✗") + " nothing was removed: all \(staleMarkers.count) marker(s) failed.")
            removalFailedEntirely = true
        } else if cleared < staleMarkers.count {
            print(yellow("!") + " cleared \(cleared) of \(staleMarkers.count) marker(s).")
            removalPartiallyFailed = true
        } else {
            print("\(green("✓")) cleared \(cleared) stale removal marker(s)")
        }
    }

    // The pre-rename store. Migration refuses to merge a profile that exists on both
    // sides, so a duplicate stays in the old directory and `doctor` reports it forever.
    // This is the only route out, and it is opt-in, exact-path and reversible.
    let residue = Migration.legacyResidue(paths: m.paths,
                                          legacy: .legacy(),
                                          sizeCache: m.directorySizeCache)
    if purgeLegacy && residue.isEmpty {
        print("\n\(green("✓")) There is no pre-rename store left to retire.")
    } else if purgeLegacy {
        print("")
        print(bold("Retire the pre-rename store"))
        for path in [residue.supportPath, residue.bundlesPath].compactMap({ $0 }) {
            print("  \(dim(path))")
        }
        if !residue.profileIdentifiers.isEmpty {
            print("  \(residue.profileIdentifiers.count) profile(s) inside, which may contain signed-in sessions:")
            for id in residue.profileIdentifiers { print("    \(dim(id))") }
        }
        print(yellow("This moves \(FSOps.humanBytes(residue.totalBytes)) to the Trash. It is recoverable until you empty the Trash."))
        print("Type \"retire\" to confirm: ", terminator: "")
        guard (readLine() ?? "") == "retire" else { fail("cancelled") }
        do {
            let moved = try Migration.trashLegacyStore(paths: m.paths, legacy: .legacy(), log: m.log)
            for path in moved { print("\(green("✓")) moved to the Trash: \(path)") }
        } catch { fail("\(error)") }
    } else {
        // Only suggest what has not just been done. Printing "run --purge-profiles" at
        // the end of a run of --purge-profiles reads as though it did not happen.
        if !doClean, findings.contains(where: { $0.safeToClean }) {
            print("\n" + dim("Run  launchagain doctor --clean  to remove the cleanable items."))
        }
        if !purgeProfiles, !orphanProfiles.isEmpty {
            print(dim("Run  launchagain doctor --purge-profiles  to delete leftover instance profiles."))
        }
        if !clearMarkers, !staleMarkers.isEmpty {
            print(dim("Run  launchagain doctor --clear-stale-markers  to clear removal markers nothing can act on."))
        }
        if !residue.isEmpty {
            print(dim("Run  launchagain doctor --retire-legacy-store  to move the pre-rename directory to the Trash."))
        }
    }

    if removalFailedEntirely || removalPartiallyFailed { exit(1) }

case "diagnostics":
    let m = makeManager()
    let dest = URL(fileURLWithPath: argv.first.map { ($0 as NSString).expandingTildeInPath }
                   ?? FileManager.default.currentDirectoryPath + "/launchagain-diagnostics.md")
    do {
        let u = try m.exportDiagnostics(to: dest)
        print("\(green("✓")) wrote \(u.path)")
        print(dim("Contains no credentials, cookies or instance data."))
    } catch { fail("\(error)") }

case "icon":
    // Used by Scripts/build-app.sh so the shipped .app has an icon that is generated
    // from source rather than checked in as a binary.
    guard let out = argv.first else { fail("usage: launchagain icon <path.icns>") }
    do {
        let url = try AppIconArt.writeICNS(to: URL(fileURLWithPath: (out as NSString).expandingTildeInPath))
        print("\(green("✓")) wrote \(url.path)")
    } catch { fail("\(error)") }

default:
    fail("unknown command \"\(command)\". Run  launchagain help")
}

#else
print("launchagain requires macOS.")
exit(1)
#endif
