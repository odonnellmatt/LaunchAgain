import XCTest
@testable import MALCore

/// Info.plist and entitlement rewriting decide whether a clone gets its own Dock tile and
/// whether it launches at all. Both of the failures these tests pin down were real: they
/// were found by building clones of Claude and watching them die.
final class PlistPatchTests: XCTestCase {

    private func electronInfo() -> [String: Any] {
        [
            "CFBundleIdentifier": "com.anthropic.claudefordesktop",
            "CFBundleName": "Claude",
            "CFBundleDisplayName": "Claude",
            "CFBundleExecutable": "Claude",
            "CFBundleIconFile": "electron",
            "CFBundleShortVersionString": "1.4.2",
            "LSMultipleInstancesProhibited": true,
            "CFBundleURLTypes": [["CFBundleURLSchemes": ["claude"]]],
            "SUFeedURL": "https://example.com/appcast.xml",
        ]
    }

    private func options(preserveBundleName: Bool = false) -> PlistPatch.InfoPlistPatchOptions {
        PlistPatch.InfoPlistPatchOptions(
            newBundleIdentifier: "com.anthropic.claudefordesktop.mal2-abcd1234",
            newBundleName: "Claude 2 – Work",
            newDisplayName: "Claude 2 – Work",
            iconFileBaseName: "MALAppIcon",
            shimExecutableName: "mal-shim",
            preserveBundleName: preserveBundleName)
    }

    /// The bundle identifier is the only key that creates a separate Launch Services
    /// identity, which is the whole point of cloning.
    func testIdentityRewrite() throws {
        let result = try PlistPatch.patchInfoPlist(electronInfo(), options: options())
        XCTAssertEqual(result.plist["CFBundleIdentifier"] as? String,
                       "com.anthropic.claudefordesktop.mal2-abcd1234")
        XCTAssertEqual(result.plist["CFBundleDisplayName"] as? String, "Claude 2 – Work")
        XCTAssertEqual(result.plist["CFBundleExecutable"] as? String, "mal-shim")
        XCTAssertEqual(result.originalExecutableName, "Claude")
        XCTAssertEqual(result.plist["CFBundleIconFile"] as? String, "MALAppIcon")
        XCTAssertEqual(result.plist["MALOriginalBundleIdentifier"] as? String,
                       "com.anthropic.claudefordesktop")
        XCTAssertNotNil(result.plist["MALGeneratedBy"], "a clone must say that it is one")
    }

    /// Regression: rewriting CFBundleName made Electron look for
    /// "Claude 2 – Work Helper.app", which does not exist, and the clone aborted at
    /// startup with `FATAL: Unable to find helper app`.
    func testPreservingBundleNameForAppsThatLocateHelpersByIt() throws {
        let preserved = try PlistPatch.patchInfoPlist(electronInfo(), options: options(preserveBundleName: true))
        XCTAssertEqual(preserved.plist["CFBundleName"] as? String, "Claude",
                       "CFBundleName is how Chromium finds its own helper processes")
        XCTAssertEqual(preserved.plist["CFBundleDisplayName"] as? String, "Claude 2 – Work",
                       "the visible name still identifies the instance")
        XCTAssertTrue(preserved.notes.contains { $0.contains("CFBundleName") },
                      "the user is told why the internal name was left alone")

        let renamed = try PlistPatch.patchInfoPlist(electronInfo(), options: options(preserveBundleName: false))
        XCTAssertEqual(renamed.plist["CFBundleName"] as? String, "Claude 2 – Work")
    }

    func testSingleInstanceProhibitionIsCleared() throws {
        let result = try PlistPatch.patchInfoPlist(electronInfo(), options: options())
        XCTAssertEqual(result.plist["LSMultipleInstancesProhibited"] as? Bool, false)
        XCTAssertTrue(result.notes.contains { $0.contains("LSMultipleInstancesProhibited") })
    }

    func testAssetCatalogueIconKeyIsRemovedSoOurIconWins() throws {
        var info = electronInfo()
        info["CFBundleIconName"] = "AppIcon"
        let result = try PlistPatch.patchInfoPlist(info, options: options())
        XCTAssertNil(result.plist["CFBundleIconName"])
        XCTAssertEqual(result.plist["CFBundleIconFile"] as? String, "MALAppIcon")
    }

