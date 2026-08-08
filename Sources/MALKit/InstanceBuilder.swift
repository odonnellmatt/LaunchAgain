#if canImport(Darwin)
import Foundation
import AppKit
import MALCore

public struct BuildRequest {
    public var instanceID: UUID
    public var sourceBundle: URL
    public var facts: AppFacts
    public var number: Int
    public var name: String
    public var accountLabel: String
    public var badge: BadgeSpec
    public var requestedMode: InstanceMode
    public var extraArguments: [String]
    public var extraEnvironment: [String: String]
    public var stripURLSchemes: Bool
    public var stripSparkleFeed: Bool
    /// Advanced, and off by default: leave the clone's own embedded updater working.
    ///
    /// The default is that an instance never updates itself, because when a clone's
    /// Squirrel or Sparkle updater applies an update it replaces `Contents` and takes
    /// the rewritten identity, the numbered icon, the shim and the ad-hoc signature with
    /// it. Turning this on restores the vendor's update path and accepts that outcome;
    /// the profile is unaffected either way.
    public var allowEmbeddedUpdater: Bool
    /// The user has been shown, and accepted, that a Lite instance of this application
    /// shares the original's session. Defaults to false, and a Lite build of a
    /// shared-credential-store app is refused without it — including a Lite build
    /// arrived at by automatic degradation from Full.
    public var acknowledgedSharedCredentialStore: Bool
    /// An acknowledgement this instance already carries, from the record as it is
    /// stored, so that a rebuild preserves *when* the user accepted rather than
    /// re-dating it on every rebuild. `nil` on a first build; on a rebuild that is where
    /// the acknowledgement is newly given, the build stamps the current time instead.
    public var acknowledgedSharedCredentialStoreAt: Date?
    /// This build re-creates a launcher the store already holds as Lite, at the same
    /// mode it already has. It permits the build; it is **not** an acknowledgement and
    /// never becomes one.
    ///
    /// The gate exists to stop a *new* shared session being created without the user
    /// being told. Re-creating a launcher that is already Lite on disk creates none: the
    /// sharing is already there, and refusing here does not undo it — it only leaves the
    /// instance unrebuildable from the command line, which has no way to supply an
    /// acknowledgement for an instance that already exists. (Advanced ▸ Apply does; see
    /// `InstanceDetailView.sharedCredentialVerdict`.)
    ///
    /// The population is narrower than it first looks and is not zero. Every launcher
    /// this version builds carries a `LauncherRecoveryManifest` holding the whole
    /// `Instance`, acknowledgement included, and reconciliation prefers that manifest —
    /// so recovering a launcher **this** build produced preserves the stamp. What
    /// arrives un-acknowledged is a launcher with no manifest, or one whose manifest
    /// fails `LauncherIdentityVerifier.verify`: pre-manifest releases, and bundles whose
    /// identity no longer matches. Those fall back to the legacy path, which reconstructs
    /// the mode from the shim config and records no acknowledgement, because it has no
    /// evidence anyone was asked.
    ///
    /// Kept separate from `acknowledgedSharedCredentialStore` rather than folded into it,
    /// because that flag also *writes the stamp*. Folding these together would mint a
    /// consent date for a user who was never asked, and `duplicate` reads that stamp to
    /// authorise a new launcher — which is precisely the defect the stamp was introduced
    /// to close. This one is read at the gate and nowhere else.
    public var rebuildsExistingLiteLauncher: Bool
    /// Which launcher root this instance installs into. `nil` means "decide from the
    /// application": `/Applications/LaunchAgain` for an app that refuses to run
    /// anywhere else, and the user's own `~/Applications/LaunchAgain` otherwise.
    ///
    /// Only ever one of `MALPaths.bundleRoots`; the builder rejects anything else rather
    /// than installing where it could not later prove ownership.
    public var installRoot: URL?
    /// Advanced: put this instance's profile somewhere other than the launcher's own
    /// support directory. A directory we did not create is never deleted on rollback.
    public var dataPathOverride: String?
    /// When this instance was first created, carried across a rebuild.
    ///
    /// `nil` on a first build, where "now" is the answer. A rebuild must pass the stored
    /// value: the bundle is regenerated but the instance is not new, and the detail view
    /// shows this as "Created". Every rebuild used to move it to the moment of the
    /// rebuild, so the field answered "when did I last rebuild" under a label that asks
    /// something else.
    public var createdAt: Date?

    public init(instanceID: UUID = UUID(),
                sourceBundle: URL,
                facts: AppFacts,
                number: Int,
                name: String,
                accountLabel: String = "",
                badge: BadgeSpec? = nil,
                requestedMode: InstanceMode = .full,
                extraArguments: [String] = [],
                extraEnvironment: [String: String] = [:],
                stripURLSchemes: Bool = false,
                stripSparkleFeed: Bool = false,
                allowEmbeddedUpdater: Bool = false,
                acknowledgedSharedCredentialStore: Bool = false,
                acknowledgedSharedCredentialStoreAt: Date? = nil,
                rebuildsExistingLiteLauncher: Bool = false,
                installRoot: URL? = nil,
                dataPathOverride: String? = nil,
                createdAt: Date? = nil) {
        self.instanceID = instanceID
        self.sourceBundle = sourceBundle
        self.facts = facts
        self.number = number
        self.name = Validation.sanitizeInstanceName(name)
        self.accountLabel = Validation.sanitizeAccountLabel(accountLabel)
        self.badge = badge ?? BadgeSpec(colorHex: BadgeSpec.suggestedColor(forNumber: number))
        self.requestedMode = requestedMode
        self.extraArguments = extraArguments
        self.extraEnvironment = extraEnvironment
        self.stripURLSchemes = stripURLSchemes
        self.stripSparkleFeed = stripSparkleFeed
        self.allowEmbeddedUpdater = allowEmbeddedUpdater
        self.acknowledgedSharedCredentialStore = acknowledgedSharedCredentialStore
        self.acknowledgedSharedCredentialStoreAt = acknowledgedSharedCredentialStoreAt
        self.rebuildsExistingLiteLauncher = rebuildsExistingLiteLauncher
        self.installRoot = installRoot
        self.dataPathOverride = dataPathOverride
        self.createdAt = createdAt
    }
}

