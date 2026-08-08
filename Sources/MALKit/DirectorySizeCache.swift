#if canImport(Darwin)
import Foundation
import MALCore

/// A small, bounded cache for expensive directory walks.
///
/// Chromium profiles contain many thousands of tiny files. Walking every profile after
/// every registry event made both `doctor` and the dashboard needlessly expensive. This
/// cache is shared by Health, the dashboard, diagnostics and the CLI. Entries expire, so
/// displayed sizes remain approximate rather than silently becoming permanent facts.
public final class DirectorySizeCache: @unchecked Sendable {

    private struct Entry: Codable, Equatable {
        var bytes: Int64
        var measuredAt: Date
        var directoryModificationDate: Date?
    }

    private struct Store: Codable {
        var entries: [String: Entry]
    }

    private let condition = NSCondition()
    private let cacheFile: URL
    private let maxAge: TimeInterval
    private let maxEntries: Int
    private let measure: (URL) -> Int64
    private var entries: [String: Entry]
    private var inFlight: Set<String> = []

    /// When false, measurements are cached in memory but never written to disk.
    ///
    /// `scan` and `inspect` read as read-only commands and were not: both measure bundle
    /// sizes, and every measurement persisted `icon-cache/directory-sizes.json` inside
    /// the store. That is how a reviewer running `inspect` modified the user's real
    /// store while trying not to touch it.
    private let persistsToDisk: Bool

    public init(paths: MALPaths,
                maxAge: TimeInterval = 10 * 60,
                maxEntries: Int = 512,
                persistsToDisk: Bool = true,
                measure: @escaping (URL) -> Int64 = FSOps.directorySize) {
        self.persistsToDisk = persistsToDisk
        self.cacheFile = paths.directorySizeCacheFile
        self.maxAge = max(0, maxAge)
        self.maxEntries = max(1, maxEntries)
        self.measure = measure
        if let data = try? Data(contentsOf: paths.directorySizeCacheFile),
           let store = try? JSONDecoder().decode(Store.self, from: data) {
            self.entries = store.entries
        } else {
            self.entries = [:]
        }
    }

    /// Returns a fresh-enough value without starting a filesystem walk.
    public func cachedSize(of url: URL, now: Date = Date()) -> Int64? {
        let path = url.standardizedFileURL.path
        condition.lock()
        defer { condition.unlock() }
        return validEntry(for: path, url: url, now: now)?.bytes
    }

    /// Returns a cached value or measures the directory exactly once.
    ///
    /// Concurrent callers for the same path wait for the first measurement instead of
    /// starting duplicate directory enumerators, bounding both memory and I/O pressure.
    public func size(of url: URL,
                     now: Date = Date(),
                     onScanStart: ((String) -> Void)? = nil) -> Int64 {
        let standardized = url.standardizedFileURL
        let path = standardized.path

        condition.lock()
        if let entry = validEntry(for: path, url: standardized, now: now) {
            condition.unlock()
            return entry.bytes
        }
        while inFlight.contains(path) {
            condition.wait()
            if let entry = entries[path] {
                condition.unlock()
                return entry.bytes
            }
        }
        inFlight.insert(path)
        condition.unlock()

        onScanStart?(path)
        let bytes = measure(standardized)
        let entry = Entry(bytes: bytes,
                          measuredAt: now,
                          directoryModificationDate: modificationDate(of: standardized))

        condition.lock()
        entries[path] = entry
        pruneIfNeeded()
        inFlight.remove(path)
        let snapshot = Store(entries: entries)
        condition.broadcast()
        condition.unlock()

        persist(snapshot)
        return bytes
    }

    /// Drops entries for paths that no longer exist, keeping the on-disk cache bounded
    /// even when instances are regularly created and removed.
    public func pruneMissingPaths() {
        condition.lock()
        let before = entries
        entries = entries.filter { FileManager.default.fileExists(atPath: $0.key) }
        let gone = Set(before.keys).subtracting(entries.keys)
        let snapshot = Store(entries: entries)
        condition.unlock()
        if before != snapshot.entries { persist(snapshot, removing: gone) }
    }

    /// Removes metadata for paths that no longer belong to an installed instance.
    ///
    /// This is called as part of a completed uninstall so even the small, shared size
    /// cache no longer contains a record keyed by that instance's profile path.
    public func invalidate(_ urls: [URL]) {
        let paths = Set(urls.map { $0.standardizedFileURL.path })
        guard !paths.isEmpty else { return }
        condition.lock()
        let before = entries
        for path in paths {
            entries.removeValue(forKey: path)
        }
        let snapshot = Store(entries: entries)
        condition.unlock()
        if before != snapshot.entries { persist(snapshot, removing: paths) }
    }

    private func validEntry(for path: String, url: URL, now: Date) -> Entry? {
        guard let entry = entries[path],
              now.timeIntervalSince(entry.measuredAt) <= maxAge,
              entry.directoryModificationDate == modificationDate(of: url) else {
            return nil
        }
        return entry
    }

    private func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private func pruneIfNeeded() {
        guard entries.count > maxEntries else { return }
        let oldest = entries.sorted { $0.value.measuredAt < $1.value.measuredAt }
        for (path, _) in oldest.prefix(entries.count - maxEntries) {
            entries.removeValue(forKey: path)
        }
    }

    /// Merges this process's measurements into whatever is on disk, under the same
    /// advisory lock the rest of the product uses.
    ///
    /// This wrote a whole-file snapshot of in-memory state and never re-read `entries`
    /// after init, so a live GUI and a CLI simply erased each other's measurements. The
    /// impact is bounded — it is a cache, and a lost entry costs one re-walk — but
    /// defeating its own purpose is not a useful property for a cache to have.
    ///
    /// On conflict the newer measurement wins, since both are honest observations of the
    /// same directory at different times.
    private func persist(_ store: Store, removing dropped: Set<String> = []) {
        guard persistsToDisk else { return }
#if canImport(Darwin) || canImport(Glibc)
        let lockURL = cacheFile.appendingPathExtension("lock")
        let fd = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        if fd >= 0 {
            defer {
                _ = flock(fd, LOCK_UN)
                close(fd)
            }
            if flock(fd, LOCK_EX) == 0 {
                var merged = store.entries
                if let data = try? Data(contentsOf: cacheFile),
                   let onDisk = try? JSONDecoder().decode(Store.self, from: data) {
                    for (path, entry) in onDisk.entries {
                        // A path this write is deliberately dropping must not come back
                        // from disk. Invalidation after an uninstall is the case that
                        // matters: merging blindly re-created the entry keyed by the
                        // profile path of the instance that was just removed.
                        guard !dropped.contains(path) else { continue }
                        if let ours = merged[path] {
                            if entry.measuredAt > ours.measuredAt { merged[path] = entry }
                        } else {
                            merged[path] = entry
                        }
                    }
                }
                if let data = try? JSONEncoder().encode(Store(entries: merged)) {
                    try? AtomicFile.write(data, to: cacheFile, keepBackup: false)
                }
                return
            }
        }
#endif
        guard let data = try? JSONEncoder().encode(store) else { return }
        try? AtomicFile.write(data, to: cacheFile, keepBackup: false)
    }
}
#endif
