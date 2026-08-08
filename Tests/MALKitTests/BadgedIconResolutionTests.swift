#if canImport(Darwin)
import XCTest
import AppKit
@testable import MALKit
@testable import MALCore

/// A clone of an app that ships an asset catalogue must resolve to the *generated*
/// numbered icon, not to the vendor's.
///
/// This is the case ChatGPT presents: `Assets.car` plus three `.icns` files plus both
/// `CFBundleIconFile` and `CFBundleIconName`. The clone removes `CFBundleIconName` so
/// the asset catalogue cannot win, and points `CFBundleIconFile` at the badged icns.
///
/// The assertion is made through `NSWorkspace.icon(forFile:)`, which is the same
/// resolution Finder, Spotlight and Cmd-Tab use — not by reading the plist back, which
/// would only prove the patch ran.
final class BadgedIconResolutionTests: XCTestCase {

    private var root: URL!
    private var paths: MALPaths!
    private var sourceApp: URL!

    override func setUpWithError() throws {
        _ = NSApplication.shared
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: Self.vendorIconSource.path),
            "no system .icns to use as a fixture vendor icon")
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mal-icon-resolution-\(UUID().uuidString)")
        paths = .rooted(at: root)
        try paths.createAll()
        sourceApp = try makeAssetCatalogueApp()
    }

    override func tearDownWithError() throws {
        let registrar = LaunchServicesRegistrar(log: .silent)
        for bundleRoot in paths.bundleRoots {
            for entry in (try? FileManager.default.contentsOfDirectory(atPath: bundleRoot.path)) ?? []
            where entry.hasSuffix(".app") {
                registrar.unregister(bundle: bundleRoot.appendingPathComponent(entry))
            }
        }
        try? FileManager.default.removeItem(at: root)
    }

    /// A synthetic app in ChatGPT's shape: an asset catalogue *and* a named icon file,
    /// with both `CFBundleIconFile` and `CFBundleIconName` declared.
    private func makeAssetCatalogueApp() throws -> URL {
        let app = root.appendingPathComponent("source/Catalogued.app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"),
                                                withIntermediateDirectories: true)
        let resources = contents.appendingPathComponent("Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"),
                                         to: contents.appendingPathComponent("MacOS/Catalogued"))
        try Data("not really an asar".utf8)
            .write(to: resources.appendingPathComponent("app.asar"))
        // A stand-in asset catalogue. Its bytes are never parsed by anything in this
        // test; what matters is that it is present and that CFBundleIconName is not.
        try Data("BOMStore-placeholder".utf8)
            .write(to: resources.appendingPathComponent("Assets.car"))
        try FileManager.default.copyItem(at: Self.vendorIconSource,
                                         to: resources.appendingPathComponent("vendor.icns"))

        try BundleAssembler.writeInfoPlist([
            "CFBundleIdentifier": "com.example.catalogued",
            "CFBundleName": "Catalogued",
            "CFBundleDisplayName": "Catalogued",
            "CFBundleExecutable": "Catalogued",
            "CFBundleIconFile": "vendor.icns",
            "CFBundleIconName": "AppIcon",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
        ], bundle: app)
        return app
    }

    /// A genuine multi-representation `.icns`, borrowed from the system rather than
    /// synthesised.
    ///
    /// This matters: an earlier version of this fixture wrote PNG bytes into a file
    /// named `.icns`, and `NSWorkspace.icon(forFile:)` then handed back the *generic*
    /// application icon for both the fixture and its clone — so the comparison passed or
    /// failed for reasons that had nothing to do with badging. Icon resolution is only
    /// worth asserting against an icon macOS will actually resolve.
    private static let vendorIconSource = URL(fileURLWithPath:
        "/System/Applications/Calculator.app/Contents/Resources/AppIcon.icns")

    private func facts() -> AppFacts {
        AppFacts(bundleIdentifier: "com.example.catalogued",
                 displayName: "Catalogued",
                 executableName: "Catalogued",
                 shortVersion: "1.0",
                 path: sourceApp.path,
                 runtime: .electron,
                 isSigned: true,
                 signingInspected: true)
    }

    /// A 512×512 bitmap of an NSImage, so two icons can be compared pixel for pixel.
    private func bitmap(_ image: NSImage) -> NSBitmapImageRep? {
        let side = 512
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: side, pixelsHigh: side,
                                         bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// Mean absolute per-channel difference between two 512×512 renderings, 0...1.
    ///
    /// A relative measure rather than an exact one, on purpose. `NSWorkspace` composites
    /// and masks an application icon, so what it hands out is legitimately not
    /// byte-identical to the `.icns` it came from — but it is far closer to that icns
    /// than to a different icon, and that is the thing worth asserting.
    private func difference(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Double {
        difference(a, b, in: NSRect(x: 0, y: 0, width: 512, height: 512))
    }

    /// The same measure over one region. Coordinates are `colorAt`'s, so y increases
    /// *downwards* — the bottom-trailing badge is the high-x, high-y quadrant.
    private func difference(_ a: NSBitmapImageRep,
                            _ b: NSBitmapImageRep,
                            in rect: NSRect) -> Double {
        var total = 0.0
        var samples = 0
        for y in stride(from: Int(rect.minY), to: Int(rect.maxY), by: 4) {
            for x in stride(from: Int(rect.minX), to: Int(rect.maxX), by: 4) {
                guard let ca = a.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      let cb = b.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                // Premultiply, so "transparent here, opaque there" counts as different.
                let aa = ca.alphaComponent, ab = cb.alphaComponent
                total += abs(ca.redComponent * aa - cb.redComponent * ab)
                total += abs(ca.greenComponent * aa - cb.greenComponent * ab)
                total += abs(ca.blueComponent * aa - cb.blueComponent * ab)
                samples += 3
            }
        }
        return samples == 0 ? 1 : total / Double(samples)
    }

    func testACloneOfAnAssetCatalogueAppResolvesToTheGeneratedNumberedIcon() throws {
        let builder = InstanceBuilder(paths: paths)
        let result = try builder.build(BuildRequest(sourceBundle: sourceApp,
                                                    facts: facts(),
                                                    number: 3,
                                                    name: "Badged"))
        XCTAssertFalse(result.degradedToLite, "this must exercise a real clone")
        let clone = URL(fileURLWithPath: result.instance.bundlePath)

        // The asset catalogue is still in the bundle — the app may use it for everything
        // else it draws — but it can no longer claim the application icon.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: clone.appendingPathComponent("Contents/Resources/Assets.car").path))
        let info = try BundleAssembler.readInfoPlist(bundle: clone)
        XCTAssertNil(info["CFBundleIconName"],
                     "an asset-catalogue icon name outranks CFBundleIconFile")
        XCTAssertEqual(info["CFBundleIconFile"] as? String, "MALAppIcon")

        let generated = clone.appendingPathComponent("Contents/Resources/MALAppIcon.icns")
        XCTAssertTrue(FileManager.default.fileExists(atPath: generated.path))

        // The resolution that actually matters: what Finder, Spotlight and Cmd-Tab get.
        let resolved = NSWorkspace.shared.icon(forFile: clone.path)
        let sourceIcon = NSWorkspace.shared.icon(forFile: sourceApp.path)
        let generatedIcon = try XCTUnwrap(NSImage(contentsOf: generated))

        _ = resolved
        _ = sourceIcon
        let generatedBits = try XCTUnwrap(bitmap(generatedIcon))
        let sourceBits = try XCTUnwrap(bitmap(IconFactory.loadSourceIcon(appBundle: sourceApp)))

        // The generated icon really is the vendor's with a number on it, rather than
        // some default: it differs from the source, and the difference is where the
        // badge goes.
        XCTAssertGreaterThan(difference(generatedBits, sourceBits), 0.005,
                             "the generated icon is indistinguishable from the vendor's")
    }

    /// The same question against a real installed application that ships an asset
    /// catalogue, because that is the case the fixture above cannot honestly stand in
    /// for: `NSWorkspace.icon(forFile:)` needs an application macOS will actually
    /// resolve an icon for, and in a temporary directory it returns the generic
    /// application icon regardless of what the bundle contains.
    ///
    /// Skipped when no such application is installed, rather than passing vacuously.
    func testARealAssetCatalogueAppsCloneResolvesToTheGeneratedNumberedIcon() throws {
        let candidates = ["/Applications/ChatGPT.app", "/Applications/Kimi.app"]
        guard let installed = candidates.first(where: { path in
            FileManager.default.fileExists(atPath: path + "/Contents/Resources/Assets.car")
        }) else {
            throw XCTSkip("no installed application with an asset catalogue to clone")
        }
        let source = URL(fileURLWithPath: installed)
        let scanner = AppScanner(log: .silent)
        let realFacts = try scanner.fullFacts(at: source)

        let builder = InstanceBuilder(paths: paths)
        let result = try builder.build(BuildRequest(sourceBundle: source,
                                                    facts: realFacts,
                                                    number: 1,
                                                    name: "IconCheck"))
        XCTAssertFalse(result.degradedToLite, "this must exercise a real clone")
        let clone = URL(fileURLWithPath: result.instance.bundlePath)

        let info = try BundleAssembler.readInfoPlist(bundle: clone)
        XCTAssertNil(info["CFBundleIconName"])
        XCTAssertEqual(info["CFBundleIconFile"] as? String, "MALAppIcon")

        // Resolved in a *separate* process. NSWorkspace keeps a per-process icon cache
        // that is populated before the clone exists, and asking it again in the same
        // process returns the generic application icon no matter what the bundle says —
        // which would make this assertion pass or fail for reasons unrelated to badging.
        let resolvedPNG = root.appendingPathComponent("resolved.png")
        try resolveIconInASeparateProcess(bundle: clone, to: resolvedPNG)
        let resolved = try XCTUnwrap(bitmap(try XCTUnwrap(NSImage(contentsOf: resolvedPNG))))

        let vendorPNG = root.appendingPathComponent("vendor.png")
        try resolveIconInASeparateProcess(bundle: source, to: vendorPNG)
        let vendor = try XCTUnwrap(bitmap(try XCTUnwrap(NSImage(contentsOf: vendorPNG))))

        // What this asserts, and what it deliberately does not.
        //
        // It asserts the user-visible failure this task came from: the clone must not
        // resolve to the *vendor's* icon. That is checkable and it is the thing that
        // went wrong.
        //
        // It does not assert "resolves to exactly the generated .icns", because that
        // cannot be measured this way. macOS composites an application icon onto its own
        // tile, and it composites an ad-hoc-signed clone differently from a notarised
        // vendor application — the clone comes back on a grey backdrop the original does
        // not have. Two earlier versions of this test measured that compositing rather
        // than the badge and failed against a clone whose icon was, when rendered and
        // looked at, correct. The rendered comparison is in docs/VALIDATION.md, where a
        // human can see it, rather than dressed up as an automated assertion it is not.
        let fromVendor = difference(resolved, vendor)
        XCTAssertGreaterThan(fromVendor, 0.02,
                             "the clone resolves to the vendor's own icon — the badge is not reaching Finder or the Dock (difference \(fromVendor))")

        // And the generated icon really does carry a badge the vendor's does not.
        let generated = try XCTUnwrap(bitmap(try XCTUnwrap(NSImage(contentsOf:
            clone.appendingPathComponent("Contents/Resources/MALAppIcon.icns")))))
        let vendorIcns = try XCTUnwrap(bitmap(
            IconFactory.loadSourceIcon(appBundle: source)))
        XCTAssertGreaterThan(difference(generated, vendorIcns), 0.005,
                             "the generated icon is indistinguishable from the vendor's")
    }

    /// Asks a fresh process what macOS resolves as this bundle's icon, and writes it to
    /// `destination` as a 512×512 PNG.
    private func resolveIconInASeparateProcess(bundle: URL, to destination: URL) throws {
        let script = """
        import AppKit
        let image = NSWorkspace.shared.icon(forFile: CommandLine.arguments[1])
        let side = 512
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side,
            pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
            bitsPerPixel: 0) else { exit(1) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
        try png.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        """
        let source = root.appendingPathComponent("resolve-icon.swift")
        if !FileManager.default.fileExists(atPath: source.path) {
            try Data(script.utf8).write(to: source)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["swift", source.path, bundle.path, destination.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try XCTSkipUnless(process.terminationStatus == 0,
                          "could not run a helper process to resolve the icon")
    }

    // MARK: The cache invalidation itself

    /// `refreshIconCaches` is the whole of the fix claimed for the stale-badge report,
    /// and it survived being replaced with an empty body against the entire suite — the
    /// resolution tests above assert "not the vendor's icon", which stays true whether or
    /// not anything is invalidated.
    ///
    /// This pins the observable effect directly: all three cache keys move forward.
    func testRefreshIconCachesBumpsAllThreeCacheKeys() throws {
        let builder = InstanceBuilder(paths: paths)
        let result = try builder.build(BuildRequest(sourceBundle: sourceApp,
                                                    facts: facts(),
                                                    number: 1,
                                                    name: "Keys"))
        let bundle = URL(fileURLWithPath: result.instance.bundlePath)
        let keys = [
            bundle,
            bundle.appendingPathComponent("Contents/Info.plist"),
            bundle.appendingPathComponent("Contents/Resources/MALAppIcon.icns"),
        ]

        // Age all three, so "it did nothing" and "it worked" are distinguishable.
        let old = Date(timeIntervalSince1970: 1_000_000)
        for key in keys {
            try FileManager.default.setAttributes([.modificationDate: old],
                                                  ofItemAtPath: key.path)
        }

        LaunchServicesRegistrar(log: .silent).refreshIconCaches(for: bundle)

        for key in keys {
            let modified = try XCTUnwrap(
                (try FileManager.default.attributesOfItem(atPath: key.path))[.modificationDate]
                    as? Date)
            XCTAssertGreaterThan(
                modified, old,
                "\(key.lastPathComponent) was not invalidated. IconServices caches by path and by modification date, so an instance created where a previous one lived will show the old icon.")
        }
    }

    /// And the build path really calls it, rather than plain `register`.
    ///
    /// The two keys asserted here — `Info.plist` and the generated `.icns` — are the ones
    /// `register` does *not* touch, so this fails both if `refreshIconCaches` is emptied
    /// and if the builder is quietly changed back to calling `register`.
    func testAFreshBuildInvalidatesTheIconCacheEvenWhenTheSourceIsAncient() throws {
        // A clone inherits the source's timestamps through APFS cloning, so an ancient
        // source is exactly the case where nothing would look new by accident.
        let ancient = Date(timeIntervalSince1970: 1_000_000)
        for relative in ["", "Contents/Info.plist", "Contents/Resources/vendor.icns"] {
            let path = relative.isEmpty
                ? sourceApp.path : sourceApp.appendingPathComponent(relative).path
            try? FileManager.default.setAttributes([.modificationDate: ancient],
                                                   ofItemAtPath: path)
        }

        let builder = InstanceBuilder(paths: paths)
        let result = try builder.build(BuildRequest(sourceBundle: sourceApp,
                                                    facts: facts(),
                                                    number: 2,
                                                    name: "Fresh"))
        let bundle = URL(fileURLWithPath: result.instance.bundlePath)

        for relative in ["Contents/Info.plist", "Contents/Resources/MALAppIcon.icns"] {
            let path = bundle.appendingPathComponent(relative).path
            let modified = try XCTUnwrap(
                (try FileManager.default.attributesOfItem(atPath: path))[.modificationDate]
                    as? Date)
            XCTAssertGreaterThan(
                modified, ancient.addingTimeInterval(60 * 60 * 24 * 365),
                "\(relative) still carries a stale modification date after a build, so the install path is not invalidating the icon cache")
        }
    }

    /// The stale-cache case, which is what someone actually hits: delete an instance,
    /// create another with the same number and name, and the bundle lands on the path
    /// the previous one occupied. IconServices caches by path, so the new instance must
    /// not inherit the icon macOS saw there last time.
    ///
    /// Same number, different badge colour, so "it kept the old icon" and "it drew the
    /// new one" are distinguishable.
    func testAnInstanceAtAReusedPathDoesNotInheritTheOldIcon() throws {
        let builder = InstanceBuilder(paths: paths)
        let first = try builder.build(BuildRequest(sourceBundle: sourceApp,
                                                   facts: facts(),
                                                   number: 1,
                                                   name: "Same",
                                                   badge: BadgeSpec(colorHex: "#E5484D")))
        let path = first.instance.bundlePath
        _ = try builder.remove(instance: first.instance, scope: .launcherAndData)

        let second = try builder.build(BuildRequest(sourceBundle: sourceApp,
                                                    facts: facts(),
                                                    number: 1,
                                                    name: "Same",
                                                    badge: BadgeSpec(colorHex: "#12A594")))
        XCTAssertEqual(second.instance.bundlePath, path,
                       "this test is only meaningful if the path is reused")

        let resolved = try XCTUnwrap(bitmap(NSWorkspace.shared.icon(forFile: path)))
        let nowGenerated = try XCTUnwrap(bitmap(try XCTUnwrap(NSImage(contentsOf:
            URL(fileURLWithPath: path)
                .appendingPathComponent("Contents/Resources/MALAppIcon.icns")))))
        let previous = try XCTUnwrap(bitmap(
            IconFactory(cacheDir: paths.iconCacheDir)
                .preview(sourceIcon: IconFactory.loadSourceIcon(appBundle: sourceApp),
                         number: 1,
                         badge: BadgeSpec(colorHex: "#E5484D"),
                         pixelSize: 512)))

        let toNow = difference(resolved, nowGenerated)
        let toPrevious = difference(resolved, previous)
        XCTAssertGreaterThan(difference(nowGenerated, previous), 0.005,
                             "the two badge colours are not distinguishable at this size")
        XCTAssertLessThan(toNow, toPrevious,
                          "a reused path still resolves to the icon macOS cached for the previous instance (now \(toNow), previous \(toPrevious))")
    }
}
#endif
