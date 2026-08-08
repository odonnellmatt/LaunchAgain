import Foundation

/// Every path the product owns, in one place.
///
/// `root` is injectable so the unit tests operate on a real temporary directory
/// rather than the user's home — the transaction and rollback tests are only
/// meaningful against a real filesystem.
public struct MALPaths: Sendable {

    /// `~/Library/Application Support/LaunchAgain`
    public let support: URL
    /// `~/Applications/LaunchAgain` — user-writable, needs no admin rights, and is
    /// indexed by Spotlight and Launchpad. The default home for every launcher.
    public let bundlesDir: URL
    /// `/Applications/LaunchAgain` — the second, and only other, place a launcher may
    /// live.
    ///
    /// Some applications refuse to run from anywhere but `/Applications`. LM Studio is
    /// the measured case: its bundled code tests the install location against the
    /// literal prefix `/Applications/`, logs "App is not running from /Applications" and
    /// then never opens a window. A clone one directory *inside* `/Applications`
    /// satisfies that test — verified — so this is a single owned directory rather than
    /// launchers scattered across `/Applications`.
    ///
    /// That distinction is the whole point. The ownership boundary widens from one root
    /// to exactly two named roots; it does not become "anything under /Applications".
    /// `assertDeletable` and `assertLauncherBundlePath` still answer from a fixed list.
    public let systemBundlesDir: URL
    /// The current user's Library directory. Explicit rather than derived during
    /// deletion so tests and alternate roots can never reach the real home directory.
    public let userLibrary: URL

    /// Every directory a generated launcher may live in, most-preferred first. This is
    /// the list every ownership check, sweep and reconciliation walks.
    public var bundleRoots: [URL] { [bundlesDir, systemBundlesDir] }

    public init(support: URL,
                bundlesDir: URL,
                systemBundlesDir: URL? = nil,
                userLibrary: URL? = nil) {
        self.support = support
        self.bundlesDir = bundlesDir
        // Defaulted rather than optional so no caller has to handle "there is no second
        // root"; for a rooted test store it is simply another directory inside the root.
        self.systemBundlesDir = systemBundlesDir
            ?? bundlesDir.deletingLastPathComponent()
                .appendingPathComponent("\(bundlesDir.lastPathComponent)-system")
        if let userLibrary {
            self.userLibrary = userLibrary
        } else if let libraryIndex = support.standardizedFileURL.pathComponents
            .lastIndex(of: "Library") {
            self.userLibrary = URL(
                fileURLWithPath: NSString.path(
                    withComponents: Array(
                        support.standardizedFileURL.pathComponents.prefix(libraryIndex + 1))))
        } else {
            self.userLibrary = support.appendingPathComponent("user-library")
        }
    }

    public static func standard(home: URL? = nil) -> MALPaths {
        let h = home ?? URL(fileURLWithPath: NSHomeDirectory())
        return MALPaths(
            support: h.appendingPathComponent("Library/Application Support/LaunchAgain"),
            bundlesDir: h.appendingPathComponent("Applications/LaunchAgain"),
            // Absolute, and not derived from `home`, because this is the real system
            // location. An injected home is for tests, and a test that reached
            // /Applications would not be a test.
            systemBundlesDir: home == nil
                ? URL(fileURLWithPath: "/Applications/LaunchAgain")
                : h.appendingPathComponent("System-Applications/LaunchAgain"),
            userLibrary: h.appendingPathComponent("Library")
        )
    }

    /// Where the first release kept everything, before the product was renamed.
    /// `Migration` moves these aside on first run; nothing else should reference them.
    public static func legacy(home: URL? = nil) -> MALPaths {
        let h = home ?? URL(fileURLWithPath: NSHomeDirectory())
        return MALPaths(
            support: h.appendingPathComponent("Library/Application Support/MultipleAppsLauncher"),
            bundlesDir: h.appendingPathComponent("Applications/Multiple Apps Launcher"),
            userLibrary: h.appendingPathComponent("Library")
        )
    }

    /// A fully self-contained tree, used by tests and by `launchagain --root`.
    public static func rooted(at root: URL) -> MALPaths {
        MALPaths(support: root.appendingPathComponent("support"),
                 bundlesDir: root.appendingPathComponent("bundles"),
                 systemBundlesDir: root.appendingPathComponent("system-bundles"),
                 userLibrary: root.appendingPathComponent("user-library"))
    }

