#if canImport(AppKit)
import XCTest
import AppKit
import SwiftUI
@testable import MALApp
@testable import MALCore
@testable import MALKit

/// Renders each screen this release changed to a PNG.
///
/// The renders go to `.build/screen-renders/` on every run; they are copied into the
/// committed `docs/evidence/` only when `MAL_WRITE_EVIDENCE=1`, which is what
/// `Scripts/render-evidence.sh` sets. Running the suite therefore leaves the working
/// tree clean, and refreshing the evidence is something a person decides to do.
///
/// Every identifier a screen can display is fixed rather than freshly generated, so two
/// runs produce byte-identical files.
///
/// The v1.2 screenshots existed only in a conversation, so nobody who was not there could
/// check them: `screencapture` needs Screen Recording permission, which the build process
/// does not have. This needs no permission at all — an `NSHostingView` in an offscreen
/// `NSWindow`, `bitmapImageRepForCachingDisplay`, write the file — and it is reproducible
/// on any machine that can run the suite.
///
/// It is a test rather than a script so it cannot rot: if a screen stops building or
/// stops laying out, this fails with the rest of the suite. It asserts what a rendering
/// can honestly assert — that the view mounts, lays out at a real size and produces a
/// non-blank image — and leaves judging the design to a person looking at the file.
@MainActor
final class ScreenRenderingTests: XCTestCase {

    private var root: URL!
    private var paths: MALPaths!
    private var state: AppState!
    private var mounted: [(NSWindow, NSView)] = []

