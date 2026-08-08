import Foundation

public enum UpdaterFramework: String, Codable, Sendable {
    case none, sparkle, squirrel, unknown
}

public enum RuntimeKind: String, Codable, Sendable {
    case electron, chromium, webkitWrapper, native, webAppShortcut, unknown

    public var displayName: String {
        switch self {
        case .electron: return "Electron"
        case .chromium: return "Chromium"
        case .webkitWrapper: return "WebKit"
        case .native: return "Native"
        case .webAppShortcut: return "Browser web app"
        case .unknown: return "Unknown"
        }
    }
}

/// How an instance is kept separate from the others.
///
/// Only `userDataDir` can be produced. `configEnvironment` is a **legacy marker**: an
/// earlier release could build launchers that opened a Terminal session with a config
/// directory variable such as `CODEX_HOME`, and those instances still exist in some
/// registries. The product boundary is now GUI applications only, so nothing constructs
/// a `configEnvironment` instance any more — the case survives solely so an existing one
/// decodes, displays, refuses to launch, and uninstalls cleanly.
public enum IsolationMechanism: String, Codable, Sendable {
    /// Chromium's `--user-data-dir`: redirects auth, cookies, storage and the
    /// single-instance lock in one move.
    case userDataDir
    /// Legacy only. A configuration-directory environment variable, e.g. `CODEX_HOME`.
    /// See the note above: no code path creates one.
    case configEnvironment
    /// Nothing known.
    case none

    public var displayName: String {
        switch self {
        case .userDataDir: return "--user-data-dir"
        case .configEnvironment: return "config directory variable (legacy)"
        case .none: return "none"
        }
    }

    /// True for an instance built by a release that predates the GUI-only boundary.
    public var isLegacyTerminal: Bool { self == .configEnvironment }
}

/// Names an earlier release used for the command line tools it could build Terminal
/// launchers for. Nothing is created from this table; it exists so a legacy instance
/// recovered from disk can be *labelled* rather than shown as an unknown key.
///
/// The tool key is recoverable from a legacy launcher's generated bundle identifier,
/// which has the shape `com.multipleappslauncher.tool.<key>.mal.<n>.<short-uuid>`.
public enum LegacyTerminalTool {
    /// Display name for a legacy registry app key of the form `tool.<key>`.
    public static func displayName(forAppKey appKey: String) -> String? {
        guard appKey.hasPrefix("tool.") else { return nil }
        let key = String(appKey.dropFirst("tool.".count))
        switch key {
        case "codex": return "Codex"
        case "claude-code": return "Claude Code"
        default: return key.isEmpty ? nil : key
        }
    }

    /// The variable that relocated a legacy instance's session directory, for display on
    /// the instance detail screen. `nil` when the key is not one this project shipped.
    public static func environmentVariable(forAppKey appKey: String) -> String? {
        guard appKey.hasPrefix("tool.") else { return nil }
        switch String(appKey.dropFirst("tool.".count)) {
        case "codex": return "CODEX_HOME"
        case "claude-code": return "CLAUDE_CONFIG_DIR"
        default: return nil
        }
    }

    /// The `tool.<key>` registry key encoded in a legacy launcher's cloned bundle
    /// identifier, or `nil` when the identifier is not a legacy tool launcher's.
    public static func appKey(fromClonedBundleIdentifier identifier: String) -> String? {
        guard let range = identifier.range(of: ".tool.") else { return nil }
        let rest = identifier[range.upperBound...]
        guard let end = rest.range(of: ".mal") else { return nil }
        let key = String(rest[rest.startIndex..<end.lowerBound])
        return key.isEmpty ? nil : "tool.\(key)"
    }
}

/// Everything the scanner learns about a candidate application. Deliberately a plain
/// value type with no macOS types in it, so the tier rules below are pure and testable.
public struct AppFacts: Codable, Sendable, Equatable {
    public var bundleIdentifier: String
    public var displayName: String
    public var executableName: String
    public var shortVersion: String
    public var bundleVersion: String
    public var path: String

