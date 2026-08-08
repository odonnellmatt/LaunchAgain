import Foundation

/// A staged, rollback-capable sequence of side effects.
///
/// Building an instance touches a lot of state: a data directory, a staged bundle, a
/// rename into `~/Applications`, a Launch Services registration, a registry entry.
/// The requirement is that a failure at any step leaves *nothing* behind — no orphan
/// bundle, no orphan data directory, no half-written registry.
///
/// Steps run in order. On failure, every step that already succeeded is undone in
/// reverse order. Rollback failures are collected rather than thrown, because a
/// failing rollback must not mask the original error.
public final class Transaction {

    public struct Step {
        public let name: String
        public let perform: () throws -> Void
        public let rollback: (() throws -> Void)?

        public init(name: String,
                    perform: @escaping () throws -> Void,
                    rollback: (() throws -> Void)? = nil) {
            self.name = name
            self.perform = perform
            self.rollback = rollback
        }
    }

    public private(set) var steps: [Step] = []
    public private(set) var completed: [String] = []
    private let label: String
    private let logger: MALLog?

    public init(label: String, logger: MALLog? = nil) {
        self.label = label
        self.logger = logger
    }

    @discardableResult
    public func add(_ name: String,
                    perform: @escaping () throws -> Void,
                    rollback: (() throws -> Void)? = nil) -> Transaction {
        steps.append(Step(name: name, perform: perform, rollback: rollback))
        return self
    }

    /// Runs the transaction. `progress` is called with (index, total, stepName) before
    /// each step so the UI can show real progress rather than a spinner.
    public func run(progress: ((Int, Int, String) -> Void)? = nil) throws {
        for (i, step) in steps.enumerated() {
            progress?(i, steps.count, step.name)
            logger?.debug("[\(label)] step \(i + 1)/\(steps.count): \(step.name)")
            do {
                try step.perform()
                completed.append(step.name)
            } catch {
                logger?.error("[\(label)] step \"\(step.name)\" failed: \(error)")
                let failures = rollbackCompleted()
                if failures.isEmpty {
                    if let m = error as? MALError { throw m }
                    throw MALError.buildFailed(step: step.name, underlying: "\(error)")
                } else {
                    throw MALError.rollbackIncomplete(
                        original: "\(step.name): \(error)",
                        rollbackFailures: failures)
                }
            }
        }
    }

    /// Undoes completed steps in reverse. Returns descriptions of rollback failures.
    @discardableResult
    public func rollbackCompleted() -> [String] {
        var failures: [String] = []
        for step in steps.prefix(completed.count).reversed() {
            guard let rb = step.rollback else { continue }
            do {
                try rb()
                logger?.debug("[\(label)] rolled back: \(step.name)")
            } catch {
                let msg = "\(step.name): \(error)"
                failures.append(msg)
                logger?.error("[\(label)] ROLLBACK FAILED \(msg)")
            }
        }
        completed.removeAll()
        return failures
    }
}

/// Filesystem helpers used by transaction steps, with rollback in mind.
public enum FSOps {

    /// Removes a path if it exists. Never throws for "already gone", because a rollback
    /// that runs after a partial delete must still succeed.
    public static func removeIfExists(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Moves an item to the user's Trash, falling back to deleting it outright if the
    /// volume has no Trash (a disk image, a network share).
    ///
    /// Deleting is the one irreversible thing this program does, so it prefers the Trash:
    /// a user who removes the wrong instance can drag it back out, and macOS shows the
    /// removal in the place people already look for removals.
    @discardableResult
    public static func moveToTrash(_ url: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        do {
            var resulting: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
            return true
        } catch {
            try FileManager.default.removeItem(at: url)
            return false
        }
    }

    /// Moves `src` to `dst` atomically. Both must be on the same filesystem, which is
    /// why staging lives inside the destination directory.
    public static func atomicMove(_ src: URL, to dst: URL) throws {
        try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        if rename(src.path, dst.path) == 0 { return }
        // Cross-device or another benign failure: fall back to a copy + delete, which
        // is not atomic but is still all-or-nothing from the caller's perspective
        // because we remove a partial destination on failure.
        do {
            try FileManager.default.moveItem(at: src, to: dst)
        } catch {
            try? FileManager.default.removeItem(at: dst)
            throw MALError.buildFailed(step: "move", underlying:
                "could not move \(src.lastPathComponent) into place: \(error)")
        }
    }

    /// Byte size of a directory tree. Used for the storage figures in the UI.
    public static func directorySize(_ url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
            options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0

#if canImport(ObjectiveC)
        // Chromium profiles can contain hundreds of thousands of files. Foundation's
        // directory enumerator and resource-value lookup create autoreleased objects;
        // leaving the only pool at the dispatch-work-item boundary lets all of those
        // objects accumulate for the duration of one large scan. Drain them in bounded
        // batches while retaining only the Int64 total.
        let batchLimit = 256
        while true {
            let visited = autoreleasepool { () -> Int in
                var count = 0
                while count < batchLimit, let value = e.nextObject() {
                    count += 1
                    guard let file = value as? URL else { continue }
                    let values = try? file.resourceValues(
                        forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
                    total += Int64(
                        values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
                }
                return count
            }
            if visited == 0 { break }
        }
#else
        for case let file as URL in e {
            let values = try? file.resourceValues(
                forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            total += Int64(
                values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
#endif
        return total
    }

    public static func humanBytes(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        // Bytes and kilobytes included: restricting the formatter to MB and GB reported a
        // 30-byte removal marker as "0 MB", which reads as "nothing is there" for a
        // finding whose whole point is that something is.
        f.allowedUnits = bytes < 1024 * 1024 ? [.useBytes, .useKB] : [.useMB, .useGB]
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }
}