public struct BuildResult {
    public var instance: Instance
    public var degradedToLite: Bool
    public var degradationReason: String?
    public var notes: [String]
    public var signedItemCount: Int
    public var verifyOutput: String
}

/// Creates, rebuilds and removes instances.
///
/// Everything happens inside a `Transaction`, staged in a directory on the same volume
/// as the destination, and moved into place with a single `rename`. A failure at any
/// point leaves no bundle, no data directory and no registry entry — and if the failure
/// is one that Lite mode can survive, the whole thing is retried in Lite mode instead
/// of being reported to the user as a dead end.
public final class InstanceBuilder {

    public static let shimName = "mal-shim"

    private let paths: MALPaths
    private let log: MALLog
    private let signer: CodeSigner
    private let icons: IconFactory
    private let registrar: LaunchServicesRegistrar
    private let artifactCleaner: InstanceArtifactCleaner

    public init(paths: MALPaths, log: MALLog = .silent) {
        self.paths = paths
        self.log = log
        self.signer = CodeSigner(log: log)
        self.icons = IconFactory(cacheDir: paths.iconCacheDir, log: log)
        self.registrar = LaunchServicesRegistrar(log: log)
        self.artifactCleaner = InstanceArtifactCleaner(paths: paths, log: log)
    }

    // MARK: - Build

    public func build(_ request: BuildRequest,
                      progress: ((Int, Int, String) -> Void)? = nil) throws -> BuildResult {
        try paths.createAll()

        let verdict = Compatibility.evaluate(request.facts)
        guard verdict.canCreate else {
            throw MALError.notSupported(reason: verdict.headline + " " + (verdict.reasons.first ?? ""))
        }

        // The GUI-only boundary, restated at the builder rather than relied on upstream.
        // `inspect` already refuses anything that is not a `.app`, but the builder is
        // public and a caller could assemble an `AppFacts` by hand; there is no build
        // path for a command-line executable, so say so instead of failing obscurely
        // further in.
        guard request.sourceBundle.pathExtension.lowercased() == "app" else {
            throw MALError.notSupported(
                reason: "LaunchAgain creates GUI application instances only. Choose the installed macOS .app, not a command-line executable.")
        }

        let effectiveMode = verdict.effectiveMode(requesting: request.requestedMode)

        // Lite runs the vendor-signed original binary, which carries the original's
        // Keychain groups, App Group containers and home-directory configuration. For an
        // app whose session lives in any of those, a Lite instance is not a second
        // account at all — it is the same account with a different Chromium cache, and
        // signing out of it signs out every copy. Refuse rather than build it quietly.
        try assertLiteIsAcknowledgedIfNeeded(request, verdict: verdict, mode: effectiveMode)

        let fingerprintBefore = BundleAssembler.sourceFingerprint(bundle: request.sourceBundle)
        let ownedProfileExisted = FileManager.default.fileExists(
            atPath: paths.instanceDir(request.instanceID).path)

        do {
            let result = try attemptBuild(request, mode: effectiveMode, progress: progress)
            try validateSourceOrRollback(
                request.sourceBundle,
                expected: fingerprintBefore,
                result: result,
                removeOwnedProfile: !ownedProfileExisted && request.dataPathOverride == nil)
            return result
        } catch let error as MALError where effectiveMode == .full && error.isDegradable {
            // Degradation is the product's answer to a signing problem, but it must not
            // become a back door into the mode this app was just refused. If the user
            // has not accepted the shared-session consequence, a failed Full build is a
            // failed build, not a silent Lite one.
            try assertLiteIsAcknowledgedIfNeeded(request, verdict: verdict, mode: .lite)
            log.warn("full build failed (\(error)); retrying in Lite mode")
            let result = try attemptBuild(request, mode: .lite, progress: progress)
            try validateSourceOrRollback(
                request.sourceBundle,
                expected: fingerprintBefore,
                result: result,
                removeOwnedProfile: !ownedProfileExisted && request.dataPathOverride == nil)
            return BuildResult(instance: result.instance,
                               degradedToLite: true,
                               degradationReason: "\(error)",
                               notes: result.notes + [
                                "Fell back to Lite mode: \(error)",
                                "Profile-resident data stays separate. Lite mode shares the original app's Dock, Keychain, privacy-permission and URL-scheme identity.",
                               ],
                               signedItemCount: result.signedItemCount,
                               verifyOutput: result.verifyOutput)
        }
    }

