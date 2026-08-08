import XCTest
@testable import MALCore

/// A failed build must leave nothing behind: no bundle, no profile, no registry entry.
/// That guarantee is entirely the transaction's, so it is tested directly rather than
/// only through the builder.
final class TransactionTests: XCTestCase {

    private struct Boom: Error {}

    func testAllStepsRunInOrder() throws {
        var order: [String] = []
        let tx = Transaction(label: "test")
        tx.add("one") { order.append("one") }
        tx.add("two") { order.append("two") }
        tx.add("three") { order.append("three") }
        try tx.run()
        XCTAssertEqual(order, ["one", "two", "three"])
    }

    func testProgressIsReportedBeforeEachStep() throws {
        var seen: [(Int, Int, String)] = []
        let tx = Transaction(label: "test")
        tx.add("a") {}
        tx.add("b") {}
        try tx.run { seen.append(($0, $1, $2)) }
        XCTAssertEqual(seen.map(\.0), [0, 1])
        XCTAssertEqual(seen.map(\.1), [2, 2])
        XCTAssertEqual(seen.map(\.2), ["a", "b"])
    }

    func testFailureRollsBackCompletedStepsInReverseOrder() {
        var order: [String] = []
        let tx = Transaction(label: "test")
        tx.add("one") { order.append("do one") } rollback: { order.append("undo one") }
        tx.add("two") { order.append("do two") } rollback: { order.append("undo two") }
        tx.add("three") { throw Boom() } rollback: { order.append("undo three") }

        XCTAssertThrowsError(try tx.run())
        XCTAssertEqual(order, ["do one", "do two", "undo two", "undo one"],
                       "the failing step never completed, so it is not rolled back")
    }

    func testTheOriginalErrorIsPreservedWhenRollbackSucceeds() {
        let tx = Transaction(label: "test")
        tx.add("sign") { throw MALError.signingFailed("no identity") } rollback: {}
        XCTAssertThrowsError(try tx.run()) { error in
            XCTAssertEqual(error as? MALError, .signingFailed("no identity"),
                           "a degradable error must survive so the builder can fall back to Lite")
        }
    }

    func testANonMALErrorIsWrappedWithTheStepName() {
        let tx = Transaction(label: "test")
        tx.add("clone bundle") { throw Boom() }
        XCTAssertThrowsError(try tx.run()) { error in
            guard case .buildFailed(let step, _) = error as? MALError else {
                return XCTFail("expected buildFailed, got \(error)")
            }
            XCTAssertEqual(step, "clone bundle")
        }
    }

    /// A rollback that itself fails must not hide the original problem.
    func testRollbackFailuresAreReportedAlongsideTheOriginalError() {
        let tx = Transaction(label: "test")
        tx.add("one") {} rollback: { throw Boom() }
        tx.add("two") { throw MALError.signingFailed("x") }

        XCTAssertThrowsError(try tx.run()) { error in
            guard case .rollbackIncomplete(let original, let failures) = error as? MALError else {
                return XCTFail("expected rollbackIncomplete, got \(error)")
            }
            XCTAssertTrue(original.contains("two"))
            XCTAssertEqual(failures.count, 1)
            XCTAssertTrue(failures[0].contains("one"))
        }
    }

    func testStepsWithoutRollbackAreSkippedQuietly() {
        var undone = false
        let tx = Transaction(label: "test")
        tx.add("no rollback") {}
        tx.add("has rollback") {} rollback: { undone = true }
        tx.add("fails") { throw Boom() }
        XCTAssertThrowsError(try tx.run())
        XCTAssertTrue(undone)
    }
}

final class MALLogTests: XCTestCase {