    func testURLSchemesAreKeptByDefaultAndStrippedOnRequest() throws {
        let kept = try PlistPatch.patchInfoPlist(electronInfo(), options: options())
        XCTAssertNotNil(kept.plist["CFBundleURLTypes"],
                       "stripping schemes by default would break sign-in for every instance")

        var stripping = options()
        stripping.stripURLSchemes = true
        let stripped = try PlistPatch.patchInfoPlist(electronInfo(), options: stripping)
        XCTAssertNil(stripped.plist["CFBundleURLTypes"])
        XCTAssertTrue(stripped.notes.contains { $0.contains("deep-link sign-in") })
    }

    func testSparkleKeysAreOnlyRemovedOnRequest() throws {
        let kept = try PlistPatch.patchInfoPlist(electronInfo(), options: options())
        XCTAssertNotNil(kept.plist["SUFeedURL"])

        var stripping = options()
        stripping.stripSparkleFeed = true
        let stripped = try PlistPatch.patchInfoPlist(electronInfo(), options: stripping)
        XCTAssertNil(stripped.plist["SUFeedURL"])
    }

    func testInvalidBundleIdentifierIsRefused() {
        var bad = options()
        bad.newBundleIdentifier = "not a valid id!"
        XCTAssertThrowsError(try PlistPatch.patchInfoPlist(electronInfo(), options: bad))
    }

    func testMissingExecutableIsRefused() {
        var info = electronInfo()
        info.removeValue(forKey: "CFBundleExecutable")
        XCTAssertThrowsError(try PlistPatch.patchInfoPlist(info, options: options()))
    }

    func testLiteLauncherPlistIsSelfContained() {
        let info = PlistPatch.liteLauncherInfoPlist(bundleIdentifier: "com.mal.x",
                                                     bundleName: "Codex 1",
                                                     displayName: "Codex 1",
                                                     iconFileBaseName: "MALAppIcon",
                                                     shimExecutableName: "mal-shim")
        XCTAssertEqual(info["CFBundlePackageType"] as? String, "APPL")
        XCTAssertEqual(info["CFBundleExecutable"] as? String, "mal-shim")
        XCTAssertEqual(info["CFBundleIdentifier"] as? String, "com.mal.x")
        XCTAssertNotNil(info["MALGeneratedBy"])
    }
}

final class EntitlementsPatchTests: XCTestCase {

    private func claudeEntitlements() -> [String: Any] {
        [
            "com.apple.application-identifier": "TEAMID.com.anthropic.claudefordesktop",
            "com.apple.developer.team-identifier": "TEAMID",
            "keychain-access-groups": ["TEAMID.com.anthropic.claudefordesktop"],
            "com.apple.security.cs.allow-jit": true,
            "com.apple.security.device.camera": true,
        ]
    }

    /// Without this key the clone builds cleanly, then dies on launch with
    /// "different Team IDs" when dyld refuses the vendor-signed Electron framework.
    func testLibraryValidationIsDisabled() {
        let result = EntitlementsPatch.patch(claudeEntitlements())
        XCTAssertEqual(result.entitlements[EntitlementsPatch.libraryValidationKey] as? Bool, true)
        XCTAssertTrue(result.added.contains { $0.contains("disable-library-validation") })
    }

    func testTeamBoundEntitlementsAreDroppedAndReported() {
        let result = EntitlementsPatch.patch(claudeEntitlements())
        for key in ["com.apple.application-identifier",
                    "com.apple.developer.team-identifier",
                    "keychain-access-groups"] {
            XCTAssertNil(result.entitlements[key], "\(key) cannot survive ad-hoc signing")
            XCTAssertTrue(result.removed.contains { $0.hasPrefix(key) },
                          "dropping \(key) must be reported to the user, not done quietly")
        }
    }

    func testHarmlessEntitlementsAreKept() {
        let result = EntitlementsPatch.patch(claudeEntitlements())
        XCTAssertEqual(result.entitlements["com.apple.security.cs.allow-jit"] as? Bool, true)
        XCTAssertEqual(result.entitlements["com.apple.security.device.camera"] as? Bool, true)
    }

