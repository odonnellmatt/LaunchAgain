#if canImport(AppKit)
import XCTest
import AppKit
import SwiftUI
@testable import MALApp
@testable import MALCore

/// Hiding the sidebar is the only structural change the dashboard container ever makes
/// to its own child list, and structural change under this container is exactly the
/// shape of the bug that produced a blank window. These tests exercise the new control
/// against the shipping `RootView`, including in combination with a sheet dismissal and
/// a row removal, which is the sequence that originally failed.
@MainActor
final class SidebarToggleRegressionTests: XCTestCase {

    private var root: URL!
    private var paths: MALPaths!
    private var state: AppState!
    private var hostView: NSView!
    private var window: NSWindow!
    private let appKey = "com.example.sidebar"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("launchagain-sidebar-\(UUID().uuidString)")
        paths = MALPaths.rooted(at: root)
        try paths.createAll()
        _ = NSApplication.shared
        UserDefaults.standard.removeObject(forKey: "com.launchagain.sidebarVisible")
    }

    override func tearDownWithError() throws {
        hostView?.removeFromSuperview()
        window?.orderOut(nil)
        window?.close()
        state = nil
        hostView = nil
        window = nil
        UserDefaults.standard.removeObject(forKey: "com.launchagain.sidebarVisible")
        try? FileManager.default.removeItem(at: root)
    }

    private func instance(_ number: Int) -> Instance {
        let id = UUID()
        let bundle = paths.bundlesDir.appendingPathComponent("Fixture \(number).app")
        let profile = paths.instanceDataDir(id)
        try? FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        return Instance(id: id, number: number, name: "Fixture \(number)",
                        bundlePath: bundle.path, dataPath: profile.path)
    }

    private func seed(_ instances: [Instance]) throws {
        let registry = try Registry(paths: paths)
        try registry.upsertApp(appKey: appKey,
                               displayName: "Sidebar Fixture",
                               sourcePath: "/Applications/Sidebar Fixture.app",
                               sourceVersion: "1.0")
        for instance in instances { try registry.addInstance(instance, toApp: appKey) }
    }

    private func hostWindow() {
        state = AppState(paths: paths, startServices: false)
        let host = NSHostingView(rootView: RootView().environmentObject(state))
        host.frame = NSRect(x: 0, y: 0, width: 1_100, height: 720)
        let testWindow = NSWindow(contentRect: host.frame,
                                  styleMask: [.titled, .closable],
                                  backing: .buffered,
                                  defer: false)
        testWindow.isReleasedWhenClosed = false
        // Mirror `WindowGroup("LaunchAgain")`; RootView does not own the scene title.
        testWindow.title = "LaunchAgain"
        testWindow.contentView = host
        testWindow.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        hostView = host
        window = testWindow
        pump()
    }

    private func pump(_ interval: TimeInterval = 0.08) {
        RunLoop.main.run(until: Date().addingTimeInterval(interval))
    }

    private func waitForTitleVisibility(_ expected: NSWindow.TitleVisibility) {
        let deadline = Date().addingTimeInterval(2)
        while window.titleVisibility != expected, Date() < deadline {
            pump(0.02)
        }
    }

    // MARK: The window must always say what it is

    /// The system title bar is the one stable identity location across sidebar states.
    private func identityIsOnScreen() -> Bool {
        window.titleVisibility == .visible && window.title.contains("LaunchAgain")
    }

    /// C2 moved the icon, name and version into the sidebar and switched the title bar
    /// text off at the scene level. Collapsing the sidebar — a toolbar button, a menu
    /// item and ⌃⌘S, all shipped in the same pass — then left the window with no name
    /// anywhere on screen.
    func testTheWindowKeepsItsNameWithTheSidebarHidden() {
        hostWindow()
        XCTAssertTrue(identityIsOnScreen(), "no identity with the sidebar shown")

        state.sidebarVisible = false
        pump(0.3)
        assertColumns(2)

        XCTAssertEqual(window.titleVisibility, .visible,
                       "with the sidebar hidden the window has no icon, no name and no version anywhere on screen")
        XCTAssertTrue(window.title.contains("LaunchAgain"))
        XCTAssertTrue(identityIsOnScreen())
    }

    /// Identity no longer moves between SwiftUI and AppKit during a sidebar transition.
    func testTheTitleBarRemainsTheIdentityAcrossSidebarChanges() {
        hostWindow()
        XCTAssertEqual(window.titleVisibility, .visible)
        XCTAssertTrue(window.title.contains("LaunchAgain"))

        state.sidebarVisible = false
        waitForTitleVisibility(.visible)
        XCTAssertEqual(window.titleVisibility, .visible)

        state.sidebarVisible = true
        waitForTitleVisibility(.visible)
        XCTAssertEqual(window.titleVisibility, .visible)
        XCTAssertTrue(window.title.contains("LaunchAgain"))
    }

    /// A relaunch that restores a collapsed sidebar must come up named, which is the
    /// state a user who hid the sidebar will actually meet.
    func testAWindowRestoredWithTheSidebarCollapsedComesUpNamed() {
        UserDefaults.standard.set(false, forKey: "com.launchagain.sidebarVisible")
        hostWindow()
        pump(0.3)

        XCTAssertFalse(state.sidebarVisible, "the fixture did not restore a collapsed sidebar")
        assertColumns(2)
        XCTAssertEqual(window.titleVisibility, .visible)
        XCTAssertTrue(identityIsOnScreen())
    }

    /// At the minimum window size, which is the combination the brief asked for and the
    /// one that fails.
    func testIdentitySurvivesAtTheMinimumWindowSize() {
        hostWindow()
        window.setContentSize(NSSize(width: 960, height: 600))
        hostView.frame = NSRect(x: 0, y: 0, width: 960, height: 600)
        state.sidebarVisible = false
        pump(0.3)

        XCTAssertEqual(window.titleVisibility, .visible)
        XCTAssertTrue(identityIsOnScreen())
        assertColumns(2)
    }

    private func splitViews(in view: NSView) -> [NSSplitView] {
        var found = view is NSSplitView ? [view as! NSSplitView] : []
        for child in view.subviews { found.append(contentsOf: splitViews(in: child)) }
        return found
    }

    /// The dashboard's own split view, identified by column count rather than by
    /// position, so this stays honest whichever columns are currently shown.
    private func dashboardColumns(expected: Int) -> [NSView]? {
        hostView.layoutSubtreeIfNeeded()
        let split = splitViews(in: hostView).first {
            $0.subviews.filter { !String(describing: type(of: $0)).contains("Divider") }
                .count == expected
        }
        return split?.subviews.filter { !String(describing: type(of: $0)).contains("Divider") }
    }

    private func assertColumns(_ expected: Int,
                               file: StaticString = #filePath,
                               line: UInt = #line) {
        guard let columns = dashboardColumns(expected: expected) else {
            return XCTFail("expected \(expected) mounted dashboard columns", file: file, line: line)
        }
        for (index, column) in columns.enumerated() {
            XCTAssertFalse(column.isHidden, "column \(index) hidden", file: file, line: line)
            XCTAssertGreaterThan(column.frame.width, 40, "column \(index) collapsed",
                                 file: file, line: line)
            XCTAssertGreaterThan(column.frame.height, 100, "column \(index) detached",
                                 file: file, line: line)
        }
        let tick = expectation(description: "main event loop tick")
        DispatchQueue.main.async { tick.fulfill() }
        wait(for: [tick], timeout: 1)
    }

    func testSidebarStartsVisibleAndTogglesBothWaysRepeatedly() throws {
        try seed([instance(1), instance(2)])
        hostWindow()

        XCTAssertTrue(state.sidebarVisible, "the sidebar must be shown by default")
        assertColumns(3)

        for _ in 0..<8 {
            state.sidebarVisible = false
            pump()
            assertColumns(2)

            state.sidebarVisible = true
            pump()
            assertColumns(3)
        }
    }

    /// The original blank-window sequence, run with the sidebar hidden and then shown
    /// again: present a sheet, dismiss it, remove the selected row, restore the sidebar.
    func testTogglingAroundSheetDismissalAndRowRemovalKeepsColumnsMounted() throws {
        let first = instance(1)
        let second = instance(2)
        try seed([first, second])
        hostWindow()
        state.selectedInstance = second.id

        state.sidebarVisible = false
        pump()
        assertColumns(2)

        state.requestDelete(second)
        pump()
        XCTAssertNotNil(window.attachedSheet, "the shipping confirmation sheet must present")
        state.presentation = nil
        let deadline = Date().addingTimeInterval(1)
        while window.attachedSheet != nil, Date() < deadline { pump(0.03) }
        XCTAssertNil(window.attachedSheet)

        try state.manager!.registry.removeInstance(second.id)
        state.refresh()
        pump(0.15)

        XCTAssertEqual(state.visibleInstances.map(\.instance.id), [first.id])
        XCTAssertNil(state.selectedInstance)
        assertColumns(2)

        state.sidebarVisible = true
        pump(0.15)
        assertColumns(3)
        XCTAssertEqual(state.visibleInstances.map(\.instance.id), [first.id])
    }

    func testTheSidebarChoiceIsRemembered() throws {
        try seed([instance(1)])
        hostWindow()
        state.sidebarVisible = false
        pump()

        // A second AppState over the same defaults is what reopening the window does.
        let reopened = AppState(paths: paths, startServices: false)
        XCTAssertFalse(reopened.sidebarVisible,
                       "the window must reopen the way the user left it")
    }
}
#endif
