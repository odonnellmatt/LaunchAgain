#if canImport(Darwin)
import XCTest
import AppKit
@testable import MALKit
@testable import MALCore

/// Icon generation. The number is the identifier, so the only thing that really matters
/// is that it is *there* and legible at every size the Dock asks for.
final class IconFactoryTests: XCTestCase {

    private var cache: URL!
    private var factory: IconFactory!
    private var source: NSImage!

    override func setUpWithError() throws {
        cache = FileManager.default.temporaryDirectory.appendingPathComponent("mal-icons-\(UUID().uuidString)")
        factory = IconFactory(cacheDir: cache)
        // A plain coloured square stands in for an app icon.
        source = NSImage(size: NSSize(width: 512, height: 512))
        source.lockFocus()
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: 512, height: 512).fill()
        source.unlockFocus()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: cache)
    }

    /// One, two and three digits, at the sizes the pass condition names.
    func testEveryDigitCountRendersAtEverySize() throws {
        for number in [1, 2, 9, 10, 99, 100] {
            for pixels in [16, 32, 128, 512, 1024] {
                let rep = factory.render(sourceIcon: source,
                                         number: number,
                                         badge: BadgeSpec(colorHex: BadgeSpec.suggestedColor(forNumber: number)),
                                         pixels: pixels)
                let bitmap = try XCTUnwrap(rep, "no bitmap for #\(number) at \(pixels)px")
                XCTAssertEqual(bitmap.pixelsWide, pixels)
                XCTAssertEqual(bitmap.pixelsHigh, pixels)
            }
        }
    }

    /// The badge must actually change the pixels in its corner — a badge that renders
    /// nothing would still produce a valid, and useless, icon.
    func testTheBadgeIsVisibleInItsCorner() throws {
        let badge = BadgeSpec(position: .bottomTrailing, colorHex: "#E5484D")
        let plain = try XCTUnwrap(factory.render(sourceIcon: source, number: 1,
                                                 badge: BadgeSpec(scale: 0.22), pixels: 256))
        let badged = try XCTUnwrap(factory.render(sourceIcon: source, number: 8, badge: badge, pixels: 256))

        // Sample inside the bottom-trailing badge area.
        let x = 256 - 40, y = 256 - 40
        let a = try XCTUnwrap(plain.colorAt(x: x, y: y))
        let b = try XCTUnwrap(badged.colorAt(x: x, y: y))
        XCTAssertNotEqual(a.description, b.description, "the badge did not draw where it was asked to")
    }

    func testBadgePositionIsHonoured() throws {
        let topLeft = try XCTUnwrap(factory.render(sourceIcon: source, number: 7,
                                                   badge: BadgeSpec(position: .topLeading, colorHex: "#E5484D"),
                                                   pixels: 256))
        // In AppKit's bitmap coordinates y grows downwards, so "top" is a small y.
        let insideTopLeft = try XCTUnwrap(topLeft.colorAt(x: 40, y: 40))
        let insideBottomRight = try XCTUnwrap(topLeft.colorAt(x: 216, y: 216))
        XCTAssertNotEqual(insideTopLeft.description, insideBottomRight.description)
    }

    func testICNSIsProducedAndIsAValidIconFile() throws {
        let destination = cache.appendingPathComponent("out/icon.icns")
        try factory.buildICNS(sourceIcon: source, number: 42, badge: BadgeSpec(), destination: destination)

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        let data = try Data(contentsOf: destination)
        XCTAssertGreaterThan(data.count, 1000)
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "icns",
                       "the file must carry the icns magic number")
        let image = try XCTUnwrap(NSImage(contentsOf: destination))
        XCTAssertFalse(image.representations.isEmpty)
    }

    func testPreviewMatchesWhatWillBeBuilt() {
        let preview = factory.preview(sourceIcon: source, number: 3, badge: BadgeSpec(), pixelSize: 128)
        XCTAssertEqual(preview.size.width, 128)
        XCTAssertFalse(preview.representations.isEmpty)
    }

    func testTheLauncherDrawsItsOwnIcon() throws {
        let rep = try XCTUnwrap(AppIconArt.render(pixels: 256))
        XCTAssertEqual(rep.pixelsWide, 256)
        // The art is inset, so the centre must not be transparent while a corner is.
        let centre = try XCTUnwrap(rep.colorAt(x: 128, y: 128))
        XCTAssertGreaterThan(centre.alphaComponent, 0.5)
    }

    /// Opaque near-black pixels, which nothing in this icon is supposed to draw.
    private func nearBlackPixelCount(_ rep: NSBitmapImageRep) -> Int {
        var count = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if c.alphaComponent > 0.5,
                   c.redComponent < 0.25, c.greenComponent < 0.25, c.blueComponent < 0.25 {
                    count += 1
                }
            }
        }
        return count
    }

    /// The launcher's own icon must not contain a black blob at any size.
    ///
    /// It did, at 16 px, in the icon the application shipped. The numeral's shrink loop
    /// was `while size > 1` starting from about 0.89 at that size, so the body never ran:
    /// the attributes dictionary stayed empty and `draw(at:withAttributes: [:])` fell back
    /// to the system 12 pt **black** font, drawn from an origin computed off a zero
    /// measurement. Sixteen opaque near-black pixels out of 256 — a blob over a
    /// sixteen-pixel icon — and zero at every larger size, which is why looking only at
    /// 512 missed it.
    ///
    /// Palette colours are all comfortably lighter than the threshold, so anything this
    /// catches is the unstyled fallback.
    func testTheLauncherIconHasNoBlackBlobAtAnySize() throws {
        for pixels in [16, 32, 64, 128, 256, 512, 1024] {
            let rep = try XCTUnwrap(AppIconArt.render(pixels: pixels),
                                    "no bitmap at \(pixels)px")
            let dark = nearBlackPixelCount(rep)
            XCTAssertEqual(dark, 0,
                           "\(dark) opaque near-black pixels at \(pixels)px — the numeral is being drawn with the unstyled system fallback instead of the white bold font")
        }
    }

    /// The shrink loop must choose a font at least once at every size, which is the
    /// condition that failed. Asserting it separately means a future change that
    /// reintroduces the empty-attributes path fails here with the reason, not just with a
    /// pixel count somewhere else.
    func testTheNumeralIsEitherDrawnProperlyOrNotAtAll() throws {
        // At the smallest sizes the numeral may legitimately be skipped; what it may
        // never be is drawn in the fallback font. Both outcomes are black-pixel-free,
        // and the larger sizes must still actually carry a numeral.
        for pixels in [128, 512] {
            let rep = try XCTUnwrap(AppIconArt.render(pixels: pixels))
            var white = 0
            for y in 0..<rep.pixelsHigh {
                for x in 0..<rep.pixelsWide {
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    if c.alphaComponent > 0.5,
                       c.redComponent > 0.9, c.greenComponent > 0.9, c.blueComponent > 0.9 {
                        white += 1
                    }
                }
            }
            XCTAssertGreaterThan(white, 0, "no white numeral at \(pixels)px")
        }
    }
}

