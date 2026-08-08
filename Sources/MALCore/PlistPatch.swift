import Foundation

/// Pure transformations of a bundle's `Info.plist` and entitlements.
///
/// Kept free of any filesystem or macOS dependency so the exact key rewrites — the
/// thing that determines whether the Dock shows one tile or three — are unit-testable
/// on any machine.
public enum PlistPatch {

    public struct InfoPlistPatchOptions: Sendable {
        public var newBundleIdentifier: String
        public var newBundleName: String
        public var newDisplayName: String
        /// Filename without the `.icns` extension, matching `CFBundleIconFile` convention.
        public var iconFileBaseName: String
        /// The shim's filename, which becomes `CFBundleExecutable`.
        public var shimExecutableName: String
        /// Remove `CFBundleURLTypes`. Prevents this instance from competing for
        /// `claude://`-style deep links. Off by default because it also breaks SSO
        /// sign-in for that instance.
        public var stripURLSchemes: Bool
        /// Remove Sparkle's feed URL so the clone cannot silently self-update and
        /// overwrite the identity we just wrote. Requires explicit user consent.
        public var stripSparkleFeed: Bool
        /// Leave `CFBundleName` at its original value.
        ///
        /// Electron and Chromium build the path to their own helper processes out of
        /// `CFBundleName`: the renderer lives at
        /// `Contents/Frameworks/<CFBundleName> Helper (Renderer).app`. Rewriting the key
        /// makes the app look for "Claude 2 – Work Helper.app", not find it, and abort at
        /// startup with `FATAL: Unable to find helper app`.
        ///
        /// `CFBundleDisplayName` is what Finder, the Dock and Spotlight actually show, so
        /// the instance still reads as "Claude 2 – Work" everywhere a user looks.
        public var preserveBundleName: Bool

        public init(newBundleIdentifier: String,
                    newBundleName: String,
                    newDisplayName: String,
                    iconFileBaseName: String,
                    shimExecutableName: String,
                    stripURLSchemes: Bool = false,
                    stripSparkleFeed: Bool = false,
                    preserveBundleName: Bool = false) {
            self.newBundleIdentifier = newBundleIdentifier
            self.newBundleName = newBundleName
            self.newDisplayName = newDisplayName
            self.iconFileBaseName = iconFileBaseName
            self.shimExecutableName = shimExecutableName
            self.stripURLSchemes = stripURLSchemes
            self.stripSparkleFeed = stripSparkleFeed
            self.preserveBundleName = preserveBundleName
        }
    }

    // Not Sendable: a property-list dictionary is `[String: Any]`, which cannot be
    // proven Sendable. It never crosses an isolation boundary — the builder consumes
    // it synchronously on the same actor that produced it.
    public struct InfoPlistPatchResult {
        public var plist: [String: Any]
        /// The original `CFBundleExecutable`, which the caller must rename on disk
        /// to `<name>.real` and record in the shim config.
        public var originalExecutableName: String
        public var notes: [String]
    }

    /// Keys we deliberately remove or rewrite, with the reason, so the UI and the
    /// docs can explain exactly what was changed relative to the original app.
    public static func patchInfoPlist(_ original: [String: Any],
                                      options: InfoPlistPatchOptions) throws -> InfoPlistPatchResult {
        guard Validation.isValidBundleIdentifier(options.newBundleIdentifier) else {
            throw MALError.invalidName(options.newBundleIdentifier, reason: "not a valid bundle identifier")
        }
        guard let originalExec = original["CFBundleExecutable"] as? String, !originalExec.isEmpty else {
            throw MALError.notSupported(reason: "The application has no CFBundleExecutable and cannot be cloned.")
        }

        var p = original
        var notes: [String] = []

        // CFBundleIdentifier is the key that actually creates a distinct Launch Services
        // identity — a separate Dock tile, a separate Cmd-Tab entry, separate privacy
        // permissions. The two name keys are cosmetic by comparison, and one of them is
        // load-bearing for Chromium's helper lookup (see `preserveBundleName`).
        p["CFBundleIdentifier"]  = options.newBundleIdentifier
        p["CFBundleDisplayName"] = options.newDisplayName
        if options.preserveBundleName {
            notes.append("Kept CFBundleName as “\(original["CFBundleName"] as? String ?? "")” because this app locates its own helper processes by that name. The instance still shows as “\(options.newDisplayName)” in Finder, the Dock and Spotlight.")
        } else {
            p["CFBundleName"] = options.newBundleName
        }

        // Icon. Set both spellings: CFBundleIconFile is the classic .icns reference,
        // CFBundleIconName points into an asset catalogue. If the source used an
        // asset catalogue we must remove that key or it wins over our .icns.
        p["CFBundleIconFile"] = options.iconFileBaseName
        if p["CFBundleIconName"] != nil {
            p.removeValue(forKey: "CFBundleIconName")
            notes.append("Removed CFBundleIconName (asset-catalogue icon) so the numbered .icns is used.")
        }

        // Point the bundle at our shim; the real binary is renamed alongside it.
        p["CFBundleExecutable"] = options.shimExecutableName

        // Some apps declare that macOS must not run two copies. Since each clone is a
        // distinct bundle identifier this is no longer meaningful, and leaving it set
        // can make Launch Services reactivate the wrong instance.
        if let prohibited = p["LSMultipleInstancesProhibited"] as? Bool, prohibited {
            p["LSMultipleInstancesProhibited"] = false
            notes.append("Cleared LSMultipleInstancesProhibited so instances can run simultaneously.")
        }

        if options.stripURLSchemes, p["CFBundleURLTypes"] != nil {
            p.removeValue(forKey: "CFBundleURLTypes")
            notes.append("Removed CFBundleURLTypes: this instance will not compete for custom URL schemes, but deep-link sign-in will not return to it.")
        }

        if options.stripSparkleFeed {
            for key in ["SUFeedURL", "SUEnableAutomaticChecks", "SUAutomaticallyUpdate"] where p[key] != nil {
                p.removeValue(forKey: key)
            }
            notes.append("Removed Sparkle auto-update keys at your request. Update this instance by rebuilding it from the source app.")
        }

        // A clone is not the original developer's product. Marking it makes the
        // difference legible to anyone inspecting the bundle, and is the honest thing
        // to do given we re-sign it ad-hoc.
        p["MALGeneratedBy"] = "LaunchAgain"
        p["MALOriginalBundleIdentifier"] = original["CFBundleIdentifier"] as? String ?? ""

        return InfoPlistPatchResult(plist: p, originalExecutableName: originalExec, notes: notes)
    }