    func testPatchingIsIdempotent() {
        let once = EntitlementsPatch.patch(claudeEntitlements())
        let twice = EntitlementsPatch.patch(once.entitlements)
        XCTAssertTrue(twice.removed.isEmpty)
        XCTAssertTrue(twice.added.isEmpty, "the key is already present, so nothing is added again")
    }

    /// Regression: helpers signed without their own entitlements start and then die the
    /// moment the renderer allocates executable memory for the JIT.
    func testHelperFallbackCoversWhatAChromiumRendererNeeds() {
        for key in ["com.apple.security.cs.allow-jit",
                    "com.apple.security.cs.allow-unsigned-executable-memory",
                    "com.apple.security.cs.allow-dyld-environment-variables",
                    EntitlementsPatch.libraryValidationKey] {
            XCTAssertEqual(EntitlementsPatch.helperFallback[key] as? Bool, true,
                           "\(key) is required by a re-signed Chromium helper")
        }
    }
}

final class CompatibilityTests: XCTestCase {

    private func electron(_ mutate: (inout AppFacts) -> Void = { _ in }) -> AppFacts {
        var f = AppFacts(bundleIdentifier: "com.example.app",
                         displayName: "Example",
                         executableName: "Example",
                         shortVersion: "1.0",
                         path: "/Applications/Example.app",
                         runtime: .electron,
                         isSigned: true,
                         signingInspected: true)
        mutate(&f)
        return f
    }

    func testAnOrdinarySignedElectronAppIsFullySupported() {
        let v = Compatibility.evaluate(electron())
        XCTAssertEqual(v.tier, .supported)
        XCTAssertEqual(v.recommendedMode, .full)
        XCTAssertEqual(v.mechanism, .userDataDir)
        XCTAssertFalse(v.provisional)
    }

    /// Regression: a browse list is built from Info.plist alone. Treating "we have not
    /// run codesign yet" as "this app is unsigned" downgraded every app on the machine
    /// to Limited.
    func testUninspectedSigningDoesNotDowngradeTheTier() {
        let v = Compatibility.evaluate(electron { $0.isSigned = false; $0.signingInspected = false })
        XCTAssertEqual(v.tier, .supported)
        XCTAssertTrue(v.provisional, "and the verdict says it has not been fully checked")
        XCTAssertTrue(v.tierLabel.contains("likely"))

        let inspected = Compatibility.evaluate(electron { $0.isSigned = false; $0.signingInspected = true })
        XCTAssertEqual(inspected.tier, .limited, "once checked, unsigned really is a downgrade")
        XCTAssertEqual(inspected.recommendedMode, .lite)
    }

    func testSandboxedAndAppStoreAppsAreRefusedWithAReason() {
        for facts in [electron { $0.isSandboxed = true }, electron { $0.hasMASReceipt = true }] {
            let v = Compatibility.evaluate(facts)
            XCTAssertEqual(v.tier, .notSupported)
            XCTAssertFalse(v.canCreate)
            XCTAssertFalse(v.reasons.isEmpty, "a refusal must say why")
        }
    }

    func testNativeAppsAreRefusedWithAnExplanationRatherThanASlogan() {
        let v = Compatibility.evaluate(electron { $0.runtime = .native })
        XCTAssertEqual(v.tier, .notSupported)
        XCTAssertTrue(v.limitations.joined().contains("bundle identifier"),
                      "the explanation should describe the actual obstacle")
    }

    func testBrowserWebAppsPointAtTheBrowserInstead() {
        let v = Compatibility.evaluate(electron { $0.runtime = .webAppShortcut })
        XCTAssertEqual(v.tier, .notSupported)
        XCTAssertTrue(v.limitations.joined().localizedCaseInsensitiveContains("browser instead"),
                      "a dead end should be turned into the thing that does work")
    }

    func testPrivilegedHelperDegradesToLite() {
        let v = Compatibility.evaluate(electron { $0.hasPrivilegedHelper = true })
        XCTAssertEqual(v.tier, .limited)
        XCTAssertEqual(v.recommendedMode, .lite)
        let limitations = v.limitations.joined(separator: " ")
        XCTAssertTrue(limitations.contains("vendor-signed original"))
        XCTAssertTrue(limitations.contains("URL-scheme ownership"))
        XCTAssertTrue(v.headline.contains("Lite profile isolation"))
    }

