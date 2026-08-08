import XCTest
@testable import MALCore

/// The detection and the disclosure behind the worst thing this product has done to a
/// user: an instance that came up already signed in, and signing out of it signed them
/// out of every copy of the application including the original.
///
/// These are pure-function tests on purpose. What the interface must say, and when it
/// must refuse, should not require a filesystem to establish.
final class SharedCredentialStoreTests: XCTestCase {

    private func facts(bundleIdentifier: String = "com.example.app",
                       displayName: String = "Example",
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

    // MARK: Detection

    func testAnOrdinaryElectronAppDeclaresNoSharedCredentialStore() {
        let verdict = Compatibility.evaluate(facts())
        XCTAssertFalse(verdict.sharesCredentialStore)
        XCTAssertTrue(verdict.sharedCredentialStores.isEmpty)
        XCTAssertFalse(
            verdict.limitations.contains { $0.contains("not separate accounts") },
            "the disclosure must not appear for an app that does not need it")
    }

    func testKeychainAccessGroupsIsASharedCredentialStore() {
        let stores = Compatibility.sharedCredentialStores(
            facts(entitlements: ["keychain-access-groups"]))
        XCTAssertEqual(stores.map(\.kind), [.keychainAccessGroup])
        XCTAssertEqual(stores.first?.evidence, "keychain-access-groups")
    }

    func testApplicationGroupsIsASharedCredentialStore() {
        let stores = Compatibility.sharedCredentialStores(
            facts(entitlements: ["com.apple.security.application-groups"]))
        XCTAssertEqual(stores.map(\.kind), [.appGroupContainer])
        XCTAssertTrue(stores.first?.evidence.contains("Group Containers") == true)
    }

    /// Both entitlements plus the measured configuration-home mechanism, which is the
    /// exact shape of `/Applications/ChatGPT.app`.
    func testChatGPTDeclaresAllThreeKinds() {
        let stores = Compatibility.sharedCredentialStores(
            facts(bundleIdentifier: "com.openai.codex",
                  displayName: "Codex",
                  entitlements: ["keychain-access-groups",
                                 "com.apple.security.application-groups",
                                 "com.apple.developer.team-identifier"]))
        XCTAssertEqual(Set(stores.map(\.kind)),
                       [.keychainAccessGroup, .appGroupContainer, .configHomeDirectory])
        XCTAssertEqual(stores.first(where: { $0.kind == .configHomeDirectory })?
            .relocationVariable, "CODEX_HOME")
    }

    /// The configuration-home table is keyed to a measured application, not to a name
    /// pattern. An unrelated app with a similar identifier must not inherit it.
    func testTheConfigurationHomeTableIsNotAHeuristic() {
        let stores = Compatibility.sharedCredentialStores(
            facts(bundleIdentifier: "com.openai.codex.something.else"))
        XCTAssertTrue(stores.isEmpty)
    }

    // MARK: The card must change

    func testTheCompatibilityCardLeadsWithTheDisclosureForSuchAnApp() {
        let verdict = Compatibility.evaluate(
            facts(bundleIdentifier: "com.openai.codex",
                  displayName: "Codex",
                  entitlements: ["keychain-access-groups",
                                 "com.apple.security.application-groups"]))

        XCTAssertTrue(verdict.sharesCredentialStore)
        // First, not buried: this is the item that decides whether creating anything is
        // worth doing at all.
        XCTAssertTrue(verdict.limitations.first?.contains("not separate accounts") == true,
                      "expected the disclosure first, got: \(verdict.limitations.first ?? "none")")
        XCTAssertTrue(
            verdict.limitations.contains { $0.contains("sign you out of all of them") },
            "the card must name the observable consequence, not just the mechanism")
        XCTAssertTrue(
            verdict.reasons.contains { $0.contains("outside the redirected profile") })
    }

    func testTheCardOffersTheRelocationVariableWhenThereIsOne() {
        let verdict = Compatibility.evaluate(
            facts(bundleIdentifier: "com.openai.codex", displayName: "Codex"))
        XCTAssertTrue(verdict.limitations.contains { $0.contains("CODEX_HOME") })
    }

    func testTheCardForAKeychainOnlyAppOffersNoRelocationVariable() {
        let verdict = Compatibility.evaluate(
            facts(entitlements: ["keychain-access-groups"]))
        XCTAssertTrue(verdict.sharesCredentialStore)
        XCTAssertFalse(verdict.limitations.contains { $0.contains("route out") },
                       "there is no measured route out for a Keychain group; do not invent one")
    }

    // MARK: The card must not contradict itself

    /// The headline and the limitations are read on one screen, four lines apart. They
    /// must not disagree.
    ///
    /// This shipped: Claude.app declares `keychain-access-groups` and nothing else, and
    /// `inspect` printed "Full profile isolation — separate accounts and a separate
    /// numbered Dock icon per instance" above "Instances of this app are not separate
    /// accounts." The headline was computed first and the disclosure only prepended
    /// afterwards, so nothing reconciled them — and the second sentence was the wrong
    /// one: a Full clone is ad-hoc signed with that entitlement stripped and cannot read
    /// the vendor's Keychain items at all.
    private func assertNoContradiction(_ verdict: CompatibilityVerdict,
                                       file: StaticString = #filePath,
                                       line: UInt = #line) {
        let claimsSeparateAccounts = verdict.headline.contains("separate accounts")
            && !verdict.headline.contains("not a separate account")
        let deniesSeparateAccounts = verdict.limitations.contains {
            $0.hasPrefix("Instances of this app are not separate accounts")
        }
        XCTAssertFalse(claimsSeparateAccounts && deniesSeparateAccounts,
                       """
                       the card claims and denies separate accounts on the same screen:
                         headline:  \(verdict.headline)
                         limitation: \(verdict.limitations.first ?? "—")
                       """,
                       file: file, line: line)
    }

    func testAKeychainOnlyAppDoesNotDenyWhatItsHeadlineClaims() {
        let verdict = Compatibility.evaluate(
            facts(bundleIdentifier: "com.anthropic.claudefordesktop",
                  displayName: "Claude",
                  entitlements: ["keychain-access-groups"]))
        assertNoContradiction(verdict)

        // And the qualification is the accurate one: this bites in Lite, not in Full.
        XCTAssertTrue(verdict.limitations.first?.hasPrefix("A Lite instance") == true,
                      "got: \(verdict.limitations.first ?? "none")")
        XCTAssertFalse(verdict.sharedCredentialStores.contains(where: \.affectsFullMode))
    }

    /// The unqualified sentence still appears where it is true, and the headline stops
    /// claiming the opposite.
    func testAnAppWhoseSessionIsSharedInFullModeSaysSoInBothPlaces() {
        let verdict = Compatibility.evaluate(
            facts(bundleIdentifier: "com.openai.codex",
                  displayName: "Codex",
                  entitlements: ["keychain-access-groups",
                                 "com.apple.security.application-groups"]))
        assertNoContradiction(verdict)

        XCTAssertTrue(verdict.sharedCredentialStores.contains(where: \.affectsFullMode))
        XCTAssertTrue(verdict.headline.contains("not a separate account"),
                      "got: \(verdict.headline)")
        XCTAssertTrue(verdict.limitations.first?
            .hasPrefix("Instances of this app are not separate accounts") == true)
        XCTAssertEqual(verdict.tier, .limited,
                       "an app whose Full clone shares its session is not fully supported")
    }

    /// Every combination of signals, so a future signal cannot reintroduce the
    /// contradiction by being added to the wrong side of the rule.
    func testNoCombinationOfSignalsContradictsItself() {
        let identifiers = ["com.example.plain", "com.openai.codex"]
        let entitlementSets: [[String]] = [
            [],
            ["keychain-access-groups"],
            ["com.apple.security.application-groups"],
            ["keychain-access-groups", "com.apple.security.application-groups"],
        ]
        for identifier in identifiers {
            for entitlements in entitlementSets {
                assertNoContradiction(Compatibility.evaluate(
                    facts(bundleIdentifier: identifier, entitlements: entitlements)))
            }
        }
    }

    /// The Lite gate must not weaken because the wording was qualified: over-warning is
    /// the safe direction here and under-warning is not.
    func testQualifyingTheWordingDoesNotWeakenTheLiteGate() {
        for entitlement in ["keychain-access-groups",
                            "com.apple.security.application-groups"] {
            let verdict = Compatibility.evaluate(facts(entitlements: [entitlement]))
            XCTAssertTrue(verdict.requiresSharedCredentialAcknowledgement(mode: .lite),
                          "\(entitlement) must still gate Lite mode")
            XCTAssertFalse(verdict.requiresSharedCredentialAcknowledgement(mode: .full))
        }
    }

    // MARK: The refusal text

    func testTheLiteRefusalNamesTheConsequenceAndTheEvidence() {
        let stores = Compatibility.sharedCredentialStores(
            facts(bundleIdentifier: "com.openai.codex",
                  displayName: "Codex",
                  entitlements: ["keychain-access-groups"]))
        let text = Compatibility.sharedCredentialLiteRefusal(appName: "Codex", stores: stores)

        XCTAssertTrue(text.contains("Codex"))
        XCTAssertTrue(text.contains("signs out every copy"),
                      "an acknowledgement the user cannot understand is not an acknowledgement")
        XCTAssertTrue(text.contains("keychain-access-groups"))
        XCTAssertTrue(text.contains("~/.codex"))
    }
}
