import XCTest
@testable import MALCore

/// Nothing in this project builds a shell command from a string, so the job of these
/// tests is to prove that adversarial names cannot corrupt a *file format* or a
/// filesystem operation — which is the failure mode that is actually available here.
final class ValidationTests: XCTestCase {

    func testInstanceNamesAreMadeSafeWithoutBeingRejected() {
        // A name field should never block the user; it should only be cleaned.
        XCTAssertEqual(Validation.sanitizeInstanceName("  Work  "), "Work")
        XCTAssertEqual(Validation.sanitizeInstanceName("Work/Personal"), "Work Personal")
        XCTAssertEqual(Validation.sanitizeInstanceName("Work:Personal"), "Work Personal")
        XCTAssertEqual(Validation.sanitizeInstanceName("line\nbreak"), "line break")
        XCTAssertEqual(Validation.sanitizeInstanceName(".hidden"), "hidden",
                       "a leading dot would create a hidden bundle")
        XCTAssertEqual(Validation.sanitizeInstanceName("...."), "")
    }

    func testAdversarialNamesSurviveAsPlainText() {
        // These are not dangerous — they are just strings — and the product should keep
        // them legible rather than mangling them.
        for name in ["$(rm -rf ~)", "`whoami`", "a\"b", "a'b", "工作", "Работа", "🌍 Work", "עברית"] {
            let clean = Validation.sanitizeInstanceName(name)
            XCTAssertFalse(clean.contains("/"))
            XCTAssertFalse(clean.contains("\n"))
            XCTAssertFalse(clean.isEmpty, "\(name) should not be emptied out")
        }
        XCTAssertEqual(Validation.sanitizeInstanceName("$(rm -rf ~)"), "$(rm -rf ~)",
                       "shell metacharacters are ordinary characters when nothing runs a shell")
    }

    func testNameLengthIsBounded() {
        let long = String(repeating: "a", count: 500)
        XCTAssertEqual(Validation.sanitizeInstanceName(long).count, Validation.maxNameLength)
        XCTAssertEqual(Validation.sanitizeAccountLabel(long).count, Validation.maxAccountLabelLength)
    }

    func testAccountLabelsKeepPunctuationButNotControlCharacters() {
        XCTAssertEqual(Validation.sanitizeAccountLabel("work@example.com"), "work@example.com")
        XCTAssertEqual(Validation.sanitizeAccountLabel("a\nb"), "a b")
    }

    // MARK: Paths

    func testAbsolutePathValidation() {
        XCTAssertNoThrow(try Validation.validateAbsolutePath("/Users/x/Library/Application Support/MAL"))
        XCTAssertThrowsError(try Validation.validateAbsolutePath(""))
        XCTAssertThrowsError(try Validation.validateAbsolutePath("relative/path"))
        XCTAssertThrowsError(try Validation.validateAbsolutePath("/has\nnewline"),
                             "a newline would truncate the shim's line-based config")
        XCTAssertThrowsError(try Validation.validateAbsolutePath("/" + String(repeating: "a", count: 2000)))
    }

    func testPathsWithSpacesQuotesAndEmojiAreAccepted() {
        for path in ["/Users/x/My Apps/Claude 2 – Work.app",
                     "/Users/x/it's here/data",
                     "/Users/x/\"quoted\"/data",
                     "/Users/x/$(echo hi)/data",
                     "/Users/x/🌍/data"] {
            XCTAssertNoThrow(try Validation.validateAbsolutePath(path), "\(path) is a legitimate path")
        }
    }

    func testContainmentCheckIsUsedToGuardDeletion() {
        XCTAssertTrue(Validation.isPath("/a/b/c", within: "/a/b"))
        XCTAssertTrue(Validation.isPath("/a/b", within: "/a/b"))
        XCTAssertFalse(Validation.isPath("/a/bc", within: "/a/b"), "prefix matching must respect separators")
        XCTAssertFalse(Validation.isPath("/a", within: "/a/b"))
        XCTAssertFalse(Validation.isPath("/a/b/../../etc", within: "/a/b"),
                       "`..` must be resolved before the comparison")
    }

