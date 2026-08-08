import XCTest
@testable import MALCore

/// The registry is the only place instance numbers exist. If it is ever half-written or
/// silently reset, the user loses the mapping between the apps in their Dock and the
/// accounts inside them — so these tests are about durability, not features.
final class RegistryTests: XCTestCase {

    private var root: URL!
    private var paths: MALPaths!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mal-registry-tests-\(UUID().uuidString)")
        paths = MALPaths.rooted(at: root)
        try paths.createAll()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeInstance(number: Int, name: String = "") -> Instance {
        Instance(number: number,
                 name: name,
                 bundlePath: root.appendingPathComponent("bundles/\(name).app").path,
                 dataPath: paths.instanceDataDir(UUID()).path)
    }

    // MARK: Numbering across the real lifecycle

    /// The headline promise: delete #2 and #3 stays #3. The freed number becomes
    /// available again, so the next instance created is #2.
    func testDeletingAnInstanceDoesNotRenumberTheOthers() throws {
        let registry = try Registry(paths: paths)
        try registry.upsertApp(appKey: "com.example.app", displayName: "Example",
                               sourcePath: "/Applications/Example.app", sourceVersion: "1.0")

        let numbers = try registry.reserveNumbers(appKey: "com.example.app", count: 3)
        XCTAssertEqual(numbers, [1, 2, 3])
        for n in numbers {
            try registry.addInstance(makeInstance(number: n, name: "Instance \(n)"), toApp: "com.example.app")
        }

        let two = try XCTUnwrap(registry.app("com.example.app")?.instance(withNumber: 2))
        try registry.removeInstance(two.id)

        let after = try XCTUnwrap(registry.app("com.example.app"))
        XCTAssertEqual(after.instances.map(\.number), [1, 3], "deleting #2 must not move #3")

        let next = try registry.reserveNumbers(appKey: "com.example.app", count: 1)
        XCTAssertEqual(next, [2], "the number freed by deleting #2 is available again")

        try registry.addInstance(makeInstance(number: 2, name: "Replacement"), toApp: "com.example.app")
        XCTAssertEqual(registry.app("com.example.app")?.instances.map(\.number), [1, 2, 3],
                       "and #3 still has the number it always had")
    }

    func testRemovingOneOfSeveralInstancesRetainsTheManagedApp() throws {
        let registry = try Registry(paths: paths)
        try registry.upsertApp(appKey: "com.example.app", displayName: "Example",
                               sourcePath: "/Applications/Example.app", sourceVersion: "1.0")
        for n in try registry.reserveNumbers(appKey: "com.example.app", count: 2) {
            try registry.addInstance(makeInstance(number: n), toApp: "com.example.app")
        }

        let first = try XCTUnwrap(registry.app("com.example.app")?.instance(withNumber: 1))
        try registry.removeInstance(first.id)

        XCTAssertEqual(registry.app("com.example.app")?.instances.map(\.number), [2])
        XCTAssertFalse(registry.allApps.contains { $0.instances.isEmpty },
                       "the sidebar source must always own at least one instance")
    }

    func testRemovingFinalInstancePrunesAppAndRediscoveryStartsAtOne() throws {
        let registry = try Registry(paths: paths)
        try registry.upsertApp(appKey: "com.example.app", displayName: "Example",
                               sourcePath: "/Applications/Example.app", sourceVersion: "1.0")
        let number = try XCTUnwrap(registry.reserveNumbers(appKey: "com.example.app", count: 1).first)
        let only = makeInstance(number: number)
        try registry.addInstance(only, toApp: "com.example.app")

        try registry.removeInstance(only.id)
        XCTAssertNil(registry.app("com.example.app"))
        XCTAssertTrue(registry.allApps.isEmpty)

        try registry.upsertApp(appKey: "com.example.app", displayName: "Example",
                               sourcePath: "/Applications/Example.app", sourceVersion: "2.0")
        XCTAssertEqual(try registry.reserveNumbers(appKey: "com.example.app", count: 1), [1])
    }

    func testNumbersSurviveReopening() throws {
        do {
            let registry = try Registry(paths: paths)
            try registry.upsertApp(appKey: "com.example.app", displayName: "Example",
                                   sourcePath: "/Applications/Example.app", sourceVersion: "1.0")
            let numbers = try registry.reserveNumbers(appKey: "com.example.app", count: 2)
            for n in numbers {
                try registry.addInstance(makeInstance(number: n), toApp: "com.example.app")
            }
        }
        let reopened = try Registry(paths: paths)
        let app = try XCTUnwrap(reopened.app("com.example.app"))
        XCTAssertEqual(app.instances.map(\.number), [1, 2])
        XCTAssertEqual(app.nextInstanceNumber, 3)
    }

