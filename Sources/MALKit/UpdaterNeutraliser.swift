#if canImport(Darwin)
import Foundation
import MALCore

/// Stops a generated clone updating itself.
///
/// A clone is a separate bundle, so the *original* application's updater never reaches
/// it — that half was never the risk. The risk is the clone's own embedded updater. It
/// inherits the vendor's feed, it fires on the vendor's schedule, and when it applies an
/// update it replaces `Contents` wholesale: the rewritten `Info.plist`, the numbered
/// icon, the shim, the renamed real executable and the ad-hoc signature all go, and the
/// instance rejoins the original's Dock tile with someone else's identity.
///
/// So an instance is non-self-updating by default, and the only route to a new version is
/// Rebuild, which regenerates the bundle from the current source app and leaves the
/// profile alone.
///
/// **What this does not do.** It does not patch, decompile or otherwise modify the
/// vendor's own code, and it does not disable the *original* application's updater —
/// that bundle is never written to at all. It removes and rewrites data files inside the
/// copy LaunchAgain made, all of which are re-signed afterwards.
public enum UpdaterNeutraliser {

    public struct Report: Sendable, Equatable {
        /// Paths removed from the clone, relative to the bundle.
        public var removedPaths: [String] = []
        /// Info.plist keys that were **found and changed** — an updater setting this
        /// application actually declared, and that this build turned off.
        public var changedKeys: [String] = []
        /// Info.plist keys written defensively, where the application declared nothing
        /// for us to disarm.
        ///
        /// Kept apart from `changedKeys` because they are two different statements.
        /// `SUEnableAutomaticChecks` and `SUAutomaticallyUpdate` are written on every
        /// clone, including clones of applications with no Sparkle at all, so counting
        /// them as work done would make "we neutralised something" true of everything
        /// and the record meaningless — which is the failure Ma-1 fixed once already.
        public var assertedKeys: [String] = []
        /// Human-readable notes for the build record and the interface.
        public var notes: [String] = []

        /// Whether an updater was actually found and disarmed. Deliberately not
        /// influenced by `assertedKeys`.
        public var didAnything: Bool {
            !removedPaths.isEmpty || !changedKeys.isEmpty
        }
    }

    /// What was neutralised in this clone, written into its `Info.plist`.
    ///
    /// This used to be `true`, written unconditionally — including for clones where
    /// **nothing had been neutralised at all**. `/Applications/ChatGPT.app` declares only
    /// `SUPublicEDKey`, none of the five keys the plist patcher looks for, so a Codex
    /// clone changed nothing, produced no build note, recorded `true`, and the interface
    /// told the user unconditionally that these instances would not update themselves.
    /// A record that is written whether or not the thing happened is not a record.
    ///
    /// It is now the list of what was actually done, and it is absent when nothing was.
    public static let markerKey = "MALEmbeddedUpdaterNeutralised"
    /// Where the vendor's Sparkle feed went, kept for the record rather than discarded.
    public static let preservedFeedKey = "MALOriginalSUFeedURL"

    // MARK: - Info.plist half

    /// Sparkle reads its schedule and its feed out of `Info.plist`, so that half is a
    /// plist rewrite and belongs with the rest of the identity patch.
    ///
    /// The feed URL is moved to `MALOriginalSUFeedURL` rather than deleted: an instance
    /// that stops checking for updates should still be able to tell you where it would
    /// have checked, and a future rebuild-from-source restores the original anyway.
    public static func patchInfoPlist(_ plist: [String: Any]) -> (plist: [String: Any], report: Report) {
        var p = plist
        var report = Report()

        if let feed = p["SUFeedURL"] as? String, !feed.isEmpty {
            p[preservedFeedKey] = feed
            p.removeValue(forKey: "SUFeedURL")
            report.changedKeys.append("SUFeedURL")
        }
        for key in ["SUEnableInstallerLauncherService", "SUScheduledCheckInterval"]
        where p[key] != nil {
            p.removeValue(forKey: key)
            report.changedKeys.append(key)
        }
        // The two schedule keys are *asserted*, not merely removed when present.
        //
        // Writing them used to sit inside `if !report.changedKeys.isEmpty`, so an
        // application that declares neither — ChatGPT declares only SUPublicEDKey — had
        // automatic checks left at Sparkle's default, which is to prompt on first run.
        // A prompt is an update path. Writing them costs nothing on an app with no
        // Sparkle at all and closes that door on one that has it, so it stays
        // unconditional.
        //
        // What that unconditional write must not do is claim credit. A key we set on
        // every clone regardless of what we found is recorded as *asserted*; only a key
        // the application declared **and had switched on** counts as one we changed.
        // One pass per key, so an app that already declares both as `false` records each
        // exactly once rather than twice — removed here, re-set there.
        for key in ["SUEnableAutomaticChecks", "SUAutomaticallyUpdate"] {
            let declared = p[key] != nil
            let alreadyOff = (p[key] as? Bool) == false
            p[key] = false
            if declared && !alreadyOff {
                report.changedKeys.append(key)
            } else {
                report.assertedKeys.append(key)
            }
        }
        if !report.changedKeys.isEmpty {
            report.notes.append("Sparkle's update settings were disabled in this instance: "
                                + report.changedKeys.sorted().joined(separator: ", ") + ".")
        }

        return (p, report)
    }