    func testCanonicalPathIdentityResolvesExistingSymlinkAncestors() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("launchagain-path-alias-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("real")
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)

        let realFuture = real.appendingPathComponent("not-created/Instance.app").path
        let aliasFuture = alias.appendingPathComponent("not-created/Instance.app").path
        XCTAssertTrue(Validation.pathsReferToSameLocation(realFuture, aliasFuture))
        XCTAssertTrue(Validation.isPath(aliasFuture, within: real.path))
    }

    // MARK: Bundle identifiers

    func testCloneIdentifiersAreValidAndUnique() {
        let a = Validation.cloneBundleIdentifier(original: "com.anthropic.claudefordesktop",
                                                 number: 2, instanceID: UUID())
        let b = Validation.cloneBundleIdentifier(original: "com.anthropic.claudefordesktop",
                                                 number: 2, instanceID: UUID())
        XCTAssertTrue(a.hasPrefix("com.anthropic.claudefordesktop.mal2-"))
        XCTAssertTrue(Validation.isValidBundleIdentifier(a))
        XCTAssertNotEqual(a, b, "recreating an instance must not collide with a stale registration")
    }

    func testOnlyTheExactGeneratedCloneIdentityCanDriveAssociatedCleanup() {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
        let generated = Validation.cloneBundleIdentifier(
            original: "com.example.app", number: 2, instanceID: id)
        XCTAssertTrue(Validation.isCloneBundleIdentifier(
            generated, forNumber: 2, instanceID: id))
        XCTAssertFalse(Validation.isCloneBundleIdentifier(
            "com.example.app", forNumber: 2, instanceID: id))
        XCTAssertFalse(Validation.isCloneBundleIdentifier(
            generated, forNumber: 1, instanceID: id))
        XCTAssertFalse(Validation.isCloneBundleIdentifier(
            "-hostile.mal2-12345678", forNumber: 2, instanceID: id))
    }

    func testBundleIdentifierSanitisation() {
        XCTAssertEqual(Validation.sanitizeBundleIDComponent("com.example.app"), "com.example.app")
        XCTAssertEqual(Validation.sanitizeBundleIDComponent("com example app"), "com-example-app")
        XCTAssertEqual(Validation.sanitizeBundleIDComponent(".leading."), "leading")
        XCTAssertEqual(Validation.sanitizeBundleIDComponent("🌍"), "app.unknown")
        XCTAssertTrue(Validation.isValidBundleIdentifier(
            Validation.cloneBundleIdentifier(original: "🌍 weird", number: 1, instanceID: UUID())))
    }

    func testBundleIdentifierValidation() {
        XCTAssertFalse(Validation.isValidBundleIdentifier(""))
        XCTAssertFalse(Validation.isValidBundleIdentifier(".leading"))
        XCTAssertFalse(Validation.isValidBundleIdentifier("trailing."))
        XCTAssertFalse(Validation.isValidBundleIdentifier("double..dot"))
        XCTAssertFalse(Validation.isValidBundleIdentifier("has space"))
        XCTAssertTrue(Validation.isValidBundleIdentifier("com.a-b.c1"))
    }

    // MARK: Bundle filenames

    func testBundleFilenamesAvoidCollisions() {
        let taken: Set<String> = ["claude 2 – work.app", "claude 2 – work (2).app"]
        let name = Validation.uniqueBundleFilename(preferred: "Claude 2 – Work", taken: taken)
        XCTAssertEqual(name, "Claude 2 – Work (3).app")
    }

    func testEmptyPreferredNameStillProducesAValidBundleName() {
        XCTAssertEqual(Validation.uniqueBundleFilename(preferred: "", taken: []), "Instance.app")
    }
}

/// The argument vector and the shim's config file are the two places a user-supplied
/// string crosses a boundary, so both are covered here including the round trip.
final class ArgumentBuilderTests: XCTestCase {