    /// Info.plist for a Lite-mode launcher bundle, which is entirely our own code and
    /// contains none of the target app's binaries.
    public static func liteLauncherInfoPlist(bundleIdentifier: String,
                                             bundleName: String,
                                             displayName: String,
                                             iconFileBaseName: String,
                                             shimExecutableName: String) -> [String: Any] {
        [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleName": bundleName,
            "CFBundleDisplayName": displayName,
            "CFBundleExecutable": shimExecutableName,
            "CFBundleIconFile": iconFileBaseName,
            "CFBundlePackageType": "APPL",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "LSMinimumSystemVersion": "13.0",
            "LSUIElement": false,
            "NSHighResolutionCapable": true,
            "MALGeneratedBy": "LaunchAgain",
        ]
    }
}

/// Entitlement rewriting for ad-hoc re-signing.
public enum EntitlementsPatch {

    /// Entitlements that are bound to a real Apple Team ID or a provisioning profile.
    /// Keeping them under an ad-hoc signature makes the app fail to launch, so they
    /// are dropped and the consequences reported.
    public static let teamBoundKeys: [String: String] = [
        "com.apple.application-identifier":
            "App identifier (requires the original developer's Team ID).",
        "com.apple.developer.team-identifier":
            "Team identifier.",
        "keychain-access-groups":
            "Shared Keychain groups — this is why an instance cannot see credentials saved by the original app.",
        "com.apple.security.application-groups":
            "App groups (shared container between the vendor's own apps).",
        "com.apple.developer.associated-domains":
            "Associated domains (universal links).",
        "com.apple.developer.icloud-container-identifiers":
            "iCloud containers.",
        "com.apple.developer.icloud-services":
            "iCloud services.",
        "com.apple.developer.ubiquity-kvstore-identifier":
            "iCloud key–value store.",
        "com.apple.developer.aps-environment":
            "Apple Push Notification environment.",
    ]

    public static let libraryValidationKey = "com.apple.security.cs.disable-library-validation"

    public struct Result {
        public var entitlements: [String: Any]
        /// Human-readable list of what was dropped and why. Shown before the user commits.
        public var removed: [String]
        public var added: [String]
    }

    /// Produces the entitlements used to ad-hoc sign a clone.
    ///
    /// The critical addition is `com.apple.security.cs.disable-library-validation`.
    /// Ad-hoc signing plus Hardened Runtime turns on library validation, which then
    /// refuses to load the vendor-signed Electron frameworks inside the bundle because
    /// they carry a different Team ID from the (team-less) outer signature. Without
    /// this key the clone builds cleanly and then crashes instantly on launch.
    ///
    /// We add exactly this one key rather than disabling Hardened Runtime wholesale,
    /// which would also switch off JIT restrictions, DYLD environment protections and
    /// library injection defences.
    public static func patch(_ original: [String: Any]) -> Result {
        var e = original
        var removed: [String] = []
        var added: [String] = []

        for (key, why) in teamBoundKeys where e[key] != nil {
            e.removeValue(forKey: key)
            removed.append("\(key) — \(why)")
        }

        if (e[libraryValidationKey] as? Bool) != true {
            e[libraryValidationKey] = true
            added.append("\(libraryValidationKey) — required so the ad-hoc signature can load the app's own vendor-signed frameworks.")
        }

        return Result(entitlements: e, removed: removed.sorted(), added: added)
    }

    /// Frameworks and dylibs are signed without entitlements; only executables carry them.
    public static func entitlementsForNestedCode() -> [String: Any] { [:] }

    /// What a Chromium helper process needs when its original entitlements cannot be
    /// read. The renderer allocates executable memory for the JavaScript JIT, and the
    /// GPU helper loads libraries through dyld environment variables; a helper signed
    /// without these launches and then dies on first use, which looks like a crash in
    /// the app rather than a signing problem.
    // Computed rather than globally stored: `[String: Any]` is not Sendable, even when
    // the dictionary is immutable, and a stored value prevents Swift 6 strict-concurrency
    // builds. Callers receive their own small property-list dictionary.
    public static var helperFallback: [String: Any] {
        [
            libraryValidationKey: true,
            "com.apple.security.cs.allow-jit": true,
            "com.apple.security.cs.allow-unsigned-executable-memory": true,
            "com.apple.security.cs.allow-dyld-environment-variables": true,
        ]
    }
}