    public var runtime: RuntimeKind
    public var isSandboxed: Bool
    public var hasMASReceipt: Bool
    public var hasHardenedRuntime: Bool
    public var isSigned: Bool
    public var teamIdentifier: String?
    public var architectures: [String]
    public var entitlementKeys: [String]
    public var updater: UpdaterFramework
    public var declaresURLSchemes: Bool
    public var hasPrivilegedHelper: Bool
    public var hasLoginItem: Bool
    public var hasXPCServices: Bool
    /// Approximate size on disk of the source bundle, bytes.
    public var bundleSizeBytes: Int64
    /// True once `codesign` has actually been run against this bundle. A browse list is
    /// built from Info.plist alone, and "we have not looked yet" must never be reported
    /// to the user as "this app is unsigned".
    public var signingInspected: Bool

    public init(bundleIdentifier: String = "",
                displayName: String = "",
                executableName: String = "",
                shortVersion: String = "",
                bundleVersion: String = "",
                path: String = "",
                runtime: RuntimeKind = .unknown,
                isSandboxed: Bool = false,
                hasMASReceipt: Bool = false,
                hasHardenedRuntime: Bool = false,
                isSigned: Bool = false,
                teamIdentifier: String? = nil,
                architectures: [String] = [],
                entitlementKeys: [String] = [],
                updater: UpdaterFramework = .none,
                declaresURLSchemes: Bool = false,
                hasPrivilegedHelper: Bool = false,
                hasLoginItem: Bool = false,
                hasXPCServices: Bool = false,
                bundleSizeBytes: Int64 = 0,
                signingInspected: Bool = false) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.executableName = executableName
        self.shortVersion = shortVersion
        self.bundleVersion = bundleVersion
        self.path = path
        self.runtime = runtime
        self.isSandboxed = isSandboxed
        self.hasMASReceipt = hasMASReceipt
        self.hasHardenedRuntime = hasHardenedRuntime
        self.isSigned = isSigned
        self.teamIdentifier = teamIdentifier
        self.architectures = architectures
        self.entitlementKeys = entitlementKeys
        self.updater = updater
        self.declaresURLSchemes = declaresURLSchemes
        self.hasPrivilegedHelper = hasPrivilegedHelper
        self.hasLoginItem = hasLoginItem
        self.hasXPCServices = hasXPCServices
        self.bundleSizeBytes = bundleSizeBytes
        self.signingInspected = signingInspected
    }

    public var version: String { shortVersion.isEmpty ? bundleVersion : shortVersion }
}

/// A place an application keeps a signed-in session that `--user-data-dir` does not
/// redirect, and that therefore stays shared between the original app and every
/// instance made from it.
///
/// This exists because an instance came up already signed in and signing out of it
/// signed the user out of every copy, including the original. That is not isolation, and
/// the product has to say so before anything is built rather than after.
public struct SharedCredentialStore: Sendable, Equatable, Hashable {
    public enum Kind: String, Sendable, Codable {
        /// `keychain-access-groups`. Keychain items are bound to the signing identity,
        /// so a Full clone genuinely loses them — but a Lite launcher runs the
        /// vendor-signed original and shares them completely.
        case keychainAccessGroup
        /// `com.apple.security.application-groups`. The container is a plain directory
        /// under `~/Library/Group Containers`. macOS only gates it for *sandboxed*
        /// apps, so an unsandboxed clone can still read and write it by path with no
        /// entitlement at all.
        case appGroupContainer
        /// A configuration directory in the user's home that the app reads by absolute
        /// path, independent of bundle identity, signature and `--user-data-dir`.
        case configHomeDirectory
    }