    /// Refuses a Lite build of an application whose signed-in session lives somewhere
    /// `--user-data-dir` does not reach, unless the caller has passed an explicit
    /// acknowledgement that names the consequence.
    ///
    /// Full mode is *disclosed*, not refused: a Full clone has a new ad-hoc identity and
    /// genuinely loses the Keychain group, so the disclosure belongs on the compatibility
    /// card. Lite mode is refused, because there is nothing about it that separates
    /// anything a shared-credential-store app cares about.
    ///
    /// The question is whether this build *introduces* a shared session, not whether one
    /// exists: re-creating a launcher the store already holds as Lite is permitted
    /// without an acknowledgement, and still records none. See
    /// `BuildRequest.rebuildsExistingLiteLauncher`. Degradation cannot reach that
    /// allowance — a rebuild of a Lite instance never runs the Full path — so a Full
    /// build that fails is still refused rather than quietly degraded.
    private func assertLiteIsAcknowledgedIfNeeded(_ request: BuildRequest,
                                                  verdict: CompatibilityVerdict,
                                                  mode: InstanceMode) throws {
        guard verdict.requiresSharedCredentialAcknowledgement(mode: mode),
              !request.acknowledgedSharedCredentialStore,
              !request.rebuildsExistingLiteLauncher else { return }
        let name = request.facts.displayName.isEmpty
            ? request.facts.bundleIdentifier : request.facts.displayName
        let detail = Compatibility.sharedCredentialLiteRefusal(
            appName: name, stores: verdict.sharedCredentialStores)
        log.warn("refused a Lite build of \(name): shared credential store, not acknowledged")
        throw MALError.sharedCredentialStoreNotAcknowledged(appName: name, detail: detail)
    }

    /// The launcher root this build installs into, and the guarantee that it is one of
    /// the two LaunchAgain owns.
    ///
    /// An install root that is not in `paths.bundleRoots` is refused rather than
    /// honoured: a launcher LaunchAgain cannot later prove it owns is a launcher it
    /// cannot later remove, and the only thing worse than refusing to install is
    /// installing something the uninstaller will not touch.
    func destinationRoot(for request: BuildRequest) throws -> URL {
        let resolved: URL
        if let requested = request.installRoot {
            guard let match = paths.bundleRoots.first(where: {
                Validation.pathsReferToSameLocation($0.path, requested.path)
            }) else {
                throw MALError.invalidPath(
                    requested.path,
                    reason: "a launcher can only be installed in a LaunchAgain applications directory: "
                        + paths.bundleRoots.map(\.path).joined(separator: " or "))
            }
            resolved = match
        } else if Compatibility.systemApplicationsRequirement(request.facts) != nil {
            resolved = paths.systemBundlesDir
        } else {
            resolved = paths.bundlesDir
        }
        try paths.prepareBundleRoot(resolved)
        return resolved
    }

    private func attemptBuild(_ request: BuildRequest,
                              mode: InstanceMode,
                              progress: ((Int, Int, String) -> Void)?) throws -> BuildResult {
        switch mode {
        case .full: return try buildFull(request, progress: progress)
        case .lite: return try buildLite(request, progress: progress)
        }
    }

    // MARK: - Full mode