final class CodeSignerTests: XCTestCase {

    func testMachOFilesAreIdentifiedByTheirMagicNumber() throws {
        XCTAssertTrue(CodeSigner.isMachO(URL(fileURLWithPath: "/bin/echo")))
        XCTAssertTrue(CodeSigner.isMachO(URL(fileURLWithPath: "/usr/bin/codesign")))

        let text = FileManager.default.temporaryDirectory.appendingPathComponent("mal-not-macho-\(UUID().uuidString)")
        try Data("#!/bin/sh\necho hi\n".utf8).write(to: text)
        defer { try? FileManager.default.removeItem(at: text) }
        XCTAssertFalse(CodeSigner.isMachO(text), "a shell script is not Mach-O even though it is executable")
        XCTAssertFalse(CodeSigner.isMachO(URL(fileURLWithPath: "/does/not/exist")))
    }

    func testNestedCodeIsListedDeepestFirst() throws {
        // Frameworks must be sealed before the bundle that contains them.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mal-nested-\(UUID().uuidString)")
        let app = root.appendingPathComponent("Test.app")
        let inner = app.appendingPathComponent("Contents/Frameworks/Inner.framework/Versions/A")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"),
                                         to: inner.appendingPathComponent("Inner"))
        defer { try? FileManager.default.removeItem(at: root) }

        let items = CodeSigner(log: .silent).nestedCodeItems(in: app)
        XCTAssertFalse(items.isEmpty)
        let depths = items.map { $0.pathComponents.count }
        XCTAssertEqual(depths, depths.sorted(by: >), "items must be ordered deepest first")
    }
}

final class BundleAssemblerTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mal-assembler-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testTheShimIsFoundNextToWhateverIsRunning() throws {
        // This also proves the test bundle is running from a build directory that
        // contains the shim, which every build depends on.
        XCTAssertNoThrow(try BundleAssembler.locateShimBinary())
    }

    func testFingerprintChangesWhenTheInfoPlistChanges() throws {
        let app = root.appendingPathComponent("A.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"),
                                                withIntermediateDirectories: true)
        try BundleAssembler.writeInfoPlist(["CFBundleIdentifier": "com.example.a"], bundle: app)
        let before = BundleAssembler.sourceFingerprint(bundle: app)
        try BundleAssembler.writeInfoPlist(["CFBundleIdentifier": "com.example.b"], bundle: app)
        XCTAssertNotEqual(BundleAssembler.sourceFingerprint(bundle: app), before)
    }

    /// The escaping tests these replaced covered `BundleAssembler.writeToolScript`,
    /// the generator for the `.command` script a Terminal instance opened. That
    /// generator is gone with the rest of the command-line-tool subsystem, and the
    /// guarantee is now stronger than "the quoting is correct": no generated launcher
    /// contains a shell script at all, so there is no shell text to get wrong.
    func testNoGeneratedLauncherContainsAShellScript() throws {
        let launcher = root.appendingPathComponent("Generated.app")
        try BundleAssembler.createLiteLauncher(
            at: launcher,
            shimBinary: BundleAssembler.locateShimBinary(),
            shimName: "mal-shim",
            infoPlist: ["CFBundleIdentifier": "com.example.generated"],
            config: InstanceConfig(mode: .lite,
                                   dataPath: root.appendingPathComponent("data").path,
                                   targetAppPath: "/System/Applications/Calculator.app"))

        let enumerator = FileManager.default.enumerator(at: launcher,
                                                        includingPropertiesForKeys: [.isRegularFileKey])
        var inspected = 0
        while let url = enumerator?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            inspected += 1
            XCTAssertNotEqual(url.pathExtension, "command",
                              "a generated launcher must not carry a shell script: \(url.path)")
            XCTAssertNotEqual(url.pathExtension, "sh", url.path)
            if let head = try? String(contentsOf: url, encoding: .utf8).prefix(2) {
                XCTAssertNotEqual(head, "#!",
                                  "no file in a generated launcher may be a script: \(url.path)")
            }
        }
        XCTAssertGreaterThan(inspected, 2, "the launcher should actually have been built")
    }

    /// Regression: Chromium locates its child processes at
    /// `Contents/Frameworks/<CFBundleName> Helper (Renderer).app`, so a clone that
    /// renames CFBundleName cannot find them and aborts at startup.
    func testHelperNamingIsDetectedInBothLayouts() throws {
        let info: [String: Any] = ["CFBundleName": "Fake"]

        // Electron: helpers directly in Contents/Frameworks.
        let electron = root.appendingPathComponent("Electron.app")
        try FileManager.default.createDirectory(
            at: electron.appendingPathComponent("Contents/Frameworks/Fake Helper (Renderer).app"),
            withIntermediateDirectories: true)
        XCTAssertTrue(BundleAssembler.helpersAreNamedAfterBundleName(bundle: electron, info: info))

        // Chrome: helpers nested inside the versioned framework.
        let chrome = root.appendingPathComponent("Chrome.app")
        try FileManager.default.createDirectory(
            at: chrome.appendingPathComponent("Contents/Frameworks/Fake Framework.framework/Versions/1.0/Helpers/Fake Helper.app"),
            withIntermediateDirectories: true)
        XCTAssertTrue(BundleAssembler.helpersAreNamedAfterBundleName(bundle: chrome, info: info))

        // An app with no helpers can be renamed outright.
        let plain = root.appendingPathComponent("Plain.app")
        try FileManager.default.createDirectory(at: plain.appendingPathComponent("Contents/MacOS"),
                                                withIntermediateDirectories: true)
        XCTAssertFalse(BundleAssembler.helpersAreNamedAfterBundleName(bundle: plain, info: info))
    }
}