    public var kind: Kind
    /// What the user should look for — an entitlement name, or a path.
    public var evidence: String
    /// One sentence naming the consequence, in the user's terms.
    public var consequence: String
    /// Set for `configHomeDirectory`: the environment variable that relocates it, when
    /// the application documents one. This is not applied automatically; it is what the
    /// interface can tell the user to set.
    public var relocationVariable: String?
    /// Whether this store is shared by a **Full** clone as well as by a Lite launcher.
    ///
    /// This is the difference between "instances of this app are not separate accounts"
    /// and "*Lite* instances of this app are not separate accounts", and getting it wrong
    /// in either direction is a real cost. Saying it of every signal made the
    /// compatibility card contradict its own headline for Claude — "Full profile
    /// isolation — separate accounts" four lines above "Instances of this app are not
    /// separate accounts" — while the user's Claude instances work correctly.
    ///
    /// · A **Keychain group** is not shared by a Full clone. The clone is ad-hoc signed
    ///   with the entitlement stripped, so macOS will not hand it the vendor's items;
    ///   that is LIMITATIONS §1 and it is the security model working. Lite runs the
    ///   vendor-signed binary and shares them outright.
    ///
    /// · An **App Group container** is likewise not vended to a clone whose entitlement
    ///   was stripped, and it was measured *not* to be the mechanism for the one
    ///   application where a Full clone did inherit a session. It is not marked as
    ///   affecting Full mode — but its consequence text still says an app that reaches
    ///   the directory by absolute path rather than through the entitlement would share
    ///   it, because that remains possible and is not something this project has ruled
    ///   out for every app.
    ///
    /// · A **configuration home** is shared by everything. It is a plain file in the home
    ///   directory read by absolute path; no signature, identifier or entitlement is
    ///   involved. This is the one that was measured, and the only one that earns the
    ///   unqualified sentence.
    public var affectsFullMode: Bool

    public init(kind: Kind,
                evidence: String,
                consequence: String,
                relocationVariable: String? = nil,
                affectsFullMode: Bool) {
        self.kind = kind
        self.evidence = evidence
        self.consequence = consequence
        self.relocationVariable = relocationVariable
        self.affectsFullMode = affectsFullMode
    }
}

public enum CompatibilityTier: String, Codable, Sendable {
    case supported, limited, notSupported

    public var displayName: String {
        switch self {
        case .supported: return "Supported"
        case .limited: return "Limited"
        case .notSupported: return "Not supported"
        }
    }
}

public struct CompatibilityVerdict: Sendable, Equatable {
    public var tier: CompatibilityTier
    public var headline: String
    /// Why the tier was assigned.
    public var reasons: [String]
    /// What the user should expect to *not* work. Always non-empty — there is no
    /// configuration in which we claim perfect isolation.
    public var limitations: [String]
    public var recommendedMode: InstanceMode
    /// Rough per-instance disk cost in bytes, for the review screen.
    public var estimatedFirstRunBytes: Int64
    /// How instances of this thing will be kept apart.
    public var mechanism: IsolationMechanism = .userDataDir
    /// True when the tier was decided without a full code-signing inspection, i.e. from
    /// a browse list. The UI marks these as provisional rather than presenting a guess
    /// as a verdict.
    public var provisional: Bool = false
    /// Places this app keeps a session that redirecting the profile does not move.
    /// Empty for the ordinary case.
    public var sharedCredentialStores: [SharedCredentialStore] = []
    /// Non-nil when this application will not run from the user's own Applications
    /// folder, with the reason. Instances of it install into `/Applications/LaunchAgain`.
    public var systemApplicationsRequirement: String?

    public var canCreate: Bool { tier != .notSupported }

    /// True when at least one signed-in session lives outside the redirected profile.
    public var sharesCredentialStore: Bool { !sharedCredentialStores.isEmpty }