    /// The repository root, or `nil` when the suite is run from somewhere without it.
    private var repositoryRoot: URL? {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { dir.deleteLastPathComponent() }      // Tests/MALAppTests/<file>
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path)
            ? dir : nil
    }

    /// Where the PNGs go: a build directory, not the working tree.
    ///
    /// `swift test` must leave `git status` clean. Writing six PNGs into `docs/evidence/`
    /// on every run meant the suite dirtied the repository as a side effect of passing,
    /// so a reviewer could not tell a stale committed image from a fresh one without
    /// diffing, and had to work around a file the tests themselves had modified.
    private var renderDirectory: URL {
        let base = repositoryRoot?.appendingPathComponent(".build/screen-renders")
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("mal-screen-renders")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// The committed evidence directory, and only when asked for explicitly.
    ///
    /// `Scripts/render-evidence.sh` sets the variable; an ordinary `swift test` does not,
    /// so refreshing the committed images is a decision someone makes rather than a
    /// side effect of running the suite.
    private var evidenceDirectory: URL? {
        guard ProcessInfo.processInfo.environment["MAL_WRITE_EVIDENCE"] == "1" else { return nil }
        guard let docs = repositoryRoot?.appendingPathComponent("docs/evidence"),
              FileManager.default.fileExists(atPath: docs.path) else { return nil }
        return docs
    }

    override func setUpWithError() throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mal-screens-\(UUID().uuidString)")
        paths = .rooted(at: root)
        try paths.createAll()
        UserDefaults.standard.removeObject(forKey: "com.launchagain.sidebarVisible")
        state = AppState(paths: paths, startServices: false)
    }

    override func tearDownWithError() throws {
        for (window, view) in mounted {
            view.removeFromSuperview()
            window.contentView = nil
            window.orderOut(nil)
            window.close()
        }
        mounted.removeAll()
        state = nil
        UserDefaults.standard.removeObject(forKey: "com.launchagain.sidebarVisible")
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Fixtures

    /// An instance with a real profile on disk, so sizes and paths in the rendered
    /// screens are real rather than placeholders.
    /// A UUID fixed by its ordinal. Instance identifiers appear in rendered paths and in
    /// health findings, so a fresh `UUID()` per run changed the text — and with it the
    /// laid-out width — of the image. `c3-health-list.png` came out a different size on
    /// each of three runs for exactly this reason.
    private func fixedID(_ ordinal: Int) -> UUID {
        UUID(uuidString: "00000000-0000-4000-8000-\(String(format: "%012x", ordinal))")!
    }

    @discardableResult
    private func seedInstance(number: Int,
                              name: String,
                              profileBytes: Int) throws -> Instance {
        let id = fixedID(number)
        let bundle = paths.bundlesDir.appendingPathComponent("Fixture \(number) – \(name).app")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let profile = paths.instanceDataDir(id)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        if profileBytes > 0 {
            try Data(repeating: 0, count: profileBytes)
                .write(to: profile.appendingPathComponent("blob"))
        }
        let instance = Instance(id: id,
                                number: number,
                                name: name,
                                mode: .full,
                                bundlePath: bundle.path,
                                dataPath: profile.path,
                                builtFromSourceVersion: "3.1.5",
                                clonedBundleIdentifier: Validation.cloneBundleIdentifier(
                                    original: "com.example.fixture",
                                    number: number,
                                    instanceID: id))
        let registry = try Registry(paths: paths)
        try registry.upsertApp(appKey: "com.example.fixture",
                               displayName: "Fixture",
                               sourcePath: "/Applications/Fixture.app",
                               sourceVersion: "3.1.5")
        try registry.addInstance(instance, toApp: "com.example.fixture")
        state.refresh()
        return instance
    }

    private func facts(entitlements: [String] = []) -> AppFacts {
        AppFacts(bundleIdentifier: entitlements.isEmpty ? "com.example.fixture" : "com.openai.codex",
                 displayName: entitlements.isEmpty ? "Fixture" : "Codex",
                 executableName: "Fixture",
                 shortVersion: "3.1.5",
                 path: "/Applications/Fixture.app",
                 runtime: .electron,
                 isSigned: true,
                 entitlementKeys: entitlements,
                 bundleSizeBytes: 1_481_763_226,
                 signingInspected: true)
    }

    // MARK: Rendering

    /// Mounts a view offscreen, renders it, and writes the PNG.
    ///
    /// Returns the number of non-transparent pixels, so "it rendered" is asserted rather
    /// than assumed — a blank image would otherwise pass silently, which is the failure
    /// mode of every screenshot test.
    @discardableResult
    private func render<V: View>(_ view: V,
                                 size: NSSize,
                                 to filename: String,
                                 file: StaticString = #filePath,
                                 line: UInt = #line) throws -> Int {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame,
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        host.layoutSubtreeIfNeeded()
        mounted.append((window, host))

        let bounds = host.bounds
        guard bounds.width > 1, bounds.height > 1,
              let rep = host.bitmapImageRepForCachingDisplay(in: bounds) else {
            XCTFail("\(filename): the view did not lay out", file: file, line: line)
            return 0
        }
        host.cacheDisplay(in: bounds, to: rep)

        var opaque = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 4) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 4) {
                if let colour = rep.colorAt(x: x, y: y), colour.alphaComponent > 0.05 {
                    opaque += 1
                }
            }
        }
        XCTAssertGreaterThan(opaque, 0, "\(filename) rendered blank", file: file, line: line)

        if let png = rep.representation(using: .png, properties: [:]) {
            try png.write(to: renderDirectory.appendingPathComponent(filename))
            if let evidenceDirectory {
                try png.write(to: evidenceDirectory.appendingPathComponent(filename))
            }
        }
        return opaque
    }

    // MARK: The screens

    /// C1 — the delete confirmation, with a real 320 MB profile behind it.
    func testRendersTheDeleteConfirmation() throws {
        // A real profile on disk, measured by AppState the way it would be in the
        // product, rather than a number written into the view.
        let instance = try seedInstance(number: 1, name: "Personal",
                                        profileBytes: 24 * 1024 * 1024)
        state.refresh()
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        XCTAssertNotNil(state.profileSizes[instance.id],
                        "the sheet's size row would render empty, which is not the screen under review")
        try render(DeleteInstanceSheet(instance: instance).environmentObject(state),
                   size: NSSize(width: 560, height: 700),
                   to: "c1-delete-confirmation.png")
    }

    /// C3 — the health list, one line per finding with a single action.
    func testRendersTheHealthList() throws {
        try seedInstance(number: 1, name: "Personal", profileBytes: 4 * 1024 * 1024)
        // Two orphan profiles and a stale marker, so the list has something in it.
        // Fixed identifiers: these are rendered into the findings, so generating them
        // made the image differ on every run.
        for ordinal in 101...102 {
            let orphan = paths.instancesDir.appendingPathComponent(fixedID(ordinal).uuidString)
            try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
            try Data(repeating: 0, count: 4 * 1024 * 1024)
                .write(to: orphan.appendingPathComponent("blob"))
        }
        try Data("removed 1785026586.705584".utf8).write(
            to: paths.removalTombstoneFile(fixedID(103)))
        state.runHealthCheck()
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))

        try render(HealthView().environmentObject(state),
                   size: NSSize(width: 460, height: 560),
                   to: "c3-health-list.png")
    }

    /// C4 — the create flow. Rendered as the compatibility card for an application whose
    /// session lives outside the profile, which is also the Bl-1/Ma-7 wording.
    func testRendersTheCompatibilityCardForASharedCredentialStoreApp() throws {
        let f = facts(entitlements: ["keychain-access-groups",
                                     "com.apple.security.application-groups"])
        try render(CompatibilityCard(facts: f, verdict: Compatibility.evaluate(f))
                    .padding(14)
                    .frame(width: 620),
                   size: NSSize(width: 620, height: 760),
                   to: "c4-compatibility-card-shared-session.png")
    }

    /// And the same card for an ordinary application, so the difference is visible rather
    /// than asserted — this is the pair Ma-7 is about.
    func testRendersTheCompatibilityCardForAnOrdinaryApp() throws {
        let f = facts()
        try render(CompatibilityCard(facts: f, verdict: Compatibility.evaluate(f))
                    .padding(14)
                    .frame(width: 620),
                   size: NSSize(width: 620, height: 560),
                   to: "c4-compatibility-card-ordinary.png")
    }

    /// C2 — the whole window, with the sidebar shown and hidden, which is Ma-4.
    func testRendersTheDashboardWithTheSidebarShownAndHidden() throws {
        try seedInstance(number: 1, name: "Personal", profileBytes: 4 * 1024 * 1024)
        try seedInstance(number: 2, name: "Work", profileBytes: 0)

        state.sidebarVisible = true
        try render(RootView().environmentObject(state),
                   size: NSSize(width: 1_100, height: 720),
                   to: "c2-window-sidebar-shown.png")

        state.sidebarVisible = false
        try render(RootView().environmentObject(state),
                   size: NSSize(width: 960, height: 600),
                   to: "c2-window-sidebar-hidden-minimum-size.png")
    }
}
#endif
