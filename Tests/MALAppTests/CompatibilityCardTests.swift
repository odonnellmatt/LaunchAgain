#if canImport(AppKit)
import XCTest
import AppKit
import SwiftUI
@testable import MALApp
@testable import MALCore

/// The compatibility card is the last thing a user reads before creating anything, so
/// for an app whose session lives outside the redirected profile it has to say so
/// *there*, not only in a document.
///
/// **What these tests check, and what they do not.** They assert the condition the card
/// branches on (`CompatibilityCard.showsSharedCredentialWarning`, which is the same
/// expression the view body uses) and the exact strings the warning renders (owned by
/// `SharedCredentialWarning` as constants and used by its body verbatim). They do not
/// read pixels or an accessibility tree: SwiftUI does not publish a usable AX tree for
/// an offscreen window with no assistive client attached, and mounting this particular
/// card in a bare XCTest process crashes inside AppKit's icon loading. A test that
/// silently found no text would have passed for the wrong reason, which is worse than a
/// narrower test that says what it covers.
final class CompatibilityCardTests: XCTestCase {

    private func facts(bundleIdentifier: String = "com.example.plain",
                       displayName: String = "Plain",
                       entitlements: [String] = []) -> AppFacts {
        AppFacts(bundleIdentifier: bundleIdentifier,
                 displayName: displayName,
                 executableName: displayName,
                 shortVersion: "1.0",
                 path: "/Applications/\(displayName).app",
                 runtime: .electron,
                 isSigned: true,
                 entitlementKeys: entitlements,
                 signingInspected: true)
    }

    func testAPlainAppShowsNoSharedSessionWarning() {
        let verdict = Compatibility.evaluate(facts())
        XCTAssertFalse(CompatibilityCard.showsSharedCredentialWarning(verdict),
                       "a warning shown for every app teaches the user to ignore it")
        XCTAssertTrue(SharedCredentialWarning.lines(for: verdict.sharedCredentialStores).isEmpty)
    }

    func testTheCardWarnsWhenTheSessionLivesOutsideTheProfile() {
        let verdict = Compatibility.evaluate(
            facts(bundleIdentifier: "com.openai.codex",
                  displayName: "Codex",
                  entitlements: ["keychain-access-groups",
                                 "com.apple.security.application-groups"]))

        XCTAssertTrue(CompatibilityCard.showsSharedCredentialWarning(verdict))

        let text = SharedCredentialWarning.lines(for: verdict.sharedCredentialStores)
            .joined(separator: "\n")
        XCTAssertTrue(text.contains("These will not be separate accounts"),
                      "the card must lead with the consequence; rendered:\n\(text)")
        XCTAssertTrue(text.contains("sign you out of every copy"),
                      "the card must name what the user will observe; rendered:\n\(text)")
        XCTAssertTrue(text.contains("keychain-access-groups"))
        XCTAssertTrue(text.contains("Group Containers"))
        XCTAssertTrue(text.contains("CODEX_HOME"),
                      "the card must offer the measured route out; rendered:\n\(text)")
    }

    /// A keychain-only app has no measured way to relocate its store, so the card must
    /// not offer one. Inventing a remedy is worse than stating the limit.
    func testNoRouteOutIsOfferedWhereNoneWasMeasured() {
        let verdict = Compatibility.evaluate(
            facts(entitlements: ["keychain-access-groups"]))
        let text = SharedCredentialWarning.lines(for: verdict.sharedCredentialStores)
            .joined(separator: "\n")
        XCTAssertTrue(CompatibilityCard.showsSharedCredentialWarning(verdict))
        XCTAssertFalse(text.contains("route out"))
    }
}
#endif
