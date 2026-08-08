import XCTest
@testable import MALCore

/// Logging must not get slower just because an instance was once uninstalled.
///
/// `log()` used to re-read the entire log and run two regular expressions over every
/// record on every single write. It short-circuited only while the redaction sidecar was
/// empty — and the sidecar becomes non-empty the first time a user uninstalls anything,
/// and is never cleared. So the cost was not hypothetical: it switched on permanently the
/// first time the product was used as intended.
///
/// These assert bounds, not comments. The bounds are deliberately loose — this is a
/// regression guard against a return to O(log size) per write, not a benchmark.
final class LogPerformanceTests: XCTestCase {

    private var root: URL!
    private var logURL: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mal-logperf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        logURL = root.appendingPathComponent("launchagain.log")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func seedLog(records: Int) throws {
        var text = ""
        for i in 0..<records {
            text += "2026-01-01T00:00:00.000Z INFO  routine record \(i) about nothing\n"
        }
        try Data(text.utf8).write(to: logURL)
    }

    private func seedSidecar() throws {
        // The shape `removeInstanceEntries` writes: one non-plaintext fingerprint.
        try Data("a1b2c3d4e5f60718\n".utf8)
            .write(to: logURL.appendingPathExtension("redactions"))
    }

    private func time(_ body: () -> Void) -> TimeInterval {
        let start = Date()
        body()
        return Date().timeIntervalSince(start)
    }

    /// The headline regression: a populated sidecar must not make writing slow.
    func testWritingIsNotSlowedByAPopulatedRedactionSidecar() throws {
        try seedLog(records: 8_000)

        let clean = MALLog(fileURL: logURL)
        let withoutSidecar = time {
            for i in 0..<200 { clean.info("clean write \(i)") }
        }

        try seedSidecar()
        let dirty = MALLog(fileURL: logURL)
        // First write absorbs the one-off full scrub the changed sidecar requires.
        dirty.info("priming write")
        let withSidecar = time {
            for i in 0..<200 { dirty.info("scrubbed write \(i)") }
        }

        // Before the fix this ratio was two orders of magnitude. Allow a generous 5x for
        // the per-write suppression check and for a loaded CI machine.
        XCTAssertLessThan(
            withSidecar, max(withoutSidecar * 5, 0.5),
            "200 writes took \(withSidecar)s with a sidecar vs \(withoutSidecar)s without; "
                + "the whole-log rescan is back on the write path")
    }

    /// Writing must not degrade as the log grows, which is what O(log size) per write
    /// looks like from the outside.
    func testWriteCostDoesNotScaleWithLogSize() throws {
        try seedSidecar()

        try seedLog(records: 1_000)
        let small = MALLog(fileURL: logURL)
        small.info("priming write")
        let smallLog = time { for i in 0..<200 { small.info("small \(i)") } }

        try seedLog(records: 20_000)
        let large = MALLog(fileURL: logURL)
        large.info("priming write")
        let largeLog = time { for i in 0..<200 { large.info("large \(i)") } }

        XCTAssertLessThan(
            largeLog, max(smallLog * 5, 0.5),
            "200 writes cost \(largeLog)s against a 20,000-record log but \(smallLog)s "
                + "against a 1,000-record one; write cost is scaling with log size")
    }

    /// Opening a logger repeatedly — every CLI invocation does — must not rescan the
    /// whole log each time once the sidecar is settled.
    func testRepeatedStartupDoesNotRescanASettledLog() throws {
        try seedLog(records: 20_000)
        try seedSidecar()

        // First rotate applies the sidecar in full; that work is real and expected.
        MALLog(fileURL: logURL).rotate()

        let steadyState = time {
            for _ in 0..<20 {
                let log = MALLog(fileURL: logURL)
                log.rotate()
            }
        }
        XCTAssertLessThan(
            steadyState, 1.0,
            "20 startups against a settled 20,000-record log took \(steadyState)s; "
                + "rotation is rescanning when nothing has changed")
    }

    // MARK: The guarantee the optimisation must not break

    /// A record carrying a deleted instance's identity must still never reach the file,
    /// even though the whole-file scrub no longer runs on every write.
    func testASuppressedIdentityStillNeverReachesTheLog() throws {
        let id = UUID()
        let clone = "com.example.app.mal2-a1b2c3d4"
        let log = MALLog(fileURL: logURL)
        log.info("before the uninstall, mentioning \(id.uuidString)")
        log.flush()
        XCTAssertTrue(try String(contentsOf: logURL, encoding: .utf8).contains(id.uuidString))

        try log.removeInstanceEntries(id: id, cloneIdentifier: clone)

        var text = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertFalse(text.contains(id.uuidString), "the scrub at uninstall must remove it")

        // A later write carrying the same identity is suppressed rather than appended.
        log.info("a late record still naming \(id.uuidString)")
        log.info("a late record still naming \(clone)")
        log.info("an unrelated record that must survive")
        log.flush()

        text = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertFalse(text.contains(id.uuidString))
        XCTAssertFalse(text.contains(clone))
        XCTAssertTrue(text.contains("an unrelated record that must survive"))
    }

    /// A second process opening the same log must also suppress a redacted identity,
    /// including one added to the sidecar after it started.
    func testASecondLoggerHonoursFingerprintsAddedAfterItOpened() throws {
        let id = UUID()
        let clone = "com.example.app.mal7-feedface"

        let first = MALLog(fileURL: logURL)
        let second = MALLog(fileURL: logURL)
        second.info("second logger is open and has cached an empty sidecar")
        second.flush()

        // The uninstall happens in the "other process".
        try first.removeInstanceEntries(id: id, cloneIdentifier: clone)

        second.info("late write from the other process naming \(id.uuidString)")
        second.info("late write from the other process naming \(clone)")
        second.info("and one unrelated record")
        second.flush()

        let text = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertFalse(text.contains(id.uuidString),
                       "a cached sidecar must be invalidated when another process adds to it")
        XCTAssertFalse(text.contains(clone))
        XCTAssertTrue(text.contains("and one unrelated record"))
    }

    /// The scrub marker must not stop a *newly* added fingerprint from being applied.
    func testANewFingerprintStillTriggersAFullScrub() throws {
        let first = UUID()
        let second = UUID()
        let log = MALLog(fileURL: logURL)
        log.info("record naming \(first.uuidString)")
        log.info("record naming \(second.uuidString)")
        log.flush()

        try log.removeInstanceEntries(id: first, cloneIdentifier: "com.example.a.mal1-11111111")
        XCTAssertFalse(try String(contentsOf: logURL, encoding: .utf8).contains(first.uuidString))
        XCTAssertTrue(try String(contentsOf: logURL, encoding: .utf8).contains(second.uuidString))

        // A second uninstall changes the sidecar again; the marker must not suppress it.
        try log.removeInstanceEntries(id: second, cloneIdentifier: "com.example.b.mal2-22222222")
        let text = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertFalse(text.contains(first.uuidString))
        XCTAssertFalse(text.contains(second.uuidString))
    }
}