    private func buildFull(_ request: BuildRequest,
                           progress: ((Int, Int, String) -> Void)?) throws -> BuildResult {
        let id = request.instanceID
        let sourceName = request.facts.displayName
        let title = Instance(number: request.number, name: request.name,
                             bundlePath: "", dataPath: "").displayTitle(sourceName: sourceName)

        let dataDir = request.dataPathOverride.map { URL(fileURLWithPath: $0) }
            ?? paths.instanceDataDir(id)
        try Validation.validateAbsolutePath(dataDir.path, label: "data directory")
        let ownsDataDir = request.dataPathOverride == nil

        let installRoot = try destinationRoot(for: request)
        let taken = existingBundleNames()
        let bundleFilename = Validation.uniqueBundleFilename(preferred: title, taken: taken)
        // Staged inside the destination root: the move into place has to be a rename
        // within one filesystem, and /Applications and ~/Applications are not always on
        // the same volume as each other, let alone as /tmp.
        let stagedBundle = paths.stagingDir(in: installRoot)
            .appendingPathComponent("\(id.uuidString)-\(bundleFilename)")
        let finalBundle = installRoot.appendingPathComponent(bundleFilename)

        let newBundleID = Validation.cloneBundleIdentifier(original: request.facts.bundleIdentifier,
                                                           number: request.number,
                                                           instanceID: id)
        let iconBaseName = "MALAppIcon"
        let realExecName = request.facts.executableName + ".real"

        var notes: [String] = []
        var signedCount = 0
        var verifyOutput = ""
        var createdDataDir = false
        let createdAt = request.createdAt ?? Date()

        func recoveredInstance(notes: [String]) -> Instance {
            Instance(id: id,
                     number: request.number,
                     name: request.name,
                     accountLabel: request.accountLabel,
                     mode: .full,
                     bundlePath: finalBundle.path,
                     dataPath: dataDir.path,
                     badge: request.badge,
                     builtFromSourceVersion: request.facts.version,
                     clonedBundleIdentifier: newBundleID,
                     extraArguments: request.extraArguments,
                     extraEnvironment: request.extraEnvironment,
                     createdAt: createdAt,
                     buildNotes: notes)
        }

        let shimBinary = try BundleAssembler.locateShimBinary()
        let useClone = BundleAssembler.supportsCloneFile(source: request.sourceBundle,
                                                         destination: stagedBundle)
        if !useClone {
            notes.append("The destination volume does not support APFS file cloning, so this instance is a full copy of the application (\(FSOps.humanBytes(request.facts.bundleSizeBytes))).")
        }

        let tx = Transaction(label: "build #\(request.number) full", logger: log)

        tx.add("prepare data directory") {
            if !FileManager.default.fileExists(atPath: dataDir.path) {
                try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
                createdDataDir = true
            }
            try FileManager.default.createDirectory(at: self.paths.instanceLogsDir(id),
                                                    withIntermediateDirectories: true)
        } rollback: {
            // Only remove a data directory this build created, and only inside our own
            // tree. Never destroy an existing profile, or anything the user chose the
            // location of — that is user data.
            if createdDataDir && ownsDataDir {
                try self.paths.assertDeletable(self.paths.instanceDir(id).path)
                try FSOps.removeIfExists(self.paths.instanceDir(id))
            }
        }

        tx.add("clone application bundle") {
            try BundleAssembler.cloneBundle(from: request.sourceBundle,
                                            to: stagedBundle,
                                            useCloneFile: useClone)
        } rollback: {
            try FSOps.removeIfExists(stagedBundle)
        }

        var patchedInfo: [String: Any] = [:]
        tx.add("rewrite bundle identity") {
            let original = try BundleAssembler.readInfoPlist(bundle: stagedBundle)
            let options = PlistPatch.InfoPlistPatchOptions(
                newBundleIdentifier: newBundleID,
                newBundleName: title,
                newDisplayName: title,
                iconFileBaseName: iconBaseName,
                shimExecutableName: Self.shimName,
                stripURLSchemes: request.stripURLSchemes,
                stripSparkleFeed: request.stripSparkleFeed,
                preserveBundleName: BundleAssembler.helpersAreNamedAfterBundleName(
                    bundle: stagedBundle, info: original))
            let patched = try PlistPatch.patchInfoPlist(original, options: options)
            patchedInfo = patched.plist
            notes.append(contentsOf: patched.notes)
            try BundleAssembler.writeInfoPlist(patched.plist, bundle: stagedBundle)
        }
        _ = patchedInfo

        // Before signing, because both halves change files the signature covers.
        //
        // The original app's updater cannot reach a separate bundle; the one that can is
        // the clone's own, and when it fires it replaces Contents and takes the
        // rewritten identity, the numbered icon, the shim and our signature with it. So
        // an instance does not update itself unless the user has explicitly asked for
        // the vendor's update path back.
        tx.add("stop this instance updating itself") {
            guard !request.allowEmbeddedUpdater else {
                notes.append("This instance keeps the application's own updater, at your request. If it applies an update it will replace the instance's identity, numbered icon and signature; rebuild it afterwards. Your profile is not affected.")
                return
            }
            let onDisk = try UpdaterNeutraliser.neutraliseInBundle(stagedBundle, log: self.log)
            let info = try BundleAssembler.readInfoPlist(bundle: stagedBundle)
            let (rewritten, plistReport) = UpdaterNeutraliser.patchInfoPlist(info)

            // One combined record, written only if something was actually done. The
            // previous version wrote `true` unconditionally, so a Codex clone — where
            // nothing had been neutralised — carried a marker saying it had.
            //
            // `plistReport.assertedKeys` is not copied in: those are the two keys every
            // clone gets whether or not the application has an updater, and folding them
            // in would put the marker back on every clone.
            var combined = UpdaterNeutraliser.Report()
            combined.removedPaths = onDisk.removedPaths
            combined.changedKeys = plistReport.changedKeys
            try BundleAssembler.writeInfoPlist(
                UpdaterNeutraliser.recordNeutralisation(combined, in: rewritten),
                bundle: stagedBundle)

            notes.append(contentsOf: onDisk.notes)
            notes.append(contentsOf: plistReport.notes)
            if combined.didAnything {
                notes.append("This instance stays at \(request.facts.version) until you rebuild it. Rebuilding regenerates the bundle from the current source application and keeps the profile and the sign-in inside it.")
            } else {
                notes.append("LaunchAgain found no embedded updater to disable in this application. Sparkle's automatic-check settings were switched off in this instance anyway, in case one is present without declaring itself. If it updates itself by some means this build does not recognise — some apps set their update feed from their own code rather than from Info.plist — an update could still replace this instance's identity and numbered icon. Rebuild it if that happens; the profile is not affected.")
            }
        }

        tx.add("install launcher shim") {
            let config = InstanceConfig(mode: .full,
                                        dataPath: dataDir.path,
                                        realExecutableName: realExecName,
                                        extraArguments: request.extraArguments,
                                        extraEnvironment: request.extraEnvironment)
            try BundleAssembler.installShim(into: stagedBundle,
                                            shimBinary: shimBinary,
                                            originalExecutableName: request.facts.executableName,
                                            shimName: Self.shimName,
                                            config: config)
        }

        tx.add("generate numbered icon") {
            let source = IconFactory.loadSourceIcon(appBundle: request.sourceBundle)
            let dest = stagedBundle.appendingPathComponent("Contents/Resources/\(iconBaseName).icns")
            try self.icons.buildICNS(sourceIcon: source,
                                     number: request.number,
                                     badge: request.badge,
                                     destination: dest)
        }

        tx.add("re-sign clone") {
            // Entitlements are read from the ORIGINAL app, not the clone: the clone's
            // signature is already invalid at this point.
            let scanner = AppScanner(log: self.log)
            let original = (try? scanner.readEntitlements(at: request.sourceBundle)) ?? [:]
            let patched = EntitlementsPatch.patch(original)
            if !patched.removed.isEmpty {
                notes.append("Entitlements removed when re-signing: " + patched.removed.joined(separator: " · "))
            }
            try BundleAssembler.writeRecoveryManifest(
                LauncherRecoveryManifest(
                    appKey: request.facts.bundleIdentifier,
                    appDisplayName: request.facts.displayName,
                    sourcePath: request.facts.path,
                    sourceVersion: request.facts.version,
                    instance: recoveredInstance(notes: notes)),
                into: stagedBundle)

            // Every nested executable gets the patched version of *its own* original
            // entitlements, read from the corresponding path inside the source app.
            //
            // Two cases are load-bearing:
            //   · `<exec>.real` — after the shim execs it, this binary *is* the running
            //     application, so it needs the main entitlements. Signed as ordinary
            //     nested code with none, it enforces library validation and dyld refuses
            //     the vendor-signed Electron framework: "different Team IDs".
            //   · the helper .apps — the renderer needs JIT and unsigned executable
            //     memory, and inherits neither from the outer bundle.
            let sourceRoot = request.sourceBundle.standardizedFileURL.path
            let stagedRoot = stagedBundle.standardizedFileURL.path
            let realExecutablePath = stagedBundle
                .appendingPathComponent("Contents/MacOS/\(realExecName)").standardizedFileURL.path
            var cache: [String: [String: Any]] = [:]

            signedCount = try self.signer.adHocSign(
                bundle: stagedBundle,
                mainEntitlements: patched.entitlements,
                hardenedRuntime: request.facts.hasHardenedRuntime,
                entitlementsFor: { item in
                    let path = item.standardizedFileURL.path
                    if path == realExecutablePath { return patched.entitlements }
                    guard ["app", "xpc", "appex"].contains(item.pathExtension.lowercased()) else {
                        return nil
                    }
                    // Map the staged item back to the untouched original and read what it
                    // was actually signed with.
                    let originalPath = path.hasPrefix(stagedRoot)
                        ? sourceRoot + String(path.dropFirst(stagedRoot.count))
                        : path
                    if let hit = cache[originalPath] { return hit }
                    let own = (try? scanner.readEntitlements(at: URL(fileURLWithPath: originalPath))) ?? [:]
                    let result = own.isEmpty
                        ? EntitlementsPatch.helperFallback
                        : EntitlementsPatch.patch(own).entitlements
                    cache[originalPath] = result
                    return result
                })
        }

        tx.add("verify signature") {
            verifyOutput = try self.signer.verify(bundle: stagedBundle)
            self.signer.clearQuarantine(bundle: stagedBundle)
        }

        tx.add("move into place") {
            try FSOps.atomicMove(stagedBundle, to: finalBundle)
        } rollback: {
            try FSOps.removeIfExists(finalBundle)
        }

        tx.add("register with Launch Services") {
            // refreshIconCaches rather than register: a fresh install at a path a
            // previous instance occupied is the case where IconServices shows what it
            // cached last time, and someone who deletes "Claude 1 – Work" and creates
            // another with the same name lands on exactly that path.
            self.registrar.refreshIconCaches(for: finalBundle)
        } rollback: {
            self.registrar.unregister(bundle: finalBundle)
        }

        try tx.run(progress: progress)

        let instance = recoveredInstance(notes: notes)

        log.info(
            "built instance #\(request.number) \(title) "
                + "[instance=\(instance.id.uuidString)] at \(finalBundle.path)")
        return BuildResult(instance: instance, degradedToLite: false, degradationReason: nil,
                           notes: notes, signedItemCount: signedCount, verifyOutput: verifyOutput)
    }