    /// What one instance is expected to cost on disk after its first run.
    ///
    /// `estimatedFirstRunBytes` is the **profile** only. A Full instance is also a copy of
    /// the source application, and that term was simply absent: for ChatGPT the review
    /// sheet said "Estimated 367 MB" for a clone whose bundle is 1.38 GB, and at the
    /// maximum of 64 it claimed 23 GB against 97 GB free and showed no warning when the
    /// real cost was far more. The free-space warning could not fire.
    ///
    /// The bundle term is the source's full size rather than its measured allocation.
    /// APFS cloning does share unchanged blocks — one Codex clone was measured consuming
    /// 854 MB of a 1.38 GB bundle before first run — but sharing decays as the clone is
    /// re-signed and as either copy is updated, and on a volume without cloning support
    /// the build falls back to a real copy and costs all of it. For a "will this fit"
    /// warning the conservative number is the useful one; the interface says so rather
    /// than presenting it as exact.
    ///
    /// Lite excludes it entirely: a Lite launcher copies nothing.
    public func estimatedBytesPerInstance(mode: InstanceMode,
                                          sourceBundleBytes: Int64) -> Int64 {
        mode == .lite ? estimatedFirstRunBytes
                      : estimatedFirstRunBytes + max(0, sourceBundleBytes)
    }

    /// Whether building this application in `mode` needs an explicit acknowledgement of
    /// the shared-session consequence first.
    ///
    /// **The single definition of the rule.** The create flow, the instance detail
    /// screen, the command line and the builder all ask this rather than each testing
    /// `mode == .lite && sharesCredentialStore` for themselves — the version of this
    /// release that shipped four copies of that expression also shipped a fifth code
    /// path that inferred the answer from the mode being requested, which is how
    /// Advanced ▸ Force Lite came to bypass the gate entirely.
    public func requiresSharedCredentialAcknowledgement(mode: InstanceMode) -> Bool {
        mode == .lite && sharesCredentialStore
    }

    /// The mode a build will **actually** produce for a requested one.
    ///
    /// Full is honoured only when this verdict also recommends it: an app that is
    /// unsigned, or installs a privileged helper, or is otherwise degraded to `.lite`
    /// here, gets a Lite instance no matter what the caller asked for. Anything deciding
    /// what a build will do — the builder, and any screen predicting it — must ask this
    /// rather than reading `requestedMode` or a stored `mode`, because those are requests
    /// and this is the answer.
    ///
    /// It exists because the interface and the builder each computed it, differently. The
    /// detail view read the stored mode, so for a shared-credential app whose source had
    /// since gained a privileged helper it predicted Full, showed no acknowledgement
    /// checkbox, left Apply enabled — and the build then refused, because the builder had
    /// resolved the same request to Lite.
    public func effectiveMode(requesting requested: InstanceMode) -> InstanceMode {
        (requested == .full && recommendedMode == .full) ? .full : .lite
    }

    /// What to call the tier in a list. A browse list is built from Info.plist alone, so
    /// its verdicts are honest guesses and are labelled as such rather than presented
    /// with the confidence of a full inspection.
    public var tierLabel: String {
        provisional ? "likely \(tier.displayName.lowercased())" : tier.displayName
    }
}

/// The tier rules. One pure function, so the honesty of the product is testable.
public enum Compatibility {

    /// Electron's first run writes a full Chromium profile; Claude Desktop additionally
    /// bootstraps a local VM image. This is an estimate shown to the user, not a promise.
    public static let baselineProfileBytes: Int64 = 350 * 1024 * 1024
    public static let heavyProfileBytes: Int64 = 2 * 1024 * 1024 * 1024

    /// Applications known — by measurement, not by guess — to keep their session in a
    /// configuration directory under the user's home, which no amount of profile
    /// redirection moves.
    ///
    /// This table is deliberately tiny and evidence-backed rather than a heuristic. The
    /// one entry is ChatGPT/Codex, where the desktop app's `getAuthStatus` is answered by
    /// the bundled `codex` app-server reading `$CODEX_HOME/auth.json`. Measured on this
    /// machine: a Full clone with every team-bound entitlement stripped started signed
    /// in and loaded the user's own threads, and the *same* clone started signed out
    /// (`hadToken=false`, `no_token_attached`) when `CODEX_HOME` pointed at an empty
    /// directory. See docs/VALIDATION.md.
    static let knownConfigHomes: [String: (variable: String, path: String)] = [
        "com.openai.codex": (variable: "CODEX_HOME", path: "~/.codex"),
    ]

