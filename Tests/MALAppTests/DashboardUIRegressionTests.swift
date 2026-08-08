#if canImport(AppKit)
import XCTest
import AppKit
import SwiftUI
@testable import MALApp
@testable import MALCore

/// Hosts the shipping `RootView` in AppKit; this is not a second dashboard
/// implementation. Every store is rooted under a unique temporary directory.
@MainActor
final class DashboardUIRegressionTests: XCTestCase {

    private var root: URL!
    private var paths: MALPaths!
    private var state: AppState!
    private var hostView: NSView!
    private var window: NSWindow!
    private let appKey = "com.example.dashboard"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("launchagain-ui-\(UUID().uuidString)")
        paths = MALPaths.rooted(at: root)
        try paths.createAll()
        _ = NSApplication.shared
        // Own the sidebar default rather than inheriting whatever another suite left.
        // These assertions require three mounted columns, and depending on a sibling's
        // tearDown plus alphabetical ordering is not a dependency worth having.
        UserDefaults.standard.removeObject(forKey: "com.launchagain.sidebarVisible")
    }

    override func tearDownWithError() throws {
        hostView?.removeFromSuperview()
        window?.orderOut(nil)
        window?.close()
        state = nil
        hostView = nil
        window = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func instance(_ number: Int, appName: String = "Fixture") -> Instance {
        let id = UUID()
        let bundle = paths.bundlesDir.appendingPathComponent("\(appName) \(number).app")
        let profile = paths.instanceDataDir(id)
        try? FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        return Instance(id: id,
                        number: number,
                        name: "\(appName) \(number)",
                        bundlePath: bundle.path,
                        dataPath: profile.path)
    }

    private func seed(_ instances: [Instance]) throws {
        let registry = try Registry(paths: paths)
        try registry.upsertApp(appKey: appKey,
                               displayName: "Dashboard Fixture",
                               sourcePath: "/Applications/Dashboard Fixture.app",
                               sourceVersion: "1.0")
        for instance in instances {
            try registry.addInstance(instance, toApp: appKey)
        }
    }

    private func hostWindow(startServices: Bool = false) {
        state = AppState(paths: paths, startServices: startServices)
        let host = NSHostingView(rootView: RootView().environmentObject(state))
        host.frame = NSRect(x: 0, y: 0, width: 1_100, height: 720)
        let testWindow = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        testWindow.isReleasedWhenClosed = false
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

    private func assertResponsive(file: StaticString = #filePath, line: UInt = #line) {
        let tick = expectation(description: "main event loop tick")
        DispatchQueue.main.async { tick.fulfill() }
        wait(for: [tick], timeout: 1)
        pump(0.03)
        XCTAssertNotNil(hostView, file: file, line: line)
        XCTAssertFalse(hostView.frame.isEmpty, file: file, line: line)
    }

    private func splitViews(in view: NSView) -> [NSSplitView] {
        var found = view is NSSplitView ? [view as! NSSplitView] : []
        for child in view.subviews {
            found.append(contentsOf: splitViews(in: child))
        }
        return found
    }

    private func assertDashboardColumnsVisible(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var split: NSSplitView?
        let deadline = Date().addingTimeInterval(2)
        repeat {
            hostView.layoutSubtreeIfNeeded()
            split = splitViews(in: hostView).first {
                let columns = $0.subviews.filter {
                    !String(describing: type(of: $0)).contains("Divider")
                }
                return columns.count == 3 && columns.allSatisfy {
                    !$0.isHidden && $0.frame.width > 40 && $0.frame.height > 100
                }
            }
            if split == nil { pump(0.02) }
        } while split == nil && Date() < deadline

        XCTAssertNotNil(split, "the shipping three-column HSplitView must remain mounted",
                        file: file, line: line)
        guard let split else { return }
        let columns = split.subviews.filter {
            !String(describing: type(of: $0)).contains("Divider")
        }
        for (index, column) in columns.enumerated() {
            XCTAssertFalse(column.isHidden, "column \(index) became hidden",
                           file: file, line: line)
            XCTAssertGreaterThan(column.frame.width, 40, "column \(index) collapsed",
                                 file: file, line: line)
            XCTAssertGreaterThan(column.frame.height, 100, "column \(index) detached",
                                 file: file, line: line)
        }
    }

    func testOneToTwoToOneRowsKeepsAllColumnsAndEventLoopResponsive() throws {
        let first = instance(1)
        let second = instance(2)
        try seed([first])
        hostWindow()

        for _ in 0..<12 {
            XCTAssertEqual(state.visibleInstances.map(\.instance.id), [first.id])
            assertResponsive()
            assertDashboardColumnsVisible()

            try state.manager!.registry.addInstance(second, toApp: appKey)
            state.refresh()
            pump()
            XCTAssertEqual(Set(state.visibleInstances.map(\.instance.id)), Set([first.id, second.id]))
            XCTAssertEqual(state.selection, .allInstances)
            assertResponsive()
            assertDashboardColumnsVisible()

            try state.manager!.registry.removeInstance(second.id)
            state.refresh()
            pump()
            XCTAssertEqual(state.visibleInstances.map(\.instance.id), [first.id])
            XCTAssertEqual(state.selection, .allInstances)
            assertResponsive()
            assertDashboardColumnsVisible()
        }
    }

    func testSelectedAndUnselectedRowRemovalRepairsSelectionCoherently() throws {
        let first = instance(1)
        let second = instance(2)
        let third = instance(3)
        try seed([first, second, third])
        hostWindow()

        state.selectedInstance = first.id
        try state.manager!.registry.removeInstance(third.id)
        state.refresh()
        XCTAssertEqual(state.selectedInstance, first.id,
                       "removing an unselected row must preserve the detail selection")
        assertResponsive()

        try state.manager!.registry.removeInstance(first.id)
        state.refresh()
        XCTAssertNil(state.selectedInstance,
                     "apps and selection must never publish a transient invalid pair")
        XCTAssertEqual(state.apps.count, 1)
        XCTAssertFalse(state.apps.contains { $0.instances.isEmpty })
        assertResponsive()
    }

    func testEveryDeletionEntryPointUsesConfirmationWithoutChangingSelection() throws {
        let first = instance(1)
        let second = instance(2)
        try seed([first, second])
        hostWindow()
        state.selectedInstance = first.id

        // Row trash, context menu, detail/toolbar and application menu all invoke this
        // single presentation route in the shipping views.
        for candidate in [second, first, second, first] {
            state.requestDelete(candidate)
            guard case .confirmDelete(let presented) = state.presentation else {
                return XCTFail("delete did not present confirmation")
            }
            XCTAssertEqual(presented.id, candidate.id)
            XCTAssertEqual(state.selectedInstance, first.id,
                           "a control click must not trigger row selection")
            state.presentation = nil
            assertResponsive()
        }
    }

    func testSheetDismissalThenDeletionKeepsDashboardStateCoherent() throws {
        let first = instance(1)
        let second = instance(2)
        try seed([first, second])
        hostWindow()
        state.selectedInstance = second.id

        // This is the exact sequence that produced a stale detail pane beside two blank
        // columns: present confirmation, dismiss its sheet, then remove the selected row.
        state.requestDelete(second)
        let presentationDeadline = Date().addingTimeInterval(2)
        while window.attachedSheet == nil, Date() < presentationDeadline {
            pump(0.03)
        }
        XCTAssertNotNil(window.attachedSheet, "the shipping confirmation sheet must be presented")
        state.presentation = nil
        let dismissalDeadline = Date().addingTimeInterval(1)
        while window.attachedSheet != nil, Date() < dismissalDeadline {
            pump(0.03)
        }
        XCTAssertNil(window.attachedSheet, "the real sheet must finish dismissing")
        try state.manager!.registry.removeInstance(second.id)
        state.refresh()
        pump(0.15)

        XCTAssertEqual(state.visibleInstances.map(\.instance.id), [first.id])
        XCTAssertNil(state.selectedInstance)
        XCTAssertEqual(state.selection, .allInstances)
        assertResponsive()
        assertDashboardColumnsVisible()
    }

    func testExternalRegistryUpdateAppearsWhileWindowIsOpen() throws {
        let first = instance(1)
        let second = instance(2)
        try seed([first])
        hostWindow(startServices: true)

        // The startup Health pass also refreshes once when it completes. Drain that
        // work before the external write so it cannot mask a broken filesystem watcher.
        let healthDeadline = Date().addingTimeInterval(3)
        while state.lastSweptAt == nil, Date() < healthDeadline {
            pump(0.02)
        }
        XCTAssertNotNil(state.lastSweptAt)
        pump(0.25)

        let external = try Registry(paths: paths)
        try external.addInstance(second, toApp: appKey)
        try? FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(2)],
            ofItemAtPath: paths.registryFile.path)

        // Do not call refresh here: this must exercise the shipping directory watcher
        // and its 175 ms coalescing path. Polling only keeps XCTest's main run loop
        // moving while the vnode notification is delivered.
        let deadline = Date().addingTimeInterval(3)
        while state.visibleInstances.count != 2, Date() < deadline {
            pump(0.04)
        }
        XCTAssertEqual(Set(state.visibleInstances.map(\.instance.id)), Set([first.id, second.id]))
        XCTAssertEqual(state.selection, .allInstances)
        assertResponsive()
        assertDashboardColumnsVisible()
    }

    func testRemovingSecondAppSectionPreservesFirstAppAndAllColumns() throws {
        let first = instance(1, appName: "Claude Fixture")
        try seed([first])

        let secondAppKey = "com.example.second-dashboard"
        let second = instance(1, appName: "Codex Fixture")
        let registry = try Registry(paths: paths)
        try registry.upsertApp(
            appKey: secondAppKey,
            displayName: "Second Dashboard Fixture",
            sourcePath: "/Applications/Second Dashboard Fixture.app",
            sourceVersion: "1.0")
        try registry.addInstance(second, toApp: secondAppKey)
        hostWindow()

        XCTAssertEqual(Set(state.apps.map(\.appKey)), Set([appKey, secondAppKey]))
        XCTAssertEqual(Set(state.visibleInstances.map(\.instance.id)), Set([first.id, second.id]))
        state.selection = .app(secondAppKey)
        state.selectedInstance = second.id
        assertDashboardColumnsVisible()

        // Removing the only row in one app must prune only that app record. This is the
        // exact two-product shape reported by the user (Claude remains after Codex is
        // removed), not merely a 2 -> 1 transition inside one section.
        try state.manager!.registry.removeInstance(second.id)
        state.refresh()
        pump()

        XCTAssertEqual(state.apps.map(\.appKey), [appKey])
        XCTAssertEqual(state.visibleInstances.map(\.instance.id), [first.id])
        XCTAssertEqual(state.selection, .allInstances)
        XCTAssertNil(state.selectedInstance)
        XCTAssertFalse(state.apps.contains { $0.instances.isEmpty })
        assertResponsive()
        assertDashboardColumnsVisible()
    }
}
#endif