    func testInstanceScrubIsCrossLoggerSafeAndPreservesUnrelatedRecords() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("launchagain-log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("launchagain.log")
        let id = UUID()
        let cloneIdentifier = Validation.cloneBundleIdentifier(
            original: "com.example.fixture",
            number: 1,
            instanceID: id)

        // Version 1.0 allowed a message to span physical lines. The continuation must
        // be removed with the timestamped record that carries this instance UUID.
        let legacy = """
        2026-01-01T00:00:00.000Z INFO  owned \(id.uuidString)
        continuation with an old profile path
        2026-01-01T00:00:01.000Z INFO  unrelated /tmp and /private/tmp record
        2026-01-01T00:00:02Z INFO  unrelated record without fractional seconds
        2026-01-01T00:00:03.123456+10:00 INFO  unrelated numeric-offset record

        """
        try Data(legacy.utf8).write(to: file)

        let scrubber = MALLog(fileURL: file)
        let writer = MALLog(fileURL: file)
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global().async {
            for index in 0..<100 {
                if index == 50 {
                    writer.info(
                        "stale queued writer \(id.uuidString) \(cloneIdentifier)")
                }
                writer.info("unrelated concurrent record \(index) under /tmp")
            }
            writer.flush()
            group.leave()
        }

        group.enter()
        let scrubResult = LockedError()
        DispatchQueue.global().async {
            do {
                try scrubber.removeInstanceEntries(
                    id: id,
                    cloneIdentifier: cloneIdentifier)
            } catch {
                scrubResult.set(error)
            }
            group.leave()
        }

        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        XCTAssertNil(scrubResult.get())
        writer.flush()
        scrubber.flush()

        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(text.contains(id.uuidString))
        XCTAssertFalse(text.contains(cloneIdentifier))
        XCTAssertFalse(text.contains("continuation with an old profile path"))
        XCTAssertTrue(text.contains("unrelated /tmp and /private/tmp record"))
        XCTAssertTrue(text.contains("unrelated record without fractional seconds"))
        XCTAssertTrue(text.contains("unrelated numeric-offset record"))
        for index in 0..<100 {
            XCTAssertTrue(text.contains("unrelated concurrent record \(index) under /tmp"))
        }

        let fingerprints = try String(
            contentsOf: file.appendingPathExtension("redactions"),
            encoding: .utf8)
        XCTAssertFalse(fingerprints.contains(id.uuidString))
        XCTAssertFalse(fingerprints.contains(cloneIdentifier))

        // Reopening the same file must use O_CREAT without O_TRUNC. This also makes a
        // persisted suppression fingerprint clean a delayed stale write on startup.
        let reopened = MALLog(fileURL: file)
        reopened.info("unrelated record after another logger initialized")
        reopened.flush()
        let reopenedText = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(reopenedText.contains("unrelated /tmp and /private/tmp record"))
        XCTAssertTrue(reopenedText.contains("unrelated record after another logger initialized"))
    }
}

private final class LockedError: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Error?

    func set(_ error: Error) {
        lock.lock()
        value = error
        lock.unlock()
    }

    func get() -> Error? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Which errors are allowed to degrade a build to Lite mode rather than fail it. This is
/// the difference between "your instance could not be created" and "your instance works,
/// with a shared Dock icon".
final class ErrorClassificationTests: XCTestCase {

    func testSigningProblemsDegrade() {
        XCTAssertTrue(MALError.signingFailed("x").isDegradable)
        XCTAssertTrue(MALError.verificationFailed("x").isDegradable)
        XCTAssertTrue(MALError.iconGenerationFailed("x").isDegradable)
        // These are the step names `InstanceBuilder` actually uses. This test used to
        // say `"sign clone"`, which no step is called — it passed because the predicate
        // was a `hasPrefix` test against `"sign"`, and the pair of them agreed with each
        // other about a build step that does not exist. The real label is
        // `"re-sign clone"`, and until Mi-d it did not degrade.
        XCTAssertTrue(MALError.buildFailed(step: "re-sign clone", underlying: "x").isDegradable)
        XCTAssertTrue(MALError.buildFailed(step: "verify signature", underlying: "x").isDegradable)
        XCTAssertTrue(MALError.buildFailed(step: "generate numbered icon", underlying: "x").isDegradable)
        XCTAssertTrue(MALError.buildFailed(step: "install launcher shim", underlying: "x").isDegradable)
    }

    func testStructuralProblemsDoNot() {
        XCTAssertFalse(MALError.sourceNotFound("/x").isDegradable)
        XCTAssertFalse(MALError.notSupported(reason: "x").isDegradable)
        XCTAssertFalse(MALError.registryCorrupt("x").isDegradable,
                       "a corrupt registry must never be papered over by retrying")
        XCTAssertFalse(MALError.alreadyRunning(dataPath: "/x").isDegradable)
        XCTAssertFalse(MALError.buildFailed(step: "clone application bundle", underlying: "x").isDegradable)
    }