    // MARK: - Lite mode

    private func buildLite(_ request: BuildRequest,
                           progress: ((Int, Int, String) -> Void)?) throws -> BuildResult {
        let id = request.instanceID
        let sourceName = request.facts.displayName
        let title = Instance(number: request.number, name: request.name,
                             bundlePath: "", dataPath: "").displayTitle(sourceName: sourceName)

        let dataDir = request.dataPathOverride.map { URL(fileURLWithPath: $0) }
            ?? paths.instanceDataDir(id)
        try Validation.validateAbsolutePath(dataDir.path, label: "data directory")
        let ownsDataDir = request.dataPathOverride == nil
        let installRoot = try destinationRoot(for: request)
        let taken = existingBundleNames()
        let bundleFilename = Validation.uniqueBundleFilename(preferred: title, taken: taken)
        // Staged inside the destination root: the move into place has to be a rename
        // within one filesystem, and /Applications and ~/Applications are not always on
        // the same volume as each other, let alone as /tmp.
        let stagedBundle = paths.stagingDir(in: installRoot)
            .appendingPathComponent("\(id.uuidString)-\(bundleFilename)")
        let finalBundle = installRoot.appendingPathComponent(bundleFilename)
        let newBundleID = Validation.cloneBundleIdentifier(original: "com.multipleappslauncher.instance",
                                                           number: request.number,
                                                           instanceID: id)
        let iconBaseName = "MALAppIcon"
        let notes = [
            "Lite mode: the original application is launched with an isolated Chromium data directory. Profile-resident state is separate; the running app shares the original's Dock, Keychain, privacy-permission and URL-scheme identity."
        ]
        var createdDataDir = false
        let createdAt = request.createdAt ?? Date()
        // Recorded here and nowhere else: this is the one build path the shared-session
        // acknowledgement is *about*, so a Full build never carries a stamp that a later
        // conversion to Lite could read back as consent it was never given.
        //
        // Preserved from the stored record when there is one, so a rebuild keeps the
        // date the user actually accepted rather than moving it forward each time.
        let acknowledgedAt: Date? = request.acknowledgedSharedCredentialStore
            ? (request.acknowledgedSharedCredentialStoreAt ?? createdAt)
            : nil

        func recoveredInstance(notes: [String]) -> Instance {
            Instance(id: id,
                     number: request.number,
                     name: request.name,
                     accountLabel: request.accountLabel,
                     mode: .lite,
                     bundlePath: finalBundle.path,
                     dataPath: dataDir.path,
                     badge: request.badge,
                     builtFromSourceVersion: request.facts.version,
                     clonedBundleIdentifier: newBundleID,
                     extraArguments: request.extraArguments,
                     extraEnvironment: request.extraEnvironment,
                     createdAt: createdAt,
                     acknowledgedSharedCredentialStoreAt: acknowledgedAt,
                     buildNotes: notes)
        }

        let shimBinary = try BundleAssembler.locateShimBinary()
        let tx = Transaction(label: "build #\(request.number) lite", logger: log)

        tx.add("prepare data directory") {
            if !FileManager.default.fileExists(atPath: dataDir.path) {
                try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
                createdDataDir = true
            }
            try FileManager.default.createDirectory(at: self.paths.instanceLogsDir(id),
                                                    withIntermediateDirectories: true)
        } rollback: {
            if createdDataDir && ownsDataDir {
                try self.paths.assertDeletable(self.paths.instanceDir(id).path)
                try FSOps.removeIfExists(self.paths.instanceDir(id))
            }
        }

        tx.add("create launcher bundle") {
            let config = InstanceConfig(mode: .lite,
                                        dataPath: dataDir.path,
                                        targetAppPath: request.sourceBundle.path,
                                        extraArguments: request.extraArguments,
                                        extraEnvironment: request.extraEnvironment)
            let info = PlistPatch.liteLauncherInfoPlist(bundleIdentifier: newBundleID,
                                                        bundleName: title,
                                                        displayName: title,
                                                        iconFileBaseName: iconBaseName,
                                                        shimExecutableName: Self.shimName)
            try BundleAssembler.createLiteLauncher(at: stagedBundle,
                                                   shimBinary: shimBinary,
                                                   shimName: Self.shimName,
                                                   infoPlist: info,
                                                   config: config)
        } rollback: {
            try FSOps.removeIfExists(stagedBundle)
        }

        tx.add("generate numbered icon") {
            let source = IconFactory.loadSourceIcon(appBundle: request.sourceBundle)
            let dest = stagedBundle.appendingPathComponent("Contents/Resources/\(iconBaseName).icns")
            try self.icons.buildICNS(sourceIcon: source,
                                     number: request.number,
                                     badge: request.badge,
                                     destination: dest)
        }

        tx.add("sign launcher") {
            // This bundle is entirely our own code, so signing it is uncomplicated.
            try BundleAssembler.writeRecoveryManifest(
                LauncherRecoveryManifest(
                    appKey: request.facts.bundleIdentifier,
                    appDisplayName: request.facts.displayName,
                    sourcePath: request.facts.path,
                    sourceVersion: request.facts.version,
                    instance: recoveredInstance(notes: notes)),
                into: stagedBundle)
            _ = try self.signer.adHocSign(bundle: stagedBundle,
                                          mainEntitlements: [:],
                                          hardenedRuntime: true)
            self.signer.clearQuarantine(bundle: stagedBundle)
        }

        tx.add("move into place") {
            try FSOps.atomicMove(stagedBundle, to: finalBundle)
        } rollback: {
            try FSOps.removeIfExists(finalBundle)
        }

        tx.add("register with Launch Services") {
            // refreshIconCaches rather than register: a fresh install at a path a
            // previous instance occupied is the case where IconServices shows what it
            // cached last time, and someone who deletes "Claude 1 – Work" and creates
            // another with the same name lands on exactly that path.
            self.registrar.refreshIconCaches(for: finalBundle)
        } rollback: {
            self.registrar.unregister(bundle: finalBundle)
        }

        try tx.run(progress: progress)

        let instance = recoveredInstance(notes: notes)

        log.info(
            "built Lite instance #\(request.number) \(title) "
                + "[instance=\(instance.id.uuidString)]")
        return BuildResult(instance: instance, degradedToLite: false, degradationReason: nil,
                           notes: notes, signedItemCount: 0, verifyOutput: "")
    }

