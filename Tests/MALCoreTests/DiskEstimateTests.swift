import XCTest
@testable import MALCore

/// What an instance is expected to cost on disk, and whether the free-space warning can
/// fire at all.
///
/// It could not. `estimatedFirstRunBytes` is the **profile** only, and the create sheet
/// multiplied it by the count — so for ChatGPT it said "Estimated 367 MB" for an instance
/// whose bundle alone is 1.38 GB, and at the maximum of 64 it claimed about 23 GB against
/// 90-odd GB free and showed nothing. The clone term was simply missing from the sum.
final class DiskEstimateTests: XCTestCase {

    /// ChatGPT's real numbers, which is where this was found.
    private let bundleBytes: Int64 = 1_481_763_226      // 1.38 GB, as `inspect` reports
    private let freeBytes: Int64 = 90 * 1024 * 1024 * 1024

    private func facts(bundleSizeBytes: Int64) -> AppFacts {
        AppFacts(bundleIdentifier: "com.example.big",
                 displayName: "Big",
                 executableName: "Big",
                 shortVersion: "1.0",
                 path: "/Applications/Big.app",
                 runtime: .electron,
                 isSigned: true,
                 bundleSizeBytes: bundleSizeBytes,
                 signingInspected: true)
    }

    func testAFullInstanceCostsTheProfileAndACopyOfTheApplication() {
        let verdict = Compatibility.evaluate(facts(bundleSizeBytes: bundleBytes))
        let perInstance = verdict.estimatedBytesPerInstance(mode: .full,
                                                            sourceBundleBytes: bundleBytes)

        XCTAssertEqual(perInstance, verdict.estimatedFirstRunBytes + bundleBytes)
        XCTAssertGreaterThan(perInstance, bundleBytes,
                             "the estimate is smaller than the bundle it copies")
    }

    /// Lite copies nothing, so it must not be charged for a copy.
    func testALiteInstanceIsNotChargedForACopyOfTheApplication() {
        let verdict = Compatibility.evaluate(facts(bundleSizeBytes: bundleBytes))
        XCTAssertEqual(
            verdict.estimatedBytesPerInstance(mode: .lite, sourceBundleBytes: bundleBytes),
            verdict.estimatedFirstRunBytes)
    }

    /// The reviewer's exact scenario: 64 Full instances of ChatGPT against ~90 GB free.
    /// The old sum came to about 23 GB and warned about nothing.
    func testTheFreeSpaceWarningCanFireAtTheMaximumCount() {
        let verdict = Compatibility.evaluate(facts(bundleSizeBytes: bundleBytes))
        let total = verdict.estimatedBytesPerInstance(mode: .full,
                                                      sourceBundleBytes: bundleBytes) * 64

        XCTAssertGreaterThan(total, freeBytes,
                             "64 instances of a 1.38 GB application still fit inside \(freeBytes / 1024 / 1024 / 1024) GB according to the estimate, so the warning cannot fire")

        // And the old sum genuinely did not, so this test is about the fix rather than
        // about the arithmetic being large.
        let oldTotal = verdict.estimatedFirstRunBytes * 64
        XCTAssertLessThan(oldTotal, freeBytes,
                          "the profile-only sum used to fit, which is why nothing warned")
    }

    /// A missing or nonsensical bundle size must not make the estimate smaller than the
    /// profile it already accounted for.
    func testAnUnknownBundleSizeDegradesToTheProfileEstimate() {
        let verdict = Compatibility.evaluate(facts(bundleSizeBytes: 0))
        XCTAssertEqual(verdict.estimatedBytesPerInstance(mode: .full, sourceBundleBytes: 0),
                       verdict.estimatedFirstRunBytes)
        XCTAssertEqual(verdict.estimatedBytesPerInstance(mode: .full, sourceBundleBytes: -5),
                       verdict.estimatedFirstRunBytes)
    }
}