    /// Applications measured to refuse to run from outside `/Applications`.
    ///
    /// One entry, and measured rather than guessed. LM Studio's bundled code compares
    /// its install location against the literal prefix `/Applications/`; run from
    /// anywhere else it logs "App is not running from /Applications. It is running from
    /// …" and opens no window at all. Run from `/Applications/LaunchAgain/…` it starts
    /// normally, which is why a single owned subdirectory is enough and launchers do not
    /// have to be scattered across `/Applications`. See docs/VALIDATION.md.
    ///
    /// There is no reliable static signal for this — the check is inside the
    /// application's own JavaScript — so this is a table rather than a heuristic, and an
    /// app that is not in it can still be installed there by choice.
    static let knownSystemApplicationsRequirements: [String: String] = [
        "ai.elementlabs.lmstudio":
            "LM Studio checks that it is running from /Applications and opens no window at all when it is not.",
    ]

    /// Why this application has to be installed in `/Applications`, or nil.
    public static func systemApplicationsRequirement(_ f: AppFacts) -> String? {
        knownSystemApplicationsRequirements[f.bundleIdentifier.lowercased()]
    }

    /// Where this application keeps a session that `--user-data-dir` does not redirect.
    ///
    /// Two of the three signals are entitlements, and they are signals rather than
    /// proof: an app that declares shared Keychain groups or an App Group container is
    /// an app whose credentials are designed to be shared between the vendor's own
    /// binaries, which is precisely the class that a profile redirect cannot separate.
    /// The third is a measured mechanism and is named as such.
    public static func sharedCredentialStores(_ f: AppFacts) -> [SharedCredentialStore] {
        var found: [SharedCredentialStore] = []

        if f.entitlementKeys.contains("keychain-access-groups") {
            found.append(SharedCredentialStore(
                kind: .keychainAccessGroup,
                evidence: "keychain-access-groups",
                consequence: "Credentials this app saves in the Keychain belong to the vendor's signing identity, not to the profile. A Lite instance runs that identity and shares them outright; a Full clone is signed ad-hoc with this entitlement removed and cannot read them at all.",
                affectsFullMode: false))
        }

        if f.entitlementKeys.contains("com.apple.security.application-groups") {
            found.append(SharedCredentialStore(
                kind: .appGroupContainer,
                evidence: "com.apple.security.application-groups (~/Library/Group Containers)",
                consequence: "A Lite instance shares the original's App Group containers outright. A Full clone has the entitlement removed, so macOS will not hand it one — but the container is an ordinary directory, and an app that reaches it by absolute path rather than through the entitlement would still share it.",
                affectsFullMode: false))
        }

        if let known = knownConfigHomes[f.bundleIdentifier.lowercased()] {
            found.append(SharedCredentialStore(
                kind: .configHomeDirectory,
                evidence: known.path,
                consequence: "This app reads its signed-in session from \(known.path) by absolute path. No signature, identifier or entitlement is involved, so every instance — Full or Lite — and the original share one session. Signing out of any of them signs out all of them.",
                relocationVariable: known.variable,
                affectsFullMode: true))
        }

        return found
    }