    func testTeamBoundEntitlementsRemainFullButDoNotOverpromiseCapabilities() {
        let v = Compatibility.evaluate(electron {
            $0.entitlementKeys = ["com.apple.security.application-groups"]
        })
        XCTAssertEqual(v.tier, .limited)
        XCTAssertEqual(v.recommendedMode, .full)
        XCTAssertTrue(v.headline.contains("numbered Dock icon"))
        XCTAssertFalse(v.headline.contains("share one Dock icon"))
    }

    func testEveryVerdictStatesTheKeychainAndSessionLimits() {
        for facts in [electron(), electron { $0.hasPrivilegedHelper = true }] {
            let joined = Compatibility.evaluate(facts).limitations.joined(separator: " ")
            XCTAssertTrue(joined.contains("Keychain"), "Keychain sharing is always stated")
            XCTAssertTrue(joined.localizedCaseInsensitiveContains("concurrent"),
                          "the vendor's own session rules are always stated")
        }
    }

    func testURLSchemeCollisionIsCalledOutWhenTheAppDeclaresSchemes() {
        let without = Compatibility.evaluate(electron())
        XCTAssertFalse(without.limitations.joined().contains("URL scheme"))
        let with = Compatibility.evaluate(electron { $0.declaresURLSchemes = true })
        XCTAssertTrue(with.limitations.joined().contains("URL scheme"))
        XCTAssertTrue(with.limitations.joined().contains("Lite launcher"))
    }

    func testUpdaterBehaviourIsDisclosed() {
        let squirrel = Compatibility.evaluate(electron { $0.updater = .squirrel })
        XCTAssertTrue(squirrel.limitations.joined().contains("Squirrel"))
        let sparkle = Compatibility.evaluate(electron { $0.updater = .sparkle })
        XCTAssertTrue(sparkle.limitations.joined().contains("Sparkle"))
    }

    // MARK: The GUI-only boundary
    //
    // These replace three tests that asserted a command line tool was `.supported`
    // through its config-directory variable. That subsystem was removed: the product
    // creates and opens GUI applications only, so the verdict it used to return was a
    // claim the rest of the codebase already refused to honour.

    /// A command-line executable has no bundle and therefore no recognisable runtime.
    /// It must be refused with a reason, not half-supported.
    func testACommandLineExecutableIsNotSupported() {
        let f = AppFacts(bundleIdentifier: "",
                         displayName: "codex",
                         executableName: "codex",
                         path: "/opt/homebrew/bin/codex",
                         runtime: .unknown,
                         signingInspected: true)
        let v = Compatibility.evaluate(f)
        XCTAssertEqual(v.tier, .notSupported)
        XCTAssertFalse(v.canCreate)
        XCTAssertFalse(v.reasons.isEmpty, "a refusal must say why")
    }

    /// No verdict this function can produce may nominate the legacy mechanism.
    func testNoVerdictEverSelectsTheLegacyTerminalMechanism() {
        let runtimes: [RuntimeKind] = [.electron, .chromium, .webkitWrapper,
                                       .native, .webAppShortcut, .unknown]
        for runtime in runtimes {
            for sandboxed in [true, false] {
                for signed in [true, false] {
                    var f = AppFacts(bundleIdentifier: "com.example.app",
                                     displayName: "App",
                                     executableName: "App",
                                     path: "/Applications/App.app",
                                     runtime: runtime,
                                     isSandboxed: sandboxed,
                                     isSigned: signed,
                                     signingInspected: true)
                    f.declaresURLSchemes = true
                    let v = Compatibility.evaluate(f)
                    XCTAssertNotEqual(v.mechanism, .configEnvironment,
                                      "runtime \(runtime) sandboxed=\(sandboxed) signed=\(signed)")
                }
            }
        }
    }

    func testTheRefusalForANonElectronAppNamesGUIApplications() {
        let f = AppFacts(bundleIdentifier: "com.example.native",
                         displayName: "Native",
                         executableName: "Native",
                         path: "/Applications/Native.app",
                         runtime: .native,
                         signingInspected: true)
        let joined = Compatibility.evaluate(f).reasons.joined(separator: " ")
        XCTAssertTrue(joined.contains("GUI applications"), "got: \(joined)")
    }
}
