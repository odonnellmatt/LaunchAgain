import XCTest
@testable import MALCore

final class WindowStateRepairTests: XCTestCase {
    private var root: URL!
    private var stateFile: URL!

    private let laptop = MALDisplayGeometry(
        bounds: MALScreenRect(x: 0, y: 0, width: 1_800, height: 1_169),
        visibleFrame: MALScreenRect(x: 0, y: 39, width: 1_800, height: 1_063))
    private let external = MALDisplayGeometry(
        bounds: MALScreenRect(x: 1_800, y: 0, width: 1_920, height: 1_080),
        visibleFrame: MALScreenRect(x: 1_800, y: 25, width: 1_920, height: 1_055))

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("launchagain-window-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        stateFile = root.appendingPathComponent(ElectronWindowStateRepairer.filename)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func writeState(x: Int = 2_234, y: Int = 144,
                            width: Int = 1_258, height: Int = 816,
                            display: MALScreenRect? = nil,
                            extra: [String: Any] = [:]) throws -> Data {
        let display = display ?? external.bounds
        var object: [String: Any] = [
            "x": x, "y": y, "width": width, "height": height,
            "displayBounds": [
                "x": display.x, "y": display.y,
                "width": display.width, "height": display.height,
            ],
            "isMaximized": false,
            "isFullScreen": false,
        ]
        object.merge(extra) { _, new in new }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: stateFile)
        return data
    }

    private func repairedState() throws -> [String: Any] {
        let data = try Data(contentsOf: stateFile)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testWindowSavedOnDisconnectedDisplayIsRepairedAndBackedUp() throws {
        let original = try writeState(extra: ["unknownVendorKey": "preserved"])

        XCTAssertEqual(
            try ElectronWindowStateRepairer.repairIfNeeded(
                profileDirectory: root, displays: [laptop]),
            .repaired)

        let state = try repairedState()
        XCTAssertEqual(try XCTUnwrap(state["x"] as? NSNumber).doubleValue,
                       271, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(state["y"] as? NSNumber).doubleValue,
                       162.5, accuracy: 0.001)
        XCTAssertEqual((state["width"] as? NSNumber)?.doubleValue, 1_258)
        XCTAssertEqual((state["height"] as? NSNumber)?.doubleValue, 816)
        XCTAssertEqual(state["unknownVendorKey"] as? String, "preserved")

        let backup = root.appendingPathComponent(ElectronWindowStateRepairer.backupFilename)
        XCTAssertEqual(try Data(contentsOf: backup), original)
    }

    func testAReachableTitleBarLeavesTheFileByteForByteUntouched() throws {
        let original = try writeState(x: 120, y: 90, display: laptop.bounds)
        XCTAssertEqual(
            try ElectronWindowStateRepairer.repairIfNeeded(
                profileDirectory: root, displays: [laptop]),
            .unchanged)
        XCTAssertEqual(try Data(contentsOf: stateFile), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root
            .appendingPathComponent(ElectronWindowStateRepairer.backupFilename).path))
    }

    func testAThinImmovableEdgeIsRescued() throws {
        try writeState(x: 1_760, y: 100, width: 1_200, display: external.bounds)
        XCTAssertEqual(
            try ElectronWindowStateRepairer.repairIfNeeded(
                profileDirectory: root, displays: [laptop]),
            .repaired)
        let state = try repairedState()
        XCTAssertLessThan((state["x"] as! NSNumber).doubleValue, laptop.bounds.maxX)
    }

    func testAnAttachedSavedDisplayRemainsTheTarget() throws {
        try writeState(x: 4_000, y: 100, display: external.bounds)
        XCTAssertEqual(
            try ElectronWindowStateRepairer.repairIfNeeded(
                profileDirectory: root, displays: [laptop, external]),
            .repaired)
        let state = try repairedState()
        XCTAssertGreaterThanOrEqual((state["x"] as! NSNumber).doubleValue, external.bounds.x)
        let bounds = state["displayBounds"] as! [String: Any]
        XCTAssertEqual((bounds["x"] as! NSNumber).doubleValue, external.bounds.x)
    }

    func testUnknownMalformedAndSymbolicLinkFilesAreNeverEdited() throws {
        let malformed = Data("{not-json".utf8)
        try malformed.write(to: stateFile)
        XCTAssertEqual(
            try ElectronWindowStateRepairer.repairIfNeeded(
                profileDirectory: root, displays: [laptop]),
            .unsupported)
        XCTAssertEqual(try Data(contentsOf: stateFile), malformed)

        try FileManager.default.removeItem(at: stateFile)
        let outside = root.appendingPathComponent("outside.json")
        try writeState(x: 3_000)
        try FileManager.default.moveItem(at: stateFile, to: outside)
        try FileManager.default.createSymbolicLink(at: stateFile, withDestinationURL: outside)
        XCTAssertEqual(
            try ElectronWindowStateRepairer.repairIfNeeded(
                profileDirectory: root, displays: [laptop]),
            .unsupported)
    }

    func testSecondLaunchIsAStableNoOpAndKeepsTheOriginalBackup() throws {
        let original = try writeState()
        XCTAssertEqual(
            try ElectronWindowStateRepairer.repairIfNeeded(
                profileDirectory: root, displays: [laptop]),
            .repaired)
        let repaired = try Data(contentsOf: stateFile)
        XCTAssertEqual(
            try ElectronWindowStateRepairer.repairIfNeeded(
                profileDirectory: root, displays: [laptop]),
            .unchanged)
        XCTAssertEqual(try Data(contentsOf: stateFile), repaired)
        XCTAssertEqual(try Data(contentsOf: root
            .appendingPathComponent(ElectronWindowStateRepairer.backupFilename)), original)
    }

    func testRepairKeepsCurrentFilePermissionsWhenAnOlderBackupAlreadyExists() throws {
        try writeState()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: stateFile.path)
        let backup = root.appendingPathComponent(ElectronWindowStateRepairer.backupFilename)
        try Data("older backup".utf8).write(to: backup)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: backup.path)

        XCTAssertEqual(
            try ElectronWindowStateRepairer.repairIfNeeded(
                profileDirectory: root, displays: [laptop]),
            .repaired)

        let attributes = try FileManager.default.attributesOfItem(atPath: stateFile.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try Data(contentsOf: backup), Data("older backup".utf8))
    }
}
