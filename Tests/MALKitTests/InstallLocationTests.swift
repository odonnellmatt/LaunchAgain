#if canImport(Darwin)
import XCTest
@testable import MALKit
@testable import MALCore

/// Some applications refuse to run from anywhere but `/Applications`. LM Studio is the
/// measured case, and supporting it widens where a launcher may live from one directory
/// to two.
///
/// The point of these tests is that the ownership boundary widened *deliberately and by
/// exactly one named directory*, and did not become "anything under /Applications". They
/// run against a rooted store whose second root is an ordinary directory, so nothing here
/// touches the real `/Applications`.
final class InstallLocationTests: XCTestCase {

    private var root: URL!
    private var paths: MALPaths!
    private var sourceApp: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mal-install-location-\(UUID().uuidString)")
        paths = .rooted(at: root)
        try paths.createAll()
        sourceApp = try makeSyntheticApp(named: "Fixture")
    }

    override func tearDownWithError() throws {
        let registrar = LaunchServicesRegistrar(log: .silent)
        for bundleRoot in paths.bundleRoots {
            for entry in (try? FileManager.default.contentsOfDirectory(atPath: bundleRoot.path)) ?? []
            where entry.hasSuffix(".app") {
                registrar.unregister(bundle: bundleRoot.appendingPathComponent(entry))
            }
        }
        try? FileManager.default.removeItem(at: root)
    }

    private func makeSyntheticApp(named name: String,
                                  bundleIdentifier: String? = nil) throws -> URL {
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
            "CFBundleIdentifier": bundleIdentifier ?? "com.example.\(name.lowercased())",
            "CFBundleName": name,
            "CFBundleDisplayName": name,
            "CFBundleExecutable": name,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
        ], bundle: app)
        return app
    }

    private func facts(for app: URL,
                       name: String = "Fixture",
                       bundleIdentifier: String? = nil) -> AppFacts {
        AppFacts(bundleIdentifier: bundleIdentifier ?? "com.example.\(name.lowercased())",
                 displayName: name,
                 executableName: name,
                 shortVersion: "1.0",
                 path: app.path,
                 runtime: .electron,
                 isSigned: true,
                 signingInspected: true)
    }

    // MARK: Choosing a root

    func testAnOrdinaryAppInstallsInTheUsersOwnApplicationsFolder() throws {
        let builder = InstanceBuilder(paths: paths)
        let result = try builder.build(BuildRequest(sourceBundle: sourceApp,
                                                    facts: facts(for: sourceApp),
                                                    number: 1,
                                                    name: "Default"))
        XCTAssertEqual(URL(fileURLWithPath: result.instance.bundlePath)
            .deletingLastPathComponent().standardizedFileURL.path,
                       paths.bundlesDir.standardizedFileURL.path)
    }

    func testAnAppThatDemandsApplicationsInstallsInTheSystemRoot() throws {
        // LM Studio's identifier is the one entry in the measured table.
        let app = try makeSyntheticApp(named: "Studio",
                                       bundleIdentifier: "ai.elementlabs.lmstudio")
        let builder = InstanceBuilder(paths: paths)
        let result = try builder.build(BuildRequest(
            sourceBundle: app,
            facts: facts(for: app, name: "Studio", bundleIdentifier: "ai.elementlabs.lmstudio"),
            number: 1,
            name: "Demanding"))
        XCTAssertEqual(URL(fileURLWithPath: result.instance.bundlePath)
            .deletingLastPathComponent().standardizedFileURL.path,
                       paths.systemBundlesDir.standardizedFileURL.path)
        XCTAssertTrue(Compatibility.evaluate(
            facts(for: app, name: "Studio", bundleIdentifier: "ai.elementlabs.lmstudio")
        ).limitations.contains { $0.contains("/Applications/LaunchAgain") })
    }

    func testAnInstallRootOutsideTheOwnedListIsRefused() throws {
        let elsewhere = root.appendingPathComponent("not-ours")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let builder = InstanceBuilder(paths: paths)
        XCTAssertThrowsError(try builder.build(BuildRequest(sourceBundle: sourceApp,
                                                            facts: facts(for: sourceApp),
                                                            number: 1,
                                                            name: "Nope",
                                                            installRoot: elsewhere))) { error in
            XCTAssertTrue("\(error)".contains("LaunchAgain applications directory"),
                          "got \(error)")
        }
        XCTAssertTrue(((try? FileManager.default.contentsOfDirectory(atPath: elsewhere.path)) ?? [])
            .isEmpty, "a refused install root must not be written to")
    }

    // MARK: The ownership boundary did not become "anything in /Applications"

    func testABundleBesideTheSystemRootIsNotDeletable() throws {
        // The shape that matters: an application sitting in the *parent* of our system
        // root — which is /Applications on a real machine — rather than inside it.
        let neighbour = paths.systemBundlesDir.deletingLastPathComponent()
            .appendingPathComponent("Someone Else.app")
        try FileManager.default.createDirectory(at: neighbour, withIntermediateDirectories: true)

        XCTAssertThrowsError(try paths.assertDeletable(neighbour.path)) { error in
            XCTAssertTrue("\(error)".contains("outside the launcher's own directories"))
        }
        XCTAssertThrowsError(try paths.assertLauncherBundlePath(neighbour.path))
        XCTAssertNil(paths.bundleRoot(containing: neighbour.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: neighbour.path))
    }

    func testTheRootsThemselvesAreNeverDeletable() throws {
        for bundleRoot in paths.bundleRoots {
            XCTAssertThrowsError(try paths.assertDeletable(bundleRoot.path),
                                 "one damaged path must not erase every instance")
        }
    }

    func testALauncherInsideEitherRootIsAcceptedAndOneNestedDeeperIsNot() throws {
        for bundleRoot in paths.bundleRoots {
            let ok = bundleRoot.appendingPathComponent("Fixture 1.app")
            XCTAssertNoThrow(try paths.assertLauncherBundlePath(ok.path))
            let nested = bundleRoot.appendingPathComponent("sub/Fixture 1.app")
            XCTAssertThrowsError(try paths.assertLauncherBundlePath(nested.path),
                                 "an intermediate directory could be a symlink")
        }
    }

    /// The health check's own refusal, not just the path guard: a bundle in
    /// /Applications that LaunchAgain did not create must be reported, never removed.
    func testTheSweeperRefusesToRemoveANonOwnedBundleBesideTheSystemRoot() throws {
        let neighbour = paths.systemBundlesDir.deletingLastPathComponent()
            .appendingPathComponent("Someone Else.app")
        try FileManager.default.createDirectory(at: neighbour, withIntermediateDirectories: true)

        let sweeper = OrphanSweeper(paths: paths)
        let finding = OrphanSweeper.Finding(kind: .unregisteredBundle,
                                            path: neighbour.path,
                                            detail: "hand-made",
                                            sizeBytes: 0,
                                            safeToClean: true)
        XCTAssertThrowsError(try sweeper.remove(finding))
        XCTAssertTrue(FileManager.default.fileExists(atPath: neighbour.path))
    }

    // MARK: Removing the evidence must not make deletion easier

    /// The reproduction, in full.
    ///
    /// `LauncherIdentityVerifier` used to verify the signature only `if hasSignature`,
    /// and only the sweeper insisted a signature existed at all — the uninstall path did
    /// not. So a planted bundle with copied ownership metadata was refused while it had a
    /// signature, and accepted once `Contents/_CodeSignature` was deleted. A check that
    /// gets weaker when evidence is removed is backwards, and this boundary now reaches
    /// into `/Applications`.
    func testStrippingABundlesSignatureDoesNotMakeItDeletable() throws {
        let builder = InstanceBuilder(paths: paths)
        let genuine = try builder.build(BuildRequest(sourceBundle: sourceApp,
                                                     facts: facts(for: sourceApp),
                                                     number: 1,
                                                     name: "Genuine"))
        let bundle = URL(fileURLWithPath: genuine.instance.bundlePath)

        // While it is intact, uninstall accepts it — otherwise this test proves nothing.
        XCTAssertNoThrow(try builder.validateRemoval(instance: genuine.instance,
                                                     scope: .launcherAndData))

        try FileManager.default.removeItem(
            at: bundle.appendingPathComponent("Contents/_CodeSignature"))

        XCTAssertThrowsError(
            try builder.validateRemoval(instance: genuine.instance, scope: .launcherAndData)
        ) { error in
            XCTAssertTrue("\(error)".contains("no sealed code signature"),
                          "expected a refusal naming the missing signature, got \(error)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.path),
                      "deleting the signature made the bundle deletable")
    }

    /// The same, one level up: a bundle that carries *copied* ownership metadata and no
    /// signature at all — the planted-application shape — must be refused by both the
    /// uninstall path and the sweeper, not just by one of them.
    func testAPlantedBundleWithCopiedMetadataAndNoSignatureIsRefusedByBothPaths() throws {
        let builder = InstanceBuilder(paths: paths)
        let genuine = try builder.build(BuildRequest(sourceBundle: sourceApp,
                                                     facts: facts(for: sourceApp),
                                                     number: 1,
                                                     name: "Genuine"))
        // The system root is created on demand, so a test that plants into it has to
        // make it first.
        try paths.prepareBundleRoot(paths.systemBundlesDir)
        let planted = paths.systemBundlesDir.appendingPathComponent("Planted.app")
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: genuine.instance.bundlePath), to: planted)
        try FileManager.default.removeItem(
            at: planted.appendingPathComponent("Contents/_CodeSignature"))

        XCTAssertThrowsError(try LauncherIdentityVerifier.verify(bundle: planted, paths: paths))
        XCTAssertThrowsError(try LauncherIdentityVerifier.verify(bundle: planted,
                                                                 paths: paths,
                                                                 requireManifest: true))

        let sweeper = OrphanSweeper(paths: paths)
        let finding = OrphanSweeper.Finding(kind: .unregisteredBundle,
                                            path: planted.path,
                                            detail: "planted",
                                            sizeBytes: 0,
                                            safeToClean: true)
        XCTAssertThrowsError(try sweeper.remove(finding))
        XCTAssertTrue(FileManager.default.fileExists(atPath: planted.path))
    }

    /// `MALGeneratedBy` is *the* check separating "a bundle we made" from "a bundle that
    /// happens to be in our folder", and with the boundary now reaching into
    /// `/Applications` it is the one that matters most.
    ///
    /// It survived deliberate removal against the whole 283-test suite: every test that
    /// exercised it also failed some *other* guard, so nothing pinned it on its own. This
    /// pins it on its own — a bundle that satisfies every other condition, in an owned
    /// root, correctly signed, differing only in that one key.
    func testABundleWithoutTheGeneratedByMarkerIsRefusedEvenWhenEverythingElseMatches() throws {
        let builder = InstanceBuilder(paths: paths)
        let genuine = try builder.build(BuildRequest(sourceBundle: sourceApp,
                                                     facts: facts(for: sourceApp),
                                                     number: 1,
                                                     name: "Genuine"))
        let source = URL(fileURLWithPath: genuine.instance.bundlePath)

        // A copy that is byte-identical apart from MALGeneratedBy, re-signed so its
        // signature is valid and its seal covers the edit. Everything else — the
        // generated identifier, the sealed config, the recovery manifest, the location —
        // is exactly what a real launcher has.
        let impostor = paths.bundlesDir.appendingPathComponent("Impostor.app")
        try FileManager.default.copyItem(at: source, to: impostor)
        var info = try BundleAssembler.readInfoPlist(bundle: impostor)
        XCTAssertEqual(info["MALGeneratedBy"] as? String, "LaunchAgain",
                       "the fixture is not exercising what this test claims")
        info.removeValue(forKey: "MALGeneratedBy")
        try BundleAssembler.writeInfoPlist(info, bundle: impostor)
        let signed = try ProcessRunner.run(
            .codesign, ["--force", "--deep", "--sign", "-", impostor.path], timeout: 180)
        try XCTSkipUnless(signed.succeeded, "could not re-sign the fixture: \(signed.stderr)")

        // Every path that can lead to deletion must refuse it.
        XCTAssertThrowsError(try LauncherIdentityVerifier.verify(bundle: impostor, paths: paths)) { error in
            XCTAssertTrue("\(error)".contains("ownership metadata"),
                          "expected a refusal naming the missing ownership marker, got \(error)")
        }
        XCTAssertThrowsError(try LauncherIdentityVerifier.verify(bundle: impostor,
                                                                 paths: paths,
                                                                 requireManifest: true))

        let sweeper = OrphanSweeper(paths: paths)
        XCTAssertThrowsError(try sweeper.remove(
            OrphanSweeper.Finding(kind: .unregisteredBundle,
                                  path: impostor.path,
                                  detail: "impostor",
                                  sizeBytes: 0,
                                  safeToClean: true)))

        // And the health check must not offer it for bulk cleanup either.
        let registry = try Registry(paths: paths)
        let findings = sweeper.sweep(registry: registry)
        let impostorFinding = findings.first { $0.path == impostor.path }
        XCTAssertEqual(impostorFinding?.safeToClean, false,
                       "a bundle with no LaunchAgain ownership marker was offered for bulk deletion")

        XCTAssertTrue(FileManager.default.fileExists(atPath: impostor.path))
    }

    // MARK: Reconciliation, health and uninstall across both roots

    func testReconciliationRecoversInstancesFromBothRoots() throws {
        let builder = InstanceBuilder(paths: paths)
        let inHome = try builder.build(BuildRequest(sourceBundle: sourceApp,
                                                    facts: facts(for: sourceApp),
                                                    number: 1,
                                                    name: "Home"))
        let inSystem = try builder.build(BuildRequest(sourceBundle: sourceApp,
                                                      facts: facts(for: sourceApp),
                                                      number: 2,
                                                      name: "System",
                                                      installRoot: paths.systemBundlesDir))
        XCTAssertNotEqual(
            URL(fileURLWithPath: inHome.instance.bundlePath).deletingLastPathComponent().path,
            URL(fileURLWithPath: inSystem.instance.bundlePath).deletingLastPathComponent().path)

        // A registry that knows nothing — the "I lost my store" case.
        let registry = try Registry(paths: paths)
        let reconciler = LauncherReconciler(paths: paths, scanner: AppScanner(log: .silent), log: .silent)
        let report = try reconciler.reconcile(registry: registry)

        XCTAssertEqual(report.launchersFound, 2,
                       "a launcher in /Applications/LaunchAgain must be recoverable too")
        let recovered = registry.allInstances.map(\.instance)
        XCTAssertEqual(Set(recovered.map(\.number)), [1, 2])
        XCTAssertEqual(Set(recovered.map(\.bundlePath)),
                       [inHome.instance.bundlePath, inSystem.instance.bundlePath])
    }

    func testTheHealthCheckSeesStrandedLaunchersInBothRoots() throws {
        let builder = InstanceBuilder(paths: paths)
        let inSystem = try builder.build(BuildRequest(sourceBundle: sourceApp,
                                                      facts: facts(for: sourceApp),
                                                      number: 1,
                                                      name: "Stranded",
                                                      installRoot: paths.systemBundlesDir))
        let registry = try Registry(paths: paths)
        let findings = OrphanSweeper(paths: paths).sweep(registry: registry)

        XCTAssertTrue(findings.contains {
            $0.kind == .unregisteredBundle && $0.path == inSystem.instance.bundlePath
        }, "a launcher in the system root was invisible to the health check")
    }

    func testAnInstanceInTheSystemRootUninstallsCompletely() throws {
        let builder = InstanceBuilder(paths: paths)
        let result = try builder.build(BuildRequest(sourceBundle: sourceApp,
                                                    facts: facts(for: sourceApp),
                                                    number: 1,
                                                    name: "Removable",
                                                    installRoot: paths.systemBundlesDir))
        XCTAssertNoThrow(try builder.validateRemoval(instance: result.instance,
                                                     scope: .launcherAndData))
        _ = try builder.remove(instance: result.instance, scope: .launcherAndData)

        XCTAssertFalse(FileManager.default.fileExists(atPath: result.instance.bundlePath))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: paths.instanceDir(result.instance.id).path))
    }

    func testARebuildKeepsAnInstanceInTheRootItIsAlreadyIn() throws {
        let builder = InstanceBuilder(paths: paths)
        let result = try builder.build(BuildRequest(sourceBundle: sourceApp,
                                                    facts: facts(for: sourceApp),
                                                    number: 1,
                                                    name: "Staying",
                                                    installRoot: paths.systemBundlesDir))
        let rebuilt = try builder.rebuild(instance: result.instance,
                                          sourceBundle: sourceApp,
                                          facts: facts(for: sourceApp),
                                          acknowledgedSharedCredentialStore: false)
        XCTAssertEqual(URL(fileURLWithPath: rebuilt.instance.bundlePath)
            .deletingLastPathComponent().standardizedFileURL.path,
                       paths.systemBundlesDir.standardizedFileURL.path,
                       "a rebuild must not silently relocate a launcher")
    }

    /// Existing instances predate the second root and must be unaffected by its
    /// existence — including when the second root does not exist on disk at all.
    func testAnExistingInstanceKeepsWorkingWithNoSystemRootOnDisk() throws {
        let builder = InstanceBuilder(paths: paths)
        let result = try builder.build(BuildRequest(sourceBundle: sourceApp,
                                                    facts: facts(for: sourceApp),
                                                    number: 1,
                                                    name: "Existing"))
        try? FileManager.default.removeItem(at: paths.systemBundlesDir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.systemBundlesDir.path))

        let registry = try Registry(paths: paths)
        let report = try LauncherReconciler(paths: paths, scanner: AppScanner(log: .silent), log: .silent).reconcile(registry: registry)
        XCTAssertEqual(report.launchersFound, 1)
        XCTAssertNoThrow(try builder.validateRemoval(instance: result.instance,
                                                     scope: .launcherAndData))
        XCTAssertEqual(OrphanSweeper(paths: paths).sweep(registry: registry)
            .filter { $0.kind == .unregisteredBundle }.count, 0)
    }

    // MARK: Permission failure

    func testAnUnwritableSystemRootFailsWithAnActionableMessage() throws {
        let blocked = MALPaths(support: paths.support,
                              bundlesDir: paths.bundlesDir,
                              systemBundlesDir: URL(fileURLWithPath: "/System/LaunchAgain-should-not-exist"),
                              userLibrary: paths.userLibrary)
        XCTAssertThrowsError(try blocked.prepareBundleRoot(blocked.systemBundlesDir)) { error in
            let text = "\(error)"
            XCTAssertTrue(text.contains("administrator"), "got \(text)")
            // This assertion used to require the message to say "install this instance in
            // your own Applications folder instead". That was wrong on two counts, and
            // the test was encoding the mistake: there is no user-facing root choice for
            // it to point at, and for LM Studio — the one application that needs this
            // directory at all — the user's own Applications folder is the single place
            // it will not run. What the message must do is name the directory and say
            // who can grant access.
            XCTAssertTrue(text.contains(blocked.systemBundlesDir.path), "got \(text)")
            XCTAssertFalse(text.contains("your own Applications folder"),
                           "the message offers a choice the product does not provide")
            XCTAssertFalse(text.contains("LaunchAgain does not ask for administrator rights") == false,
                           "the message must still say what LaunchAgain will not do")
            // This branch — the directory does not exist — suggests no command at all.
            XCTAssertFalse(text.contains("sudo"),
                           "nothing here needs a command; the fix is to have one created: \(text)")
        }
    }

    /// B2 — the branch the documents were wrong about.
    ///
    /// `/Applications/LaunchAgain` existing and being read-only is the likelier real
    /// failure, and that message **does** contain the word `sudo`: it suggests
    /// `sudo chown -R $(whoami) <path>`. VALIDATION claimed the word never appeared,
    /// which was true only of the not-exists branch above.
    ///
    /// The property worth asserting is not the absence of a word. It is that the command
    /// is a suggestion the user may choose to run, and that LaunchAgain does not run it
    /// — so this test asserts the suggestion is well-formed, names the directory it is
    /// about, and is accompanied by the sentence saying the product will not do it.
    func testAnExistingReadOnlyRootSuggestsACommandAndSaysItWillNotRunIt() throws {
        let existing = paths.support.appendingPathComponent("read-only-root")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500],
                                              ofItemAtPath: existing.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                   ofItemAtPath: existing.path)
        }

        let blocked = MALPaths(support: paths.support,
                               bundlesDir: paths.bundlesDir,
                               systemBundlesDir: existing,
                               userLibrary: paths.userLibrary)
        XCTAssertThrowsError(try blocked.prepareBundleRoot(existing)) { error in
            let text = "\(error)"
            XCTAssertTrue(text.contains("exists but"), "got \(text)")
            XCTAssertTrue(text.contains(existing.path), "the message must name the directory: \(text)")
            XCTAssertTrue(text.contains("administrator"), "got \(text)")
            // The word appears, and it appears exactly once, inside a quoted command
            // about this directory and nothing else.
            XCTAssertTrue(text.contains("`sudo chown -R $(whoami) \(existing.path)`"),
                          "the suggested command is not the one documented: \(text)")
            XCTAssertEqual(text.components(separatedBy: "sudo").count - 1, 1,
                           "sudo appears somewhere other than the one suggested command: \(text)")
            XCTAssertTrue(text.contains("does not run any command for you"),
                          "a suggested command must come with the statement that it is only a suggestion: \(text)")
        }
    }

    /// The claim underneath all of that: LaunchAgain does not escalate. It runs a fixed,
    /// enumerated set of Apple-supplied tools by absolute path, and `sudo` is not among
    /// them — so no message it prints can be describing something it is about to do.
    func testTheProductNeverRunsAPrivilegedTool() {
        let executables = ProcessRunner.Tool.allCases.map(\.rawValue)
        XCTAssertFalse(executables.isEmpty)
        for path in executables {
            XCTAssertTrue(path.hasPrefix("/"), "tools are resolved by absolute path, not PATH: \(path)")
            let name = (path as NSString).lastPathComponent
            XCTAssertFalse(["sudo", "osascript", "security", "authopen", "SystemPolicy"].contains(name),
                           "\(name) escalates or bypasses something this product promises not to touch")
        }
    }
}
#endif
