#if canImport(Darwin)
import XCTest
@testable import MALKit
@testable import MALCore

/// Every route into Lite mode for an application whose signed-in session lives outside
/// the redirected profile.
///
/// The create path was gated in v1.2 and the conversion path was not. `updateAdvancedSettings`
/// set `proposed.mode = .lite` and `InstanceBuilder.rebuild` then derived the
/// acknowledgement from `instance.mode == .lite` — so the gate read back the flag the
/// caller had just set and let it through. Three clicks from the dashboard converted a
/// Full instance of such an app to Lite with no warning card, no acknowledgement and no
/// refusal.
///
/// These tests exist so that no route can answer its own question again. They work at the
/// `InstanceManager` API the interface actually calls, not at the builder underneath it.
final class SharedCredentialGateTests: XCTestCase {

    private var root: URL!
    private var paths: MALPaths!
    private var manager: InstanceManager!
    private var sourceApp: URL!

    /// An application that declares shared Keychain groups, which is what the detection
    /// keys on. The synthetic bundle is otherwise an ordinary Electron app.
    private let sharedCredentialEntitlements = ["keychain-access-groups"]

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mal-credential-gate-\(UUID().uuidString)")
        paths = .rooted(at: root)
        try paths.createAll()
        manager = try InstanceManager(paths: paths)
        sourceApp = try makeSyntheticApp()
    }

    override func tearDownWithError() throws {
        let registrar = LaunchServicesRegistrar(log: .silent)
        for bundleRoot in paths.bundleRoots {
            for entry in (try? FileManager.default.contentsOfDirectory(atPath: bundleRoot.path)) ?? []
            where entry.hasSuffix(".app") {
                registrar.unregister(bundle: bundleRoot.appendingPathComponent(entry))
            }
        }
        manager = nil
        try? FileManager.default.removeItem(at: root)
    }

    /// A synthetic app that **really** declares `keychain-access-groups` in its
    /// signature, not just in a hand-made `AppFacts`.
    ///
    /// This matters more than it looks. `updateAdvancedSettings` re-scans the source
    /// application with `codesign` rather than trusting facts a caller supplies, so a
    /// fixture that only claims the entitlement in a struct exercises nothing: the
    /// verdict comes back with no shared credential store and the gate correctly does not
    /// fire. The first version of this test did exactly that and passed against the
    /// unfixed code for the wrong reason.
    private func makeSyntheticApp(named name: String = "Shared",
                                  bundleIdentifier: String = "com.example.shared",
                                  entitlements: [String] = ["keychain-access-groups"]) throws -> URL {
        let app = root.appendingPathComponent("source/\(name).app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("Resources"),
                                                withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"),
                                         to: contents.appendingPathComponent("MacOS/\(name)"))
        try Data("not really an asar".utf8)
            .write(to: contents.appendingPathComponent("Resources/app.asar"))
        try BundleAssembler.writeInfoPlist([
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleName": name,
            "CFBundleDisplayName": name,
            "CFBundleExecutable": name,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
        ], bundle: app)

        if !entitlements.isEmpty {
            var body = ""
            for key in entitlements {
                body += "  <key>\(key)</key>\n  <array><string>TEST.\(bundleIdentifier)</string></array>\n"
            }
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
            \(body)</dict>
            </plist>
            """
            let entitlementsFile = root.appendingPathComponent("\(name).entitlements")
            try Data(plist.utf8).write(to: entitlementsFile)
            let result = try ProcessRunner.run(
                .codesign,
                ["--force", "--sign", "-", "--entitlements", entitlementsFile.path, app.path],
                timeout: 120)
            try XCTSkipUnless(result.succeeded,
                              "could not ad-hoc sign the fixture with entitlements: \(result.stderr)")
        }
        return app
    }

    private func facts() -> AppFacts {
        AppFacts(bundleIdentifier: "com.example.shared",
                 displayName: "Shared",
                 executableName: "Shared",
                 shortVersion: "1.0",
                 path: sourceApp.path,
                 runtime: .electron,
                 isSigned: true,
                 entitlementKeys: sharedCredentialEntitlements,
                 signingInspected: true)
    }

    /// Creates a Full instance and registers it, the way `create` would.
    @discardableResult
    private func makeFullInstance(number: Int = 1, name: String = "Converting") throws -> Instance {
        try manager.registry.upsertApp(appKey: "com.example.shared",
                                       displayName: "Shared",
                                       sourcePath: sourceApp.path,
                                       sourceVersion: "1.0")
        let result = try manager.builder.build(BuildRequest(sourceBundle: sourceApp,
                                                            facts: facts(),
                                                            number: number,
                                                            name: name,
                                                            requestedMode: .full))
        XCTAssertEqual(result.instance.mode, .full)
        try manager.registry.addInstance(result.instance, toApp: "com.example.shared")
        return result.instance
    }

    // MARK: The conversion route

    /// The reproduction, at the API the Advanced panel calls.
    func testConvertingAFullInstanceToLiteIsRefusedWithoutAcknowledgement() throws {
        let instance = try makeFullInstance()
        let bundleBefore = instance.bundlePath

        XCTAssertThrowsError(
            try manager.updateAdvancedSettings(instance,
                                               arguments: [],
                                               environment: [:],
                                               forceLite: true)
        ) { error in
            guard let malError = error as? MALError,
                  case .sharedCredentialStoreNotAcknowledged = malError else {
                return XCTFail("Advanced ▸ Force Lite converted a shared-credential-store app to Lite without asking anyone. Got \(error)")
            }
        }

        // And it really did not convert: the stored instance is still Full, and its
        // launcher is still the clone.
        let stored = try XCTUnwrap(manager.registry.instance(instance.id)?.instance)
        XCTAssertEqual(stored.mode, .full, "the instance was converted despite the refusal")
        XCTAssertEqual(stored.bundlePath, bundleBefore)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleBefore))
    }

    func testConvertingToLiteProceedsWhenTheConsequenceIsAcknowledged() throws {
        let instance = try makeFullInstance()

        try manager.updateAdvancedSettings(instance,
                                           arguments: [],
                                           environment: [:],
                                           forceLite: true,
                                           acknowledgedSharedCredentialStore: true)

        let stored = try XCTUnwrap(manager.registry.instance(instance.id)?.instance)
        XCTAssertEqual(stored.mode, .lite)
    }

    /// An ordinary application has nothing to acknowledge, so the conversion must still
    /// be one step. A gate that fires for everything teaches people to click through it.
    func testConvertingAnOrdinaryAppToLiteNeedsNoAcknowledgement() throws {
        let plainApp = try makeSyntheticApp(named: "Plain",
                                            bundleIdentifier: "com.example.plain",
                                            entitlements: [])
        try manager.registry.upsertApp(appKey: "com.example.plain",
                                       displayName: "Plain",
                                       sourcePath: plainApp.path,
                                       sourceVersion: "1.0")
        var plainFacts = facts()
        plainFacts.bundleIdentifier = "com.example.plain"
        plainFacts.displayName = "Plain"
        plainFacts.executableName = "Plain"
        plainFacts.path = plainApp.path
        plainFacts.entitlementKeys = []
        let result = try manager.builder.build(BuildRequest(sourceBundle: plainApp,
                                                            facts: plainFacts,
                                                            number: 1,
                                                            name: "Plain",
                                                            requestedMode: .full))
        try manager.registry.addInstance(result.instance, toApp: "com.example.plain")

        XCTAssertNoThrow(try manager.updateAdvancedSettings(result.instance,
                                                            arguments: [],
                                                            environment: [:],
                                                            forceLite: true))
        XCTAssertEqual(manager.registry.instance(result.instance.id)?.instance.mode, .lite)
    }

    /// Rebuilding an instance that is *already* Lite in the store must keep working: the
    /// decision was made when it was created, and re-asking would leave it permanently
    /// unrebuildable. This is the case the old `instance.mode == .lite` shape got right,
    /// and the fix must not lose it.
    func testRebuildingAnInstanceThatIsAlreadyLiteIsNotRefused() throws {
        try manager.registry.upsertApp(appKey: "com.example.shared",
                                       displayName: "Shared",
                                       sourcePath: sourceApp.path,
                                       sourceVersion: "1.0")
        let result = try manager.builder.build(
            BuildRequest(sourceBundle: sourceApp,
                         facts: facts(),
                         number: 1,
                         name: "AlreadyLite",
                         requestedMode: .lite,
                         acknowledgedSharedCredentialStore: true))
        XCTAssertEqual(result.instance.mode, .lite)
        try manager.registry.addInstance(result.instance, toApp: "com.example.shared")

        XCTAssertNoThrow(try manager.rebuild(result.instance))
        XCTAssertNoThrow(try manager.updateAdvancedSettings(result.instance,
                                                            arguments: ["--flag"],
                                                            environment: [:],
                                                            forceLite: true))
    }

    /// Duplicating a Full instance of such an app must not produce a Lite one, and must
    /// not smuggle an acknowledgement in through the duplicate path either.
    func testDuplicatingAFullInstanceStaysFull() throws {
        let instance = try makeFullInstance()
        let copy = try manager.duplicate(instance)
        XCTAssertEqual(copy.mode, .full)
    }

    // MARK: The duplicate route, and what counts as consent

    /// Builds a Lite instance the way an acknowledged creation would, and registers it.
    @discardableResult
    private func makeAcknowledgedLiteInstance(number: Int = 1,
                                              name: String = "Acknowledged") throws -> Instance {
        try manager.registry.upsertApp(appKey: "com.example.shared",
                                       displayName: "Shared",
                                       sourcePath: sourceApp.path,
                                       sourceVersion: "1.0")
        let result = try manager.builder.build(
            BuildRequest(sourceBundle: sourceApp,
                         facts: facts(),
                         number: number,
                         name: name,
                         requestedMode: .lite,
                         acknowledgedSharedCredentialStore: true))
        XCTAssertEqual(result.instance.mode, .lite)
        XCTAssertNotNil(result.instance.acknowledgedSharedCredentialStoreAt,
                        "an acknowledged Lite build must record the acknowledgement it was given")
        try manager.registry.addInstance(result.instance, toApp: "com.example.shared")
        return result.instance
    }

    /// The B1 reproduction.
    ///
    /// `duplicate` is a bare one-click menu item with no card in front of it, and it
    /// mints a **new** launcher. It used to infer the acknowledgement from
    /// `mode == .lite`, so any Lite row in the store — one created before the gate
    /// existed, one a hand-edited registry claims is Lite — silently authorised a new
    /// Lite launcher for an app whose session is shared. Being Lite is a state; it is not
    /// a record that anybody was ever asked.
    func testDuplicatingALiteInstanceWithNoRecordedAcknowledgementIsRefused() throws {
        let instance = try makeAcknowledgedLiteInstance()
        // Exactly what a pre-gate registry row looks like: Lite, with no acknowledgement
        // recorded against it.
        try manager.registry.updateInstance(instance.id) {
            $0.acknowledgedSharedCredentialStoreAt = nil
        }
        let countBefore = manager.registry.allInstances.count

        XCTAssertThrowsError(try manager.duplicate(instance)) { error in
            guard let malError = error as? MALError,
                  case .sharedCredentialStoreNotAcknowledged = malError else {
                return XCTFail("Duplicate minted a new Lite launcher for a shared-credential-store app from an acknowledgement nobody ever gave. Got \(error)")
            }
        }
        XCTAssertEqual(manager.registry.allInstances.count, countBefore,
                       "the refused duplicate was created anyway")
    }

    /// The other half: a real acknowledgement is copied, so duplicating an instance the
    /// user genuinely accepted is still one click.
    func testDuplicatingAnAcknowledgedLiteInstanceIsAllowed() throws {
        let instance = try makeAcknowledgedLiteInstance()
        let copy = try manager.duplicate(instance)
        XCTAssertEqual(copy.mode, .lite)
        XCTAssertEqual(copy.acknowledgedSharedCredentialStoreAt,
                       instance.acknowledgedSharedCredentialStoreAt,
                       "the copy must carry the acknowledgement the original recorded, not a fresh one")
    }

    /// Rebuilding an acknowledged instance must not re-prompt — that was the failure the
    /// old `mode == .lite` shape existed to avoid — and must not re-date the
    /// acknowledgement either, because "when did I agree to this" is the question the
    /// record answers.
    func testRebuildingAnAcknowledgedInstanceKeepsTheAcknowledgementUnchanged() throws {
        let instance = try makeAcknowledgedLiteInstance()
        let originalDate = try XCTUnwrap(instance.acknowledgedSharedCredentialStoreAt)

        XCTAssertNoThrow(try manager.rebuild(instance))

        let stored = try XCTUnwrap(manager.registry.instance(instance.id)?.instance)
        XCTAssertEqual(stored.mode, .lite)
        XCTAssertEqual(stored.acknowledgedSharedCredentialStoreAt, originalDate)
    }

    // MARK: The stranded-instance route — a Lite launcher with no record of consent

    /// What `LauncherReconciler`'s **legacy** path reconstructs: the shim config says
    /// Lite, so the row is Lite, and no acknowledgement is recorded, because recovery has
    /// no evidence anyone was ever asked.
    ///
    /// This is not the pre-gate population, which is empty and closed — but it is
    /// narrower than "any recovered launcher". A launcher built by this version carries a
    /// `LauncherRecoveryManifest` holding the acknowledgement, and reconciliation prefers
    /// it, so recovering one of those keeps the stamp. The un-acknowledged shape comes
    /// from launchers with no manifest or a manifest that fails identity verification.
    @discardableResult
    private func makeRecoveredLiteInstance(number: Int = 1,
                                           name: String = "Recovered") throws -> Instance {
        let instance = try makeAcknowledgedLiteInstance(number: number, name: name)
        try manager.registry.updateInstance(instance.id) {
            $0.acknowledgedSharedCredentialStoreAt = nil
        }
        return try XCTUnwrap(manager.registry.instance(instance.id)?.instance)
    }

    /// Rebuilding it must work. The launcher is already Lite on disk and stays Lite, so
    /// the rebuild introduces no sharing that is not already there; refusing does not
    /// remove the sharing, it only makes the instance unrebuildable from the command
    /// line, which has no flag to supply an acknowledgement for an existing instance.
    func testRebuildingARecoveredLiteInstanceIsAllowed() throws {
        let instance = try makeRecoveredLiteInstance()
        XCTAssertNoThrow(try manager.rebuild(instance))
        XCTAssertEqual(manager.registry.instance(instance.id)?.instance.mode, .lite)
    }

    /// Renaming used to fail on a consent question it never asked. A rename changes the
    /// name; `proposed.mode` is the stored mode, so nothing about the shared session
    /// moves, and the message it used to fail with named `--acknowledge-shared-credentials`
    /// — a flag only `create` parses.
    func testRenamingARecoveredLiteInstanceIsAllowed() throws {
        let instance = try makeRecoveredLiteInstance()
        XCTAssertNoThrow(try manager.rename(instance, to: "Renamed", rebuildBundle: true))
        XCTAssertEqual(manager.registry.instance(instance.id)?.instance.name, "Renamed")
    }

    /// The GUI's Advanced ▸ Apply route, which is the one the detail view enables for a
    /// stored-Lite instance. Enabled and then failing is the defect; this asserts they
    /// agree.
    func testApplyingAdvancedSettingsToARecoveredLiteInstanceIsAllowed() throws {
        let instance = try makeRecoveredLiteInstance()
        XCTAssertNoThrow(try manager.updateAdvancedSettings(instance,
                                                            arguments: ["--flag"],
                                                            environment: [:],
                                                            forceLite: true))
        XCTAssertEqual(manager.registry.instance(instance.id)?.instance.extraArguments, ["--flag"])
    }

    /// The load-bearing one.
    ///
    /// Permission to rebuild is not consent, and must never be recorded as consent. If
    /// the allowance were folded into `acknowledgedSharedCredentialStore` — the obvious
    /// one-line version of this fix — the Lite build path would stamp `createdAt` as the
    /// date the user accepted, for a user who was never asked. `duplicate` reads that
    /// stamp to authorise a **new** launcher, so the one-line version reopens B1 through
    /// a different door: rebuild once, and duplicate stops refusing.
    func testRebuildingARecoveredLiteInstanceRecordsNoAcknowledgement() throws {
        let instance = try makeRecoveredLiteInstance()
        try manager.rebuild(instance)

        let stored = try XCTUnwrap(manager.registry.instance(instance.id)?.instance)
        XCTAssertNil(stored.acknowledgedSharedCredentialStoreAt,
                     "the rebuild minted a consent date for a user who was never asked")

        let countBefore = manager.registry.allInstances.count
        XCTAssertThrowsError(try manager.duplicate(stored)) { error in
            guard let malError = error as? MALError,
                  case .sharedCredentialStoreNotAcknowledged = malError else {
                return XCTFail("B1 reopened: rebuilding a recovered instance made duplicate stop refusing. Got \(error)")
            }
        }
        XCTAssertEqual(manager.registry.allInstances.count, countBefore)
    }

    /// The same, through the other two routes that reach `rebuildProposed`.
    func testRenameAndApplyAlsoRecordNoAcknowledgement() throws {
        let renamed = try makeRecoveredLiteInstance(number: 1, name: "ForRename")
        try manager.rename(renamed, to: "Renamed", rebuildBundle: true)
        XCTAssertNil(manager.registry.instance(renamed.id)?.instance
                        .acknowledgedSharedCredentialStoreAt)

        let applied = try makeRecoveredLiteInstance(number: 2, name: "ForApply")
        try manager.updateAdvancedSettings(applied,
                                           arguments: ["--flag"],
                                           environment: [:],
                                           forceLite: true)
        XCTAssertNil(manager.registry.instance(applied.id)?.instance
                        .acknowledgedSharedCredentialStoreAt)
    }

    /// The allowance is scoped to the *stored* mode, so it cannot be reached by proposing
    /// Lite for an instance the store holds as Full. That is the conversion the gate was
    /// built for, and it stays gated whether or not the caller also asks for other
    /// changes in the same Apply.
    func testTheAllowanceDoesNotExtendToConvertingAStoredFullInstance() throws {
        let instance = try makeFullInstance()
        XCTAssertThrowsError(try manager.updateAdvancedSettings(instance,
                                                                arguments: ["--flag"],
                                                                environment: [:],
                                                                forceLite: true)) { error in
            guard let malError = error as? MALError,
                  case .sharedCredentialStoreNotAcknowledged = malError else {
                return XCTFail("Force Lite on a stored-Full instance reached the rebuild allowance. Got \(error)")
            }
        }
        XCTAssertEqual(manager.registry.instance(instance.id)?.instance.mode, .full)
    }

    /// Round 5, F1. The allowance's justification is a claim about the **disk** — "this
    /// launcher is already Lite, so the rebuild introduces no sharing". It was read from
    /// the registry row, and the two can disagree.
    ///
    /// A row edited to say Lite over a Full clone converted a clone with its own ad-hoc
    /// identity — which genuinely could not read the vendor's Keychain items — into a
    /// launcher running the vendor-signed original, sharing them outright, silently. The
    /// gate now reads the shim config, the same physical fact the reconciler reads.
    func testARegistryRowClaimingLiteOverAFullCloneDoesNotReachTheAllowance() throws {
        let instance = try makeFullInstance(name: "Tampered")
        XCTAssertEqual(instance.mode, .full)
        // The launcher on disk is a Full clone; only the record is changed.
        try manager.registry.updateInstance(instance.id) { $0.mode = .lite }
        let tampered = try XCTUnwrap(manager.registry.instance(instance.id)?.instance)
        XCTAssertEqual(tampered.mode, .lite, "the fixture must actually diverge from disk")

        XCTAssertThrowsError(try manager.rebuild(tampered)) { error in
            guard let malError = error as? MALError,
                  case .sharedCredentialStoreNotAcknowledged = malError else {
                return XCTFail("A hand-edited registry row converted a Full clone into a shared-session Lite launcher. Got \(error)")
            }
        }
        let after = try XCTUnwrap(manager.registry.instance(instance.id)?.instance)
        XCTAssertNil(after.acknowledgedSharedCredentialStoreAt)
    }

    /// The other half of F1: the allowance must still be reachable for a launcher that
    /// really is Lite on disk, or the fix has simply re-stranded everything.
    func testTheAllowanceIsStillReachedWhenTheLauncherIsGenuinelyLiteOnDisk() throws {
        let instance = try makeRecoveredLiteInstance()
        let config = try BundleAssembler.readInstanceConfig(
            from: URL(fileURLWithPath: instance.bundlePath))
        XCTAssertEqual(config.mode, .lite, "the fixture must be Lite on disk, not just in the row")
        XCTAssertNoThrow(try manager.rebuild(instance))
    }

    /// Round 5, F3. `renumber` rebuilds the row field by field. Omitting the
    /// acknowledgement date did not preserve it — the acknowledgement still read `true`
    /// from the registry, so the build stamped the moment of the renumber instead.
    func testRenumberingAnAcknowledgedInstanceKeepsTheOriginalAcknowledgementDate() throws {
        let instance = try makeAcknowledgedLiteInstance(number: 2, name: "Renumbered")
        let originalDate = try XCTUnwrap(instance.acknowledgedSharedCredentialStoreAt)

        _ = try manager.renumber(appKey: "com.example.shared")

        let stored = try XCTUnwrap(manager.registry.instance(instance.id)?.instance)
        XCTAssertEqual(stored.number, 1, "the renumber must actually have moved the number")
        XCTAssertEqual(stored.acknowledgedSharedCredentialStoreAt, originalDate,
                       "renumbering re-dated the acknowledgement to the moment of the renumber")
    }

    /// Round 5, F2. The detail view predicted the mode from the stored record while the
    /// builder resolved it through the verdict, so for an application that has become
    /// Lite-only since the instance was built the two disagreed: no checkbox, Apply
    /// enabled, and then a refusal. Both now ask `effectiveMode(requesting:)`.
    ///
    /// This asserts the shared rule, which is the thing that made them disagree. The
    /// view's use of it is a SwiftUI expression and is not reachable from here.
    func testAFullRequestResolvesToLiteWhenTheVerdictOnlyRecommendsLite() throws {
        let liteOnly = CompatibilityVerdict(
            tier: .limited,
            headline: "",
            reasons: [],
            limitations: [],
            recommendedMode: .lite,
            estimatedFirstRunBytes: 0,
            sharedCredentialStores: [
                SharedCredentialStore(kind: .keychainAccessGroup,
                                      evidence: "keychain-access-groups",
                                      consequence: "shares the original's session",
                                      affectsFullMode: false),
            ])
        // What the builder will produce for a Full request, and therefore what any screen
        // predicting it has to show.
        XCTAssertEqual(liteOnly.effectiveMode(requesting: InstanceMode.full), InstanceMode.lite)
        XCTAssertTrue(liteOnly.requiresSharedCredentialAcknowledgement(
            mode: liteOnly.effectiveMode(requesting: InstanceMode.full)),
            "a stored-Full instance of a now-Lite-only shared-credential app still needs the acknowledgement")

        let fullCapable = CompatibilityVerdict(
            tier: .supported,
            headline: "",
            reasons: [],
            limitations: [],
            recommendedMode: .full,
            estimatedFirstRunBytes: 0,
            sharedCredentialStores: [
                SharedCredentialStore(kind: .keychainAccessGroup,
                                      evidence: "keychain-access-groups",
                                      consequence: "shares the original's session",
                                      affectsFullMode: false),
            ])
        XCTAssertEqual(fullCapable.effectiveMode(requesting: InstanceMode.full), InstanceMode.full)
        XCTAssertEqual(fullCapable.effectiveMode(requesting: InstanceMode.lite), InstanceMode.lite)
        XCTAssertFalse(fullCapable.requiresSharedCredentialAcknowledgement(
            mode: fullCapable.effectiveMode(requesting: InstanceMode.full)))
    }

    /// Round 5, F2, through the engine.
    ///
    /// **This is a regression guard and it passes against the pre-fix code**, stated
    /// plainly because the previous round's document claimed six-of-six where five was
    /// the truth. The engine always refused here — F2 was that the *view* predicted
    /// otherwise, left Apply enabled and offered no checkbox. The view's half is a
    /// SwiftUI expression and is covered by
    /// `testAFullRequestResolvesToLiteWhenTheVerdictOnlyRecommendsLite`, which pins the
    /// rule both now consult. What this pins is that the engine's answer is the one the
    /// view has to match, so a later change to `effectiveMode` cannot quietly move it.
    func testAnInstanceOfAnAppThatBecameLiteOnlyIsRefusedNotSilentlyDegraded() throws {
        let instance = try makeFullInstance(name: "BecameLiteOnly")
        // A privileged helper in the *source* is what flips `recommendedMode` to Lite.
        let helper = sourceApp.appendingPathComponent("Contents/Library/LaunchServices")
        try FileManager.default.createDirectory(at: helper, withIntermediateDirectories: true)

        XCTAssertThrowsError(try manager.rebuild(instance)) { error in
            guard let malError = error as? MALError,
                  case .sharedCredentialStoreNotAcknowledged = malError else {
                return XCTFail("Expected a refusal, got \(error)")
            }
        }
        let stored = try XCTUnwrap(manager.registry.instance(instance.id)?.instance)
        XCTAssertEqual(stored.mode, .full)
        XCTAssertNil(stored.acknowledgedSharedCredentialStoreAt)
    }

    /// Round 5, F4. A rebuild regenerates the bundle; it does not create a new instance.
    /// `createdAt` was restamped on every rebuild, and the detail view labels it
    /// "Created".
    func testRebuildingAnInstanceKeepsItsCreationDate() throws {
        let instance = try makeAcknowledgedLiteInstance(name: "Aged")
        let originalCreatedAt = instance.createdAt

        try manager.rebuild(instance)
        let afterRebuild = try XCTUnwrap(manager.registry.instance(instance.id)?.instance)
        XCTAssertEqual(afterRebuild.createdAt, originalCreatedAt,
                       "the rebuild restamped createdAt, which the UI shows as \"Created\"")

        try manager.rename(instance, to: "Aged and renamed", rebuildBundle: true)
        let afterRename = try XCTUnwrap(manager.registry.instance(instance.id)?.instance)
        XCTAssertEqual(afterRename.createdAt, originalCreatedAt)
    }

    /// A Full build never records an acknowledgement, even when a caller passes one.
    /// If it did, converting that instance to Lite later would read its own flag back —
    /// the blocking finding this whole area exists because of.
    func testAFullBuildRecordsNoAcknowledgementEvenWhenOneIsPassed() throws {
        try manager.registry.upsertApp(appKey: "com.example.shared",
                                       displayName: "Shared",
                                       sourcePath: sourceApp.path,
                                       sourceVersion: "1.0")
        let result = try manager.builder.build(
            BuildRequest(sourceBundle: sourceApp,
                         facts: facts(),
                         number: 1,
                         name: "Full",
                         requestedMode: .full,
                         acknowledgedSharedCredentialStore: true))
        XCTAssertEqual(result.instance.mode, .full)
        XCTAssertNil(result.instance.acknowledgedSharedCredentialStoreAt)

        try manager.registry.addInstance(result.instance, toApp: "com.example.shared")
        XCTAssertThrowsError(try manager.updateAdvancedSettings(result.instance,
                                                                arguments: [],
                                                                environment: [:],
                                                                forceLite: true)) { error in
            guard let malError = error as? MALError,
                  case .sharedCredentialStoreNotAcknowledged = malError else {
                return XCTFail("a Full instance carried an acknowledgement into its own conversion. Got \(error)")
            }
        }
    }

    /// A registry written before the field existed decodes to "un-acknowledged" rather
    /// than to a default that would wave everything through.
    func testAnInstanceFromAnOlderRegistryDecodesAsUnacknowledged() throws {
        let json = """
        {"id":"\(UUID().uuidString)","number":3,"name":"Old","accountLabel":"",
         "mode":"lite","mechanism":"userDataDir","bundlePath":"/tmp/Old.app",
         "dataPath":"/tmp/old-data","builtFromSourceVersion":"1.0",
         "clonedBundleIdentifier":"com.example.old","extraArguments":[],
         "extraEnvironment":{},"buildNotes":[]}
        """
        let decoded = try JSONDecoder().decode(Instance.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.mode, .lite)
        XCTAssertNil(decoded.acknowledgedSharedCredentialStoreAt,
                     "a Lite row with no recorded acknowledgement must not be read as an acknowledged one")
    }

    // MARK: The degradation route

    /// `InstanceBuilder.build` retries in Lite mode when a Full build fails in a way Lite
    /// could survive. That retry must not become a way of arriving at the mode this
    /// application was just refused.
    func testAFailedFullBuildDoesNotSilentlyDegradeToLite() throws {
        // Break the source so the Full path cannot complete.
        let broken = root.appendingPathComponent("source/Broken.app")
        try FileManager.default.createDirectory(
            at: broken.appendingPathComponent("Contents/Resources"),
            withIntermediateDirectories: true)
        try Data("not really an asar".utf8)
            .write(to: broken.appendingPathComponent("Contents/Resources/app.asar"))
        try BundleAssembler.writeInfoPlist([
            "CFBundleIdentifier": "com.example.shared",
            "CFBundleName": "Broken",
            "CFBundleDisplayName": "Broken",
            "CFBundleExecutable": "Broken",
            "CFBundlePackageType": "APPL",
        ], bundle: broken)

        var brokenFacts = facts()
        brokenFacts.path = broken.path
        brokenFacts.executableName = "Broken"
        brokenFacts.displayName = "Broken"

        XCTAssertThrowsError(try manager.builder.build(
            BuildRequest(sourceBundle: broken,
                         facts: brokenFacts,
                         number: 1,
                         name: "Degrading",
                         requestedMode: .full)))

        let built = paths.bundleRoots.flatMap { bundleRoot in
            ((try? FileManager.default.contentsOfDirectory(atPath: bundleRoot.path)) ?? [])
                .filter { $0.hasSuffix(".app") }
        }
        XCTAssertTrue(built.isEmpty,
                      "a Full build that failed produced a Lite instance of a shared-credential-store app without asking: \(built)")
    }

    // MARK: The rule has one definition

    /// `requiresSharedCredentialAcknowledgement` is what the create flow, the detail
    /// screen, the command line and the builder all consult. If it stops agreeing with
    /// the builder's behaviour, every one of those drifts at once.
    func testTheRuleAndTheBuilderAgree() throws {
        let verdict = Compatibility.evaluate(facts())
        XCTAssertTrue(verdict.requiresSharedCredentialAcknowledgement(mode: .lite))
        XCTAssertFalse(verdict.requiresSharedCredentialAcknowledgement(mode: .full))

        var plain = facts()
        plain.entitlementKeys = []
        let plainVerdict = Compatibility.evaluate(plain)
        XCTAssertFalse(plainVerdict.requiresSharedCredentialAcknowledgement(mode: .lite))
        XCTAssertFalse(plainVerdict.requiresSharedCredentialAcknowledgement(mode: .full))
    }
}
#endif
