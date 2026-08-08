import Foundation

// MARK: - Instance identity

public enum InstanceMode: String, Codable, Sendable, CaseIterable {
    /// Cloned bundle with rewritten identity, badged icon, ad-hoc re-signed.
    /// Gives a separate Dock tile.
    case full
    /// No clone. A small launcher bundle we author ourselves opens the *original*
    /// app with `--user-data-dir`. Profile-resident state is separate; the Dock,
    /// Keychain, privacy-permission and URL-scheme identity are shared.
    case lite

    public var displayName: String {
        switch self {
        case .full: return "Full"
        case .lite: return "Lite"
        }
    }
}

public enum BadgePosition: String, Codable, Sendable, CaseIterable {
    case bottomTrailing, bottomLeading, topTrailing, topLeading

    public var displayName: String {
        switch self {
        case .bottomTrailing: return "Bottom right"
        case .bottomLeading:  return "Bottom left"
        case .topTrailing:    return "Top right"
        case .topLeading:     return "Top left"
        }
    }
}

public enum BadgeShape: String, Codable, Sendable, CaseIterable {
    case circle, roundedRect

    public var displayName: String {
        switch self {
        case .circle: return "Circle"
        case .roundedRect: return "Rounded"
        }
    }
}

public struct BadgeSpec: Codable, Hashable, Sendable {
    /// Fraction of the icon's edge taken by the badge's short side. Clamped 0.22...0.5.
    public var scale: Double
    public var position: BadgePosition
    public var shape: BadgeShape
    /// `#RRGGBB`. Validated on construction; falls back to the default on garbage.
    public var colorHex: String
    /// Draw a light ring around the badge so it survives on same-colour icons.
    public var outlined: Bool

    public static let defaultColor = "#1B6EF3"

    public init(scale: Double = 0.36,
                position: BadgePosition = .bottomTrailing,
                shape: BadgeShape = .circle,
                colorHex: String = BadgeSpec.defaultColor,
                outlined: Bool = true) {
        self.scale = BadgeSpec.clampScale(scale)
        self.position = position
        self.shape = shape
        self.colorHex = BadgeSpec.normalizeHex(colorHex) ?? BadgeSpec.defaultColor
        self.outlined = outlined
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? 0.36
        let position = try c.decodeIfPresent(BadgePosition.self, forKey: .position) ?? .bottomTrailing
        let shape = try c.decodeIfPresent(BadgeShape.self, forKey: .shape) ?? .circle
        let hex = try c.decodeIfPresent(String.self, forKey: .colorHex) ?? BadgeSpec.defaultColor
        let outlined = try c.decodeIfPresent(Bool.self, forKey: .outlined) ?? true
        self.init(scale: scale, position: position, shape: shape, colorHex: hex, outlined: outlined)
    }

    public static func clampScale(_ v: Double) -> Double {
        guard v.isFinite else { return 0.36 }
        return min(max(v, 0.22), 0.5)
    }

    /// Accepts `#RGB`, `#RRGGBB`, `RGB`, `RRGGBB` (any case). Returns canonical `#RRGGBB`.
    public static func normalizeHex(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.allSatisfy({ $0.isHexDigit }) else { return nil }
        if s.count == 3 {
            s = s.map { "\($0)\($0)" }.joined()
        }
        guard s.count == 6 else { return nil }
        return "#" + s
    }

    /// Returns (r, g, b) in 0...1.
    public var rgb: (Double, Double, Double) {
        let s = colorHex.dropFirst()
        let v = UInt32(s, radix: 16) ?? 0x1B6EF3
        return (Double((v >> 16) & 0xFF) / 255.0,
                Double((v >> 8) & 0xFF) / 255.0,
                Double(v & 0xFF) / 255.0)
    }