    /// What the interface must show before anything is built. One headline plus one line
    /// per store, rather than a single paragraph: this is the item a user has to be able
    /// to read and act on, and it is the reason they may decide not to create anything.
    public static func sharedCredentialDisclosure(
        _ stores: [SharedCredentialStore]
    ) -> [String] {
        guard !stores.isEmpty else { return [] }
        // Qualified by which modes the detected signals actually bite in. The
        // unconditional sentence is only true when something is shared by a Full clone
        // too; saying it of a Keychain-only app contradicted this card's own headline and
        // was wrong about apps whose instances work.
        var lines = [sharedCredentialLead(stores)]
        lines.append(contentsOf: stores.map { "\($0.evidence) — \($0.consequence)" })
        if let variable = stores.compactMap(\.relocationVariable).first {
            // Names where the route actually is. This line is printed by the command
            // line too, which has no way to set an environment variable on an instance —
            // so "under Advanced" alone sent a CLI user looking for a flag that does not
            // exist. Setting it is a decision about the user's data, so it stays manual.
            lines.append("There is a route out for this one: set \(variable) to this "
                         + "instance's own directory in the LaunchAgain app, under "
                         + "Instance → Advanced → environment variables, and the instance "
                         + "gets a session of its own. There is no command-line flag for "
                         + "it. LaunchAgain does not set it for you, because moving where "
                         + "an application keeps its configuration is a decision about "
                         + "your data rather than a default.")
        }
        return lines
    }

    /// The leading sentence, scoped to the modes the detected signals affect.
    public static func sharedCredentialLead(_ stores: [SharedCredentialStore]) -> String {
        if stores.contains(where: \.affectsFullMode) {
            return "Instances of this app are not separate accounts. It keeps its "
                + "signed-in session outside the profile LaunchAgain redirects, so "
                + "signing out of one instance may sign you out of all of them, "
                + "including the original application."
        }
        return "A Lite instance of this app will not be a separate account: it runs the "
            + "vendor-signed original, so it shares the credentials below with every other "
            + "copy. A Full clone has a new ad-hoc identity and does not."
    }

    /// The sentence a Lite instance of such an app must be acknowledged against.
    public static func sharedCredentialLiteRefusal(
        appName: String,
        stores: [SharedCredentialStore]
    ) -> String {
        "Lite mode cannot isolate \(appName). A Lite launcher runs the vendor-signed "
            + "original application, so it has the original's Keychain identity, the "
            + "original's App Group containers and the original's home-directory "
            + "configuration — every place this app's session actually lives. The likely "
            + "result is an instance that is already signed in, and signing out of it "
            + "signs out every copy including the original. Detected: "
            + stores.map(\.evidence).joined(separator: ", ") + "."
    }

