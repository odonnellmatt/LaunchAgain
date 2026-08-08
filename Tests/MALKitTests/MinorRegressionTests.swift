#if canImport(Darwin)
import XCTest
@testable import MALKit
@testable import MALCore

/// The small ones. Each is cheap to break again and none of them had a test.
final class MinorRegressionTests: XCTestCase {

    private var root: URL!
    private var paths: MALPaths!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mal-minor-\(UUID().uuidString)")
        paths = .rooted(at: root)
        try paths.createAll()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Mi-11 — read-only commands must be read-only

    /// `scan` and `inspect` read as read-only and were not: both measure bundle sizes,
    /// and every measurement persisted `icon-cache/directory-sizes.json` inside the
    /// store. That is how a reviewer modified the user's real store while trying not to.
    func testAReadOnlyManagerDoesNotWriteTheSizeCache() throws {
        let subject = root.appendingPathComponent("measure-me")
        try FileManager.default.createDirectory(at: subject, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 4096).write(to: subject.appendingPathComponent("blob"))

        let cacheFile = paths.directorySizeCacheFile
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheFile.path))

        let readOnly = DirectorySizeCache(paths: paths, persistsToDisk: false)
        XCTAssertGreaterThan(readOnly.size(of: subject), 0, "it must still measure")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheFile.path),
                       "a read-only command wrote \(cacheFile.lastPathComponent) into the store")

        // And the writing one still writes, so this is a switch rather than a removal.
        let writing = DirectorySizeCache(paths: paths, persistsToDisk: true)
        _ = writing.size(of: subject)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheFile.path))
    }

    // MARK: Mi-12 — sizes below a megabyte

    /// A 30-byte removal marker was reported as "0 MB", which reads as "nothing is
    /// there" for a finding whose whole point is that something is.
    func testSizesBelowAMegabyteAreNotReportedAsZero() {
        XCTAssertEqual(FSOps.humanBytes(30), "30 bytes")
        XCTAssertFalse(FSOps.humanBytes(30).hasPrefix("0"))
        XCTAssertFalse(FSOps.humanBytes(4096).hasPrefix("0"))
        XCTAssertFalse(FSOps.humanBytes(900_000).hasPrefix("0"))
        // The larger scales are unchanged.
        XCTAssertTrue(FSOps.humanBytes(320_000_000).contains("MB"))
        XCTAssertTrue(FSOps.humanBytes(12_650_000_000).contains("GB"))
    }

    // MARK: Mi-5 / Mi-6 — the permission message

    /// One message covered two different failures, and gave wrong advice for one of
    /// them: "ask an administrator to create /Applications/LaunchAgain" when
    /// /Applications/LaunchAgain already exists and is merely read-only.
    func testAnUnwritableRootThatExistsIsNotDescribedAsMissing() throws {
        let existing = root.appendingPathComponent("existing-root")
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
            XCTAssertTrue(text.contains("exists but"),
                          "a read-only directory that exists must not be described as missing: \(text)")
            XCTAssertFalse(text.contains("Ask one to create"),
                           "the message tells the user to create a directory that already exists: \(text)")
        }
    }

    func testAMissingRootUnderAnUnwritableParentSaysCreate() {
        let blocked = MALPaths(support: paths.support,
                               bundlesDir: paths.bundlesDir,
                               systemBundlesDir: URL(fileURLWithPath: "/System/LaunchAgain-should-not-exist"),
                               userLibrary: paths.userLibrary)
        XCTAssertThrowsError(try blocked.prepareBundleRoot(blocked.systemBundlesDir)) { error in
            let text = "\(error)"
            XCTAssertTrue(text.contains("cannot create"), "got \(text)")
            XCTAssertTrue(text.contains("administrator"))
            // The old message offered a fallback the interface does not expose, and which
            // for the one application that needs this directory is the one place it will
            // not run.
            XCTAssertFalse(text.contains("your own Applications folder"),
                           "the message offers a choice the product does not provide: \(text)")
        }
    }

    // MARK: Mi-d — degradation matched step names that do not exist

    /// The step names in this test are the ones the code **actually throws**: the
    /// `tx.add(…)` labels from `InstanceBuilder` and the short names a few sites throw by
    /// hand. The predicate used to be `hasPrefix` against `["sign", "verify", "icon",
    /// "shim"]`, which met the real vocabulary in exactly two places — `"verify
    /// signature"` and the hand-thrown `"shim"` — so a wrapped signing or icon failure
    /// failed the build instead of degrading. Nothing was broken by it, because the
    /// unwrapped `MALError` cases still degraded; it was a branch that could not be
    /// reached, which is worth no less attention for being harmless.
    func testDegradationMatchesTheStepNamesTheBuilderActuallyUses() {
        // Every label in the Full build path, verbatim, in order.
        let fullBuildSteps = [
            "prepare data directory",
            "clone application bundle",
            "rewrite bundle identity",
            "stop this instance updating itself",
            "install launcher shim",
            "generate numbered icon",
            "re-sign clone",
            "verify signature",
            "move into place",
            "register with Launch Services",
        ]
        let degradable = Set(["install launcher shim", "generate numbered icon",
                              "re-sign clone", "verify signature"])
        for step in fullBuildSteps {
            XCTAssertEqual(MALError.buildFailed(step: step, underlying: "x").isDegradable,
                           degradable.contains(step),
                           "\(step) degrades when it should not, or does not when it should")
        }

        // The short names thrown by hand rather than by `Transaction`.
        XCTAssertTrue(MALError.buildFailed(step: "shim", underlying: "x").isDegradable,
                      "BundleAssembler throws this one when the real executable is missing")
        for step in ["clone", "move", "integrity check"] {
            XCTAssertFalse(MALError.buildFailed(step: step, underlying: "x").isDegradable,
                           "\(step) must fail the build rather than produce a silent Lite instance")
        }

        // A name nobody throws must not match by accident, which a prefix test would.
        XCTAssertFalse(MALError.buildFailed(step: "signal handler", underlying: "x").isDegradable)
        XCTAssertFalse(MALError.buildFailed(step: "iconography", underlying: "x").isDegradable)

        // The unwrapped cases, unchanged.
        XCTAssertTrue(MALError.signingFailed("x").isDegradable)
        XCTAssertTrue(MALError.verificationFailed("x").isDegradable)
        XCTAssertTrue(MALError.iconGenerationFailed("x").isDegradable)
    }
}
#endif