    public var registryFile: URL { support.appendingPathComponent("registry.json") }
    /// IDs explicitly removed by the user. Launcher reconciliation skips these, which
    /// prevents a delayed filesystem event or a half-finished Trash operation from
    /// resurrecting something the user just deleted.
    public var removalTombstonesDir: URL { support.appendingPathComponent("removed-instances") }
    public var instancesDir: URL { support.appendingPathComponent("instances") }
    /// One file per instance number that has been drawn but not yet committed to the
    /// registry. The reserving process holds an advisory lock on each for the whole
    /// build, which is what makes a reservation visible to other processes and what
    /// releases it if that process dies. See `Registry.reserveNumbers`.
    public var numberReservationsDir: URL { support.appendingPathComponent("number-reservations") }
    public var iconCacheDir: URL { support.appendingPathComponent("icon-cache") }
    public var directorySizeCacheFile: URL { iconCacheDir.appendingPathComponent("directory-sizes.json") }
    public var logsDir: URL { support.appendingPathComponent("logs") }

    /// Staging lives *inside* the destination directory on purpose: `rename(2)` is only
    /// atomic within a single filesystem, and `~/Applications` may be on a different
    /// volume from `/tmp`.
    public var stagingDir: URL { stagingDir(in: bundlesDir) }

    /// Staging for one launcher root. A build that will land in `/Applications/LaunchAgain`
    /// must stage there too, for the same reason: the move into place has to be a rename
    /// within one filesystem, not a copy across two.
    public func stagingDir(in root: URL) -> URL {
        root.appendingPathComponent(".staging")
    }

    /// The launcher root that contains `path`, or nil when it is in neither.
    public func bundleRoot(containing path: String) -> URL? {
        let candidate = Validation.canonicalFilesystemPath(path)
        return bundleRoots.first {
            let root = Validation.canonicalFilesystemPath($0.path)
            return candidate != root && Validation.isPath(candidate, within: root)
        }
    }

    public func instanceDir(_ id: UUID) -> URL {
        instancesDir.appendingPathComponent(id.uuidString)
    }
    public func instanceDataDir(_ id: UUID) -> URL {
        instanceDir(id).appendingPathComponent("userdata")
    }
    public func instanceLogsDir(_ id: UUID) -> URL {
        instanceDir(id).appendingPathComponent("logs")
    }
    public func instanceLockFile(_ id: UUID) -> URL {
        instanceDir(id).appendingPathComponent("instance.lock")
    }
    public func removalTombstoneFile(_ id: UUID) -> URL {
        removalTombstonesDir.appendingPathComponent("\(id.uuidString).removed")
    }

    public func createAll() throws {
        for d in [support, bundlesDir, instancesDir, iconCacheDir, logsDir,
                  removalTombstonesDir, numberReservationsDir, stagingDir] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        // Keep the staging directory out of Spotlight and out of the user's way.
        let marker = stagingDir.appendingPathComponent(".metadata_never_index")
        if !FileManager.default.fileExists(atPath: marker.path) {
            _ = FileManager.default.createFile(atPath: marker.path, contents: Data())
        }
        // The system root is deliberately *not* created here. /Applications is
        // admin-writable rather than user-writable, so creating it on every start would
        // make an ordinary launch fail on a managed Mac for a directory most users never
        // need. It is created on demand, by `prepareBundleRoot`, with a message that
        // says what to do.
    }