    func testDuplicateNumbersAreRejected() throws {
        let registry = try Registry(paths: paths)
        try registry.upsertApp(appKey: "com.example.app", displayName: "Example",
                               sourcePath: "/Applications/Example.app", sourceVersion: "1.0")
        _ = try registry.reserveNumbers(appKey: "com.example.app", count: 1)
        try registry.addInstance(makeInstance(number: 1), toApp: "com.example.app")

        XCTAssertThrowsError(try registry.addInstance(makeInstance(number: 1), toApp: "com.example.app")) {
            XCTAssertEqual($0 as? MALError, .duplicateInstanceNumber(1))
        }
    }

    func testReservingForAnUnknownAppFails() throws {
        let registry = try Registry(paths: paths)
        XCTAssertThrowsError(try registry.reserveNumbers(appKey: "nope", count: 1))
    }

    // MARK: Renumbering

    func testExplicitRenumberIsTheOnlyThingThatChangesNumbers() throws {
        let registry = try Registry(paths: paths)
        try registry.upsertApp(appKey: "com.example.app", displayName: "Example",
                               sourcePath: "/Applications/Example.app", sourceVersion: "1.0")
        for n in try registry.reserveNumbers(appKey: "com.example.app", count: 4) {
            try registry.addInstance(makeInstance(number: n, name: "n\(n)"), toApp: "com.example.app")
        }
        // Remove #2 and #3, leaving 1 and 4.
        for n in [2, 3] {
            let i = try XCTUnwrap(registry.app("com.example.app")?.instance(withNumber: n))
            try registry.removeInstance(i.id)
        }
        XCTAssertEqual(registry.app("com.example.app")?.instances.map(\.number), [1, 4])

        let plan = try registry.renumber(appKey: "com.example.app")
        XCTAssertEqual(plan, [4: 2])
        XCTAssertEqual(registry.app("com.example.app")?.instances.map(\.number), [1, 2])
        XCTAssertEqual(registry.app("com.example.app")?.nextInstanceNumber, 3)
    }

    func testRenumberPreservesIdentityAndData() throws {
        let registry = try Registry(paths: paths)
        try registry.upsertApp(appKey: "com.example.app", displayName: "Example",
                               sourcePath: "/Applications/Example.app", sourceVersion: "1.0")
        for n in try registry.reserveNumbers(appKey: "com.example.app", count: 2) {
            try registry.addInstance(makeInstance(number: n, name: "n\(n)"), toApp: "com.example.app")
        }
        let before = try XCTUnwrap(registry.app("com.example.app")?.instance(withNumber: 2))
        _ = try registry.renumber(appKey: "com.example.app")
        let after = try XCTUnwrap(registry.app("com.example.app")?.instance(withNumber: 2))
        XCTAssertEqual(before.id, after.id)
        XCTAssertEqual(before.dataPath, after.dataPath, "renumbering must never move a profile")
        XCTAssertEqual(before.name, after.name)
    }

    // MARK: Seeing what another writer did

