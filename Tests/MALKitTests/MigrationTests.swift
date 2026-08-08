#if canImport(Darwin)
import XCTest
@testable import MALKit
@testable import MALCore

/// Renaming the product moves two directories that instances point into by absolute path.
/// Getting that wrong would leave someone's signed-in instances pointing at profiles that
/// no longer exist, which is the worst kind of failure this project can have: silent, and
/// looking exactly like being logged out.
final class MigrationTests: XCTestCase {

    private var root: URL!
    private var legacy: MALPaths!
    private var current: MALPaths!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mal-migration-\(UUID().uuidString)")
        legacy = MALPaths(support: root.appendingPathComponent("Library/Application Support/MultipleAppsLauncher"),
                          bundlesDir: root.appendingPathComponent("Applications/Multiple Apps Launcher"))
        current = MALPaths(support: root.appendingPathComponent("Library/Application Support/LaunchAgain"),
                           bundlesDir: root.appendingPathComponent("Applications/LaunchAgain"))
        try legacy.createAll()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func seedLegacyInstallation(instanceID: UUID) throws {
        // A profile with something recognisable in it.
        let profile = legacy.instanceDataDir(instanceID)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try Data("signed in".utf8).write(to: profile.appendingPathComponent("session.txt"))

        // A registry that refers to both old directories by absolute path.
        let registry = """
        {
          "schemaVersion": 1,
          "apps": [{
            "appKey": "com.example.app",
            "displayName": "Example",
            "sourcePath": "/Applications/Example.app",
            "sourceVersion": "1.0",
            "nextInstanceNumber": 2,
            "instances": [{
              "id": "\(instanceID.uuidString)",
              "number": 1,
              "name": "Work",
              "accountLabel": "",
              "mode": "full",
              "bundlePath": "\(legacy.bundlesDir.path)/Example 1 – Work.app",
              "dataPath": "\(profile.path)",
              "badge": { "scale": 0.36, "position": "bottomTrailing", "shape": "circle",
                         "colorHex": "#1B6EF3", "outlined": true },
              "builtFromSourceVersion": "1.0",
              "clonedBundleIdentifier": "com.example.app.mal1-abc",
              "extraArguments": [], "extraEnvironment": {},
              "createdAt": "2026-01-01T00:00:00Z",
              "buildNotes": []
            }]
          }]
        }
        """
        try Data(registry.utf8).write(to: legacy.registryFile)

        // A launcher bundle whose instance config points into the old support directory.
        let bundle = legacy.bundlesDir.appendingPathComponent("Example 1 – Work.app")
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents/Resources"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents/MacOS"),
                                                withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"),
                                         to: bundle.appendingPathComponent("Contents/MacOS/mal-shim"))
        try BundleAssembler.writeInfoPlist(["CFBundleIdentifier": "com.example.app.mal1-abc",
                                            "CFBundleExecutable": "mal-shim",
                                            "CFBundleName": "Example"],
                                           bundle: bundle)
        let config = InstanceConfig(mode: .full, dataPath: profile.path, realExecutableName: "Example.real")
        try Data(config.serialized().utf8)
            .write(to: bundle.appendingPathComponent("Contents/Resources/MALInstance.conf"))
    }

    func testAnExistingInstallationIsMovedIntact() throws {
        let id = UUID()
        try seedLegacyInstallation(instanceID: id)

        let report = Migration.migrateIfNeeded(to: current, from: legacy)
        XCTAssertTrue(report.didAnything)

        // The directories moved.
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.registryFile.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: current.bundlesDir.appendingPathComponent("Example 1 – Work.app").path))

        // The profile came with it, contents and all.
        let movedProfile = current.instanceDataDir(id).appendingPathComponent("session.txt")
        XCTAssertEqual(try String(contentsOf: movedProfile, encoding: .utf8), "signed in")

        // The registry now points at the new locations, and the number is untouched.
        let registry = try Registry(paths: current)
        let instance = try XCTUnwrap(registry.app("com.example.app")?.instance(withNumber: 1))
        XCTAssertEqual(instance.name, "Work")
        XCTAssertTrue(instance.dataPath.hasPrefix(current.support.path),
                      "the stored profile path must follow the move, got \(instance.dataPath)")
        XCTAssertTrue(instance.bundlePath.hasPrefix(current.bundlesDir.path))
        XCTAssertFalse(instance.dataPath.contains("MultipleAppsLauncher"))
    }

    /// The part that is easy to forget: the absolute path inside the bundle, which is
    /// what the instance actually launches with.
    func testTheInstanceConfigInsideEachBundleIsRewritten() throws {
        let id = UUID()
        try seedLegacyInstallation(instanceID: id)
        let report = Migration.migrateIfNeeded(to: current, from: legacy)
        XCTAssertEqual(report.repairedBundles, 1)

        let configURL = current.bundlesDir
            .appendingPathComponent("Example 1 – Work.app/Contents/Resources/MALInstance.conf")
        let config = try InstanceConfig.parse(String(contentsOf: configURL, encoding: .utf8))
        XCTAssertEqual(config.dataPath, current.instanceDataDir(id).path)
        XCTAssertFalse(config.dataPath.contains("MultipleAppsLauncher"))
    }

    func testMigrationIsIdempotent() throws {
        try seedLegacyInstallation(instanceID: UUID())
        let first = Migration.migrateIfNeeded(to: current, from: legacy)
        XCTAssertTrue(first.didAnything)

        let second = Migration.migrateIfNeeded(to: current, from: legacy)
        XCTAssertFalse(second.didAnything, "a second run must be a no-op, not a second move")
    }

    func testNothingHappensWithoutAnOldInstallation() {
        let report = Migration.migrateIfNeeded(to: current, from: legacy)
        XCTAssertFalse(report.didAnything)
    }

    /// A fresh install that has already been used, plus an old one left behind: neither
    /// side may be clobbered.
    func testAnExistingNewInstallationIsNotOverwritten() throws {
        try current.createAll()
        let existing = UUID()
        try FileManager.default.createDirectory(at: current.instanceDataDir(existing),
                                                withIntermediateDirectories: true)
        try Data("new install".utf8)
            .write(to: current.instanceDataDir(existing).appendingPathComponent("marker.txt"))

        let old = UUID()
        try seedLegacyInstallation(instanceID: old)

        _ = Migration.migrateIfNeeded(to: current, from: legacy)

        XCTAssertEqual(try String(contentsOf: current.instanceDataDir(existing)
                                    .appendingPathComponent("marker.txt"), encoding: .utf8),
                       "new install", "the newer installation's data must survive")
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.instanceDataDir(old).path),
                      "and the older installation's profile must be brought across")
    }

    func testDuplicateProfileUUIDCreatesDurableConflictAndNeverMergesEitherSide() throws {
        try current.createAll()
        let id = UUID()
        let legacyProfile = legacy.instanceDir(id)
        let currentProfile = current.instanceDir(id)
        try FileManager.default.createDirectory(at: legacyProfile, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: currentProfile, withIntermediateDirectories: true)
        try Data("legacy signed-in session".utf8)
            .write(to: legacyProfile.appendingPathComponent("session.txt"))
        try Data("current signed-in session".utf8)
            .write(to: currentProfile.appendingPathComponent("session.txt"))

        let first = Migration.migrateIfNeeded(to: current, from: legacy)

        XCTAssertFalse(first.didAnything,
                       "recording a conflict is not a migration and must not be reported as one")
        XCTAssertEqual(first.profileConflicts.map(\.instanceID), [id])
        XCTAssertEqual(try String(contentsOf: legacyProfile.appendingPathComponent("session.txt"),
                                  encoding: .utf8), "legacy signed-in session")
        XCTAssertEqual(try String(contentsOf: currentProfile.appendingPathComponent("session.txt"),
                                  encoding: .utf8), "current signed-in session")

        let marker = current.support
            .appendingPathComponent("migration-conflicts/\(id.uuidString).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        let markerData = try Data(contentsOf: marker)

        let second = Migration.migrateIfNeeded(to: current, from: legacy)
        XCTAssertFalse(second.didAnything, "subsequent launches must be migration no-ops")
        XCTAssertEqual(try Data(contentsOf: marker), markerData,
                       "the durable marker must not be rewritten on every launch")

        let registry = try Registry(paths: current)
        let findings = OrphanSweeper(paths: current).sweep(registry: registry)
        XCTAssertTrue(findings.contains {
            $0.kind == .migrationConflict && $0.detail.contains(id.uuidString)
        }, "Health must expose the unresolved collision")
    }

    // MARK: Retiring the pre-rename store

    /// The one route that touches a directory outside the product's current two roots.
    /// It must only ever accept the exact pre-rename paths, whatever it is handed.
    func testRetiringTheLegacyStoreRefusesAnyPathThatIsNotTheRealLegacyStore() throws {
        let id = UUID()
        try seedLegacyInstallation(instanceID: id)

        // The fixture's `legacy` is a temporary directory, not ~/Library/Application
        // Support/MultipleAppsLauncher, so the exact-path check must reject it. This is
        // the assertion that stops a registry value, a display name or a crafted
        // argument from redirecting the deletion.
        XCTAssertThrowsError(
            try Migration.trashLegacyStore(paths: current, legacy: legacy)) { error in
                guard case .invalidPath(_, let reason) = error as? MALError else {
                    return XCTFail("expected invalidPath, got \(error)")
                }
                XCTAssertTrue(reason.contains("exact pre-rename"), reason)
            }
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.instanceDir(id).path),
                      "a refused retirement must not have moved anything")
    }

    /// Retiring the store the product is currently using would delete the live
    /// installation, so it is refused before the path check is even reached.
    func testRetiringTheLegacyStoreRefusesTheStoreInUse() throws {
        XCTAssertThrowsError(
            try Migration.trashLegacyStore(paths: current, legacy: current)) { error in
                guard case .invalidPath(_, let reason) = error as? MALError else {
                    return XCTFail("expected invalidPath, got \(error)")
                }
                XCTAssertTrue(reason.contains("currently in use"), reason)
            }
    }

    func testLegacyResidueReportsWhatIsThereWithoutChangingIt() throws {
        let id = UUID()
        try seedLegacyInstallation(instanceID: id)

        let residue = Migration.legacyResidue(paths: current, legacy: legacy)
        XCTAssertFalse(residue.isEmpty)
        XCTAssertEqual(residue.supportPath, legacy.support.path)
        XCTAssertTrue(residue.profileIdentifiers.contains(id.uuidString))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.instanceDir(id).path),
                      "reporting is read-only")
    }

    /// An effectively-empty pre-rename directory must be **left alone**, not deleted.
    ///
    /// This is the v1.1 bug the pull request claims was removed, and it survived
    /// reintroduction against the whole suite: `migrateIfNeeded` used to `removeItem()`
    /// both legacy directories whenever they held nothing "meaningful", on every
    /// `InstanceManager` construction — including a read-only `doctor` run — logging at
    /// `.debug`, below the configured level, so there was no record that it had happened.
    /// Those paths are outside both roots this product may delete inside, and removing
    /// them silently contradicts both the promise that nothing goes without being asked
    /// and the `--retire-legacy-store` route that exists precisely to remove them on
    /// request.
    ///
    /// "Effectively empty" is the exact condition the old code deleted on: directories
    /// and dotfiles only, no ordinary files.
    func testAnEmptyPreRenameStoreIsLeftInPlaceRatherThanSilentlyDeleted() throws {
        let fm = FileManager.default
        // Exactly what `isEffectivelyEmpty` considers empty: subdirectories and a
        // dotfile, and nothing else.
        try fm.createDirectory(at: legacy.support.appendingPathComponent("instances"),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: legacy.support.appendingPathComponent("logs"),
                               withIntermediateDirectories: true)
        try Data().write(to: legacy.support.appendingPathComponent(".DS_Store"))
        try fm.createDirectory(at: legacy.bundlesDir, withIntermediateDirectories: true)

        let report = Migration.migrateIfNeeded(to: current, from: legacy)

        XCTAssertFalse(report.didAnything,
                       "an empty pre-rename store is not a migration")
        XCTAssertTrue(fm.fileExists(atPath: legacy.support.path),
                      "the pre-rename support directory was deleted without being asked. It is outside both roots this product may delete inside, and `doctor --retire-legacy-store` is the route that removes it on request.")
        XCTAssertTrue(fm.fileExists(atPath: legacy.bundlesDir.path),
                      "the pre-rename applications directory was deleted without being asked")
        XCTAssertTrue(fm.fileExists(
            atPath: legacy.support.appendingPathComponent("instances").path),
                      "the contents of the pre-rename store were deleted without being asked")
    }

    /// The same, through the object that actually runs migration on every launch — a
    /// plain `InstanceManager` construction, which is what a read-only `doctor` does.
    func testConstructingAManagerDoesNotDeleteAnEmptyPreRenameStore() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: legacy.support.appendingPathComponent("instances"),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: legacy.bundlesDir, withIntermediateDirectories: true)

        _ = try InstanceManager(paths: current, migrateFrom: legacy)

        XCTAssertTrue(fm.fileExists(atPath: legacy.support.path),
                      "opening the store deleted the pre-rename directory. `doctor` opens the store.")
        XCTAssertTrue(fm.fileExists(atPath: legacy.bundlesDir.path))
    }

    func testLegacyResidueIsEmptyWhenThereIsNoOldStore() {
        let residue = Migration.legacyResidue(
            paths: current,
            legacy: .rooted(at: root.appendingPathComponent("no-such-store")))
        XCTAssertTrue(residue.isEmpty)
        XCTAssertEqual(residue.totalBytes, 0)
    }

    func testCustomManagerRootNeverImplicitlyMigratesARealOrLegacyStore() throws {
        let id = UUID()
        try seedLegacyInstallation(instanceID: id)

        let manager = try InstanceManager(paths: current)

        XCTAssertTrue(manager.registry.allInstances.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.instanceDir(id).path),
                      "an injected/test root must never pull data from another root")
        XCTAssertFalse(FileManager.default.fileExists(atPath: current.instanceDir(id).path))
    }
}
#endif