    // MARK: - Rebuild / repair

    /// Rebuilds an instance's *bundle* from the current source app, preserving its
    /// number, name, badge and — critically — its data directory, which is never touched.
    ///
    /// - Parameter acknowledgedSharedCredentialStore: whether the shared-session
    ///   consequence has been accepted for this instance. **The caller must supply this
    ///   from the instance as it is stored**, never from the one being proposed.
    ///
    ///   This parameter exists because the previous shape did not have it. `rebuild`
    ///   used to derive the answer from `instance.mode == .lite`, and
    ///   `updateAdvancedSettings` sets `proposed.mode = .lite` before calling through —
    ///   so Advanced ▸ Force Lite ▸ Apply asked the question and answered it in the same
    ///   breath, converting a Full instance of a shared-credential-store app to Lite with
    ///   no warning and no acknowledgement. Passing it in makes that impossible to
    ///   express by accident: there is nothing here for a caller to reflect back.
    ///
    /// - Parameter rebuildsExistingLiteLauncher: whether the instance **as stored** is
    ///   already Lite, so this rebuild introduces no sharing that is not already on disk.
    ///   Also the caller's job, and for the same reason: derived from the stored record,
    ///   never from `instance`, which on the Advanced path is the proposal.
    public func rebuild(instance: Instance,
                        sourceBundle: URL,
                        facts: AppFacts,
                        acknowledgedSharedCredentialStore: Bool,
                        rebuildsExistingLiteLauncher: Bool = false,
                        progress: ((Int, Int, String) -> Void)? = nil,
                        commit: ((BuildResult) throws -> Void)? = nil) throws -> BuildResult {
        let oldBundle = URL(fileURLWithPath: instance.bundlePath)
        // A rebuild must land on the *same* profile the instance is already signed in
        // to, which is not necessarily the default location for its id.
        let standardData = paths.instanceDataDir(instance.id).path
        let override = (instance.dataPath == standardData || instance.dataPath.isEmpty)
            ? nil : instance.dataPath
        // A rebuild stays where the instance already is. Moving a launcher between
        // /Applications/LaunchAgain and ~/Applications/LaunchAgain is a separate,
        // explicit operation, not a side effect of picking up a new version.
        let currentRoot = paths.bundleRoot(containing: oldBundle.path) ?? paths.bundlesDir
        let request = BuildRequest(instanceID: instance.id,
                                   sourceBundle: sourceBundle,
                                   facts: facts,
                                   number: instance.number,
                                   name: instance.name,
                                   accountLabel: instance.accountLabel,
                                   badge: instance.badge,
                                   requestedMode: instance.mode,
                                   extraArguments: instance.extraArguments,
                                   extraEnvironment: instance.extraEnvironment,
                                   acknowledgedSharedCredentialStore:
                                    acknowledgedSharedCredentialStore,
                                   acknowledgedSharedCredentialStoreAt:
                                    instance.acknowledgedSharedCredentialStoreAt,
                                   rebuildsExistingLiteLauncher:
                                    rebuildsExistingLiteLauncher,
                                   installRoot: currentRoot,
                                   dataPathOverride: override,
                                   // The bundle is regenerated; the instance is not new.
                                   createdAt: instance.createdAt)

        // Retire the old bundle rather than deleting it, so a failed rebuild can be undone.
        // Into the staging directory of the root it currently lives in: retiring is a
        // rename, and the two roots are not guaranteed to be on one volume.
        try paths.prepareBundleRoot(currentRoot)
        let retired = paths.stagingDir(in: currentRoot)
            .appendingPathComponent("retired-\(instance.id.uuidString)-\(Int(Date().timeIntervalSince1970))")
        var didRetire = false
        if FileManager.default.fileExists(atPath: oldBundle.path) {
            registrar.unregister(bundle: oldBundle)
            try FSOps.atomicMove(oldBundle, to: retired)
            didRetire = true
        }

        var installedBundle: URL?
        do {
            let result = try build(request, progress: progress)
            installedBundle = URL(fileURLWithPath: result.instance.bundlePath)
            try commit?(result)
            if didRetire {
                try? paths.assertDeletable(retired.path)
                try? FSOps.removeIfExists(retired)
            }
            return result
        } catch {
            var rollbackFailures: [String] = []
            if let installedBundle,
               FileManager.default.fileExists(atPath: installedBundle.path) {
                registrar.unregister(bundle: installedBundle)
                do {
                    try paths.assertLauncherBundlePath(installedBundle.path)
                    try FSOps.removeIfExists(installedBundle)
                } catch {
                    rollbackFailures.append("remove replacement launcher: \(error)")
                }
            }
            if didRetire {
                do {
                    try FSOps.atomicMove(retired, to: oldBundle)
                    registrar.register(bundle: oldBundle)
                    log.warn("rebuild failed; restored the previous bundle")
                } catch {
                    rollbackFailures.append("restore previous launcher: \(error)")
                }
            }
            if !rollbackFailures.isEmpty {
                throw MALError.rollbackIncomplete(
                    original: "\(error)",
                    rollbackFailures: rollbackFailures)
            }
            throw error
        }
    }