    public static func evaluate(_ f: AppFacts) -> CompatibilityVerdict {
        var reasons: [String] = []
        var limits = universalLimitations(f)

        // --- Hard exclusions -------------------------------------------------

        if f.hasMASReceipt || f.isSandboxed {
            return CompatibilityVerdict(
                tier: .notSupported,
                headline: "Mac App Store and sandboxed apps can't be isolated safely yet.",
                reasons: [f.hasMASReceipt
                          ? "This app carries a Mac App Store receipt."
                          : "This app is sandboxed (com.apple.security.app-sandbox)."],
                limitations: ["A sandboxed app's container is keyed to its signed identity. Re-creating that identity requires the original developer's Team ID, which we neither have nor should forge."],
                recommendedMode: .lite,
                estimatedFirstRunBytes: 0)
        }

        // A browser "web app" is not an application at all: it is a shortcut whose
        // executable asks an already-installed browser to open one site in app mode. The
        // user's session belongs to the browser, so the useful answer is to point them at
        // the thing that *can* be isolated rather than at a dead end.
        if f.runtime == .webAppShortcut {
            return CompatibilityVerdict(
                tier: .notSupported,
                headline: "This is a browser web app, not an application of its own.",
                reasons: [
                    "Its executable is a shortcut that asks an installed browser to open one site in app mode. The account, the cookies and the session all belong to the browser.",
                ],
                limitations: [
                    "Create instances of the browser instead — Chrome, Brave and Edge are all supported. Each browser instance has its own profile, and this web app appears inside whichever instance you install it in.",
                ],
                recommendedMode: .lite,
                estimatedFirstRunBytes: 0)
        }

        guard f.runtime == .electron || f.runtime == .chromium else {
            var why = "Detected runtime: \(f.runtime.displayName)."
            var how = "A native macOS app keeps its state under a path derived from its bundle identifier, and nothing supported redirects that from outside the app. Cloning the bundle would give a new identifier and therefore an empty state — but the app would also lose its Keychain access and any entitlement bound to the developer's Team ID, so it would be a broken copy, not a second account."
            if f.updater == .sparkle || f.updater == .squirrel {
                why += " It ships its own updater, which would also overwrite any clone."
            }
            if f.runtime == .unknown {
                how = "The bundle has no recognisable runtime — no Chromium framework, no asar archive, no executable directory. There is nothing here to point at a separate profile."
            }
            return CompatibilityVerdict(
                tier: .notSupported,
                headline: "No known way to give this app a separate profile.",
                reasons: [why,
                          "LaunchAgain supports Electron and Chromium GUI applications, which accept --user-data-dir."],
                limitations: [how],
                recommendedMode: .lite,
                estimatedFirstRunBytes: 0)
        }

        if f.executableName.isEmpty {
            return CompatibilityVerdict(
                tier: .notSupported,
                headline: "This bundle has no executable we can launch.",
                reasons: ["CFBundleExecutable is missing or empty."],
                limitations: [],
                recommendedMode: .lite,
                estimatedFirstRunBytes: 0)
        }

        // --- Degradations ----------------------------------------------------

        reasons.append("\(f.runtime.displayName) app — accepts --user-data-dir, which redirects auth, cookies, local storage and the single-instance lock.")

        var tier: CompatibilityTier = .supported
        var mode: InstanceMode = .full

        let blockingEntitlements = f.entitlementKeys.filter {
            EntitlementsPatch.teamBoundKeys.keys.contains($0)
        }

        // "We have not run codesign yet" is not the same fact as "this app is unsigned",
        // and conflating the two made every app in a browse list look degraded.
        if f.signingInspected && !f.isSigned {
            tier = .limited
            mode = .lite
            reasons.append("The app is unsigned, so a clone can't be verified after re-signing.")
        }

        if f.hasPrivilegedHelper {
            tier = .limited
            mode = .lite
            reasons.append("The app installs a privileged helper tool, which is registered against the original signature and will not follow a clone.")
            limits.append("Any feature that relies on this app's privileged helper may not work in a cloned instance.")
        }

        if !blockingEntitlements.isEmpty {
            // Not automatically fatal — these get stripped — but worth flagging when
            // they are ones a user will notice.
            if blockingEntitlements.contains("com.apple.security.application-groups")
                || blockingEntitlements.contains("com.apple.developer.icloud-container-identifiers") {
                tier = max(tier, .limited)
                reasons.append("Uses entitlements bound to the developer's Team ID; these are removed when re-signing.")
            }
            limits.append("These entitlements are dropped from the clone: " + blockingEntitlements.sorted().joined(separator: ", ") + ".")
        }

        if f.hasXPCServices {
            limits.append("Bundled XPC services are re-signed too. If the app verifies their signature only at runtime it may refuse to start; LaunchAgain reports that launch failure because the build cannot safely probe a live signed-in application.")
        }

        switch f.updater {
        case .squirrel:
            limits.append("This app updates itself with Squirrel. An update will replace the clone's contents and remove its numbered icon and identity — use Rebuild afterwards. The original app is never touched.")
        case .sparkle:
            limits.append("This app updates itself with Sparkle. The feed is preserved; if an update replaces the generated identity, rebuild the instance from the source app.")
        case .unknown, .none:
            break
        }

        if f.hasLoginItem {
            limits.append("The app registers a login item under its own identity; a clone's login item will be separate and may need re-approving.")
        }

        // Computed before the headline, because it can change the headline. The version
        // that computed the headline first and only prepended limitations afterwards
        // produced "Full profile isolation — separate accounts" four lines above
        // "Instances of this app are not separate accounts", on one screen.
        let shared = sharedCredentialStores(f)
        let sharedInFullMode = shared.contains(where: \.affectsFullMode)
        if sharedInFullMode {
            // A Full clone of this application genuinely does not get its own account,
            // so it is not fully supported however well the rest of it clones.
            tier = max(tier, .limited)
        }

        let headline: String
        if mode == .lite {
            headline = "Lite profile isolation — separate Chromium data, with the original app's Dock, Keychain, privacy and URL-scheme identity."
            limits.append("Lite mode isolates profile-resident data routed through --user-data-dir. Because it launches the vendor-signed original app, Keychain items, macOS privacy permissions and URL-scheme ownership are shared with that original identity.")
        } else if sharedInFullMode {
            headline = "Separate profile and numbered Dock icon — but not a separate account: this app keeps its signed-in session outside the profile."
        } else {
            switch tier {
            case .supported:
                headline = "Full profile isolation — separate accounts and a separate numbered Dock icon per instance."
            case .limited:
                headline = "Full launcher with a separate profile and numbered Dock icon; the listed developer-team capabilities are removed."
            case .notSupported:
                headline = "Can't isolate this app safely yet."
            }
        }

        // Said before anything is created, and said first, because it is the one thing
        // that can make an instance useless in the way the user actually cares about:
        // it is not a second account. Everything else on this list is cosmetic beside it.
        let disclosure = sharedCredentialDisclosure(shared)
        if !disclosure.isEmpty {
            limits.insert(contentsOf: disclosure, at: 0)
            reasons.append(sharedInFullMode
                ? "Keeps a signed-in session outside the redirected profile, so a separate profile does not give this app a separate account."
                : "Declares shared credential capabilities, which a Lite instance would inherit from the original application.")
        }

        let systemRequirement = systemApplicationsRequirement(f)
        if let systemRequirement {
            limits.append("\(systemRequirement) Instances are therefore installed in /Applications/LaunchAgain rather than your own Applications folder. That directory usually needs an administrator the first time; LaunchAgain will say so rather than asking for elevated rights.")
        }

        let heavy = f.bundleIdentifier.lowercased().contains("claude")
            || f.bundleIdentifier.lowercased().contains("docker")
        return CompatibilityVerdict(
            tier: tier,
            headline: headline,
            reasons: reasons,
            limitations: limits,
            recommendedMode: mode,
            estimatedFirstRunBytes: heavy ? heavyProfileBytes : baselineProfileBytes,
            mechanism: .userDataDir,
            provisional: !f.signingInspected,
            sharedCredentialStores: shared,
            systemApplicationsRequirement: systemRequirement)
    }

