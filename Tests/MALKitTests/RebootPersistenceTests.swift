#if canImport(Darwin)
import XCTest
@testable import MALKit
@testable import MALCore

/// A reboot removes every in-memory object but leaves the filesystem mounted again.
/// These tests exercise that boundary with a brand-new Registry repeatedly and with a
/// separate CLI process. All fixtures live under one temporary `--root`.
final class RebootPersistenceTests: XCTestCase {

    private var root: URL!
    private var paths: MALPaths!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("launchagain-reboot-\(UUID().uuidString)")
        paths = .rooted(at: root)
        try paths.createAll()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testRegistryProfileBundleOrphanAndConflictSurviveRestartCycles() throws {
        let instanceID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
        let orphanID = UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")!
        let dataDirectory = paths.instanceDataDir(instanceID)
        let sessionFile = dataDirectory.appendingPathComponent("Default/session-state.json")
        let sessionBytes = Data(#"{"signedIn":true,"account":"fixture"}"#.utf8)
        try FileManager.default.createDirectory(at: sessionFile.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try sessionBytes.write(to: sessionFile)

        let bundle = paths.bundlesDir.appendingPathComponent("Fixture 1 – Personal.app")
        let bundleSentinel = bundle.appendingPathComponent("Contents/reboot-sentinel.txt")
        try FileManager.default.createDirectory(at: bundleSentinel.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("launcher survives".utf8).write(to: bundleSentinel)

        let orphan = paths.instanceDataDir(orphanID).appendingPathComponent("former-work-session.txt")
        try FileManager.default.createDirectory(at: orphan.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("retain me".utf8).write(to: orphan)

        let legacyDuplicate = root.appendingPathComponent("legacy-duplicate/\(instanceID.uuidString)")
        try FileManager.default.createDirectory(at: legacyDuplicate, withIntermediateDirectories: true)
        try Data("different legacy session".utf8)
            .write(to: legacyDuplicate.appendingPathComponent("session.txt"))

        do {
            let registry = try Registry(paths: paths)
            try registry.upsertApp(appKey: "com.example.fixture",
                                   displayName: "Fixture",
                                   sourcePath: "/Applications/Fixture.app",
                                   sourceVersion: "1.0")
            XCTAssertEqual(try registry.reserveNumbers(appKey: "com.example.fixture", count: 1), [1])
            let instance = Instance(id: instanceID,
                                    number: 1,
                                    name: "Personal",
                                    accountLabel: "retained after reboot",
                                    bundlePath: bundle.path,
                                    dataPath: dataDirectory.path,
                                    builtFromSourceVersion: "1.0",
                                    clonedBundleIdentifier: "com.example.fixture.mal1-11111111")
            try registry.addInstance(instance, toApp: "com.example.fixture")
        }

        let conflictDirectory = paths.support.appendingPathComponent("migration-conflicts")
        try FileManager.default.createDirectory(at: conflictDirectory,
                                                withIntermediateDirectories: true)
        let conflict = Migration.ConflictRecord(instanceID: instanceID,
                                                legacyPath: legacyDuplicate.path,
                                                currentPath: dataDirectory.deletingLastPathComponent().path,
                                                detectedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicFile.write(try encoder.encode(conflict),
                             to: conflictDirectory.appendingPathComponent("\(instanceID.uuidString).json"),
                             keepBackup: false)

        // Three complete object reconstructions stand in for successive app launches
        // after reboots. No in-memory Registry state crosses an iteration.
        for _ in 0..<3 {
            let restarted = try Registry(paths: .rooted(at: root))
            let restored = try XCTUnwrap(restarted.instance(instanceID))
            XCTAssertEqual(restored.app.displayName, "Fixture")
            XCTAssertEqual(restored.instance.number, 1)
            XCTAssertEqual(restored.instance.name, "Personal")
            XCTAssertEqual(restored.instance.accountLabel, "retained after reboot")
            XCTAssertEqual(restored.instance.bundlePath, bundle.path)
            XCTAssertEqual(restored.instance.dataPath, dataDirectory.path)
            XCTAssertEqual(try Data(contentsOf: sessionFile), sessionBytes)
            XCTAssertEqual(try String(contentsOf: bundleSentinel, encoding: .utf8),
                           "launcher survives")
            XCTAssertEqual(try String(contentsOf: orphan, encoding: .utf8), "retain me")
            XCTAssertEqual(Migration.unresolvedConflicts(in: paths).map(\.instanceID),
                           [instanceID])
        }

        // Cross a real process boundary too: the new CLI process must load the same
        // state, and a read-only doctor run must retain both the orphan and conflict.
        let cli = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/debug/launchagain")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: cli.path),
                          "debug CLI is not available")

        let listed = try ProcessRunner.run(
            executable: cli.path,
            ["--root", root.path, "--json", "list"],
            timeout: 20)
        XCTAssertTrue(listed.succeeded, listed.stderr)
        let rows = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(listed.stdout.utf8)) as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["name"] as? String, "Personal")
        XCTAssertEqual(rows.first?["number"] as? Int, 1)
        XCTAssertEqual(rows.first?["bundle"] as? String, bundle.path)
        XCTAssertEqual(rows.first?["data"] as? String, dataDirectory.path)

        let checked = try ProcessRunner.run(
            executable: cli.path,
            ["--root", root.path, "doctor"],
            timeout: 20)
        XCTAssertTrue(checked.succeeded, checked.stderr)
        XCTAssertTrue(checked.stdout.contains(orphanID.uuidString), checked.stdout)
        XCTAssertTrue(checked.stdout.contains("Both copies were preserved"), checked.stdout)
        XCTAssertEqual(try Data(contentsOf: sessionFile), sessionBytes)
        XCTAssertEqual(try String(contentsOf: orphan, encoding: .utf8), "retain me")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.path))
    }
}
#endif