    // MARK: - Removal

    public enum RemovalScope: Equatable {
        /// Remove the launcher bundle, keep the profile so the instance can be recreated.
        case launcherOnly
        /// Remove the launcher bundle and the profile.
        case launcherAndData
    }

    public struct RemovalReport: Sendable {
        public var removedBundle: Bool
        public var removedData: Bool
        /// True when what was removed went to the Trash rather than being erased, so the
        /// interface can tell the user it is recoverable.
        public var wentToTrash: Bool = false
        /// A profile we deliberately did not delete, and why. Non-nil when the user
        /// pointed this instance at a directory outside the launcher's own folders.
        public var keptDataPath: String?
        public var keptReason: String?
        /// Exact macOS Library paths keyed to this generated clone identifier.
        public var removedAssociatedArtifacts: [String] = []
    }

    /// Validates the complete owned deletion plan before its first mutation.
    public func validateRemoval(instance: Instance, scope: RemovalScope) throws {
        let bundle = URL(fileURLWithPath: instance.bundlePath)
        try paths.assertLauncherBundlePath(bundle.path)
        if FileManager.default.fileExists(atPath: bundle.path) {
            _ = try LauncherIdentityVerifier.verify(
                bundle: bundle,
                paths: paths,
                expected: instance)
        }

        if scope == .launcherAndData {
            let ours = paths.instanceDir(instance.id)
            try paths.assertInstanceDirectory(ours.path, for: instance.id)
            _ = try artifactCleaner.candidates(for: instance)
        }
    }