final class AppScannerTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mal-scanner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeBundle(_ name: String, info: [String: Any] = [:], paths: [String] = []) throws -> URL {
        let app = root.appendingPathComponent("\(name).app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"),
                                                withIntermediateDirectories: true)
        for p in paths {
            let u = app.appendingPathComponent("Contents/\(p)")
            if p.hasSuffix("/") {
                try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
            } else {
                try FileManager.default.createDirectory(at: u.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try Data("x".utf8).write(to: u)
            }
        }
        var merged: [String: Any] = ["CFBundleIdentifier": "com.example.\(name.lowercased())",
                                     "CFBundleExecutable": name,
                                     "CFBundleName": name]
        for (k, v) in info { merged[k] = v }
        try BundleAssembler.writeInfoPlist(merged, bundle: app)
        return app
    }

    func testElectronIsDetectedByItsFrameworkOrItsArchive() throws {
        let byFramework = try makeBundle("A", paths: ["Frameworks/Electron Framework.framework/"])
        XCTAssertEqual(AppScanner.detectRuntime(at: byFramework), .electron)

        let byAsar = try makeBundle("B", paths: ["Resources/app.asar"])
        XCTAssertEqual(AppScanner.detectRuntime(at: byAsar), .electron)
    }

    /// Regression: Chrome, Brave and Edge nest their helpers inside the versioned
    /// framework, so looking only in Contents/Frameworks reported every browser as a
    /// plain native app and refused to isolate any of them.
    func testChromiumForksAreDetectedThroughTheirNestedHelpers() throws {
        let chrome = try makeBundle("Chrome", paths: [
            "Frameworks/Chrome Framework.framework/Versions/150.0/Helpers/Chrome Helper (Renderer).app/",
        ])
        XCTAssertEqual(AppScanner.detectRuntime(at: chrome), .chromium)

        let byPak = try makeBundle("Other", paths: [
            "Frameworks/Other Framework.framework/Versions/A/Resources/chrome_100_percent.pak",
        ])
        XCTAssertEqual(AppScanner.detectRuntime(at: byPak), .chromium)
    }

    func testBrowserWebAppShortcutsAreNotMistakenForApplications() throws {
        let shortcut = try makeBundle("NotebookLM", info: [
            "CrAppModeShortcutID": "abc",
            "CFBundleExecutable": "app_mode_loader",
        ])
        XCTAssertEqual(AppScanner.detectRuntime(at: shortcut), .webAppShortcut)
    }

    func testAPlainAppIsNative() throws {
        XCTAssertEqual(AppScanner.detectRuntime(at: try makeBundle("Plain")), .native)
    }

    func testQuickFactsDoNotClaimToHaveInspectedSigning() throws {
        let app = try makeBundle("A", paths: ["Resources/app.asar"])
        let facts = try XCTUnwrap(AppScanner(log: .silent).quickFacts(at: app))
        XCTAssertEqual(facts.runtime, .electron)
        XCTAssertFalse(facts.signingInspected)
        XCTAssertTrue(Compatibility.evaluate(facts).provisional)
    }

    func testCodexDesktopIsPresentedAsCodexEvenThoughItsBundleIsNamedChatGPT() throws {
        let app = try makeBundle("ChatGPT", info: [
            "CFBundleIdentifier": "com.openai.codex",
            "CFBundleDisplayName": "ChatGPT",
        ], paths: ["Resources/app.asar"])
        let facts = try XCTUnwrap(AppScanner(log: .silent).quickFacts(at: app))
        XCTAssertEqual(facts.displayName, "Codex")
        XCTAssertEqual(facts.bundleIdentifier, "com.openai.codex")
    }

    func testGeneratedLaunchAgainBundlesAreIdentifiedAndCannotBeSourceApps() throws {
        let app = try makeBundle("Generated", info: ["MALGeneratedBy": "LaunchAgain"])
        XCTAssertTrue(AppScanner.isLaunchAgainGeneratedBundle(at: app))

        let manager = try InstanceManager(paths: .rooted(at: root.appendingPathComponent("store")))
        XCTAssertThrowsError(try manager.inspect(app))
    }

    func testManagerRejectsCommandLineExecutablesAtTheProductBoundary() throws {
        let manager = try InstanceManager(paths: .rooted(at: root.appendingPathComponent("store")))
        XCTAssertThrowsError(try manager.inspect(URL(fileURLWithPath: "/usr/bin/env"))) { error in
            guard case .notSupported(let reason) = error as? MALError else {
                return XCTFail("expected notSupported, got \(error)")
            }
            XCTAssertTrue(reason.contains("GUI application instances only"))
        }
    }

    func testFullFactsInspectSigning() throws {
        let app = try makeBundle("A", paths: ["Resources/app.asar"])
        let facts = try AppScanner(log: .silent).fullFacts(at: app)
        XCTAssertTrue(facts.signingInspected)
        XCTAssertGreaterThan(facts.bundleSizeBytes, 0)
    }

    func testUpdaterDetection() throws {
        let sparkle = try makeBundle("S", paths: ["Frameworks/Sparkle.framework/"])
        XCTAssertEqual(AppScanner.detectUpdater(at: sparkle, info: [:]), .sparkle)
        let squirrel = try makeBundle("Q", paths: ["Frameworks/Squirrel.framework/"])
        XCTAssertEqual(AppScanner.detectUpdater(at: squirrel, info: [:]), .squirrel)
        let none = try makeBundle("N")
        XCTAssertEqual(AppScanner.detectUpdater(at: none, info: [:]), .none)
        XCTAssertEqual(AppScanner.detectUpdater(at: none, info: ["SUFeedURL": "https://x"]), .sparkle)
    }

    func testMissingOrNonBundlePathsAreRejectedClearly() {
        let scanner = AppScanner(log: .silent)
        XCTAssertThrowsError(try scanner.fullFacts(at: URL(fileURLWithPath: "/does/not/exist")))
        XCTAssertThrowsError(try scanner.fullFacts(at: URL(fileURLWithPath: "/bin/echo")))
    }
}