    func testUserDataDirComesFirst() throws {
        let args = try ArgumentBuilder.launchArguments(dataPath: "/tmp/profile",
                                                       extraArguments: ["--disable-gpu"])
        XCTAssertEqual(args.first, "--user-data-dir=/tmp/profile",
                       "ours must win if the app takes the first occurrence of a repeated flag")
        XCTAssertEqual(args.last, "--disable-gpu")
    }

    func testFlagsThatWouldDefeatIsolationAreRefused() {
        for flag in ["--user-data-dir=/elsewhere", "--profile-directory=Default"] {
            XCTAssertThrowsError(try ArgumentBuilder.sanitizeExtraArguments([flag]),
                                 "\(flag) would break the isolation the instance exists for")
        }
    }

    func testControlCharactersInArgumentsAreRefused() {
        XCTAssertThrowsError(try ArgumentBuilder.sanitizeExtraArguments(["--flag\nmore"]))
        XCTAssertThrowsError(try ArgumentBuilder.sanitizeExtraArguments(["--flag\u{0}"]))
    }

    func testOrdinaryArgumentsPassThroughUntouched() throws {
        let args = try ArgumentBuilder.sanitizeExtraArguments(["  --lang=en-GB  ", "", "--x=$(id)"])
        XCTAssertEqual(args, ["--lang=en-GB", "--x=$(id)"])
    }

    func testHomeCannotBeRedirected() {
        XCTAssertThrowsError(try ArgumentBuilder.sanitizeEnvironment(["HOME": "/tmp/fake"])) { error in
            XCTAssertTrue("\(error)".contains("Keychain"),
                          "the refusal should say why, not just refuse")
        }
    }

    func testMalformedEnvironmentIsRefused() {
        XCTAssertThrowsError(try ArgumentBuilder.sanitizeEnvironment(["A=B": "c"]))
        XCTAssertThrowsError(try ArgumentBuilder.sanitizeEnvironment(["A": "line\nbreak"]))
    }
}

final class InstanceConfigTests: XCTestCase {

    func testAppConfigRoundTrip() throws {
        let config = InstanceConfig(mode: .full,
                                    dataPath: "/Users/x/Library/Application Support/MAL/instances/1/userdata",
                                    realExecutableName: "Claude.real",
                                    extraArguments: ["--lang=en-GB"],
                                    extraEnvironment: ["FOO": "bar=baz"])
        let parsed = try InstanceConfig.parse(try config.serialized())
        XCTAssertEqual(parsed, config)
    }

    func testAdversarialPathsSurviveTheRoundTrip() throws {
        for path in ["/Users/x/My Apps/it's a 🌍 “profile”/data",
                     "/Users/x/$(rm -rf ~)/data",
                     "/Users/x/a=b/data"] {
            let config = InstanceConfig(mode: .full, dataPath: path, realExecutableName: "App.real")
            let parsed = try InstanceConfig.parse(try config.serialized())
            XCTAssertEqual(parsed.dataPath, path)
        }
    }

    func testEnvironmentValuesMayContainEquals() throws {
        let config = InstanceConfig(mode: .full, dataPath: "/tmp/x", realExecutableName: "A.real",
                                    extraEnvironment: ["K": "a=b=c"])
        let parsed = try InstanceConfig.parse(try config.serialized())
        XCTAssertEqual(parsed.extraEnvironment["K"], "a=b=c",
                       "everything after the first = is the value")
    }

    func testToolConfigRoundTrip() throws {
        let config = InstanceConfig(kind: .tool,
                                    mode: .full,
                                    dataPath: "/Users/x/instances/1/userdata",
                                    scriptPath: "/Users/x/Codex 1.app/Contents/Resources/Launch.command",
                                    terminalApp: "Terminal")
        let text = try config.serialized()
        XCTAssertTrue(text.contains("kind=tool"))
        let parsed = try InstanceConfig.parse(text)
        XCTAssertEqual(parsed, config)
    }