    /// A stable palette so instance 1..n get visually distinct badges by default.
    /// Number is always the primary identifier; colour is decoration only, because
    /// colour alone is not accessible.
    public static func suggestedColor(forNumber n: Int) -> String {
        let palette = ["#1B6EF3", "#E5484D", "#12A594", "#F76B15",
                       "#8E4EC6", "#0090FF", "#D6409F", "#46A758"]
        guard n > 0 else { return palette[0] }
        return palette[(n - 1) % palette.count]
    }
}

    public struct Instance: Codable, Identifiable, Hashable, Sendable {
    /// Immutable for the lifetime of the instance.
    public let id: UUID
    /// Immutable for this instance. Existing instances are never renumbered implicitly;
    /// ordinary creation fills the lowest currently available positive number.
    public let number: Int

    public var name: String
    public var accountLabel: String
    public var mode: InstanceMode
    /// How this instance is kept separate. `userDataDir` for desktop apps,
    /// `configEnvironment` for command line tools.
    public var mechanism: IsolationMechanism
    /// Absolute path to the launcher bundle (`full`: the clone, `lite`: our shim bundle).
    public var bundlePath: String
    /// Absolute path to this instance's own directory: the `--user-data-dir` for an app,
    /// the value of the config variable (e.g. `CODEX_HOME`) for a tool.
    public var dataPath: String
    public var badge: BadgeSpec
    /// Source app version this instance's bundle was built from. Drives the
    /// "source updated — rebuild available" indicator.
    public var builtFromSourceVersion: String
    /// Bundle identifier written into the generated Full clone or Lite launcher.
    public var clonedBundleIdentifier: String
    public var extraArguments: [String]
    public var extraEnvironment: [String: String]
    public var createdAt: Date
    public var lastLaunchedAt: Date?
    /// When the user accepted the shared-credential-store consequence for **this**
    /// instance, or `nil` if they never did.
    ///
    /// This is the acknowledgement itself, recorded once at the moment it is given. It
    /// used to be inferred from `mode == .lite`, which is not the same statement: an
    /// instance can be Lite because a build degraded, because a registry was edited by
    /// hand, or because it predates the gate. Consent is a fact about what the user was
    /// shown, so it is stored rather than reconstructed.
    ///
    /// Absent in registries written before this field existed, which decodes to `nil` —
    /// those instances are un-acknowledged and are asked again.
    public var acknowledgedSharedCredentialStoreAt: Date?
    /// Non-fatal issues recorded at build time, surfaced in the UI.
    public var buildNotes: [String]

    public init(id: UUID = UUID(),
                number: Int,
                name: String,
                accountLabel: String = "",
                mode: InstanceMode = .full,
                mechanism: IsolationMechanism = .userDataDir,
                bundlePath: String,
                dataPath: String,
                badge: BadgeSpec = BadgeSpec(),
                builtFromSourceVersion: String = "",
                clonedBundleIdentifier: String = "",
                extraArguments: [String] = [],
                extraEnvironment: [String: String] = [:],
                createdAt: Date = Date(),
                lastLaunchedAt: Date? = nil,
                acknowledgedSharedCredentialStoreAt: Date? = nil,
                buildNotes: [String] = []) {
        self.id = id
        self.number = number
        self.name = name
        self.accountLabel = accountLabel
        self.mode = mode
        self.mechanism = mechanism
        self.bundlePath = bundlePath
        self.dataPath = dataPath
        self.badge = badge
        self.builtFromSourceVersion = builtFromSourceVersion
        self.clonedBundleIdentifier = clonedBundleIdentifier
        self.extraArguments = extraArguments
        self.extraEnvironment = extraEnvironment
        self.createdAt = createdAt
        self.lastLaunchedAt = lastLaunchedAt
        self.acknowledgedSharedCredentialStoreAt = acknowledgedSharedCredentialStoreAt
        self.buildNotes = buildNotes
    }

    /// Decoding is written by hand so that a registry written by an older build still
    /// loads: every field added after v1 has a default rather than being required. The
    /// alternative — a failed decode — would lose the user's numbering, which is the one
    /// thing the product promises never to lose.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        number = try c.decode(Int.self, forKey: .number)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        accountLabel = try c.decodeIfPresent(String.self, forKey: .accountLabel) ?? ""
        mode = try c.decodeIfPresent(InstanceMode.self, forKey: .mode) ?? .full
        mechanism = try c.decodeIfPresent(IsolationMechanism.self, forKey: .mechanism) ?? .userDataDir
        bundlePath = try c.decode(String.self, forKey: .bundlePath)
        dataPath = try c.decode(String.self, forKey: .dataPath)
        badge = try c.decodeIfPresent(BadgeSpec.self, forKey: .badge) ?? BadgeSpec()
        builtFromSourceVersion = try c.decodeIfPresent(String.self, forKey: .builtFromSourceVersion) ?? ""
        clonedBundleIdentifier = try c.decodeIfPresent(String.self, forKey: .clonedBundleIdentifier) ?? ""
        extraArguments = try c.decodeIfPresent([String].self, forKey: .extraArguments) ?? []
        extraEnvironment = try c.decodeIfPresent([String: String].self, forKey: .extraEnvironment) ?? [:]
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        lastLaunchedAt = try c.decodeIfPresent(Date.self, forKey: .lastLaunchedAt)
        // Absent in every registry written before the field existed. `nil` is the
        // conservative reading — no record of consent means no consent — and it is why
        // the field is optional rather than defaulted to something.
        acknowledgedSharedCredentialStoreAt = try c.decodeIfPresent(
            Date.self, forKey: .acknowledgedSharedCredentialStoreAt)
        buildNotes = try c.decodeIfPresent([String].self, forKey: .buildNotes) ?? []
    }

    /// "Claude 2 – Work". Used for the bundle filename and CFBundleDisplayName.
    public func displayTitle(sourceName: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "\(sourceName) \(number)" }
        return "\(sourceName) \(number) – \(trimmed)"
    }
}