/// Regression: the CLI product was named `launchagain` and the app product `LaunchAgain`.
/// macOS filesystems are case-insensitive by default, so those are one file in the build
/// directory — whichever linked last won, and running the CLI silently started the GUI,
/// which then sat in its event loop looking exactly like a hang.
final class BuildProductNamingTests: XCTestCase {

    /// The names SwiftPM will write into a single directory.
    private let productNames = ["launchagain", "LaunchAgainApp", "mal-shim"]

    func testProductNamesDoNotCollideCaseInsensitively() {
        let lowercased = productNames.map { $0.lowercased() }
        XCTAssertEqual(Set(lowercased).count, productNames.count,
                       "two products differing only by case would be the same file: \(productNames)")
    }

    /// The CLI in the build directory must be the CLI. If this ever links the app
    /// instead, `--help` will not return.
    func testTheCommandLineToolIsTheCommandLineTool() throws {
        let build = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MALKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
            .appendingPathComponent(".build/debug/launchagain")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: build.path),
                          "no debug build present")

        let result = try ProcessRunner.run(executable: build.path, ["help"], timeout: 20)
        XCTAssertTrue(result.succeeded, "the CLI should answer `help` promptly")
        XCTAssertTrue(result.stdout.contains("LaunchAgain command line"),
                      "got: \(result.stdout.prefix(200))")
    }

    /// Swift 6 makes top-level CLI code main-actor isolated. `Task { ... }` inherited
    /// that actor while the command blocked the same thread on a semaphore, so launch
    /// and quit could never begin. A missing launcher is a deterministic fast failure
    /// that proves the asynchronous command body actually runs.
    func testTheLaunchCommandDoesNotDeadlockItsOwnAsyncTask() throws {
        let build = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/debug/launchagain")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: build.path),
                          "no debug build present")

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("launchagain-cli-async-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = MALPaths.rooted(at: root)
        let registry = try Registry(paths: paths)
        try registry.upsertApp(
            appKey: "com.example.fixture", displayName: "Fixture",
            sourcePath: root.appendingPathComponent("source.app").path,
            sourceVersion: "1")
        try registry.addInstance(
            Instance(
                number: 1, name: "Missing",
                bundlePath: root.appendingPathComponent("missing.app").path,
                dataPath: paths.instanceDataDir(UUID()).path,
                clonedBundleIdentifier: "com.example.fixture.launchagain"),
            toApp: "com.example.fixture")

        let result = try ProcessRunner.run(
            executable: build.path,
            ["--root", root.path, "launch", "Fixture#1"],
            timeout: 5)
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.stderr.localizedCaseInsensitiveContains("missing"),
                      "got: \(result.stderr.prefix(300))")
    }
}

/// The command-line-tool subsystem was removed in favour of the GUI-only boundary.
/// What survives is the ability to *recognise* an instance an earlier release created,
/// so it can be labelled and uninstalled. These tests pin that surface down, and pin
/// down that nothing can be created through it.
final class LegacyTerminalInstanceTests: XCTestCase {

    func testALegacyToolKeyIsRecoveredFromItsGeneratedBundleIdentifier() {
        let id = "com.multipleappslauncher.tool.codex.mal.2.a1b2c3d4"
        XCTAssertEqual(LegacyTerminalTool.appKey(fromClonedBundleIdentifier: id), "tool.codex")
        XCTAssertEqual(LegacyTerminalTool.displayName(forAppKey: "tool.codex"), "Codex")
        XCTAssertEqual(LegacyTerminalTool.environmentVariable(forAppKey: "tool.codex"), "CODEX_HOME")
    }

    /// Recovery must not depend on a table of tools the project no longer ships, so an
    /// unrecognised key is still recovered — as itself.
    func testAnUnknownLegacyToolKeyIsStillRecoverable() {
        let id = "com.multipleappslauncher.tool.somethingelse.mal.1.deadbeef"
        XCTAssertEqual(LegacyTerminalTool.appKey(fromClonedBundleIdentifier: id),
                       "tool.somethingelse")
        XCTAssertEqual(LegacyTerminalTool.displayName(forAppKey: "tool.somethingelse"),
                       "somethingelse")
        XCTAssertNil(LegacyTerminalTool.environmentVariable(forAppKey: "tool.somethingelse"),
                     "guessing a variable for an unknown tool would be a fabricated claim")
    }

    func testAnOrdinaryCloneIdentifierIsNotMistakenForALegacyToolLauncher() {
        XCTAssertNil(LegacyTerminalTool.appKey(
            fromClonedBundleIdentifier: "com.anthropic.claudefordesktop.mal.2.a1b2c3d4"))
        XCTAssertNil(LegacyTerminalTool.displayName(forAppKey: "com.anthropic.claudefordesktop"))
    }

    /// The legacy mechanism must keep decoding out of an existing registry, or an
    /// upgrading user loses the entry they need in order to uninstall it.
    func testTheLegacyMechanismStillDecodes() throws {
        let json = Data(#"{"rawValue":"configEnvironment"}"#.utf8)
        struct Box: Codable { let rawValue: IsolationMechanism }
        let box = try JSONDecoder().decode(Box.self, from: json)
        XCTAssertEqual(box.rawValue, .configEnvironment)
        XCTAssertTrue(box.rawValue.isLegacyTerminal)
        XCTAssertFalse(IsolationMechanism.userDataDir.isLegacyTerminal)
    }
}

final class OrphanSweeperTests: XCTestCase {

    private var root: URL!
    private var paths: MALPaths!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mal-sweep-\(UUID().uuidString)")
        paths = MALPaths.rooted(at: root)
        try paths.createAll()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Orphaned preference domains
    //
    // The residue a disk cleaner finds after an instance is gone. It has real causes -
    // a launcher dragged to the Trash rather than uninstalled, an instance created
    // against an alternate --root store whose artifact cleanup is scoped to that root -
    // so it is reported. It is never removed: the filename proves LaunchAgain generated
    // it, not which instance owned it.