    func testFullModeRequiresARealExecutableName() {
        let config = InstanceConfig(mode: .full, dataPath: "/tmp/x")
        XCTAssertThrowsError(try config.serialized())
    }

    func testRealExecutableMustBeAFilenameNotAPath() {
        let config = InstanceConfig(mode: .full, dataPath: "/tmp/x", realExecutableName: "../../etc/passwd")
        XCTAssertThrowsError(try config.serialized())
    }

    func testLiteModeRequiresATargetApplication() {
        XCTAssertThrowsError(try InstanceConfig(mode: .lite, dataPath: "/tmp/x").serialized())
        XCTAssertNoThrow(try InstanceConfig(mode: .lite, dataPath: "/tmp/x",
                                            targetAppPath: "/Applications/Claude.app").serialized())
    }

    func testToolModeRequiresAScript() {
        XCTAssertThrowsError(try InstanceConfig(kind: .tool, mode: .full, dataPath: "/tmp/x").serialized())
    }

    func testConfigWithoutADataDirectoryIsRejected() {
        XCTAssertThrowsError(try InstanceConfig.parse("mode=full\nexec=A.real\n"))
    }

    func testUnknownKeysAndCommentsAreIgnored() throws {
        let text = """
        # a comment
        mode=full
        udd=/tmp/x
        exec=A.real
        somethingNew=value
        """
        let parsed = try InstanceConfig.parse(text)
        XCTAssertEqual(parsed.dataPath, "/tmp/x")
        XCTAssertEqual(parsed.kind, .app, "an older config has no kind and must default")
    }
}

final class BadgeSpecTests: XCTestCase {

    func testColourNormalisation() {
        XCTAssertEqual(BadgeSpec.normalizeHex("#1b6ef3"), "#1B6EF3")
        XCTAssertEqual(BadgeSpec.normalizeHex("1B6EF3"), "#1B6EF3")
        XCTAssertEqual(BadgeSpec.normalizeHex("#abc"), "#AABBCC")
        XCTAssertNil(BadgeSpec.normalizeHex("#zzz"))
        XCTAssertNil(BadgeSpec.normalizeHex(""))
    }

    func testGarbageColourFallsBackRatherThanThrowing() {
        XCTAssertEqual(BadgeSpec(colorHex: "not a colour").colorHex, BadgeSpec.defaultColor)
    }

    func testScaleIsClamped() {
        XCTAssertEqual(BadgeSpec.clampScale(0.01), 0.22)
        XCTAssertEqual(BadgeSpec.clampScale(9.0), 0.5)
        XCTAssertEqual(BadgeSpec.clampScale(.nan), 0.36)
    }

    func testSuggestedColoursCycleAndAreStable() {
        XCTAssertEqual(BadgeSpec.suggestedColor(forNumber: 1), BadgeSpec.suggestedColor(forNumber: 9))
        XCTAssertNotEqual(BadgeSpec.suggestedColor(forNumber: 1), BadgeSpec.suggestedColor(forNumber: 2))
        XCTAssertEqual(BadgeSpec.suggestedColor(forNumber: 0), BadgeSpec.suggestedColor(forNumber: 1))
    }

    func testRGBDecoding() {
        let (r, g, b) = BadgeSpec(colorHex: "#FF8000").rgb
        XCTAssertEqual(r, 1.0, accuracy: 0.001)
        XCTAssertEqual(g, 128.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(b, 0.0, accuracy: 0.001)
    }

    func testDisplayTitleUsesTheNumberWhenUnnamed() {
        let unnamed = Instance(number: 3, name: "", bundlePath: "", dataPath: "")
        XCTAssertEqual(unnamed.displayTitle(sourceName: "Claude"), "Claude 3")
        let named = Instance(number: 3, name: "Work", bundlePath: "", dataPath: "")
        XCTAssertEqual(named.displayTitle(sourceName: "Claude"), "Claude 3 – Work")
    }
}
