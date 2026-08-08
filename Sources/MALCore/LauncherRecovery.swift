import Foundation

/// A self-contained, signed description of one launcher.
///
/// The registry remains the live source of truth, but it is deliberately not the only
/// copy of an instance's identity. Every launcher carries this small document inside
/// `Contents/Resources`, so reinstalling LaunchAgain (or recovering from a damaged
/// registry) can rebuild the dashboard from the launchers that are still on disk.
public struct LauncherRecoveryManifest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let filename = "LaunchAgainInstance.json"

    public var schemaVersion: Int
    public var appKey: String
    public var appDisplayName: String
    public var sourcePath: String
    public var sourceVersion: String
    public var instance: Instance

    public init(schemaVersion: Int = LauncherRecoveryManifest.currentSchemaVersion,
                appKey: String,
                appDisplayName: String,
                sourcePath: String,
                sourceVersion: String,
                instance: Instance) {
        self.schemaVersion = schemaVersion
        self.appKey = appKey
        self.appDisplayName = appDisplayName
        self.sourcePath = sourcePath
        self.sourceVersion = sourceVersion
        self.instance = instance
    }
}

/// Durable record of a user-confirmed uninstall. It is written before the first file
/// moves and removed only after launcher, profile, artifacts, registry copies and cache
/// metadata have all committed. A later process can therefore resume an interrupted
/// uninstall without guessing ownership from a broad directory scan.
public struct RemovalJournalRecord: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var requestedAt: Date
    public var instance: Instance
    public var deleteData: Bool

    public init(schemaVersion: Int = RemovalJournalRecord.currentSchemaVersion,
                requestedAt: Date = Date(),
                instance: Instance,
                deleteData: Bool) {
        self.schemaVersion = schemaVersion
        self.requestedAt = requestedAt
        self.instance = instance
        self.deleteData = deleteData
    }
}