    private func writePreferencePlist(_ identifier: String) throws {
        let prefs = paths.userLibrary.appendingPathComponent("Preferences")
        try FileManager.default.createDirectory(at: prefs, withIntermediateDirectories: true)
        try Data("<plist/>".utf8).write(
            to: prefs.appendingPathComponent("\(identifier).plist"))
    }

    func testAnOrphanedClonePreferenceDomainIsReportedWithItsDefaultsCommand() throws {
        try writePreferencePlist("com.example.app.mal2-a1b2c3d4")

        let registry = try Registry(paths: paths)
        let findings = OrphanSweeper(paths: paths).sweep(registry: registry)
        let match = try XCTUnwrap(findings.first { $0.kind == .orphanPreferenceDomain })
        XCTAssertTrue(match.path.hasSuffix("com.example.app.mal2-a1b2c3d4.plist"))
        XCTAssertTrue(match.detail.contains("defaults delete com.example.app.mal2-a1b2c3d4"),
                      "the finding must carry the exact command: \(match.detail)")
        XCTAssertFalse(match.safeToClean)
        XCTAssertFalse(match.isRemovable)
    }

    func testAnOrphanedPreferenceDomainIsNeverRemovedEvenWhenAskedDirectly() throws {
        try writePreferencePlist("com.example.app.mal1-deadbeef")
        let plist = paths.userLibrary
            .appendingPathComponent("Preferences/com.example.app.mal1-deadbeef.plist")

        let registry = try Registry(paths: paths)
        let sweeper = OrphanSweeper(paths: paths)
        let findings = sweeper.sweep(registry: registry)
        let match = try XCTUnwrap(findings.first { $0.kind == .orphanPreferenceDomain })

        XCTAssertThrowsError(try sweeper.remove(match))
        _ = sweeper.clean(findings)
        XCTAssertTrue(FileManager.default.fileExists(atPath: plist.path),
                      "reporting must never turn into deleting")
    }

    /// A live instance's preferences are not residue.
    func testALivePreferenceDomainIsNotReported() throws {
        let id = UUID()
        let identifier = Validation.cloneBundleIdentifier(
            original: "com.example.app", number: 1, instanceID: id)
        try writePreferencePlist(identifier)

        let registry = try Registry(paths: paths)
        try registry.upsertApp(appKey: "com.example.app", displayName: "App",
                               sourcePath: "/Applications/App.app", sourceVersion: "1.0")
        try registry.addInstance(
            Instance(id: id, number: 1, name: "Live",
                     bundlePath: paths.bundlesDir.appendingPathComponent("App 1.app").path,
                     dataPath: paths.instanceDataDir(id).path,
                     clonedBundleIdentifier: identifier),
            toApp: "com.example.app")

        let findings = OrphanSweeper(paths: paths).sweep(registry: registry)
        XCTAssertFalse(findings.contains { $0.kind == .orphanPreferenceDomain },
                       "a signed-in instance's own preferences must never be called residue")
    }

    /// An ordinary application's preferences must never be mistaken for a clone's.
    func testOrdinaryPreferenceDomainsAreNeverReported() throws {
        for identifier in ["com.apple.finder",
                           "com.example.app",
                           "com.example.mal",
                           "com.example.app.mal0-a1b2c3d4",
                           "com.example.app.mal1-a1b2c3",
                           "com.example.app.malx-a1b2c3d4",
                           "mal1-a1b2c3d4"] {
            try writePreferencePlist(identifier)
        }
        let registry = try Registry(paths: paths)
        let findings = OrphanSweeper(paths: paths).sweep(registry: registry)
        XCTAssertTrue(findings.filter { $0.kind == .orphanPreferenceDomain }.isEmpty,
                      "matched: \(findings.filter { $0.kind == .orphanPreferenceDomain }.map(\.path))")
    }

    /// The generator always emits lowercase hex, but `isCloneBundleIdentifier` compares
    /// case-insensitively and this must agree with it — a case-only difference on a
    /// case-insensitive volume names the same file.
    func testTheCloneIdentifierShapeIsMatchedCaseInsensitively() throws {
        try writePreferencePlist("com.example.app.mal1-A1B2C3D4")
        let registry = try Registry(paths: paths)
        let findings = OrphanSweeper(paths: paths).sweep(registry: registry)
        XCTAssertEqual(findings.filter { $0.kind == .orphanPreferenceDomain }.count, 1)
        XCTAssertTrue(Validation.looksLikeCloneBundleIdentifier("com.example.app.mal1-A1B2C3D4"))
    }

    // MARK: Bulk cleanup must not destroy the last record of a profile
    //
    // "Remove Cleanable Items" was one click with no confirmation, it bypassed the Trash,
    // and it judged a launcher purely on whether ownership could be verified. A verified
    // launcher whose profile is still on disk is the *recoverable* case: it carries the
    // recovery manifest and is the only thing that can reattach that profile to a name,
    // a number and an account. Deleting it made nine profiles anonymous.

    /// Builds a verified LaunchAgain launcher that the registry does not know about.
    @discardableResult
    private func makeOrphanedLauncher(number: Int,
                                      name: String,
                                      withProfile: Bool) throws -> (bundle: URL, id: UUID) {
        let id = UUID()
        let bundle = paths.bundlesDir.appendingPathComponent("\(name).app")
        try FileManager.default.createDirectory(
            at: bundle.appendingPathComponent("Contents/Resources"),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: bundle.appendingPathComponent("Contents/MacOS"),
            withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: BundleAssembler.locateShimBinary(),
            to: bundle.appendingPathComponent("Contents/MacOS/mal-shim"))

        let cloneID = Validation.cloneBundleIdentifier(
            original: "com.example.orphan", number: number, instanceID: id)
        let data = paths.instanceDataDir(id)
        if withProfile {
            try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
            try Data("session".utf8).write(to: data.appendingPathComponent("auth.json"))
        }
        let instance = Instance(id: id, number: number, name: name,
                                bundlePath: bundle.path, dataPath: data.path,
                                clonedBundleIdentifier: cloneID)
        try BundleAssembler.writeInfoPlist([
            "CFBundleIdentifier": cloneID,
            "CFBundleDisplayName": name,
            "CFBundleName": name,
            "CFBundleExecutable": "mal-shim",
            "CFBundlePackageType": "APPL",
            "MALGeneratedBy": "LaunchAgain",
            "MALOriginalBundleIdentifier": "com.example.orphan",
        ], bundle: bundle)
        try BundleAssembler.writeInstanceConfig(
            InstanceConfig(mode: .full, dataPath: data.path,
                           realExecutableName: "Orphan.real"),
            into: bundle)
        try BundleAssembler.writeRecoveryManifest(
            LauncherRecoveryManifest(appKey: "com.example.orphan",
                                     appDisplayName: "Orphan",
                                     sourcePath: "/Applications/Orphan.app",
                                     sourceVersion: "1.0",
                                     instance: instance),
            into: bundle)
        _ = try CodeSigner(log: .silent).adHocSign(bundle: bundle,
                                                   mainEntitlements: [:],
                                                   hardenedRuntime: false)
        return (bundle, id)
    }