    @discardableResult
    public func remove(instance: Instance, scope: RemovalScope) throws -> RemovalReport {
        var report = RemovalReport(removedBundle: false, removedData: false)

        let bundle = URL(fileURLWithPath: instance.bundlePath)
        try validateRemoval(instance: instance, scope: scope)

        if FileManager.default.fileExists(atPath: bundle.path) {
            registrar.unregister(bundle: bundle)
            report.wentToTrash = try FSOps.moveToTrash(bundle)
            report.removedBundle = true
        } else {
            // Already gone — the user removed it in Finder. That is a perfectly ordinary
            // way to delete an app, so it is not an error; there is simply nothing left
            // to remove here.
            registrar.unregister(bundle: bundle)
        }

        if scope == .launcherAndData {
            // Our own directory for this instance — logs, lock file, and the profile when
            // it lives in the default place.
            let ours = paths.instanceDir(instance.id)
            try paths.assertInstanceDirectory(ours.path, for: instance.id)
            if FileManager.default.fileExists(atPath: ours.path) {
                report.wentToTrash = try FSOps.moveToTrash(ours) || report.wentToTrash
            }
            report.removedData = true

            // A profile the user relocated is theirs. Deleting it because a checkbox said
            // "and its data" would be exactly the kind of surprise this product refuses,
            // so it is kept and the caller is told, rather than being quietly ignored.
            let dataPath = instance.dataPath
            if !dataPath.isEmpty,
               !Validation.isPath(dataPath, within: ours.path),
               FileManager.default.fileExists(atPath: dataPath) {
                report.removedData = false
                report.keptDataPath = dataPath
                report.keptReason = "This profile is not inside this instance's UUID-owned directory, so it was left where it is. Delete it yourself if you want it gone."
                log.warn(
                    "kept profile outside this instance's directory "
                        + "[instance=\(instance.id.uuidString)]: \(dataPath)")
            }

            let artifactReport = try artifactCleaner.removeArtifacts(for: instance)
            report.wentToTrash = artifactReport.wentToTrash || report.wentToTrash
            report.removedAssociatedArtifacts = artifactReport.removedPaths
        }

        log.info(
            "removed instance #\(instance.number) "
                + "[instance=\(instance.id.uuidString)] "
                + "(\(report.removedData ? "with" : "without") data)")
        if scope == .launcherAndData {
            try log.removeInstanceEntries(
                id: instance.id,
                cloneIdentifier: instance.clonedBundleIdentifier,
                additionalFiles: [
                    paths.logsDir.appendingPathComponent("mal.log"),
                ])
        }
        return report
    }

    // MARK: - Helpers

    /// Filenames already taken, across *both* launcher roots.
    ///
    /// Deliberately not per-root: two instances of the same app with the same name in
    /// two different directories is exactly the ambiguity numbering exists to avoid, and
    /// it would make a Finder search return two identical-looking apps.
    private func existingBundleNames() -> Set<String> {
        var names: Set<String> = []
        for root in paths.bundleRoots {
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
            names.formUnion(entries.map { $0.lowercased() })
        }
        return names
    }

    private func assertSourceUntouched(_ source: URL, expected: String) throws {
        let now = BundleAssembler.sourceFingerprint(bundle: source)
        guard now == expected else {
            log.error("SOURCE MODIFIED: \(source.path)")
            throw MALError.buildFailed(step: "integrity check",
                                       underlying: "the source application changed during the build. No instance was created.")
        }
    }

    private func validateSourceOrRollback(
        _ source: URL,
        expected: String,
        result: BuildResult,
        removeOwnedProfile: Bool
    ) throws {
        do {
            try assertSourceUntouched(source, expected: expected)
        } catch {
            var failures: [String] = []
            let bundle = URL(fileURLWithPath: result.instance.bundlePath)
            registrar.unregister(bundle: bundle)
            do {
                try paths.assertLauncherBundlePath(bundle.path)
                try FSOps.removeIfExists(bundle)
            } catch {
                failures.append("remove uncommitted launcher: \(error)")
            }
            if removeOwnedProfile {
                let owned = paths.instanceDir(result.instance.id)
                do {
                    try paths.assertInstanceDirectory(owned.path, for: result.instance.id)
                    try FSOps.removeIfExists(owned)
                } catch {
                    failures.append("remove uncommitted profile: \(error)")
                }
            }
            if !failures.isEmpty {
                throw MALError.rollbackIncomplete(
                    original: "\(error)",
                    rollbackFailures: failures)
            }
            throw error
        }
    }
}
#endif