    func testErrorsReadAsSentencesAUserCanActustOn() {
        XCTAssertTrue(MALError.alreadyRunning(dataPath: "/x").description.contains("Quit it first"))
        XCTAssertTrue(MALError.registrySchemaTooNew(found: 2, supported: 1).description.contains("Update the app"))
        XCTAssertFalse(MALError.toolMissing("/usr/bin/codesign").description.isEmpty)
    }
}

final class PathsTests: XCTestCase {

    func testStandardLayout() {
        let paths = MALPaths.standard(home: URL(fileURLWithPath: "/Users/x"))
        XCTAssertEqual(paths.support.path, "/Users/x/Library/Application Support/LaunchAgain")
        XCTAssertEqual(paths.bundlesDir.path, "/Users/x/Applications/LaunchAgain")
        XCTAssertEqual(paths.registryFile.lastPathComponent, "registry.json")
    }

    /// The locations the first release used, which `Migration` moves out of.
    func testLegacyLayoutIsStillDescribed() {
        let legacy = MALPaths.legacy(home: URL(fileURLWithPath: "/Users/x"))
        XCTAssertEqual(legacy.support.path, "/Users/x/Library/Application Support/MultipleAppsLauncher")
        XCTAssertEqual(legacy.bundlesDir.path, "/Users/x/Applications/Multiple Apps Launcher")
        XCTAssertNotEqual(legacy.support, MALPaths.standard(home: URL(fileURLWithPath: "/Users/x")).support)
    }

    /// Staging must be on the same volume as the destination or the final move stops
    /// being atomic.
    func testStagingLivesInsideTheDestinationDirectory() {
        let paths = MALPaths.standard(home: URL(fileURLWithPath: "/Users/x"))
        XCTAssertTrue(paths.stagingDir.path.hasPrefix(paths.bundlesDir.path))
    }

    func testDeletionIsRefusedOutsideOurOwnDirectories() throws {
        let paths = MALPaths.standard(home: URL(fileURLWithPath: "/Users/x"))
        XCTAssertNoThrow(try paths.assertDeletable(paths.instanceDir(UUID()).path))
        XCTAssertNoThrow(try paths.assertDeletable(paths.bundlesDir.appendingPathComponent("A.app").path))
        XCTAssertThrowsError(try paths.assertDeletable(paths.support.path))
        XCTAssertThrowsError(try paths.assertDeletable(paths.bundlesDir.path))
        XCTAssertThrowsError(try paths.assertDeletable("/Applications/Claude.app"))
        XCTAssertThrowsError(try paths.assertDeletable("/Users/x"))
        XCTAssertThrowsError(try paths.assertDeletable("/"))
    }

    func testLauncherDeletionPathMustBeOneImmediateAppChild() {
        let paths = MALPaths.standard(home: URL(fileURLWithPath: "/Users/x"))
        XCTAssertNoThrow(try paths.assertLauncherBundlePath(
            paths.bundlesDir.appendingPathComponent("Owned.app").path))
        XCTAssertThrowsError(try paths.assertLauncherBundlePath(paths.bundlesDir.path))
        XCTAssertThrowsError(try paths.assertLauncherBundlePath(
            paths.bundlesDir.appendingPathComponent("Nested/Owned.app").path))
        XCTAssertThrowsError(try paths.assertLauncherBundlePath(
            paths.bundlesDir.appendingPathComponent("not-an-app").path))
    }

    func testInstancePathsAreDerivedFromTheIdentifier() {
        let paths = MALPaths.standard(home: URL(fileURLWithPath: "/Users/x"))
        let id = UUID()
        XCTAssertTrue(paths.instanceDataDir(id).path.contains(id.uuidString))
        XCTAssertTrue(paths.instanceLogsDir(id).path.hasSuffix("logs"))
        XCTAssertTrue(paths.instanceLockFile(id).path.hasSuffix("instance.lock"))
    }
}