    /// Regression: the interface held the registry it loaded at launch and never looked
    /// again, so an instance created or deleted by the command line tool was invisible —
    /// and the next save from the window wrote the stale list back over it. This is what
    /// "I deleted one and they both disappeared from the app" looked like from inside.
    func testAWriteByAnotherProcessIsPickedUp() throws {
        let ours = try Registry(paths: paths)
        try ours.upsertApp(appKey: "com.example.app", displayName: "Example",
                           sourcePath: "/Applications/Example.app", sourceVersion: "1.0")
        _ = try ours.reserveNumbers(appKey: "com.example.app", count: 1)
        try ours.addInstance(makeInstance(number: 1, name: "First"), toApp: "com.example.app")
        XCTAssertEqual(ours.allInstances.count, 1)

        // A second process — the CLI — adds an instance behind our back.
        let theirs = try Registry(paths: paths)
        _ = try theirs.reserveNumbers(appKey: "com.example.app", count: 1)
        try theirs.addInstance(makeInstance(number: 2, name: "Second"), toApp: "com.example.app")

        // Modification dates have one-second resolution on some filesystems; make sure
        // the change is unambiguous rather than relying on timing.
        try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(2)],
                                               ofItemAtPath: paths.registryFile.path)

        XCTAssertTrue(ours.reloadIfChanged(), "the file changed, so it must be re-read")
        XCTAssertEqual(ours.allInstances.map(\.instance.number).sorted(), [1, 2],
                       "both instances should be visible after reloading")
    }

    func testReloadingIsANoOpWhenNothingChanged() throws {
        let registry = try Registry(paths: paths)
        try registry.upsertApp(appKey: "com.example.app", displayName: "Example",
                               sourcePath: "/Applications/Example.app", sourceVersion: "1.0")
        XCTAssertFalse(registry.reloadIfChanged(), "our own write must not count as an external change")
        XCTAssertFalse(registry.reloadIfChanged())
    }

    func testIdenticalAppMetadataDoesNotRewriteTheRegistry() throws {
        let registry = try Registry(paths: paths)
        try registry.upsertApp(appKey: "com.example.app", displayName: "Example",
                               sourcePath: "/Applications/Example.app", sourceVersion: "1.0")
        let sentinel = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: sentinel],
                                              ofItemAtPath: paths.registryFile.path)

        try registry.upsertApp(appKey: "com.example.app", displayName: "Example",
                               sourcePath: "/Applications/Example.app", sourceVersion: "1.0")

        let after = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: paths.registryFile.path)[.modificationDate]
                as? Date)
        XCTAssertEqual(after, sentinel,
                       "a no-op source refresh must not wake registry filesystem watchers")
    }

    func testReconciliationTreatsSymlinkAliasesAsOneInstalledLauncher() throws {
        let registry = try Registry(paths: paths)
        try registry.upsertApp(appKey: "com.example.app", displayName: "Example",
                               sourcePath: "/Applications/Example.app", sourceVersion: "1.0")

        let realDirectory = root.appendingPathComponent("real-launchers")
        let aliasDirectory = root.appendingPathComponent("alias-launchers")
        try FileManager.default.createDirectory(
            at: realDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: aliasDirectory, withDestinationURL: realDirectory)
        let realBundle = realDirectory.appendingPathComponent("Example 1.app")
        try FileManager.default.createDirectory(
            at: realBundle, withIntermediateDirectories: true)

        let id = UUID()
        let registered = Instance(
            id: id,
            number: 1,
            name: "",
            bundlePath: realBundle.path,
            dataPath: paths.instanceDataDir(id).path,
            clonedBundleIdentifier: Validation.cloneBundleIdentifier(
                original: "com.example.app", number: 1, instanceID: id))
        try registry.addInstance(registered, toApp: "com.example.app")

        var recovered = registered
        recovered.bundlePath = aliasDirectory
            .appendingPathComponent("Example 1.app").path
        let report = try registry.reconcile([
            LauncherRecoveryManifest(
                appKey: "com.example.app",
                appDisplayName: "Example",
                sourcePath: "/Applications/Example.app",
                sourceVersion: "1.0",
                instance: recovered),
        ])

        XCTAssertTrue(report.conflicts.isEmpty)
        XCTAssertTrue(report.relocatedInstanceIDs.isEmpty)
        XCTAssertEqual(
            registry.instance(id)?.instance.bundlePath,
            realBundle.path,
            "an alternate spelling of the same live bundle is not a duplicate")
    }

    /// A reload must never be able to empty the list because the file was caught
    /// mid-write.
    func testReloadKeepsWhatItHasIfTheFileIsMomentarilyUnreadable() throws {
        let registry = try Registry(paths: paths)
        try registry.upsertApp(appKey: "com.example.app", displayName: "Example",
                               sourcePath: "/Applications/Example.app", sourceVersion: "1.0")
        _ = try registry.reserveNumbers(appKey: "com.example.app", count: 1)
        try registry.addInstance(makeInstance(number: 1, name: "Kept"), toApp: "com.example.app")

        try Data("{ half written".utf8).write(to: paths.registryFile)
        try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(2)],
                                               ofItemAtPath: paths.registryFile.path)

        _ = registry.reloadIfChanged()
        XCTAssertEqual(registry.allInstances.count, 1, "the in-memory list survives a bad read")
    }

    // MARK: Durability

    /// A truncated primary file is what a crash mid-write looks like from the outside.
    /// The backup must carry the user's numbering through it.
    func testCorruptRegistryRecoversFromBackup() throws {
        do {
            let registry = try Registry(paths: paths)
            try registry.upsertApp(appKey: "com.example.app", displayName: "Example",
                                   sourcePath: "/Applications/Example.app", sourceVersion: "1.0")
            for n in try registry.reserveNumbers(appKey: "com.example.app", count: 2) {
                try registry.addInstance(makeInstance(number: n, name: "n\(n)"), toApp: "com.example.app")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.registryFile.appendingPathExtension("bak").path),
                      "a backup must exist once the registry has been written more than once")

        try Data("{ this is not json".utf8).write(to: paths.registryFile)

        let recovered = try Registry(paths: paths)
        XCTAssertTrue(recovered.recoveredFromBackup)
        let app = try XCTUnwrap(recovered.app("com.example.app"))
        XCTAssertFalse(app.instances.isEmpty, "the backup should still describe the instances")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for url in [paths.registryFile, paths.registryFile.appendingPathExtension("bak")] {
            XCTAssertNoThrow(
                try decoder.decode(RegistryDocument.self, from: Data(contentsOf: url)),
                "backup recovery must leave both redundant copies parseable")
        }
        // Whatever the backup contained, the counter must not re-issue a live number.
        let highest = app.instances.map(\.number).max() ?? 0
        XCTAssertGreaterThan(app.nextInstanceNumber, highest)
    }

    func testUnreadableRegistryAndBackupIsReportedRatherThanSilentlyReset() throws {
        try Data("garbage".utf8).write(to: paths.registryFile)
        try Data("also garbage".utf8).write(to: paths.registryFile.appendingPathExtension("bak"))
        XCTAssertThrowsError(try Registry(paths: paths)) { error in
            guard case .registryCorrupt = error as? MALError else {
                return XCTFail("expected registryCorrupt, got \(error)")
            }
        }
    }

    func testSchemaFromTheFutureIsRefused() throws {
        let doc = """
        { "schemaVersion": 99, "apps": [] }
        """
        try Data(doc.utf8).write(to: paths.registryFile)
        XCTAssertThrowsError(try Registry(paths: paths)) { error in
            guard case .registrySchemaTooNew = error as? MALError else {
                return XCTFail("expected registrySchemaTooNew, got \(error)")
            }
        }
    }

    /// A registry written by an earlier build has no `mechanism` field. It must still
    /// load — losing a user's numbering because a field was added would be unforgivable.
    func testRegistryFromAnOlderBuildStillLoads() throws {
        let legacy = """
        {
          "schemaVersion": 1,
          "apps": [{
            "appKey": "com.example.app",
            "displayName": "Example",
            "sourcePath": "/Applications/Example.app",
            "sourceVersion": "1.0",
            "nextInstanceNumber": 3,
            "instances": [{
              "id": "6F1C3E62-0000-4000-8000-000000000001",
              "number": 2,
              "name": "Work",
              "accountLabel": "",
              "mode": "full",
              "bundlePath": "/x/Work.app",
              "dataPath": "/x/data",
              "badge": { "scale": 0.36, "position": "bottomTrailing", "shape": "circle",
                         "colorHex": "#1B6EF3", "outlined": true },
              "builtFromSourceVersion": "1.0",
              "clonedBundleIdentifier": "com.example.app.mal2-abc",
              "extraArguments": [],
              "extraEnvironment": {},
              "createdAt": "2026-01-01T00:00:00Z",
              "buildNotes": []
            }]
          }]
        }
        """
        try Data(legacy.utf8).write(to: paths.registryFile)
        let registry = try Registry(paths: paths)
        let instance = try XCTUnwrap(registry.app("com.example.app")?.instance(withNumber: 2))
        XCTAssertEqual(instance.name, "Work")
        XCTAssertEqual(instance.mechanism, .userDataDir, "missing fields take their default")
        XCTAssertEqual(registry.app("com.example.app")?.nextInstanceNumber, 3)
    }

    func testStaleInstancesAreThoseBuiltFromAnOlderSource() throws {
        let registry = try Registry(paths: paths)
        try registry.upsertApp(appKey: "com.example.app", displayName: "Example",
                               sourcePath: "/Applications/Example.app", sourceVersion: "2.0")
        var i = makeInstance(number: 1)
        i.builtFromSourceVersion = "1.0"
        try registry.addInstance(i, toApp: "com.example.app")
        var current = makeInstance(number: 2)
        current.builtFromSourceVersion = "2.0"
        try registry.addInstance(current, toApp: "com.example.app")

        let app = try XCTUnwrap(registry.app("com.example.app"))
        XCTAssertEqual(app.staleInstances.map(\.number), [1])
    }
}
