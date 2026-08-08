#if canImport(Darwin)
import XCTest
@testable import MALKit
@testable import MALCore

final class LauncherReconciliationTests: XCTestCase {
    private var root: URL!
    private var paths: MALPaths!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("launchagain-recovery-\(UUID().uuidString)")
        paths = .rooted(at: root)
        try paths.createAll()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testFreshInstallationRecoversInstalledLauncherAndProfileIdentity() throws {
        let expected = try makeManifestLauncher(number: 2, name: "Work")

        // Simulate uninstall/reinstall with the launcher and profile left in place but
        // no registry. A new manager must populate its first snapshot immediately.
        try? FileManager.default.removeItem(at: paths.registryFile)
        try? FileManager.default.removeItem(at: paths.registryFile.appendingPathExtension("bak"))
        let manager = try InstanceManager(paths: paths)

        XCTAssertEqual(manager.registry.allInstances.count, 1)
        let recovered = try XCTUnwrap(manager.registry.instance(expected.instance.id))
        XCTAssertEqual(recovered.app.appKey, expected.appKey)
        XCTAssertEqual(recovered.instance.id, expected.instance.id)
        XCTAssertEqual(recovered.instance.number, expected.instance.number)
        XCTAssertEqual(recovered.instance.name, expected.instance.name)
        XCTAssertEqual(recovered.instance.accountLabel, expected.instance.accountLabel)
        XCTAssertEqual(recovered.instance.bundlePath, expected.instance.bundlePath)
        XCTAssertEqual(recovered.instance.dataPath, expected.instance.dataPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recovered.instance.dataPath))
        XCTAssertEqual(manager.initialLauncherReconciliation.recoveredInstanceIDs,
                       [expected.instance.id])
    }

    func testExplicitRemovalTombstonePreventsAStaleLauncherFromReappearing() throws {
        let expected = try makeManifestLauncher(number: 1, name: "Temporary")
        let first = try InstanceManager(paths: paths)
        XCTAssertNotNil(first.registry.instance(expected.instance.id))

        // This models a delayed filesystem/Trash event: the registry deletion has
        // committed while an old launcher directory is still visible for one scan.
        try first.launcherReconciler.markRemoved(expected.instance.id)
        try first.registry.removeInstance(expected.instance.id)

        let second = try InstanceManager(paths: paths)
        XCTAssertNil(second.registry.instance(expected.instance.id))
        XCTAssertTrue(second.initialLauncherReconciliation.recoveredInstanceIDs.isEmpty)
    }

    func testCompletedUninstallRemovesOnlyThatInstancesEntireOwnedFootprint() throws {
        let removed = try makeManifestLauncher(number: 1, name: "Remove")
        let kept = try makeManifestLauncher(number: 2, name: "Keep")
        let external = root.appendingPathComponent("user-owned/do-not-touch.txt")
        try FileManager.default.createDirectory(
            at: external.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: external)

        let ownedDirectory = paths.instanceDir(removed.instance.id)
        try FileManager.default.createDirectory(
            at: paths.instanceLogsDir(removed.instance.id), withIntermediateDirectories: true)
        try Data("log".utf8).write(
            to: paths.instanceLogsDir(removed.instance.id).appendingPathComponent("run.log"))
        try Data("999999\n".utf8).write(to: paths.instanceLockFile(removed.instance.id))
        let identifier = removed.instance.clonedBundleIdentifier
        let associated = [
            paths.userLibrary.appendingPathComponent(
                "Preferences/\(identifier).plist"),
            paths.userLibrary.appendingPathComponent(
                "Preferences/\(identifier).plist.lockfile"),
            paths.userLibrary.appendingPathComponent(
                "SyncedPreferences/\(identifier).plist"),
            paths.userLibrary.appendingPathComponent(
                "Preferences/ByHost/\(identifier).fixture.plist"),
            paths.userLibrary.appendingPathComponent(
                "Caches/\(identifier)"),
            paths.userLibrary.appendingPathComponent(
                "Caches/\(identifier).ShipIt"),
            paths.userLibrary.appendingPathComponent(
                "Caches/com.apple.nsurlsessiond/Downloads/\(identifier)"),
            paths.userLibrary.appendingPathComponent(
                "Application Support/\(identifier)"),
            paths.userLibrary.appendingPathComponent(
                "Saved Application State/\(identifier).savedState"),
            paths.userLibrary.appendingPathComponent(
                "HTTPStorages/\(identifier)"),
            paths.userLibrary.appendingPathComponent(
                "HTTPStorages/\(identifier).binarycookies"),
            paths.userLibrary.appendingPathComponent(
                "WebKit/\(identifier)"),
            paths.userLibrary.appendingPathComponent(
                "Cookies/\(identifier).binarycookies"),
            paths.userLibrary.appendingPathComponent(
                "Logs/\(identifier)"),
            paths.userLibrary.appendingPathComponent(
                "Containers/\(identifier)"),
            paths.userLibrary.appendingPathComponent(
                "Application Scripts/\(identifier)"),
            paths.userLibrary.appendingPathComponent(
                "LaunchAgents/\(identifier).plist"),
            paths.userLibrary.appendingPathComponent(
                "Caches/LaunchAgain/instances/\(removed.instance.id.uuidString)"),
        ]
        for artifact in associated {
            try FileManager.default.createDirectory(
                at: artifact.deletingLastPathComponent(), withIntermediateDirectories: true)
            if artifact.pathExtension == "plist" {
                try Data("preference".utf8).write(to: artifact)
            } else {
                try FileManager.default.createDirectory(
                    at: artifact, withIntermediateDirectories: true)
            }
        }
        let sourcePreference = paths.userLibrary
            .appendingPathComponent("Preferences/com.example.recoverable.plist")
        try Data("source".utf8).write(to: sourcePreference)

        let manager = try InstanceManager(paths: paths)
        manager.log.info(
            "instance \(removed.instance.id.uuidString) "
                + "\(removed.instance.clonedBundleIdentifier) "
                + "\(removed.instance.bundlePath) "
                + "\(removed.instance.dataPath)")
        manager.log.info("unrelated application log record must remain")
        _ = manager.directorySizeCache.size(of: URL(fileURLWithPath: removed.instance.dataPath))
        let report = try manager.remove(removed.instance, scope: .launcherAndData)

        XCTAssertTrue(report.removedBundle)
        XCTAssertTrue(report.removedData)
        XCTAssertNil(manager.registry.instance(removed.instance.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: removed.instance.bundlePath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownedDirectory.path),
                       "profile, logs and lock must be removed as one owned directory")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: paths.removalTombstoneFile(removed.instance.id).path),
            "completed uninstall must not leave per-instance recovery metadata")
        XCTAssertEqual(report.removedAssociatedArtifacts.count, associated.count)
        for artifact in associated {
            XCTAssertFalse(FileManager.default.fileExists(atPath: artifact.path))
        }

        XCTAssertNotNil(manager.registry.instance(kept.instance.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.instance.bundlePath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.instance.dataPath))
        XCTAssertEqual(try String(contentsOf: sourcePreference, encoding: .utf8), "source",
                       "source-app preference domains must never be derived or removed")
        XCTAssertEqual(try String(contentsOf: external, encoding: .utf8), "mine")

        if let cacheData = try? Data(contentsOf: paths.directorySizeCacheFile),
           let cacheText = String(data: cacheData, encoding: .utf8) {
            XCTAssertFalse(cacheText.contains(removed.instance.id.uuidString),
                           "shared cache must not retain the removed instance path")
        }
        let sharedLog = try String(
            contentsOf: paths.logsDir.appendingPathComponent("launchagain.log"),
            encoding: .utf8)
        for identity in [
            removed.instance.id.uuidString,
            removed.instance.clonedBundleIdentifier,
            removed.instance.bundlePath,
            removed.instance.dataPath,
        ] {
            XCTAssertFalse(
                sharedLog.contains(identity),
                "completed uninstall must scrub the selected instance identity from the shared log")
        }
        XCTAssertTrue(sharedLog.contains("unrelated application log record must remain"))
    }

    func testCallerSuppliedDamageCannotRedirectAuthoritativeRemoval() throws {
        let manifest = try makeManifestLauncher(number: 1, name: "Guarded")
        let manager = try InstanceManager(paths: paths)
        var damaged = manifest.instance
        damaged.clonedBundleIdentifier = "com.apple.finder"
        damaged.bundlePath = paths.bundlesDir.appendingPathComponent("Not The Instance.app").path

        XCTAssertNoThrow(try manager.remove(damaged, scope: .launcherAndData))
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifest.instance.bundlePath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifest.instance.dataPath))
        XCTAssertNil(manager.registry.instance(manifest.instance.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: damaged.bundlePath))
    }

    func testCorruptRegistryPathCannotDeleteRootsOrAnotherInstance() throws {
        let first = try makeManifestLauncher(number: 1, name: "First")
        let second = try makeManifestLauncher(number: 2, name: "Second")
        let manager = try InstanceManager(paths: paths)

        try manager.registry.updateInstance(first.instance.id) {
            $0.bundlePath = second.instance.bundlePath
        }
        XCTAssertThrowsError(try manager.remove(first.instance, scope: .launcherAndData))
        for manifest in [first, second] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: manifest.instance.bundlePath))
            XCTAssertTrue(FileManager.default.fileExists(atPath: manifest.instance.dataPath))
            XCTAssertNotNil(manager.registry.instance(manifest.instance.id))
        }

        try manager.registry.updateInstance(first.instance.id) {
            $0.bundlePath = paths.bundlesDir.path
        }
        XCTAssertThrowsError(try manager.remove(first.instance, scope: .launcherAndData))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.bundlesDir.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.instance.bundlePath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.instance.dataPath))
    }

    func testCompletedDeleteIsAbsentFromPrimaryBackupAndFallbackRecovery() throws {
        let removed = try makeManifestLauncher(number: 1, name: "Delete")
        let kept = try makeManifestLauncher(number: 2, name: "Keep")
        let manager = try InstanceManager(paths: paths)

        _ = try manager.remove(removed.instance, scope: .launcherAndData)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for url in [paths.registryFile, paths.registryFile.appendingPathExtension("bak")] {
            let document = try decoder.decode(
                RegistryDocument.self,
                from: Data(contentsOf: url))
            XCTAssertFalse(document.apps.flatMap(\.instances).contains {
                $0.id == removed.instance.id
            })
            XCTAssertTrue(document.apps.flatMap(\.instances).contains {
                $0.id == kept.instance.id
            })
        }

        try Data("{corrupt-primary".utf8).write(to: paths.registryFile)
        let restarted = try InstanceManager(paths: paths)
        XCTAssertNil(restarted.registry.instance(removed.instance.id))
        XCTAssertNotNil(restarted.registry.instance(kept.instance.id))
    }

    func testAdvancedProfileCannotOverlapSupportOrAnotherInstance() throws {
        let first = try makeManifestLauncher(number: 1, name: "First")
        let second = try makeManifestLauncher(number: 2, name: "Second")
        let manager = try InstanceManager(paths: paths)

        for forbidden in [
            paths.support.appendingPathComponent("custom-profile").path,
            second.instance.dataPath,
            URL(fileURLWithPath: second.instance.dataPath)
                .appendingPathComponent("nested").path,
        ] {
            XCTAssertThrowsError(
                try manager.updateAdvancedSettings(
                    first.instance,
                    arguments: [],
                    environment: [:],
                    forceLite: false,
                    dataPath: forbidden))
        }
        XCTAssertEqual(
            manager.registry.instance(first.instance.id)?.instance.dataPath,
            first.instance.dataPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.instance.bundlePath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.instance.bundlePath))
    }

    func testConfirmedInterruptedUninstallResumesOnNextLaunch() throws {
        let removed = try makeManifestLauncher(number: 1, name: "Resume")
        let first = try InstanceManager(paths: paths)
        try first.launcherReconciler.markRemoved(removed.instance, deleteData: true)

        let restarted = try InstanceManager(paths: paths)

        XCTAssertNil(restarted.registry.instance(removed.instance.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: removed.instance.bundlePath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: removed.instance.dataPath))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: paths.removalTombstoneFile(removed.instance.id).path))
        restarted.log.flush()
        let sharedLog = try String(
            contentsOf: paths.logsDir.appendingPathComponent("launchagain.log"),
            encoding: .utf8)
        XCTAssertFalse(sharedLog.contains(removed.instance.id.uuidString))
        XCTAssertFalse(sharedLog.contains(removed.instance.clonedBundleIdentifier))
    }

    func testTamperedOrDuplicateRecoveryIdentityIsNeverSilentlyAdopted() throws {
        let original = try makeManifestLauncher(number: 1, name: "Original")
        let duplicateURL = paths.bundlesDir.appendingPathComponent("Duplicate.app")
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: original.instance.bundlePath),
            to: duplicateURL)

        try? FileManager.default.removeItem(at: paths.registryFile)
        try? FileManager.default.removeItem(at: paths.registryFile.appendingPathExtension("bak"))
        let manager = try InstanceManager(paths: paths)

        XCTAssertNil(manager.registry.instance(original.instance.id))
        XCTAssertFalse(manager.initialLauncherReconciliation.conflicts.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.instance.bundlePath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: duplicateURL.path))
    }

    func testTempAndDarwinCacheArtifactsUseExactBoundedIdentity() throws {
        let id = UUID()
        let identifier = Validation.cloneBundleIdentifier(
            original: "com.example.temp",
            number: 1,
            instanceID: id)
        let instance = Instance(
            id: id,
            number: 1,
            name: "Temp",
            bundlePath: paths.bundlesDir.appendingPathComponent("Temp.app").path,
            dataPath: paths.instanceDataDir(id).path,
            clonedBundleIdentifier: identifier)
        let temp = root.appendingPathComponent("darwin/T")
        let darwinCache = root.appendingPathComponent("darwin/C")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: darwinCache, withIntermediateDirectories: true)
        let ownedTemp = temp.appendingPathComponent("\(identifier).ABC123")
        let decoyTemp = temp.appendingPathComponent("\(identifier).short")
        let ownedCache = darwinCache.appendingPathComponent(identifier)
        for url in [ownedTemp, decoyTemp, ownedCache] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        let cleaner = InstanceArtifactCleaner(
            paths: paths,
            temporaryDirectory: temp)
        let report = try cleaner.removeArtifacts(for: instance)

        XCTAssertTrue(report.removedPaths.contains(ownedTemp.path))
        XCTAssertTrue(report.removedPaths.contains(ownedCache.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownedTemp.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownedCache.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: decoyTemp.path))
    }

    /// The uninstall sweep against the shapes a real clone of a
    /// shared-credential-store app produces, and — the part that matters — against the
    /// shapes it produces under the *vendor's* identifier, which are shared with the
    /// original application and every other instance and must survive.
    func testTheSweepTakesCloneKeyedArtifactsAndLeavesVendorKeyedOnesAlone() throws {
        let id = UUID()
        let vendor = "com.example.vendor"
        let identifier = Validation.cloneBundleIdentifier(
            original: vendor, number: 1, instanceID: id)
        let instance = Instance(
            id: id,
            number: 1,
            name: "Residue",
            bundlePath: paths.bundlesDir.appendingPathComponent("Residue.app").path,
            dataPath: paths.instanceDataDir(id).path,
            clonedBundleIdentifier: identifier)

        let library = paths.userLibrary
        // Measured against a real ChatGPT clone: these four are what it actually wrote
        // outside its profile, plus the App Group and container shapes an app of this
        // class can create.
        let owned = [
            "Preferences/\(identifier).plist",
            "Caches/\(identifier)",
            "HTTPStorages/\(identifier)",
            "HTTPStorages/\(identifier).binarycookies",
            "Group Containers/\(identifier)",
            "Containers/\(identifier)",
            "WebKit/\(identifier)",
            "Saved Application State/\(identifier).savedState",
        ]
        // Written under the vendor's identity, shared with the original application.
        // Deleting any of these when one instance is uninstalled destroys data the
        // instance does not own.
        let shared = [
            "Logs/\(vendor)",
            "Caches/\(vendor)",
            "Preferences/\(vendor).plist",
            "Group Containers/TEAMID123.\(vendor)",
            "Application Support/\(vendor)",
        ]

        for relative in owned + shared {
            let url = library.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if url.pathExtension.isEmpty {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                try Data("x".utf8).write(to: url)
            }
        }

        let cleaner = InstanceArtifactCleaner(paths: paths)
        _ = try cleaner.removeArtifacts(for: instance)

        for relative in owned {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: library.appendingPathComponent(relative).path),
                "the instance's own artifact survived: \(relative)")
        }
        for relative in shared {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: library.appendingPathComponent(relative).path),
                "uninstalling one instance destroyed something the original owns: \(relative)")
        }
    }

    /// A vendor App Group container is never a candidate, however it is spelled.
    func testAVendorGroupContainerIsNeverACandidate() throws {
        let id = UUID()
        let identifier = Validation.cloneBundleIdentifier(
            original: "com.openai.codex", number: 1, instanceID: id)
        let instance = Instance(
            id: id, number: 1, name: "Groups",
            bundlePath: paths.bundlesDir.appendingPathComponent("Groups.app").path,
            dataPath: paths.instanceDataDir(id).path,
            clonedBundleIdentifier: identifier)

        let candidates = try InstanceArtifactCleaner(paths: paths)
            .candidates(for: instance).map(\.path)

        XCTAssertTrue(candidates.contains {
            $0.hasSuffix("Group Containers/\(identifier)") })
        for path in candidates {
            XCTAssertFalse(path.contains("2DC432GLL2"),
                           "a team-prefixed group container is the vendor's: \(path)")
            XCTAssertFalse(path.hasSuffix("Group Containers/com.openai.codex"),
                           "the vendor's own container is not ours to delete: \(path)")
        }
    }

    func testMissingLauncherCannotDeleteAProfileStillOwnedByALiveProcess() throws {
        let manifest = try makeManifestLauncher(number: 1, name: "Running")
        let manager = try InstanceManager(paths: paths)
        try FileManager.default.removeItem(
            at: URL(fileURLWithPath: manifest.instance.bundlePath))

        let process = Process()
        let input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c", "read launchagain_hold", "launchagain-forget-fixture",
            "--user-data-dir=\(manifest.instance.dataPath)",
        ]
        process.standardInput = input
        var environment = ProcessInfo.processInfo.environment
        environment["MAL_INSTANCE_DATA_DIR"] = manifest.instance.dataPath
        process.environment = environment
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }
        let deadline = Date().addingTimeInterval(2)
        while ProcessInspector.dataDirectory(ofPID: process.processIdentifier)
                != manifest.instance.dataPath,
              Date() < deadline {
            usleep(10_000)
        }
        let lock = paths.instanceLockFile(manifest.instance.id)
        try Data(
            "\(process.processIdentifier)\n\(Date().timeIntervalSince1970)\n".utf8)
            .write(to: lock)

        XCTAssertThrowsError(
            try manager.forget(manifest.instance, alsoDeleteData: true))
        XCTAssertNotNil(manager.registry.instance(manifest.instance.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifest.instance.dataPath))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: paths.removalTombstoneFile(manifest.instance.id).path))
    }

    func testLiteLauncherCannotClaimSourceApplicationURLSchemes() throws {
        let manifest = try makeManifestLauncher(number: 1, name: "Lite")
        let manager = try InstanceManager(paths: paths)
        try manager.registry.updateInstance(manifest.instance.id) {
            $0.mode = .lite
        }

        XCTAssertThrowsError(
            try manager.claimURLSchemes(manifest.instance)) { error in
                XCTAssertTrue("\(error)".contains("Lite launchers"))
            }
    }

    func testBothCorruptRegistryCopiesArePreservedThenRecoveredFromLauncher() throws {
        let expected = try makeManifestLauncher(number: 3, name: "Recovered")
        try Data("{broken-primary".utf8).write(to: paths.registryFile)
        try Data("{broken-backup".utf8)
            .write(to: paths.registryFile.appendingPathExtension("bak"))

        let manager = try InstanceManager(paths: paths)

        XCTAssertTrue(manager.registry.recoveredFromCorruption)
        XCTAssertEqual(manager.registry.preservedCorruptFiles.count, 2)
        for path in manager.registry.preservedCorruptFiles {
            XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        }
        XCTAssertNotNil(manager.registry.instance(expected.instance.id))
        XCTAssertNoThrow(try Registry(paths: paths),
                         "the repaired registry must survive the next process launch")
    }

    func testLegacyLiteLauncherWithoutManifestIsStillRecovered() throws {
        let id = UUID()
        let source = try makeSourceApp()
        let data = paths.instanceDataDir(id)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let bundle = paths.bundlesDir.appendingPathComponent("Legacy 4 – Second.app")
        try FileManager.default.createDirectory(
            at: bundle.appendingPathComponent("Contents/Resources"),
            withIntermediateDirectories: true)
        let cloneID = Validation.cloneBundleIdentifier(
            original: "com.multipleappslauncher.instance",
            number: 4,
            instanceID: id)
        try BundleAssembler.writeInfoPlist([
            "CFBundleIdentifier": cloneID,
            "CFBundleDisplayName": "Legacy 4 – Second",
            "CFBundleName": "Legacy 4 – Second",
            "CFBundleExecutable": "mal-shim",
            "CFBundlePackageType": "APPL",
            "MALGeneratedBy": "LaunchAgain",
            "MALOriginalBundleIdentifier": "com.example.recoverable",
        ], bundle: bundle)
        try BundleAssembler.writeInstanceConfig(
            InstanceConfig(mode: .lite,
                           dataPath: data.path,
                           targetAppPath: source.path),
            into: bundle)

        let manager = try InstanceManager(paths: paths)
        let recovered = try XCTUnwrap(manager.registry.instance(id))
        XCTAssertEqual(recovered.app.appKey, "com.example.legacy")
        XCTAssertEqual(recovered.instance.number, 4)
        XCTAssertEqual(recovered.instance.name, "Second")
        XCTAssertEqual(manager.initialLauncherReconciliation.legacyLaunchersFound, 1)

        // Recovery reads the mode from the shim config on disk and records no
        // acknowledgement, because it has no evidence anyone was ever asked — inventing
        // one here is the thing the whole gate exists to prevent.
        //
        // This is why the rebuild allowance in `rebuildProposed` is not a closed
        // pre-gate population: a shipped build mints a row of exactly this shape every
        // time it adopts a launcher. See `SharedCredentialGateTests`.
        XCTAssertEqual(recovered.instance.mode, .lite)
        XCTAssertNil(recovered.instance.acknowledgedSharedCredentialStoreAt,
                     "recovery invented an acknowledgement it had no evidence for")
    }

    func testLegacyFullCloneIsRecoveredWhenItsSourceAppIsUnavailable() throws {
        let id = UUID()
        let data = paths.instanceDataDir(id)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let bundle = paths.bundlesDir.appendingPathComponent("Claude 1 – Personal.app")
        try FileManager.default.createDirectory(
            at: bundle.appendingPathComponent("Contents/Resources"),
            withIntermediateDirectories: true)
        let cloneID = Validation.cloneBundleIdentifier(
            original: "com.anthropic.claudefordesktop",
            number: 1,
            instanceID: id)
        try BundleAssembler.writeInfoPlist([
            "CFBundleIdentifier": cloneID,
            "CFBundleDisplayName": "Claude 1 – Personal",
            "CFBundleName": "Claude",
            "CFBundleExecutable": "mal-shim",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.24012.9",
            "MALGeneratedBy": "LaunchAgain",
            "MALOriginalBundleIdentifier": "com.anthropic.claudefordesktop",
        ], bundle: bundle)
        try BundleAssembler.writeInstanceConfig(
            InstanceConfig(mode: .full,
                           dataPath: data.path,
                           realExecutableName: "Claude.real"),
            into: bundle)

        let manager = try InstanceManager(paths: paths)
        let recovered = try XCTUnwrap(manager.registry.instance(id))
        XCTAssertEqual(recovered.app.appKey, "com.anthropic.claudefordesktop")
        XCTAssertEqual(recovered.app.displayName, "Claude")
        XCTAssertEqual(recovered.instance.name, "Personal")
        XCTAssertEqual(recovered.instance.number, 1)
        XCTAssertEqual(recovered.instance.dataPath, data.path)
    }

    // MARK: Legacy Terminal instances (created before the GUI-only boundary)

    /// The whole legacy contract in one test: an instance an earlier release created is
    /// still *found*, is still *refused* a launch, and is still *completely removable* —
    /// launcher, profile and registry entry — after the command-line-tool subsystem that
    /// created it was deleted.
    func testALegacyTerminalInstanceIsVisibleUnlaunchableAndFullyUninstallable() async throws {
        let legacy = try makeLegacyTerminalLauncher(number: 3, name: "Old Session")
        try? FileManager.default.removeItem(at: paths.registryFile)
        try? FileManager.default.removeItem(at: paths.registryFile.appendingPathExtension("bak"))

        // Visible: recovered from the launcher alone, with no registry to read.
        let manager = try InstanceManager(paths: paths)
        let pair = try XCTUnwrap(manager.registry.instance(legacy.id),
                                 "a legacy Terminal instance must survive into the dashboard")
        XCTAssertEqual(pair.instance.mechanism, .configEnvironment)
        XCTAssertTrue(pair.instance.mechanism.isLegacyTerminal)
        XCTAssertEqual(pair.app.appKey, "tool.codex")
        XCTAssertEqual(pair.app.displayName, "Codex")

        // Non-launchable, at the supervisor rather than only in the interface.
        do {
            _ = try await manager.supervisor.launch(pair.instance)
            XCTFail("a legacy Terminal instance must never be launched")
        } catch let error as MALError {
            guard case .notSupported = error else {
                return XCTFail("expected notSupported, got \(error)")
            }
        }

        // Not rebuildable either — a rebuild would have to run the deleted builder.
        XCTAssertThrowsError(try manager.renumber(appKey: "tool.codex"))

        // Fully uninstallable, including the profile the legacy instance owned.
        let profile = paths.instanceDir(legacy.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: profile.path))
        _ = try manager.remove(pair.instance, scope: .launcherAndData)

        XCTAssertNil(manager.registry.instance(legacy.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pair.instance.bundlePath),
                       "the legacy launcher must be gone")
        XCTAssertFalse(FileManager.default.fileExists(atPath: profile.path),
                       "the legacy instance's own directory must be gone")

        // And it must not come back on the next launch.
        let reopened = try InstanceManager(paths: paths)
        XCTAssertNil(reopened.registry.instance(legacy.id))
        XCTAssertTrue(reopened.registry.allInstances.isEmpty)
    }

    /// A legacy launcher whose bundle has already been dragged to the Trash still has a
    /// LaunchAgain-owned profile. Removing the entry must clear that profile too.
    func testALegacyTerminalInstanceWithAMissingLauncherStillUninstallsItsProfile() throws {
        let legacy = try makeLegacyTerminalLauncher(number: 4, name: "Vanished")
        let manager = try InstanceManager(paths: paths)
        let pair = try XCTUnwrap(manager.registry.instance(legacy.id))

        try FileManager.default.removeItem(at: URL(fileURLWithPath: pair.instance.bundlePath))
        let profile = paths.instanceDir(legacy.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: profile.path))

        _ = try manager.remove(pair.instance, scope: .launcherAndData)
        XCTAssertNil(manager.registry.instance(legacy.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: profile.path))
    }

    /// Builds the bundle a pre-GUI-only release planted for a command line tool: shim,
    /// `kind=tool` config, a `.command` script and a tool-shaped clone identifier.
    private func makeLegacyTerminalLauncher(number: Int, name: String) throws -> Instance {
        let id = UUID()
        let home = paths.instanceDataDir(id)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data("session".utf8).write(to: home.appendingPathComponent("auth.json"))

        let bundle = paths.bundlesDir.appendingPathComponent("Codex \(number) – \(name).app")
        try FileManager.default.createDirectory(
            at: bundle.appendingPathComponent("Contents/Resources"),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: bundle.appendingPathComponent("Contents/MacOS"),
            withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: BundleAssembler.locateShimBinary(),
            to: bundle.appendingPathComponent("Contents/MacOS/mal-shim"))

        let script = bundle.appendingPathComponent("Contents/Resources/Launch.command")
        try Data("#!/bin/sh\nexport CODEX_HOME='\(home.path)'\nexec /usr/bin/true\n".utf8)
            .write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: script.path)

        let cloneID = Validation.cloneBundleIdentifier(
            original: "com.multipleappslauncher.tool.codex",
            number: number,
            instanceID: id)
        try BundleAssembler.writeInfoPlist([
            "CFBundleIdentifier": cloneID,
            "CFBundleDisplayName": "Codex \(number) – \(name)",
            "CFBundleName": "Codex \(number) – \(name)",
            "CFBundleExecutable": "mal-shim",
            "CFBundlePackageType": "APPL",
            "MALGeneratedBy": "LaunchAgain",
        ], bundle: bundle)
        try BundleAssembler.writeInstanceConfig(
            InstanceConfig(kind: .tool,
                           mode: .full,
                           dataPath: home.path,
                           scriptPath: script.path,
                           terminalApp: "Terminal"),
            into: bundle)
        _ = try CodeSigner(log: .silent).adHocSign(bundle: bundle,
                                                   mainEntitlements: [:],
                                                   hardenedRuntime: false)
        return Instance(id: id,
                        number: number,
                        name: name,
                        mechanism: .configEnvironment,
                        bundlePath: bundle.path,
                        dataPath: home.path,
                        clonedBundleIdentifier: cloneID)
    }

    private func makeManifestLauncher(number: Int,
                                      name: String) throws -> LauncherRecoveryManifest {
        let id = UUID()
        let data = paths.instanceDataDir(id)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let bundle = paths.bundlesDir
            .appendingPathComponent("Recoverable \(number) – \(name).app")
        try FileManager.default.createDirectory(
            at: bundle.appendingPathComponent("Contents/Resources"),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: bundle.appendingPathComponent("Contents/MacOS"),
            withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/bin/echo"),
            to: bundle.appendingPathComponent("Contents/MacOS/mal-shim"))
        let cloneID = Validation.cloneBundleIdentifier(
            original: "com.example.recoverable",
            number: number,
            instanceID: id)
        let instance = Instance(
            id: id,
            number: number,
            name: name,
            accountLabel: "account@example.com",
            bundlePath: bundle.path,
            dataPath: data.path,
            builtFromSourceVersion: "1.2.3",
            clonedBundleIdentifier: cloneID)
        let manifest = LauncherRecoveryManifest(
            appKey: "com.example.recoverable",
            appDisplayName: "Recoverable",
            sourcePath: "/Applications/Recoverable.app",
            sourceVersion: "1.2.3",
            instance: instance)
        try BundleAssembler.writeInfoPlist([
            "CFBundleIdentifier": cloneID,
            "CFBundleDisplayName": "Recoverable \(number) – \(name)",
            "CFBundleName": "Recoverable",
            "CFBundleExecutable": "mal-shim",
            "CFBundlePackageType": "APPL",
            "MALGeneratedBy": "LaunchAgain",
            "MALOriginalBundleIdentifier": "com.example.recoverable",
        ], bundle: bundle)
        try BundleAssembler.writeInstanceConfig(
            InstanceConfig(mode: .full,
                           dataPath: data.path,
                           realExecutableName: "Recoverable.real"),
            into: bundle)
        try BundleAssembler.writeRecoveryManifest(manifest, into: bundle)
        _ = try CodeSigner(log: .silent).adHocSign(
            bundle: bundle,
            mainEntitlements: [:],
            hardenedRuntime: false)
        return manifest
    }

    private func makeSourceApp() throws -> URL {
        let bundle = root.appendingPathComponent("Legacy.app")
        try FileManager.default.createDirectory(
            at: bundle.appendingPathComponent("Contents"),
            withIntermediateDirectories: true)
        try BundleAssembler.writeInfoPlist([
            "CFBundleIdentifier": "com.example.legacy",
            "CFBundleDisplayName": "Legacy",
            "CFBundleName": "Legacy",
            "CFBundleExecutable": "Legacy",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
        ], bundle: bundle)
        return bundle
    }
}
#endif