public struct ManagedApp: Codable, Identifiable, Hashable, Sendable {
    public var id: String { appKey }
    /// The *original* app's bundle identifier. Stable key.
    public var appKey: String
    public var displayName: String
    public var sourcePath: String
    /// Security-scoped bookmark so we keep read access if the user moves the app.
    public var sourceBookmark: Data?
    public var sourceVersion: String
    /// High-water safety value retained for compatibility with older registries.
    /// Availability is determined from the live instance numbers.
    public var nextInstanceNumber: Int
    public var instances: [Instance]

    public init(appKey: String,
                displayName: String,
                sourcePath: String,
                sourceBookmark: Data? = nil,
                sourceVersion: String = "",
                nextInstanceNumber: Int = 1,
                instances: [Instance] = []) {
        self.appKey = appKey
        self.displayName = displayName
        self.sourcePath = sourcePath
        self.sourceBookmark = sourceBookmark
        self.sourceVersion = sourceVersion
        self.nextInstanceNumber = nextInstanceNumber
        self.instances = instances
    }

    public func instance(withNumber n: Int) -> Instance? {
        instances.first { $0.number == n }
    }

    /// The numbers the next `count` instances would be given: the lowest ones not
    /// currently in use. Shown in the create flow so the numbers on screen are the
    /// numbers you get.
    public func nextAvailableNumbers(count: Int) -> [Int] {
        NumberAllocator.allocate(count: count,
                                 from: nextInstanceNumber,
                                 existing: instances.map(\.number)).numbers
    }

    /// Instances whose bundle was built from an older source version.
    public var staleInstances: [Instance] {
        guard !sourceVersion.isEmpty else { return [] }
        return instances.filter { $0.mode == .full && $0.builtFromSourceVersion != sourceVersion }
    }
}

public struct RegistryDocument: Codable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var apps: [ManagedApp]

    public init(schemaVersion: Int = RegistryDocument.currentSchemaVersion,
                apps: [ManagedApp] = []) {
        self.schemaVersion = schemaVersion
        self.apps = apps
    }
}
