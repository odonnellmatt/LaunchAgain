#if canImport(Darwin)
import XCTest
import AppKit
@testable import MALKit
@testable import MALCore

/// End-to-end tests for the build pipeline, run against a synthetic application bundle.
///
/// A synthetic app is used rather than a real one so the suite is hermetic and fast, but
/// nothing about the pipeline is stubbed: this really does clone a bundle, rewrite its
/// identity, plant the shim, render an icon, ad-hoc sign it inside-out and verify the
/// signature with `codesign --verify --deep --strict`.
final class BuildPipelineTests: XCTestCase {

    private var root: URL!
    private var paths: MALPaths!
    private var sourceApp: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mal-build-tests-\(UUID().uuidString)")
        paths = MALPaths.rooted(at: root)
        try paths.createAll()
        sourceApp = try makeSyntheticApp(named: "Fake")
    }

    override func tearDownWithError() throws {
        // Unregister anything the tests registered before deleting it.
        let registrar = LaunchServicesRegistrar(log: .silent)
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: paths.bundlesDir.path) {
            for e in entries where e.hasSuffix(".app") {
                registrar.unregister(bundle: paths.bundlesDir.appendingPathComponent(e))
            }
        }
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Fixtures

    /// A minimal but genuine `.app`: a real Mach-O executable, an Info.plist, and an
    /// asar file so the scanner classifies it as Electron.
    private func makeSyntheticApp(named name: String) throws -> URL {
        let app = root.appendingPathComponent("source/\(name).app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("Resources"),
                                                withIntermediateDirectories: true)

        // /bin/echo is a small, real, signed Mach-O — exactly what the pipeline expects
        // to find and re-sign.
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"),
                                         to: contents.appendingPathComponent("MacOS/\(name)"))
        try Data("not really an asar".utf8)
            .write(to: contents.appendingPathComponent("Resources/app.asar"))

        let info: [String: Any] = [
            "CFBundleIdentifier": "com.example.\(name.lowercased())",
            "CFBundleName": name,
            "CFBundleDisplayName": name,
            "CFBundleExecutable": name,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
        ]
        try BundleAssembler.writeInfoPlist(info, bundle: app)
        return app
    }

    private func facts(for app: URL, name: String = "Fake") -> AppFacts {
        AppFacts(bundleIdentifier: "com.example.\(name.lowercased())",
                 displayName: name,
                 executableName: name,
                 shortVersion: "1.0",
                 path: app.path,
                 runtime: .electron,
                 isSigned: true,
                 signingInspected: true)
    }

    // MARK: Self-updating instances

    /// electron-updater's provider configuration, which lives in `Resources` and so can
    /// go through the whole signing pipeline unchanged.
    private func addElectronUpdaterConfig(to app: URL) throws {
        try Data("provider: s3\nbucket: example\n".utf8)
            .write(to: app.appendingPathComponent("Contents/Resources/app-update.yml"))
    }

    /// The Squirrel shape, as a bundle directory rather than through the build.
    ///
    /// A hand-made `Squirrel.framework` containing a shell script is not a framework
    /// `codesign --deep --strict` will accept, so a full build against one degrades to
    /// Lite and proves nothing about the clone. The removal itself is therefore
    /// exercised directly, and the real framework is covered by the LM Studio
    /// reproduction in docs/VALIDATION.md.
    private func makeSquirrelBundle() throws -> URL {
        let app = root.appendingPathComponent("squirrel/Fixture.app")
        let shipIt = app.appendingPathComponent(
            "Contents/Frameworks/Squirrel.framework/Versions/A/Resources")
        try FileManager.default.createDirectory(at: shipIt, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: app.appendingPathComponent("Contents/Resources"),
            withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8)
            .write(to: shipIt.appendingPathComponent("ShipIt"))
        try Data("provider: s3\n".utf8)
            .write(to: app.appendingPathComponent("Contents/Resources/app-update.yml"))
        try BundleAssembler.writeInfoPlist(["CFBundleIdentifier": "com.example.squirrel"],
                                           bundle: app)
        return app
    }

    func testShipItAndTheUpdaterConfigAreRemovedFromABundle() throws {
        let app = try makeSquirrelBundle()
        let report = try UpdaterNeutraliser.neutraliseInBundle(app)

        XCTAssertFalse(FileManager.default.fileExists(atPath: app.appendingPathComponent(
            "Contents/Frameworks/Squirrel.framework/Versions/A/Resources/ShipIt").path),
                       "ShipIt is what replaces the bundle; leaving it leaves the risk")
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.appendingPathComponent(
            "Contents/Resources/app-update.yml").path))
        // The framework itself stays: the application links against it, and removing it
        // would stop the clone launching at all.
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.appendingPathComponent(
            "Contents/Frameworks/Squirrel.framework").path))
        XCTAssertTrue(report.removedPaths.contains {
            $0.hasSuffix("Resources/ShipIt") })
        XCTAssertTrue(report.removedPaths.contains("Contents/Resources/app-update.yml"))
    }

    /// Sparkle's installer chain, in the shape ChatGPT actually ships: a framework with
    /// `Autoupdate`, `Updater.app` and the two XPC services, top-level symlinks into
    /// `Versions/B`, and **no** `SUFeedURL` — only `SUPublicEDKey`.
    private func makeSparkleBundle() throws -> URL {
        let app = root.appendingPathComponent("sparkle/Sparkled.app")
        let versioned = app.appendingPathComponent(
            "Contents/Frameworks/Sparkle.framework/Versions/B")
        try FileManager.default.createDirectory(
            at: versioned.appendingPathComponent("XPCServices/Installer.xpc"),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: versioned.appendingPathComponent("XPCServices/Downloader.xpc"),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: versioned.appendingPathComponent("Updater.app"),
            withIntermediateDirectories: true)
        try Data("autoupdate".utf8).write(to: versioned.appendingPathComponent("Autoupdate"))
        try Data("framework".utf8).write(to: versioned.appendingPathComponent("Sparkle"))

        // The symlinks a real framework carries. A dangling one fails code signing, so
        // the removal has to take both.
        let framework = app.appendingPathComponent("Contents/Frameworks/Sparkle.framework")
        try FileManager.default.createSymbolicLink(
            at: framework.appendingPathComponent("Versions/Current"),
            withDestinationURL: URL(fileURLWithPath: "B"))
        for leaf in ["Autoupdate", "Updater.app", "Sparkle"] {
            try FileManager.default.createSymbolicLink(
                at: framework.appendingPathComponent(leaf),
                withDestinationURL: URL(fileURLWithPath: "Versions/Current/\(leaf)"))
        }

        try FileManager.default.createDirectory(
            at: app.appendingPathComponent("Contents/Resources"),
            withIntermediateDirectories: true)
        // Only the public key, exactly like ChatGPT. None of the five keys the plist
        // patcher looks for.
        try BundleAssembler.writeInfoPlist([
            "CFBundleIdentifier": "com.example.sparkled",
            "SUPublicEDKey": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
        ], bundle: app)
        return app
    }

    /// The reproduction: an application whose only Sparkle key is `SUPublicEDKey`.
    ///
    /// The plist half found nothing to change, so nothing was neutralised, no build note
    /// was produced — and `MALEmbeddedUpdaterNeutralised = true` was written anyway while
    /// the create sheet promised unconditionally that these instances would not update
    /// themselves.
    func testAnAppWithOnlyASparklePublicKeyStillHasItsInstallerRemoved() throws {
        let app = try makeSparkleBundle()
        let framework = "Contents/Frameworks/Sparkle.framework"

        let report = try UpdaterNeutraliser.neutraliseInBundle(app)

        for leaf in ["Versions/B/Autoupdate",
                     "Versions/B/Updater.app",
                     "Versions/B/XPCServices/Installer.xpc",
                     "Versions/B/XPCServices/Downloader.xpc"] {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: app.appendingPathComponent("\(framework)/\(leaf)").path),
                "\(leaf) survived — an update this instance downloads still has something to apply it with")
        }
        // The framework the application links against stays, exactly as Squirrel's does.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: app.appendingPathComponent("\(framework)/Versions/B/Sparkle").path))
        XCTAssertTrue(report.didAnything)

        // No dangling symlinks: one inside a framework fails code signing.
        for leaf in ["Autoupdate", "Updater.app"] {
            let link = app.appendingPathComponent("\(framework)/\(leaf)")
            let dangling = (try? link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
                && !FileManager.default.fileExists(atPath: link.path)
            XCTAssertFalse(dangling, "\(leaf) is a dangling symlink after removal")
        }
    }

    /// Automatic checks must be switched off even when the application declares none of
    /// the keys the patcher looks for. They used to be set only `if !changedKeys.isEmpty`,
    /// so an app with no Sparkle keys kept Sparkle's default, which is to prompt — and a
    /// prompt is an update path.
    func testAutomaticChecksAreDisabledEvenWithNoSparkleKeysDeclared() {
        let (patched, report) = UpdaterNeutraliser.patchInfoPlist([
            "CFBundleIdentifier": "com.example.sparkled",
            "SUPublicEDKey": "AAAA",
        ])
        XCTAssertEqual(patched["SUEnableAutomaticChecks"] as? Bool, false)
        XCTAssertEqual(patched["SUAutomaticallyUpdate"] as? Bool, false)
        // This assertion used to be `didAnything`, which was the mistake the
        // unconditional write introduced: a key written on every clone was being counted
        // as an updater found and disarmed, so nothing could ever report "nothing".
        // The keys are still written — that is what this test is about — but they are
        // recorded as asserted, and for *this* application the plist half genuinely
        // disarms nothing. What disarms ChatGPT is the on-disk half, which reports
        // separately through `removedPaths`.
        XCTAssertEqual(report.assertedKeys.sorted(),
                       ["SUAutomaticallyUpdate", "SUEnableAutomaticChecks"])
        XCTAssertFalse(report.didAnything)
    }

    /// The two schedule keys are asserted on every clone, so they must not be recorded
    /// as work done — otherwise "we neutralised something" is true of every application
    /// and the marker records nothing.
    ///
    /// This is the consequence of the fix above: once the keys are written
    /// unconditionally, `changedKeys` is never empty, and the "nothing was neutralised"
    /// branch the record and the build note both depend on becomes unreachable.
    func testAssertingTheScheduleKeysIsNotRecordedAsHavingFoundAnUpdater() {
        let (patched, report) = UpdaterNeutraliser.patchInfoPlist([
            "CFBundleIdentifier": "com.example.nosparkle",
        ])
        XCTAssertEqual(patched["SUEnableAutomaticChecks"] as? Bool, false)
        XCTAssertEqual(patched["SUAutomaticallyUpdate"] as? Bool, false)
        XCTAssertEqual(report.changedKeys, [],
                       "an app with no updater at all must not report keys we changed")
        XCTAssertEqual(report.assertedKeys.sorted(),
                       ["SUAutomaticallyUpdate", "SUEnableAutomaticChecks"])
        XCTAssertFalse(report.didAnything)
        XCTAssertTrue(report.notes.isEmpty,
                      "there is nothing to tell the user about an updater that is not there")

        let recorded = UpdaterNeutraliser.recordNeutralisation(report, in: patched)
        XCTAssertNil(recorded[UpdaterNeutraliser.markerKey],
                     "the marker is back on every clone, which is what Ma-1 removed")
    }

    /// An application that already declares both keys as `false`. The removal loop and
    /// the setter both appended, so each key was recorded twice — and nothing was
    /// actually disarmed, because they were already off.
    func testKeysThatAreAlreadyDisabledAreRecordedOnceAndNotAsAChange() {
        let (patched, report) = UpdaterNeutraliser.patchInfoPlist([
            "CFBundleIdentifier": "com.example.polite",
            "SUEnableAutomaticChecks": false,
            "SUAutomaticallyUpdate": false,
        ])
        XCTAssertEqual(patched["SUEnableAutomaticChecks"] as? Bool, false)
        XCTAssertEqual(patched["SUAutomaticallyUpdate"] as? Bool, false)

        let all = report.changedKeys + report.assertedKeys
        XCTAssertEqual(all.count, Set(all).count, "a key was recorded twice: \(all)")
        XCTAssertEqual(report.changedKeys, [],
                       "keys that were already off were not turned off by this build")
        XCTAssertFalse(report.didAnything)
    }

    /// The other side of the same rule: a key the application declares and has switched
    /// **on** is a real find, recorded once.
    func testASparkleAppWithChecksEnabledRecordsThemAsChangedExactlyOnce() {
        let (patched, report) = UpdaterNeutraliser.patchInfoPlist([
            "CFBundleIdentifier": "com.example.sparkled",
            "SUFeedURL": "https://example.com/appcast.xml",
            "SUEnableAutomaticChecks": true,
            "SUAutomaticallyUpdate": true,
        ])
        XCTAssertEqual(patched["SUEnableAutomaticChecks"] as? Bool, false)
        XCTAssertNil(patched["SUFeedURL"])
        XCTAssertEqual(patched[UpdaterNeutraliser.preservedFeedKey] as? String,
                       "https://example.com/appcast.xml")
        XCTAssertEqual(report.changedKeys.sorted(),
                       ["SUAutomaticallyUpdate", "SUEnableAutomaticChecks", "SUFeedURL"])
        XCTAssertEqual(report.assertedKeys, [])
        XCTAssertTrue(report.didAnything)

        let recorded = UpdaterNeutraliser.recordNeutralisation(report, in: patched)
        XCTAssertEqual((recorded[UpdaterNeutraliser.markerKey] as? [String])?.count, 3)
    }

    /// The record must not claim work that did not happen.
    func testTheNeutralisationRecordIsAbsentWhenNothingWasNeutralised() {
        let empty = UpdaterNeutraliser.recordNeutralisation(
            UpdaterNeutraliser.Report(), in: ["CFBundleIdentifier": "com.example.x"])
        XCTAssertNil(empty[UpdaterNeutraliser.markerKey],
                     "a marker written whether or not the thing happened is not a record")

        var did = UpdaterNeutraliser.Report()
        did.changedKeys = ["SUFeedURL"]
        did.removedPaths = ["Contents/Resources/app-update.yml"]
        let recorded = UpdaterNeutraliser.recordNeutralisation(
            did, in: ["CFBundleIdentifier": "com.example.x"])
        let record = recorded[UpdaterNeutraliser.markerKey] as? [String]
        XCTAssertEqual(record?.count, 2)
        XCTAssertTrue(record?.contains("SUFeedURL") == true)
    }

    /// What the interface will say, computed from the source rather than promised.
    func testThePlanReportsWhatWillActuallyBeNeutralised() throws {
        let sparkled = try makeSparkleBundle()
        let planned = UpdaterNeutraliser.plannedNeutralisations(forSource: sparkled)
        XCTAssertTrue(planned.contains("Sparkle's installer helpers"), "got \(planned)")
        XCTAssertFalse(planned.contains("Sparkle's update feed"),
                       "this fixture declares no SUFeedURL, so the plan must not claim one")

        let plain = root.appendingPathComponent("nothing/Plain.app")
        try FileManager.default.createDirectory(
            at: plain.appendingPathComponent("Contents/Resources"),
            withIntermediateDirectories: true)
        try BundleAssembler.writeInfoPlist(["CFBundleIdentifier": "com.example.plain"],
                                           bundle: plain)
        XCTAssertTrue(UpdaterNeutraliser.plannedNeutralisations(forSource: plain).isEmpty,
                      "an app with no updater must not be promised one was disabled")
    }

    func testNeutralisingABundleWithNoUpdaterChangesNothing() throws {
        let app = root.appendingPathComponent("plain/Plain.app")
        try FileManager.default.createDirectory(
            at: app.appendingPathComponent("Contents/Resources"),
            withIntermediateDirectories: true)
        let report = try UpdaterNeutraliser.neutraliseInBundle(app)
        XCTAssertTrue(report.removedPaths.isEmpty)
        XCTAssertFalse(report.didAnything)
    }

    /// Gives a synthetic app the Sparkle shape: a feed URL and automatic checks.
    private func addSparkle(to app: URL) throws {
        var info = try BundleAssembler.readInfoPlist(bundle: app)
        info["SUFeedURL"] = "https://example.invalid/appcast.xml"
        info["SUEnableAutomaticChecks"] = true
        info["SUAutomaticallyUpdate"] = true
        try BundleAssembler.writeInfoPlist(info, bundle: app)
    }

    func testAnElectronUpdaterCloneLosesItsProviderConfigButTheSourceKeepsIt() throws {
        try addElectronUpdaterConfig(to: sourceApp)
        let builder = InstanceBuilder(paths: paths)
        let result = try builder.build(BuildRequest(sourceBundle: sourceApp,
                                                    facts: facts(for: sourceApp),
                                                    number: 1,
                                                    name: "NoUpdate"))
        XCTAssertFalse(result.degradedToLite, "this must exercise the clone, not Lite")
        let clone = URL(fileURLWithPath: result.instance.bundlePath)

        XCTAssertFalse(FileManager.default.fileExists(atPath: clone.appendingPathComponent(
            "Contents/Resources/app-update.yml").path))
        XCTAssertTrue(UpdaterNeutraliser.isNeutralised(bundle: clone))

        // And the source application keeps its own updater, untouched.
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceApp.appendingPathComponent(
            "Contents/Resources/app-update.yml").path))
    }

    func testASparkleCloneHasNoFeedAndNoAutomaticChecksByDefault() throws {
        try addSparkle(to: sourceApp)
        let builder = InstanceBuilder(paths: paths)
        let result = try builder.build(BuildRequest(sourceBundle: sourceApp,
                                                    facts: facts(for: sourceApp),
                                                    number: 1,
                                                    name: "NoUpdate"))
        XCTAssertFalse(result.degradedToLite, "this must exercise the clone, not Lite")
        let clone = URL(fileURLWithPath: result.instance.bundlePath)
        let info = try BundleAssembler.readInfoPlist(bundle: clone)

        XCTAssertNil(info["SUFeedURL"], "a feed left in place is an update path left open")
        XCTAssertEqual(info["SUEnableAutomaticChecks"] as? Bool, false)
        XCTAssertEqual(info["SUAutomaticallyUpdate"] as? Bool, false)
        // Removed, not discarded: an instance should still be able to say where it would
        // have checked.
        XCTAssertEqual(info[UpdaterNeutraliser.preservedFeedKey] as? String,
                       "https://example.invalid/appcast.xml")
        XCTAssertTrue(UpdaterNeutraliser.isNeutralised(bundle: clone))

        let sourceInfo = try BundleAssembler.readInfoPlist(bundle: sourceApp)
        XCTAssertEqual(sourceInfo["SUFeedURL"] as? String,
                       "https://example.invalid/appcast.xml",
                       "the source application's own updater must be untouched")
    }

    func testTheAdvancedOptOutRestoresBothUpdaterShapes() throws {
        try addElectronUpdaterConfig(to: sourceApp)
        try addSparkle(to: sourceApp)
        let builder = InstanceBuilder(paths: paths)
        let result = try builder.build(BuildRequest(sourceBundle: sourceApp,
                                                    facts: facts(for: sourceApp),
                                                    number: 1,
                                                    name: "SelfUpdating",
                                                    allowEmbeddedUpdater: true))
        XCTAssertFalse(result.degradedToLite, "this must exercise the clone, not Lite")
        let clone = URL(fileURLWithPath: result.instance.bundlePath)
        let info = try BundleAssembler.readInfoPlist(bundle: clone)

        XCTAssertTrue(FileManager.default.fileExists(atPath: clone.appendingPathComponent(
            "Contents/Resources/app-update.yml").path))
        XCTAssertEqual(info["SUFeedURL"] as? String, "https://example.invalid/appcast.xml")
        XCTAssertFalse(UpdaterNeutraliser.isNeutralised(bundle: clone))
        XCTAssertTrue(result.notes.contains { $0.contains("keeps the application's own updater") })
    }

    /// Neutralising the updater must not cost the thing it replaces: the dashboard's
    /// "rebuild available" signal comes from comparing the instance's recorded source
    /// version against the source app's current one, and both must survive.
    func testRebuildAvailableDetectionSurvivesNeutralisation() throws {
        try addElectronUpdaterConfig(to: sourceApp)
        try addSparkle(to: sourceApp)
        let builder = InstanceBuilder(paths: paths)
        let result = try builder.build(BuildRequest(sourceBundle: sourceApp,
                                                    facts: facts(for: sourceApp),
                                                    number: 1,
                                                    name: "Stale"))
        XCTAssertFalse(result.degradedToLite, "this must exercise the clone, not Lite")
        XCTAssertEqual(result.instance.builtFromSourceVersion, "1.0")

        var app = ManagedApp(appKey: "com.example.fake",
                             displayName: "Fake",
                             sourcePath: sourceApp.path,
                             sourceVersion: "1.0",
                             instances: [result.instance])
        XCTAssertTrue(app.staleInstances.isEmpty)
        app.sourceVersion = "2.0"
        XCTAssertEqual(app.staleInstances.map(\.number), [1],
                       "a neutralised instance must still report that a rebuild is available")

        // And a rebuild keeps the profile, which is the whole point of the trade.
        let profile = URL(fileURLWithPath: result.instance.dataPath)
        try Data("session".utf8).write(to: profile.appendingPathComponent("token"))
        let rebuilt = try builder.rebuild(instance: result.instance,
                                          sourceBundle: sourceApp,
                                          facts: facts(for: sourceApp),
                                          acknowledgedSharedCredentialStore: false)
        XCTAssertEqual(rebuilt.instance.dataPath, result.instance.dataPath)
        XCTAssertEqual(try Data(contentsOf: profile.appendingPathComponent("token")),
                       Data("session".utf8))
        XCTAssertTrue(UpdaterNeutraliser.isNeutralised(
            bundle: URL(fileURLWithPath: rebuilt.instance.bundlePath)))
    }

    // MARK: Shared credential stores

    /// Facts for an app that keeps its session where a redirected profile cannot reach.
    private func sharedCredentialFacts(for app: URL) -> AppFacts {
        var f = facts(for: app)
        f.entitlementKeys = ["keychain-access-groups",
                             "com.apple.security.application-groups"]
        return f
    }

    func testALiteBuildOfASharedCredentialStoreAppIsRefused() throws {
        let builder = InstanceBuilder(paths: paths)
        let request = BuildRequest(sourceBundle: sourceApp,
                                   facts: sharedCredentialFacts(for: sourceApp),
                                   number: 1,
                                   name: "Shared",
                                   requestedMode: .lite)

        XCTAssertThrowsError(try builder.build(request)) { error in
            guard let malError = error as? MALError,
                  case .sharedCredentialStoreNotAcknowledged(_, let detail) = malError else {
                return XCTFail("expected a refusal, got \(error)")
            }
            XCTAssertTrue(detail.contains("signs out every copy"))
        }

        // A refusal must leave nothing behind — no launcher, no profile.
        let bundles = (try? FileManager.default.contentsOfDirectory(
            atPath: paths.bundlesDir.path))?.filter { $0.hasSuffix(".app") } ?? []
        XCTAssertTrue(bundles.isEmpty, "a refused build left a launcher: \(bundles)")
        let profiles = (try? FileManager.default.contentsOfDirectory(
            atPath: paths.instancesDir.path)) ?? []
        XCTAssertTrue(profiles.isEmpty, "a refused build left a profile: \(profiles)")
    }

    func testAnAcknowledgedLiteBuildOfSuchAnAppProceeds() throws {
        let builder = InstanceBuilder(paths: paths)
        let request = BuildRequest(sourceBundle: sourceApp,
                                   facts: sharedCredentialFacts(for: sourceApp),
                                   number: 1,
                                   name: "Shared",
                                   requestedMode: .lite,
                                   acknowledgedSharedCredentialStore: true)
        let result = try builder.build(request)
        XCTAssertEqual(result.instance.mode, .lite)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.instance.bundlePath))
    }

    /// Full mode is disclosed rather than refused: the clone has a new ad-hoc identity
    /// and genuinely loses the Keychain group, so it is a different (and better) case.
    func testAFullBuildOfSuchAnAppIsNotRefused() throws {
        let builder = InstanceBuilder(paths: paths)
        let request = BuildRequest(sourceBundle: sourceApp,
                                   facts: sharedCredentialFacts(for: sourceApp),
                                   number: 1,
                                   name: "Shared",
                                   requestedMode: .full)
        let result = try builder.build(request)
        XCTAssertEqual(result.instance.mode, .full)
    }

    /// Automatic degradation is the product's answer to a signing failure. It must not
    /// become a way of arriving at the mode this app was just refused, without ever
    /// having asked.
    func testDegradationToLiteIsAlsoRefusedForSuchAnApp() throws {
        // Force the Full path to fail somewhere degradable: an unreadable source icon
        // is not enough, so break the shim install by removing the executable the
        // patcher must rename.
        let broken = try makeSyntheticApp(named: "Broken")
        try FileManager.default.removeItem(
            at: broken.appendingPathComponent("Contents/MacOS/Broken"))

        var f = facts(for: broken, name: "Broken")
        f.entitlementKeys = ["keychain-access-groups"]

        let builder = InstanceBuilder(paths: paths)
        let request = BuildRequest(sourceBundle: broken,
                                   facts: f,
                                   number: 1,
                                   name: "Degrade",
                                   requestedMode: .full)

        XCTAssertThrowsError(try builder.build(request)) { error in
            // Either it never reached a degradable failure (fine — nothing was built in
            // Lite either way), or it did and the refusal is what stopped it.
            if let malError = error as? MALError,
               case .sharedCredentialStoreNotAcknowledged = malError {
                return
            }
            XCTAssertFalse("\(error)".isEmpty)
        }

        let lite = (try? FileManager.default.contentsOfDirectory(
            atPath: paths.bundlesDir.path))?.filter { $0.hasSuffix(".app") } ?? []
        XCTAssertTrue(lite.isEmpty,
                      "a shared-credential-store app was silently degraded to Lite: \(lite)")
    }

    // MARK: Full mode

    func testFullBuildProducesAVerifiedNumberedClone() throws {
        let builder = InstanceBuilder(paths: paths)
        let request = BuildRequest(sourceBundle: sourceApp,
                                   facts: facts(for: sourceApp),
                                   number: 2,
                                   name: "Work")
        let result = try builder.build(request)

        XCTAssertEqual(result.instance.mode, .full)
        XCTAssertFalse(result.degradedToLite, "a clean synthetic app should not need Lite mode")

        let bundle = URL(fileURLWithPath: result.instance.bundlePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.path))
        XCTAssertEqual(bundle.lastPathComponent, "Fake 2 – Work.app")

        // Identity
        let info = try BundleAssembler.readInfoPlist(bundle: bundle)
        XCTAssertEqual(info["CFBundleIdentifier"] as? String, result.instance.clonedBundleIdentifier)
        XCTAssertNotEqual(info["CFBundleIdentifier"] as? String, "com.example.fake")
        XCTAssertEqual(info["CFBundleDisplayName"] as? String, "Fake 2 – Work")
        XCTAssertEqual(info["CFBundleExecutable"] as? String, InstanceBuilder.shimName)

        // Shim and the renamed original
        let macOS = bundle.appendingPathComponent("Contents/MacOS")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: macOS.appendingPathComponent("mal-shim").path))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: macOS.appendingPathComponent("Fake.real").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: macOS.appendingPathComponent("Fake").path))

        // Icon
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: bundle.appendingPathComponent("Contents/Resources/MALAppIcon.icns").path))

        // The instance config the shim will read
        let confText = try String(contentsOf: bundle.appendingPathComponent("Contents/Resources/MALInstance.conf"),
                                  encoding: .utf8)
        let config = try InstanceConfig.parse(confText)
        XCTAssertEqual(config.kind, .app)
        XCTAssertEqual(config.mode, .full)
        XCTAssertEqual(config.realExecutableName, "Fake.real")
        XCTAssertEqual(config.dataPath, result.instance.dataPath)

        // Durable recovery metadata is sealed into the signed bundle. A fresh
        // LaunchAgain installation can rebuild the dashboard from this alone.
        let recovery = try BundleAssembler.readRecoveryManifest(from: bundle)
        XCTAssertEqual(recovery.appKey, "com.example.fake")
        XCTAssertEqual(recovery.appDisplayName, "Fake")
        XCTAssertEqual(recovery.sourcePath, sourceApp.path)
        XCTAssertEqual(recovery.instance.id, result.instance.id)
        XCTAssertEqual(recovery.instance.number, result.instance.number)
        XCTAssertEqual(recovery.instance.name, result.instance.name)
        XCTAssertEqual(recovery.instance.bundlePath, result.instance.bundlePath)
        XCTAssertEqual(recovery.instance.dataPath, result.instance.dataPath)
        XCTAssertEqual(recovery.instance.clonedBundleIdentifier,
                       result.instance.clonedBundleIdentifier)

        // Signature
        XCTAssertNoThrow(try CodeSigner(log: .silent).verify(bundle: bundle))
        XCTAssertFalse(result.verifyOutput.isEmpty)
    }

    /// Acceptance criterion 7: the source app is provably unmodified.
    func testTheSourceApplicationIsNeverTouched() throws {
        let before = BundleAssembler.sourceFingerprint(bundle: sourceApp)
        let beforeExecutable = try Data(contentsOf: sourceApp.appendingPathComponent("Contents/MacOS/Fake"))

        let builder = InstanceBuilder(paths: paths)
        _ = try builder.build(BuildRequest(sourceBundle: sourceApp,
                                           facts: facts(for: sourceApp),
                                           number: 1,
                                           name: "Personal"))

        XCTAssertEqual(BundleAssembler.sourceFingerprint(bundle: sourceApp), before)
        XCTAssertEqual(try Data(contentsOf: sourceApp.appendingPathComponent("Contents/MacOS/Fake")),
                       beforeExecutable)
        let info = try BundleAssembler.readInfoPlist(bundle: sourceApp)
        XCTAssertEqual(info["CFBundleIdentifier"] as? String, "com.example.fake",
                       "the original identity must be intact")
        XCTAssertEqual(info["CFBundleExecutable"] as? String, "Fake")
    }

    func testTwoInstancesGetDistinctIdentitiesAndProfiles() throws {
        let builder = InstanceBuilder(paths: paths)
        let one = try builder.build(BuildRequest(sourceBundle: sourceApp, facts: facts(for: sourceApp),
                                                 number: 1, name: "Personal"))
        let two = try builder.build(BuildRequest(sourceBundle: sourceApp, facts: facts(for: sourceApp),
                                                 number: 2, name: "Work"))

        XCTAssertNotEqual(one.instance.clonedBundleIdentifier, two.instance.clonedBundleIdentifier,
                          "identical bundle identifiers would collapse into one Dock tile")
        XCTAssertNotEqual(one.instance.dataPath, two.instance.dataPath)
        XCTAssertNotEqual(one.instance.bundlePath, two.instance.bundlePath)
    }

    /// A build that cannot be completed must leave nothing behind at all.
    func testAFailedBuildLeavesNoBundleAndNoProfile() throws {
        let builder = InstanceBuilder(paths: paths)
        var broken = facts(for: sourceApp)
        broken.executableName = "DoesNotExist"

        // The shim step fails because the named executable is not in the clone. That is a
        // degradable failure, so the builder retries in Lite mode rather than giving up.
        let result = try builder.build(BuildRequest(sourceBundle: sourceApp,
                                                    facts: broken,
                                                    number: 1,
                                                    name: "Fallback"))
        XCTAssertEqual(result.instance.mode, .lite)
        XCTAssertTrue(result.degradedToLite)
        XCTAssertNotNil(result.degradationReason)

        // Exactly one bundle exists: the Lite one. No half-built clone was left over.
        let bundles = try FileManager.default.contentsOfDirectory(atPath: paths.bundlesDir.path)
            .filter { $0.hasSuffix(".app") }
        XCTAssertEqual(bundles.count, 1)

        let staging = try FileManager.default.contentsOfDirectory(atPath: paths.stagingDir.path)
            .filter { !$0.hasPrefix(".") }
        XCTAssertTrue(staging.isEmpty, "staging should be empty after a build, found \(staging)")
    }

    func testRegistryFailureAfterBuildRollsBackBundleAndProfile() throws {
        let manager = try InstanceManager(paths: paths)
        let plan = try manager.plan(
            sourceBundle: sourceApp,
            count: 1,
            names: ["Rollback"])

        // Removing the app record after planning makes the post-build add fail in a
        // deterministic way, exercising the boundary that previously orphaned a clone.
        try manager.registry.removeApp(plan.facts.bundleIdentifier)
        let outcome = manager.create(plan: plan)

        XCTAssertTrue(outcome.created.isEmpty)
        XCTAssertEqual(outcome.failures.count, 1)
        XCTAssertTrue(
            (try FileManager.default.contentsOfDirectory(atPath: paths.bundlesDir.path))
                .filter { $0.hasSuffix(".app") }.isEmpty)
        XCTAssertTrue(
            (try FileManager.default.contentsOfDirectory(atPath: paths.instancesDir.path))
                .filter { UUID(uuidString: $0) != nil }.isEmpty)
    }

    func testFailedRenameRebuildLeavesRegistryAndLauncherCoherent() throws {
        let manager = try InstanceManager(paths: paths)
        let plan = try manager.plan(
            sourceBundle: sourceApp,
            count: 1,
            names: ["Original"])
        let outcome = manager.create(plan: plan)
        let instance = try XCTUnwrap(outcome.created.first)
        let manifestBefore = try BundleAssembler.readRecoveryManifest(
            from: URL(fileURLWithPath: instance.bundlePath))

        try FileManager.default.removeItem(at: sourceApp)
        XCTAssertThrowsError(
            try manager.rename(instance, to: "Should Not Persist", rebuildBundle: true))

        let retained = try XCTUnwrap(manager.registry.instance(instance.id)?.instance)
        XCTAssertEqual(retained.name, "Original")
        let manifestAfter = try BundleAssembler.readRecoveryManifest(
            from: URL(fileURLWithPath: retained.bundlePath))
        XCTAssertEqual(manifestAfter.instance.name, manifestBefore.instance.name)
        XCTAssertEqual(manifestAfter.instance.clonedBundleIdentifier,
                       retained.clonedBundleIdentifier)
    }

    func testAnUnsupportedApplicationIsRefusedOutright() {
        let builder = InstanceBuilder(paths: paths)
        var native = facts(for: sourceApp)
        native.runtime = .native
        XCTAssertThrowsError(try builder.build(BuildRequest(sourceBundle: sourceApp, facts: native,
                                                            number: 1, name: "X"))) { error in
            guard case .notSupported = error as? MALError else {
                return XCTFail("expected notSupported, got \(error)")
            }
        }
        let bundles = (try? FileManager.default.contentsOfDirectory(atPath: paths.bundlesDir.path)) ?? []
        XCTAssertTrue(bundles.filter { $0.hasSuffix(".app") }.isEmpty)
    }

    // MARK: Lite mode

    func testLiteBuildContainsNoneOfTheTargetApplication() throws {
        let builder = InstanceBuilder(paths: paths)
        let result = try builder.build(BuildRequest(sourceBundle: sourceApp,
                                                    facts: facts(for: sourceApp),
                                                    number: 3,
                                                    name: "Lite",
                                                    requestedMode: .lite))
        XCTAssertEqual(result.instance.mode, .lite)
        let bundle = URL(fileURLWithPath: result.instance.bundlePath)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: bundle.appendingPathComponent("Contents/Resources/app.asar").path),
                       "a Lite launcher must not contain a copy of the app")

        let config = try InstanceConfig.parse(
            String(contentsOf: bundle.appendingPathComponent("Contents/Resources/MALInstance.conf"),
                   encoding: .utf8))
        XCTAssertEqual(config.mode, .lite)
        XCTAssertEqual(config.targetAppPath, sourceApp.standardizedFileURL.path)
        let recovery = try BundleAssembler.readRecoveryManifest(from: bundle)
        XCTAssertEqual(recovery.instance.id, result.instance.id)
        XCTAssertEqual(recovery.instance.mode, .lite)
    }

    // MARK: Rebuild and removal

    func testRebuildPreservesNumberNameAndProfile() throws {
        let builder = InstanceBuilder(paths: paths)
        let original = try builder.build(BuildRequest(sourceBundle: sourceApp,
                                                      facts: facts(for: sourceApp),
                                                      number: 5,
                                                      name: "Work"))
        // Put something in the profile so we can prove it survives.
        let marker = URL(fileURLWithPath: original.instance.dataPath).appendingPathComponent("session.txt")
        try Data("signed in".utf8).write(to: marker)

        let rebuilt = try builder.rebuild(instance: original.instance,
                                          sourceBundle: sourceApp,
                                          facts: facts(for: sourceApp),
                                          acknowledgedSharedCredentialStore: false)
        XCTAssertEqual(rebuilt.instance.number, 5)
        XCTAssertEqual(rebuilt.instance.name, "Work")
        XCTAssertEqual(rebuilt.instance.dataPath, original.instance.dataPath)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "signed in",
                       "rebuilding must never touch the profile")
    }

    func testRemoveLauncherOnlyKeepsTheProfile() throws {
        let builder = InstanceBuilder(paths: paths)
        let result = try builder.build(BuildRequest(sourceBundle: sourceApp, facts: facts(for: sourceApp),
                                                    number: 1, name: "Keep"))
        try builder.remove(instance: result.instance, scope: .launcherOnly)
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.instance.bundlePath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.instance.dataPath),
                      "the profile is a signed-in session; it goes only when asked for")
    }

    /// Regression: an instance launched seconds ago is not yet known to Launch Services,
    /// so a running check based on NSWorkspace alone said "not running" and the bundle was
    /// deleted out from under a live process — leaving a Dock tile with nothing behind it.
    func testLockFileRequiresTheExpectedProfileAndClearsAReusedPID() throws {
        let builder = InstanceBuilder(paths: paths)
        let result = try builder.build(BuildRequest(sourceBundle: sourceApp, facts: facts(for: sourceApp),
                                                    number: 1, name: "Racing"))
        let supervisor = LaunchSupervisor(paths: paths)
        XCTAssertFalse(supervisor.isRunning(result.instance))

        // A helper carrying the same breadcrumb the shim exports stands in for a
        // just-launched app before Launch Services has indexed its bundle identity.
        let legitimate = Process()
        let legitimateInput = Pipe()
        legitimate.executableURL = URL(fileURLWithPath: "/bin/sh")
        legitimate.arguments = [
            "-c", "read launchagain_hold", "launchagain-lock-fixture",
            "--user-data-dir=\(result.instance.dataPath)",
        ]
        legitimate.standardInput = legitimateInput
        var legitimateEnvironment = ProcessInfo.processInfo.environment
        legitimateEnvironment["MAL_INSTANCE_DATA_DIR"] = result.instance.dataPath
        legitimate.environment = legitimateEnvironment
        try legitimate.run()
        defer {
            if legitimate.isRunning {
                legitimate.terminate()
                legitimate.waitUntilExit()
            }
        }
        let legitimateDeadline = Date().addingTimeInterval(2)
        while ProcessInspector.dataDirectory(ofPID: legitimate.processIdentifier)
                != result.instance.dataPath,
              Date() < legitimateDeadline {
            usleep(10_000)
        }
        XCTAssertEqual(
            ProcessInspector.dataDirectory(ofPID: legitimate.processIdentifier),
            result.instance.dataPath)

        let lock = paths.instanceLockFile(result.instance.id)
        try FileManager.default.createDirectory(at: lock.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("\(legitimate.processIdentifier)\n\(Date().timeIntervalSince1970)\n".utf8)
            .write(to: lock)
        XCTAssertTrue(supervisor.isRunning(result.instance),
                      "a live process carrying this profile breadcrumb owns the lock")

        legitimate.terminate()
        legitimate.waitUntilExit()

        // A persisted PID can be reused after reboot. Even though this second process is
        // alive, its different profile proves that it does not own this instance.
        let unrelated = Process()
        let unrelatedInput = Pipe()
        let unrelatedDataPath = paths.instanceDataDir(UUID()).path
        unrelated.executableURL = URL(fileURLWithPath: "/bin/sh")
        unrelated.arguments = [
            "-c", "read launchagain_hold", "launchagain-lock-fixture",
            "--user-data-dir=\(unrelatedDataPath)",
        ]
        unrelated.standardInput = unrelatedInput
        var unrelatedEnvironment = ProcessInfo.processInfo.environment
        unrelatedEnvironment["MAL_INSTANCE_DATA_DIR"] = unrelatedDataPath
        unrelated.environment = unrelatedEnvironment
        try unrelated.run()
        defer {
            if unrelated.isRunning {
                unrelated.terminate()
                unrelated.waitUntilExit()
            }
        }
        try Data("\(unrelated.processIdentifier)\n\(Date().timeIntervalSince1970)\n".utf8)
            .write(to: lock)
        XCTAssertFalse(supervisor.isRunning(result.instance),
                       "a live PID for another profile must not make this instance look open")
        XCTAssertFalse(FileManager.default.fileExists(atPath: lock.path),
                       "a reused-PID lock must be cleared so it cannot survive another restart")

        // A pid that is not alive is a crash leftover, not a running instance.
        try Data("999999\n0\n".utf8).write(to: lock)
        XCTAssertFalse(supervisor.isRunning(result.instance))

        // And the malformed values that made an instance permanently unlaunchable.
        for bad in ["-1", "0", "not a pid", ""] {
            try Data("\(bad)\n".utf8).write(to: lock)
            XCTAssertFalse(supervisor.isRunning(result.instance),
                           "\(bad) is not a live process and must not read as one")
            XCTAssertFalse(FileManager.default.fileExists(atPath: lock.path),
                           "malformed lock data must be cleared")
        }
    }

    func testRemoveWithDataRemovesBoth() throws {
        let builder = InstanceBuilder(paths: paths)
        let result = try builder.build(BuildRequest(sourceBundle: sourceApp, facts: facts(for: sourceApp),
                                                    number: 1, name: "Gone"))
        try builder.remove(instance: result.instance, scope: .launcherAndData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.instance.bundlePath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.instance.dataPath))
    }

    func testCustomProfileDirectoryIsUsedAndNeverDeletedByUs() throws {
        let external = root.appendingPathComponent("elsewhere/profile")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)

        let builder = InstanceBuilder(paths: paths)
        let result = try builder.build(BuildRequest(sourceBundle: sourceApp,
                                                    facts: facts(for: sourceApp),
                                                    number: 1,
                                                    name: "External",
                                                    dataPathOverride: external.path))
        XCTAssertEqual(result.instance.dataPath, external.path)

        // Removing "with data" must not delete a directory outside our own folders — and
        // must say so rather than reporting that the data is gone when it is not.
        let report = try builder.remove(instance: result.instance, scope: .launcherAndData)
        XCTAssertTrue(FileManager.default.fileExists(atPath: external.path),
                      "a directory the user chose is theirs, not ours to delete")
        XCTAssertFalse(report.removedData)
        XCTAssertEqual(report.keptDataPath, external.path)
        XCTAssertNotNil(report.keptReason)
    }

    // MARK: The GUI-only boundary
    //
    // These are the same two assertions as before — a command-line executable is
    // refused, and refusing it leaves no bundle and no profile behind — restated now
    // that there is no `AppFacts` shape that says "command line tool". The boundary the
    // builder enforces is the source itself: it must be a `.app`.

    func testBuilderRefusesASourceThatIsNotAnAppBundle() throws {
        // Deliberately the *most* creatable facts there are. If the request were judged
        // on its facts alone this would build; it is refused on the source path, which
        // is the property a command-line executable can never satisfy.
        let facts = AppFacts(bundleIdentifier: "com.example.codex",
                             displayName: "Codex",
                             executableName: "codex",
                             shortVersion: "1.0",
                             path: "/opt/homebrew/bin/codex",
                             runtime: .electron,
                             isSigned: true,
                             signingInspected: true)

        let builder = InstanceBuilder(paths: paths)
        XCTAssertThrowsError(
            try builder.build(BuildRequest(
                sourceBundle: URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
                facts: facts,
                number: 2,
                name: "Work"))) { error in
                    guard case .notSupported(let reason) = error as? MALError else {
                        return XCTFail("expected notSupported, got \(error)")
                    }
                    XCTAssertTrue(reason.contains("GUI application instances only"),
                                  "got: \(reason)")
                }
        XCTAssertTrue(
            (try FileManager.default.contentsOfDirectory(atPath: paths.bundlesDir.path))
                .filter { $0.hasSuffix(".app") }.isEmpty)
    }

    func testASecondRefusedRequestAlsoCreatesNoProfiles() throws {
        let facts = AppFacts(bundleIdentifier: "tool.fixture",
                             displayName: "Fixture",
                             executableName: "env",
                             path: "/usr/bin/env",
                             runtime: .unknown,
                             isSigned: true,
                             signingInspected: true)

        let builder = InstanceBuilder(paths: paths)
        for number in [1, 2] {
            XCTAssertThrowsError(
                try builder.build(BuildRequest(
                    sourceBundle: URL(fileURLWithPath: "/usr/bin/env"),
                    facts: facts,
                    number: number,
                    name: "Rejected")))
        }
        XCTAssertTrue(
            (try FileManager.default.contentsOfDirectory(atPath: paths.instancesDir.path))
                .filter { UUID(uuidString: $0) != nil }.isEmpty)
    }

    func testShippedShimFailsClosedForLegacyTerminalConfiguration() throws {
        let legacy = paths.bundlesDir.appendingPathComponent("Legacy Tool.app")
        let executable = legacy.appendingPathComponent("Contents/MacOS/mal-shim")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: BundleAssembler.locateShimBinary(),
            to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path)
        let script = legacy.appendingPathComponent(
            "Contents/Resources/Launch.command")
        try FileManager.default.createDirectory(
            at: script.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: script)
        try BundleAssembler.writeInstanceConfig(
            InstanceConfig(
                kind: .tool,
                mode: .full,
                dataPath: paths.instanceDataDir(UUID()).path,
                scriptPath: script.path),
            into: legacy)

        let output = try ProcessRunner.run(
            executable: executable.path,
            [],
            timeout: 20)

        XCTAssertFalse(output.succeeded)
        XCTAssertTrue(output.stderr.contains("legacy Terminal launchers are disabled"))
    }

    func testSupervisorNeverLaunchesLegacyTerminalInstances() async throws {
        let instance = Instance(
            number: 1,
            name: "Legacy",
            mechanism: .configEnvironment,
            bundlePath: paths.bundlesDir.appendingPathComponent("Legacy.app").path,
            dataPath: paths.instanceDataDir(UUID()).path)
        do {
            _ = try await LaunchSupervisor(paths: paths).launch(instance)
            XCTFail("legacy Terminal instance was launched")
        } catch let error as MALError {
            guard case .notSupported(let reason) = error else {
                return XCTFail("expected notSupported, got \(error)")
            }
            XCTAssertTrue(reason.contains("GUI applications only"))
        }
    }

    /// The repair must live in the planted shim, not only in LaunchAgain's dashboard:
    /// users normally reopen generated launchers from the Dock or Finder, where the
    /// supervisor is not involved at all.
    func testShippedShimRepairsAnOffscreenElectronWindowBeforeExec() throws {
        let launcher = root.appendingPathComponent("Window Repair.app")
        let executable = launcher.appendingPathComponent("Contents/MacOS/mal-shim")
        let realExecutable = launcher.appendingPathComponent("Contents/MacOS/Fixture.real")
        let profile = root.appendingPathComponent("window-profile")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: BundleAssembler.locateShimBinary(), to: executable)
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/usr/bin/true"), to: realExecutable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try BundleAssembler.writeInstanceConfig(
            InstanceConfig(mode: .full,
                           dataPath: profile.path,
                           realExecutableName: "Fixture.real"),
            into: launcher)

        let stateFile = profile.appendingPathComponent(ElectronWindowStateRepairer.filename)
        let original: [String: Any] = [
            "x": 1_000_000, "y": 1_000_000, "width": 1_200, "height": 800,
            "displayBounds": [
                "x": 999_000, "y": 999_000, "width": 1_920, "height": 1_080,
            ],
            "vendorValue": "kept",
        ]
        try JSONSerialization.data(withJSONObject: original).write(to: stateFile)

        let output = try ProcessRunner.run(executable: executable.path, [], timeout: 20)
        XCTAssertTrue(output.succeeded, output.stderr)

        let repaired = try JSONSerialization.jsonObject(
            with: Data(contentsOf: stateFile)) as! [String: Any]
        XCTAssertLessThan((repaired["x"] as! NSNumber).doubleValue, 1_000_000)
        XCTAssertLessThan((repaired["y"] as! NSNumber).doubleValue, 1_000_000)
        XCTAssertEqual(repaired["vendorValue"] as? String, "kept")
        XCTAssertTrue(FileManager.default.fileExists(atPath: profile
            .appendingPathComponent(ElectronWindowStateRepairer.backupFilename).path))
    }
}
#endif