    /// Writes the record of what was neutralised, or writes nothing.
    ///
    /// Separate from `patchInfoPlist` because the record has to cover the on-disk half
    /// too, and because the whole point is that it is not written when the answer is
    /// "nothing".
    ///
    /// `assertedKeys` are deliberately not part of the record. They are written on every
    /// clone, so including them would make the marker present on every clone — and a
    /// marker that is always present records nothing at all.
    public static func recordNeutralisation(_ report: Report, in plist: [String: Any]) -> [String: Any] {
        var p = plist
        let record = report.changedKeys.sorted() + report.removedPaths.sorted()
        if record.isEmpty {
            p.removeValue(forKey: markerKey)
        } else {
            p[markerKey] = record
        }
        return p
    }

    // MARK: - On-disk half

    /// Squirrel and electron-updater do their work from files inside the bundle, so that
    /// half is a filesystem operation on the staged clone.
    ///
    /// Two exact paths, both data rather than the app's own code:
    ///
    /// · `Contents/Frameworks/Squirrel.framework/…/Resources/ShipIt` — the separate
    ///   helper process Squirrel spawns to swap the bundle. The framework itself is left
    ///   in place, because the application links against it and removing it would stop
    ///   the app launching at all; without ShipIt the download still happens and the
    ///   install step fails, which is the outcome we want and the one Squirrel already
    ///   has an error path for.
    ///
    /// · `Contents/Resources/app-update.yml` — electron-updater's provider
    ///   configuration. Without it electron-updater reports that it is not configured
    ///   and does nothing.
    @discardableResult
    public static func neutraliseInBundle(_ bundle: URL, log: MALLog = .silent) throws -> Report {
        var report = Report()
        let fm = FileManager.default

        for relative in shipItPaths(in: bundle) {
            let url = bundle.appendingPathComponent(relative)
            guard fm.fileExists(atPath: url.path) else { continue }
            try fm.removeItem(at: url)
            report.removedPaths.append(relative)
        }
        if !report.removedPaths.isEmpty {
            report.notes.append("Squirrel's ShipIt installer was removed from this instance, so an update it downloads cannot replace the instance's identity. The original application is untouched and updates normally.")
        }

        let updateConfig = "Contents/Resources/app-update.yml"
        if fm.fileExists(atPath: bundle.appendingPathComponent(updateConfig).path) {
            try fm.removeItem(at: bundle.appendingPathComponent(updateConfig))
            report.removedPaths.append(updateConfig)
            report.notes.append("electron-updater's provider configuration was removed from this instance. Rebuild it to pick up a new version of the source application.")
        }

        var removedSparkle: [String] = []
        for relative in sparkleInstallerPaths(in: bundle) {
            let url = bundle.appendingPathComponent(relative)
            let exists = fm.fileExists(atPath: url.path)
                || (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
            guard exists else { continue }
            try fm.removeItem(at: url)
            removedSparkle.append(relative)
        }
        if !removedSparkle.isEmpty {
            report.removedPaths.append(contentsOf: removedSparkle)
            report.notes.append("Sparkle's installer helpers were removed from this instance — Autoupdate, Updater.app and the installer and downloader XPC services. The framework itself stays, because the application links against it. An update it decides to fetch has nothing left to apply it with.")
        }

        if report.didAnything {
            log.info("neutralised the embedded updater in \(bundle.lastPathComponent): "
                     + report.removedPaths.joined(separator: ", "))
        }
        return report
    }

    /// Sparkle's installer chain: the parts that *apply* an update, as opposed to the
    /// framework the application links against.
    ///
    /// This is the same trade-off already accepted for Squirrel. `ShipIt` is deleted
    /// because it is the separate process that swaps the bundle; Sparkle's equivalents
    /// are `Autoupdate` (the helper that performs the install), `Updater.app` (its UI),
    /// and the `Installer.xpc` and `Downloader.xpc` services. The framework binary stays,
    /// so the app still links and still launches — it simply has nothing left to install
    /// with.
    ///
    /// This matters for ChatGPT specifically, which declares **only** `SUPublicEDKey` in
    /// its `Info.plist` and sets its feed at runtime from
    /// `Contents/Resources/native/sparkle.node` (`fallbackFeedURL`, `setFeedURL`). A
    /// plist edit cannot reach a feed that is assigned in code, so for that application
    /// the plist half of this alone neutralised nothing at all.
    ///
    /// Enumerated rather than globbed, and both the versioned files and the top-level
    /// symlinks that point at them, because a dangling symlink inside a framework fails
    /// code signing.
    static func sparkleInstallerPaths(in bundle: URL) -> [String] {
        let framework = "Contents/Frameworks/Sparkle.framework"
        let leaves = ["Autoupdate",
                      "Updater.app",
                      "XPCServices/Installer.xpc",
                      "XPCServices/Downloader.xpc"]
        var candidates = leaves.map { "\(framework)/\($0)" }
        let versions = bundle.appendingPathComponent("\(framework)/Versions")
        if let names = try? FileManager.default.contentsOfDirectory(atPath: versions.path) {
            for name in names where !name.contains("/") {
                candidates.append(contentsOf: leaves.map { "\(framework)/Versions/\(name)/\($0)" })
            }
        }
        // Deepest first, so a versioned file is removed before the symlink to it.
        return Array(Set(candidates)).sorted { $0.count > $1.count }
    }

    /// Every ShipIt an installed Squirrel framework may present, versioned or flat.
    /// Enumerated rather than globbed: these are exact, known paths inside a bundle
    /// LaunchAgain created, and a wildcard here would be a wildcard inside an app.
    private static func shipItPaths(in bundle: URL) -> [String] {
        let framework = "Contents/Frameworks/Squirrel.framework"
        var candidates = [
            "\(framework)/Resources/ShipIt",
            "\(framework)/Versions/A/Resources/ShipIt",
            "\(framework)/Versions/Current/Resources/ShipIt",
        ]
        // Some builds ship a differently-lettered version directory. Read the names that
        // are actually there rather than guessing further.
        let versions = bundle.appendingPathComponent("\(framework)/Versions")
        if let names = try? FileManager.default.contentsOfDirectory(atPath: versions.path) {
            for name in names where !name.contains("/") {
                candidates.append("\(framework)/Versions/\(name)/Resources/ShipIt")
            }
        }
        // A symlinked Versions/Current would otherwise be removed twice.
        return Array(Set(candidates)).sorted()
    }

    /// What a clone of `sourceBundle` would have neutralised, in the user's terms.
    ///
    /// Read-only, and computed from the *source* application, so the interface can say
    /// what it is about to do rather than promising it in advance. The create flow said
    /// "These instances will not update themselves" unconditionally, which for ChatGPT —
    /// where nothing was neutralised at all — was simply false.
    public static func plannedNeutralisations(forSource bundle: URL) -> [String] {
        let fm = FileManager.default
        var planned: [String] = []

        if !shipItPaths(in: bundle).allSatisfy({
            !fm.fileExists(atPath: bundle.appendingPathComponent($0).path)
        }) {
            planned.append("Squirrel's ShipIt installer")
        }
        if fm.fileExists(atPath: bundle.appendingPathComponent(
            "Contents/Resources/app-update.yml").path) {
            planned.append("electron-updater's configuration")
        }
        if !sparkleInstallerPaths(in: bundle).allSatisfy({
            !fm.fileExists(atPath: bundle.appendingPathComponent($0).path)
        }) {
            planned.append("Sparkle's installer helpers")
        }
        if let info = try? BundleAssembler.readInfoPlist(bundle: bundle),
           info["SUFeedURL"] != nil {
            planned.append("Sparkle's update feed")
        }
        return planned
    }

    /// True when this bundle carries the marker written by `patchInfoPlist`.
    public static func isNeutralised(bundle: URL) -> Bool {
        guard let info = try? BundleAssembler.readInfoPlist(bundle: bundle) else { return false }
        // The marker is a list of what was neutralised. Clones built by the release that
        // wrote an unconditional `true` are still read, so an existing instance does not
        // start reporting differently after an upgrade.
        if let record = info[markerKey] as? [String] { return !record.isEmpty }
        return (info[markerKey] as? Bool) == true
    }
}
#endif