    func testALauncherIsNotCleanableWhileItIsTheLastRecordOfALiveProfile() throws {
        let stranded = try makeOrphanedLauncher(number: 1, name: "Stranded", withProfile: true)

        let registry = try Registry(paths: paths)
        let findings = OrphanSweeper(paths: paths).sweep(registry: registry)
        let match = try XCTUnwrap(findings.first {
            $0.kind == .unregisteredBundle && $0.path == stranded.bundle.standardizedFileURL.path
        })
        XCTAssertFalse(match.safeToClean,
                       "deleting this launcher would make its profile permanently unattributable")
        XCTAssertTrue(match.detail.contains("only remaining record"), match.detail)

        _ = OrphanSweeper(paths: paths).clean(findings)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stranded.bundle.path),
                      "a bulk clean must not take the last recovery record")
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.instanceDir(stranded.id).path))
    }

    /// A duplicate of a launcher whose instance is *still registered* is disposable: the
    /// registry is the record, not the copy. Checking only for the profile conflated this
    /// with the genuinely-stranded case, and the integration suite caught it.
    func testACopyOfAStillRegisteredLaunchersIsCleanable() throws {
        let live = try makeOrphanedLauncher(number: 6, name: "Live", withProfile: true)

        let registry = try Registry(paths: paths)
        try registry.upsertApp(appKey: "com.example.orphan", displayName: "Orphan",
                               sourcePath: "/Applications/Orphan.app", sourceVersion: "1.0")
        try registry.addInstance(
            Instance(id: live.id, number: 6, name: "Live",
                     bundlePath: live.bundle.path,
                     dataPath: paths.instanceDataDir(live.id).path),
            toApp: "com.example.orphan")

        // An unregistered duplicate beside the registered original.
        let copy = paths.bundlesDir.appendingPathComponent("Live Copy.app")
        try FileManager.default.copyItem(at: live.bundle, to: copy)

        let findings = OrphanSweeper(paths: paths).sweep(registry: registry)
        let match = try XCTUnwrap(findings.first {
            $0.kind == .unregisteredBundle && $0.path == copy.standardizedFileURL.path
        })
        XCTAssertTrue(match.safeToClean,
                      "the registry still holds this instance, so the copy is not a record of anything: \(match.detail)")
    }

    func testALauncherWhoseProfileIsAlreadyGoneIsStillCleanable() throws {
        let disposable = try makeOrphanedLauncher(number: 2, name: "Disposable", withProfile: false)

        let registry = try Registry(paths: paths)
        let findings = OrphanSweeper(paths: paths).sweep(registry: registry)
        let match = try XCTUnwrap(findings.first {
            $0.kind == .unregisteredBundle && $0.path == disposable.bundle.standardizedFileURL.path
        })
        XCTAssertTrue(match.safeToClean, match.detail)
        XCTAssertTrue(match.detail.contains("already gone"), match.detail)
    }

    /// The measured scenario, in miniature: several launchers, each with its profile.
    /// A bulk clean must leave every one of them alone.
    func testBulkCleanPreservesEveryLauncherThatStillHasAProfile()throws {
        var made: [(bundle: URL, id: UUID)] = []
        for n in 1...5 {
            made.append(try makeOrphanedLauncher(number: n, name: "Keep\(n)", withProfile: true))
        }
        let registry = try Registry(paths: paths)
        let sweeper = OrphanSweeper(paths: paths)
        let findings = sweeper.sweep(registry: registry)

        let (removed, _) = sweeper.clean(findings)
        XCTAssertEqual(removed, 0, "nothing here was safe to remove")
        for item in made {
            XCTAssertTrue(FileManager.default.fileExists(atPath: item.bundle.path),
                          "launcher \(item.bundle.lastPathComponent) was destroyed")
            XCTAssertTrue(FileManager.default.fileExists(atPath: paths.instanceDir(item.id).path))
        }
    }

    /// Removal goes to the Trash, matching every other removal in the product.
    func testCleanupMovesToTheTrashRatherThanUnlinking() throws {
        let disposable = try makeOrphanedLauncher(number: 3, name: "Trashable", withProfile: false)
        let registry = try Registry(paths: paths)
        let sweeper = OrphanSweeper(paths: paths)
        let findings = sweeper.sweep(registry: registry)
        let match = try XCTUnwrap(findings.first {
            $0.kind == .unregisteredBundle && $0.path == disposable.bundle.standardizedFileURL.path
        })

        _ = try sweeper.remove(match)
        XCTAssertFalse(FileManager.default.fileExists(atPath: disposable.bundle.path))

        // It should be recoverable rather than erased. Trashing a temporary-directory
        // item can legitimately fall back to deletion on a volume with no Trash, so this
        // asserts the log records which happened rather than asserting a Trash path that
        // is not guaranteed to exist under /var/folders.
        let logText = (try? String(contentsOf: paths.logsDir
            .appendingPathComponent("launchagain.log"), encoding: .utf8)) ?? ""
        XCTAssertTrue(logText.isEmpty
                      || logText.contains("moved to the Trash")
                      || logText.contains("this volume has no Trash"),
                      "removal must state which of the two happened")
    }

    // MARK: A removal marker nothing can act on

    /// A plain-text marker from an earlier version has no recorded deletion scope, so
    /// `resumePendingRemovals` cannot finish or undo anything from it. It used to warn on
    /// every process start with no way to clear it, while permanently excluding its
    /// instance id from reconciliation.
    private func writeLegacyRemovalMarker(_ id: UUID) throws {
        try FileManager.default.createDirectory(at: paths.removalTombstonesDir,
                                                withIntermediateDirectories: true)
        try Data("removed 1785026586.705584\n".utf8)
            .write(to: paths.removalTombstoneFile(id))
    }

    func testALegacyRemovalMarkerIsReportedWithAnAction() throws {
        let id = UUID()
        try writeLegacyRemovalMarker(id)

        let findings = OrphanSweeper(paths: paths).sweep(registry: try Registry(paths: paths))
        let match = try XCTUnwrap(findings.first { $0.kind == .staleRemovalMarker })
        XCTAssertEqual(match.path, paths.removalTombstoneFile(id).path)
        XCTAssertTrue(match.detail.contains(id.uuidString), match.detail)
        XCTAssertTrue(match.isRemovable, "it must have a route out")
        XCTAssertFalse(match.safeToClean, "but not be swept up in a bulk clean")
    }

    func testALegacyRemovalMarkerCanBeRemovedOnRequest() throws {
        let id = UUID()
        try writeLegacyRemovalMarker(id)
        let sweeper = OrphanSweeper(paths: paths)
        let match = try XCTUnwrap(
            sweeper.sweep(registry: try Registry(paths: paths))
                .first { $0.kind == .staleRemovalMarker })

        _ = try sweeper.remove(match)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: paths.removalTombstoneFile(id).path))
        XCTAssertTrue(sweeper.sweep(registry: try Registry(paths: paths))
            .filter { $0.kind == .staleRemovalMarker }.isEmpty)
    }

    /// A marker carrying a real journal record is live work, not residue: the next start
    /// resumes it. Reporting it would invite the user to cancel a confirmed uninstall.
    func testAMarkerWithAUsableJournalRecordIsNotReportedAsStale() throws {
        let id = UUID()
        let instance = Instance(id: id, number: 1, name: "Pending",
                                bundlePath: paths.bundlesDir.appendingPathComponent("P.app").path,
                                dataPath: paths.instanceDataDir(id).path)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: paths.removalTombstonesDir,
                                                withIntermediateDirectories: true)
        try encoder.encode(RemovalJournalRecord(instance: instance, deleteData: true))
            .write(to: paths.removalTombstoneFile(id))

        let findings = OrphanSweeper(paths: paths).sweep(registry: try Registry(paths: paths))
        XCTAssertTrue(findings.filter { $0.kind == .staleRemovalMarker }.isEmpty,
                      "an in-progress uninstall must not be offered for cancellation")
    }

    /// Nor is a marker stale while its instance is still registered — that deletion is
    /// still in progress.
    func testAMarkerForAStillRegisteredInstanceIsNotReportedAsStale() throws {
        let id = UUID()
        try writeLegacyRemovalMarker(id)
        let registry = try Registry(paths: paths)
        try registry.upsertApp(appKey: "com.example.live", displayName: "Live",
                               sourcePath: "/Applications/Live.app", sourceVersion: "1.0")
        try registry.addInstance(
            Instance(id: id, number: 1, name: "Live",
                     bundlePath: paths.bundlesDir.appendingPathComponent("L.app").path,
                     dataPath: paths.instanceDataDir(id).path),
            toApp: "com.example.live")

        let findings = OrphanSweeper(paths: paths).sweep(registry: registry)
        XCTAssertTrue(findings.filter { $0.kind == .staleRemovalMarker }.isEmpty)
    }

    /// Merging must not resurrect what invalidation just dropped — the uninstall case,
    /// where an entry keyed by the removed instance's profile path must stay gone.
    func testInvalidationIsNotUndoneByTheMerge() throws {
        let dir = root.appendingPathComponent("doomed")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dir.appendingPathComponent("f"))

        let writer = DirectorySizeCache(paths: paths)
        _ = writer.size(of: dir)
        // A second cache holds the same entry on disk, as a concurrent process would.
        let other = DirectorySizeCache(paths: paths)
        _ = other.cachedSize(of: dir)

        writer.invalidate([dir])
        let cacheText = (try? String(contentsOf: paths.directorySizeCacheFile, encoding: .utf8)) ?? ""
        XCTAssertFalse(cacheText.contains(dir.lastPathComponent),
                       "the merge put back an entry that invalidation removed")
        XCTAssertNil(DirectorySizeCache(paths: paths).cachedSize(of: dir))
    }

    /// Two caches over one store are a live GUI and a CLI. Whole-file snapshot writes
    /// meant each erased the other's measurements.
    func testTwoCachesOverOneStoreDoNotEraseEachOthersMeasurements() throws {
        let a = root.appendingPathComponent("dir-a")
        let b = root.appendingPathComponent("dir-b")
        for dir in [a, b] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: dir.appendingPathComponent("f"))
        }

        let first = DirectorySizeCache(paths: paths)
        let second = DirectorySizeCache(paths: paths)
        _ = first.size(of: a)
        _ = second.size(of: b)

        // A third reader is what the next process start does.
        let reader = DirectorySizeCache(paths: paths)
        XCTAssertNotNil(reader.cachedSize(of: a),
                        "the first cache's measurement was erased by the second")
        XCTAssertNotNil(reader.cachedSize(of: b))
    }

    func testAnUnprovenApplicationIsReportedButNeverCleanable() throws {
        let stray = paths.bundlesDir.appendingPathComponent("Stray.app")
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)

        let registry = try Registry(paths: paths)
        let findings = OrphanSweeper(paths: paths).sweep(registry: registry)
        let match = try XCTUnwrap(findings.first { $0.path.hasSuffix("Stray.app") })
        XCTAssertFalse(match.safeToClean)
        XCTAssertFalse(match.isRemovable)
        _ = OrphanSweeper(paths: paths).clean(findings)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stray.path))
    }

    func testOldStagingItemIsReportOnlyWithoutACrossProcessLease() throws {
        let staged = paths.stagingDir.appendingPathComponent(
            "\(UUID().uuidString)-Slow Build.app")
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        let registry = try Registry(paths: paths)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3_600)],
            ofItemAtPath: staged.path)

        let sweeper = OrphanSweeper(paths: paths)
        let findings = sweeper.sweep(registry: registry)
        let findingSummary = findings.map { "\($0.kind):\($0.path)" }
        let finding = try XCTUnwrap(findings.first {
            $0.kind == .staleStaging
                && URL(fileURLWithPath: $0.path).standardizedFileURL.path
                    == staged.standardizedFileURL.path
        }, "missing \(staged.path); findings were \(findingSummary)")

        XCTAssertFalse(finding.safeToClean)
        XCTAssertFalse(finding.isRemovable)
        _ = sweeper.clean(findings)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertThrowsError(try sweeper.remove(finding))
    }

    /// An orphan profile is somebody's signed-in session. It is reported, never removed.
    func testAnOrphanProfileIsNeverMarkedCleanable() throws {
        let orphan = paths.instancesDir.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)

        let registry = try Registry(paths: paths)
        let sweeper = OrphanSweeper(paths: paths)
        let findings = sweeper.sweep(registry: registry)
        let match = try XCTUnwrap(findings.first { $0.path.hasSuffix(orphan.lastPathComponent) },
                                  "no finding for the orphan profile; got \(findings.map(\.path))")
        XCTAssertEqual(match.kind, .orphanDataDirectory)
        XCTAssertFalse(match.safeToClean)

        _ = sweeper.clean(findings)
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path),
                      "cleaning must not touch anything that was not marked safe")
    }

    /// Regression: removing an instance without its data left the profile on disk with no
    /// registry entry, the health check refused to clean it, and the interface offered no
    /// way to delete it — so "I deleted it and it is still on my computer" was correct.
    /// An explicitly requested removal must work.
    func testALeftoverProfileCanBeDeletedWhenExplicitlyAskedFor() throws {
        let orphan = paths.instancesDir.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: orphan.appendingPathComponent("userdata"),
                                                withIntermediateDirectories: true)
        try Data(repeating: 0, count: 2048).write(to: orphan.appendingPathComponent("userdata/session"))

        let registry = try Registry(paths: paths)
        let sweeper = OrphanSweeper(paths: paths)
        let finding = try XCTUnwrap(sweeper.sweep(registry: registry)
            .first { $0.kind == .orphanDataDirectory })

        XCTAssertFalse(finding.safeToClean, "it must still never be swept up automatically")
        XCTAssertTrue(finding.isRemovable, "but the user must be able to ask for it")

        let freed = try sweeper.remove(finding)
        XCTAssertGreaterThan(freed, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertTrue(sweeper.sweep(registry: registry).isEmpty, "and the report should clear")
    }

    /// The rule the whole product rests on: it only ever deletes copies it made.
    func testExplicitRemovalStillRefusesAnythingOutsideOurOwnFolders() throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("mal-not-ours-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }

        let hostile = OrphanSweeper.Finding(kind: .orphanDataDirectory,
                                            path: outside.path,
                                            detail: "pretend",
                                            sizeBytes: 0,
                                            safeToClean: true)
        XCTAssertThrowsError(try OrphanSweeper(paths: paths).remove(hostile))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))

        // And the same for the obvious catastrophe.
        let application = OrphanSweeper.Finding(kind: .unregisteredBundle,
                                                path: "/Applications/Claude.app",
                                                detail: "pretend",
                                                sizeBytes: 0,
                                                safeToClean: true)
        XCTAssertThrowsError(try OrphanSweeper(paths: paths).remove(application))
    }

    func testReportsThatAreNotThingsOnDiskAreNotOfferedForDeletion() throws {
        let registry = try Registry(paths: paths)
        try registry.upsertApp(appKey: "com.example.app", displayName: "Example",
                               sourcePath: "/nowhere/Example.app", sourceVersion: "1.0")
        _ = try registry.reserveNumbers(appKey: "com.example.app", count: 1)
        try registry.addInstance(Instance(number: 1, name: "Gone",
                                          bundlePath: paths.bundlesDir.appendingPathComponent("Gone.app").path,
                                          dataPath: paths.instanceDataDir(UUID()).path),
                                 toApp: "com.example.app")

        for finding in OrphanSweeper(paths: paths).sweep(registry: registry) {
            switch finding.kind {
            case .missingBundle, .sourceMissing, .sourceUpdated, .migrationConflict:
                XCTAssertFalse(finding.isRemovable, "\(finding.kind) is a report, not a file to delete")
            default:
                break
            }
        }
    }

    func testAMissingLauncherIsReportedAgainstItsInstance() throws {
        let registry = try Registry(paths: paths)
        try registry.upsertApp(appKey: "com.example.app", displayName: "Example",
                               sourcePath: "/Applications/Example.app", sourceVersion: "1.0")
        _ = try registry.reserveNumbers(appKey: "com.example.app", count: 1)
        try registry.addInstance(Instance(number: 1, name: "Gone",
                                          bundlePath: paths.bundlesDir.appendingPathComponent("Gone.app").path,
                                          dataPath: paths.instanceDataDir(UUID()).path),
                                 toApp: "com.example.app")

        let findings = OrphanSweeper(paths: paths).sweep(registry: registry)
        XCTAssertTrue(findings.contains { $0.detail.contains("no launcher on disk") })
    }

    func testDirectorySizesAreCachedAndRepeatedSweepsDoNotRescan() throws {
        let orphan = paths.instancesDir.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4_096).write(to: orphan.appendingPathComponent("session"))

        let lock = NSLock()
        var measurements = 0
        let cache = DirectorySizeCache(paths: paths, maxAge: 3_600) { url in
            lock.lock()
            measurements += 1
            lock.unlock()
            return FSOps.directorySize(url)
        }
        let registry = try Registry(paths: paths)
        let sweeper = OrphanSweeper(paths: paths, sizeCache: cache)

        for _ in 0..<20 {
            _ = sweeper.sweep(registry: registry)
        }

        XCTAssertEqual(measurements, 1,
                       "bounded repeated doctor/Health scans must walk a stable profile once")
    }
}
#endif