    /// Stated for every app, in every tier, before creation. These are the things the
    /// original brief asked us to be honest about rather than paper over.
    private static func universalLimitations(_ f: AppFacts) -> [String] {
        var l: [String] = [
            "Keychain behavior depends on mode. A Full clone has a new ad-hoc identity and cannot read credentials saved by the original app. Lite mode runs the vendor-signed original and shares its Keychain identity. LaunchAgain never reads or copies either.",
            "Your provider's own rules still apply. If a service limits concurrent sessions per account, that limit is unchanged. This tool separates local profiles for accounts you already have; it does not bypass licensing, subscription or authentication controls.",
            "Privacy permissions depend on mode. A Full clone has a new bundle identity and starts with new macOS privacy records; Lite mode shares the original app's privacy identity.",
        ]
        if f.declaresURLSchemes {
            l.append("This app registers custom URL schemes. A Full launcher can own a scheme one instance at a time. A Lite launcher declares no source-app schemes, so a browser callback may return to the original/default app rather than the intended profile; use an in-app, device-code or password sign-in when available.")
        }
        return l
    }
}

extension CompatibilityTier: Comparable {
    private var severity: Int {
        switch self {
        case .supported: return 0
        case .limited: return 1
        case .notSupported: return 2
        }
    }
    public static func < (a: CompatibilityTier, b: CompatibilityTier) -> Bool {
        a.severity < b.severity
    }
}