    /// Creates a launcher root if it does not exist, and reports a permission failure in
    /// terms the user can act on.
    ///
    /// No privilege escalation and no helper: if the user cannot write to
    /// `/Applications`, the honest answers are "ask an administrator" or "install this
    /// instance in your own Applications folder instead", and this says so.
    public func prepareBundleRoot(_ root: URL) throws {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: root.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw MALError.invalidPath(
                    root.path,
                    reason: "a file is in the way of the launcher directory")
            }
            guard fm.isWritableFile(atPath: root.path) else {
                throw MALError.invalidPath(root.path, reason: notWritableReason(root))
            }
            return
        }
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            throw MALError.invalidPath(root.path, reason: notWritableReason(root))
        }
        let staging = stagingDir(in: root)
        try? fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let marker = staging.appendingPathComponent(".metadata_never_index")
        if !fm.fileExists(atPath: marker.path) {
            _ = fm.createFile(atPath: marker.path, contents: Data())
        }
    }

    /// Two different failures, which used to produce the same sentence.
    ///
    /// **On the word `sudo`.** The exists-but-read-only branch suggests
    /// `sudo chown -R $(whoami) <path>`, and that is deliberate: it is the shortest
    /// correct answer to "how do I get write access to this directory", and it is
    /// printed for the user to read, decide about and run themselves in a terminal.
    /// LaunchAgain never runs it. The product does not escalate, does not install a
    /// privileged helper and does not prompt for a password — `ProcessRunner.Tool`
    /// enumerates every executable it will ever launch and none of them is `sudo` —
    /// which is what the sentence appended below says in as many words. Suggesting a
    /// command and executing one are different acts, and the documents now say which
    /// this is rather than claiming the word never appears.
    ///
    /// "Ask an administrator to create /Applications/LaunchAgain" is wrong advice when
    /// /Applications/LaunchAgain already exists and is merely read-only, and the old
    /// message said it anyway. It also offered "install in your own Applications folder
    /// instead", which is not a choice the interface exposes — and for the one
    /// application that needs this directory, LM Studio, it is the single place the app
    /// will not run.
    private func notWritableReason(_ root: URL) -> String {
        let fm = FileManager.default
        let parent = root.deletingLastPathComponent().path
        let common = " LaunchAgain does not ask for administrator rights, does not "
            + "install a helper tool and does not run any command for you, so this is "
            + "something to change outside it."

        if fm.fileExists(atPath: root.path) {
            return "\(root.path) exists but LaunchAgain cannot write to it, so it cannot "
                + "install a launcher there. An administrator can give you write access "
                + "to that directory — for example with "
                + "`sudo chown -R $(whoami) \(root.path)`." + common
        }
        return "LaunchAgain cannot create \(root.path), because it cannot write to "
            + "\(parent). That directory usually needs an administrator. Ask one to "
            + "create \(root.path) and give you write access to it." + common
    }

    /// Guard for every destructive operation: we refuse to delete anything that is not
    /// demonstrably below a directory we own. The roots themselves are never valid
    /// targets: one damaged registry value must not be able to erase every instance.
    public func assertDeletable(_ path: String) throws {
        let standardized = Validation.canonicalFilesystemPath(path)
        // A fixed list of named roots, not a rule about /Applications. Adding the
        // system root widened this by exactly one directory; nothing else under
        // /Applications became deletable, and a bundle sitting beside our directory is
        // still refused here before any ownership check even runs.
        let roots = ([support] + bundleRoots).map { Validation.canonicalFilesystemPath($0.path) }
        let ok = roots.contains { root in
            standardized != root && Validation.isPath(standardized, within: root)
        }
        guard ok else {
            throw MALError.invalidPath(path, reason: "refusing to delete outside the launcher's own directories")
        }
    }

    /// A generated launcher is always one immediate `.app` child of one of the launcher
    /// roots. Nested paths are rejected so an intermediate symlink cannot redirect
    /// deletion, and a `.app` sitting directly in `/Applications` — beside our directory
    /// rather than inside it — is rejected here, before any ownership check runs.
    public func assertLauncherBundlePath(_ path: String) throws {
        let candidate = URL(fileURLWithPath: path).standardizedFileURL
        let parent = candidate.deletingLastPathComponent().standardizedFileURL
        let inARoot = bundleRoots.contains { root in
            Validation.pathsReferToSameLocation(parent.path, root.path)
                && !Validation.pathsReferToSameLocation(candidate.path, root.path)
        }
        guard candidate.pathExtension.lowercased() == "app", inARoot else {
            throw MALError.invalidPath(
                path,
                reason: "a launcher must be an immediate .app child of a LaunchAgain applications directory")
        }
    }

    /// The only profile/log/lock directory owned by an instance is the UUID-derived
    /// directory returned by `instanceDir`.
    public func assertInstanceDirectory(_ path: String, for id: UUID) throws {
        guard Validation.pathsReferToSameLocation(path, instanceDir(id).path) else {
            throw MALError.invalidPath(
                path,
                reason: "the instance directory does not match instance \(id.uuidString)")
        }
    }

    public func assertRemovalTombstone(_ path: String, for id: UUID) throws {
        guard Validation.pathsReferToSameLocation(path, removalTombstoneFile(id).path) else {
            throw MALError.invalidPath(path, reason: "the removal marker does not match this instance")
        }
    }
}
