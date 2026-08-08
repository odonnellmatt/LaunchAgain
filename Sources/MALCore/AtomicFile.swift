import Foundation

/// Crash-safe file writing.
///
/// The registry is the single source of truth for instance numbers. If it is ever
/// half-written, the user loses the mapping between bundles on disk and their
/// numbers — which is exactly the failure the spec forbids. So every write is:
///
///   1. write the new bytes to a temporary file in the *same directory*,
///   2. fsync/full-fsync the temporary file,
///   3. atomically install the same committed bytes as `<name>.bak`,
///   4. atomically install them as the primary file,
///   5. fsync the containing directory after each rename.
///
/// The backup is a redundant copy of the committed document, not the previous logical
/// state. That distinction matters for deletion: a removed instance must not survive in
/// `registry.json.bak` and later be resurrected after primary-file damage. Installing the
/// backup first also means a failed primary rename leaves the old primary intact.
public enum AtomicFile {

    public static func write(_ data: Data, to url: URL, keepBackup: Bool = true) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        if keepBackup {
            try replace(data, at: url.appendingPathExtension("bak"))
        }
        try replace(data, at: url)
    }

    private static func replace(_ data: Data, at url: URL) throws {
        let dir = url.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(
            ".\(url.lastPathComponent).tmp-\(getpid())-\(UUID().uuidString.prefix(8))")

        // Write and flush to stable storage before making the name visible.
        guard let out = FileHandle(forWritingAtPath: tmp.path) ?? {
            FileManager.default.createFile(atPath: tmp.path, contents: nil)
            return FileHandle(forWritingAtPath: tmp.path)
        }() else {
            throw MALError.invalidPath(tmp.path, reason: "could not create temporary file")
        }
        do {
            try out.write(contentsOf: data)
            try out.synchronize()
#if os(macOS)
            // `synchronize()` provides the normal fsync guarantee. Ask macOS for a
            // full device-cache flush as well so registry/config commits survive an
            // immediate restart or power transition whenever the volume supports it.
            // Some virtual/network filesystems return ENOTSUP; the completed fsync is
            // still the strongest guarantee available there.
            _ = fcntl(out.fileDescriptor, F_FULLFSYNC)
#endif
            try out.close()
        } catch {
            try? out.close()
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }

        // Atomic replacement. `rename(2)` replaces an existing regular file.
        let ok = rename(tmp.path, url.path) == 0
        if !ok {
            let err = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: tmp)
            throw MALError.invalidPath(url.path, reason: "atomic rename failed: \(err)")
        }

        // Make the directory entry itself durable.
        syncDirectory(dir)
    }

    /// Reads `url`, transparently falling back to `<url>.bak` if the primary file is
    /// missing or fails the caller's parse. Returns nil when neither exists.
    public static func readWithFallback(_ url: URL,
                                        parse: (Data) throws -> Bool) -> (data: Data, usedBackup: Bool)? {
        if let d = try? Data(contentsOf: url), (try? parse(d)) == true {
            return (d, false)
        }
        let bak = url.appendingPathExtension("bak")
        if let d = try? Data(contentsOf: bak), (try? parse(d)) == true {
            return (d, true)
        }
        return nil
    }

    private static func syncDirectory(_ dir: URL) {
        let fd = open(dir.path, O_RDONLY)
        guard fd >= 0 else { return }
        _ = fsync(fd)
        close(fd)
    }
}