/// Crash-safe writing. The registry is small and rewritten whole, so the only thing that
/// matters is that a partial write can never be observed.
final class AtomicFileTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mal-atomic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testWriteAndBackup() throws {
        let file = dir.appendingPathComponent("registry.json")
        try AtomicFile.write(Data("first".utf8), to: file)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "first")
        XCTAssertEqual(
            try String(contentsOf: file.appendingPathExtension("bak"), encoding: .utf8),
            "first",
            "the backup mirrors the committed document from the first write")

        try AtomicFile.write(Data("second".utf8), to: file)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "second")
        XCTAssertEqual(
            try String(contentsOf: file.appendingPathExtension("bak"), encoding: .utf8),
            "second",
            "a deleted logical state must not survive in the backup")
    }

    func testNoTemporaryFilesAreLeftBehind() throws {
        let file = dir.appendingPathComponent("registry.json")
        for i in 0..<5 { try AtomicFile.write(Data("\(i)".utf8), to: file) }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.contains(".tmp-") }
        XCTAssertTrue(leftovers.isEmpty, "found \(leftovers)")
    }

    func testReadFallsBackToTheBackupWhenThePrimaryIsUnparseable() throws {
        let file = dir.appendingPathComponent("registry.json")
        try AtomicFile.write(Data("good".utf8), to: file)
        try AtomicFile.write(Data("also good".utf8), to: file)
        try Data("truncated".utf8).write(to: file)

        let result = AtomicFile.readWithFallback(file) { data in
            String(decoding: data, as: UTF8.self).hasSuffix("good")
        }
        XCTAssertEqual(result?.usedBackup, true)
        XCTAssertEqual(result.map { String(decoding: $0.data, as: UTF8.self) }, "also good")
    }

    func testReadReturnsNilWhenNothingIsUsable() {
        let missing = dir.appendingPathComponent("absent.json")
        XCTAssertNil(AtomicFile.readWithFallback(missing) { _ in true })
    }

    func testKeepBackupCanBeDisabledForFilesThatAreNotTheRegistry() throws {
        let file = dir.appendingPathComponent("MALInstance.conf")
        try AtomicFile.write(Data("a".utf8), to: file, keepBackup: false)
        try AtomicFile.write(Data("b".utf8), to: file, keepBackup: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.appendingPathExtension("bak").path))
    }
}

final class FSOpsTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mal-fsops-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testRemoveIfExistsIsSafeToCallTwice() throws {
        let file = dir.appendingPathComponent("x")
        try Data("x".utf8).write(to: file)
        XCTAssertNoThrow(try FSOps.removeIfExists(file))
        XCTAssertNoThrow(try FSOps.removeIfExists(file), "a rollback may run after a partial delete")
    }

    func testAtomicMoveReplacesTheDestinationDirectory() throws {
        let src = dir.appendingPathComponent("src")
        let dst = dir.appendingPathComponent("dst")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: src.appendingPathComponent("file"))

        try FSOps.atomicMove(src, to: dst)
        XCTAssertFalse(FileManager.default.fileExists(atPath: src.path))
        XCTAssertEqual(try String(contentsOf: dst.appendingPathComponent("file"), encoding: .utf8), "payload")
    }

    func testDirectorySizeCountsNestedFiles() throws {
        let sub = dir.appendingPathComponent("a/b")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 4096).write(to: sub.appendingPathComponent("blob"))
        XCTAssertGreaterThan(FSOps.directorySize(dir), 0)
    }

    func testDirectorySizeTraversesMoreThanOneBoundedBatch() throws {
        let files = dir.appendingPathComponent("many")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        for index in 0..<600 {
            try Data([UInt8(index % 251)]).write(
                to: files.appendingPathComponent("file-\(index)"))
        }

        XCTAssertGreaterThanOrEqual(
            FSOps.directorySize(dir),
            600,
            "bounded autorelease batches must not truncate a large directory walk")
    }

    func testHumanBytesIsReadable() {
        XCTAssertFalse(FSOps.humanBytes(0).isEmpty)
        XCTAssertTrue(FSOps.humanBytes(2 * 1024 * 1024 * 1024).contains("GB"))
    }
}
