import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Structured, local-only logging.
///
/// Logs are written to plain files under the launcher's own support directory and are
/// never transmitted anywhere. The diagnostics export bundles these files and
/// deliberately excludes the contents of any instance data directory, which is where
/// tokens and cookies live.
public final class MALLog: @unchecked Sendable {

    public enum Level: Int, Comparable, Sendable {
        case debug = 0, info = 1, warn = 2, error = 3
        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
        var tag: String {
            switch self {
            case .debug: return "DEBUG"
            case .info:  return "INFO "
            case .warn:  return "WARN "
            case .error: return "ERROR"
            }
        }
    }

    public var minimumLevel: Level
    private let fileURL: URL?
    private let queue = DispatchQueue(label: "com.mal.log")
    /// Guarded by `queue`, and only ever read or written under the log's file lock.
    private var redactionCache: RedactionCache?
    private let echoToStandardError: Bool
    private static let maximumRedactionFingerprints = 4_096
    private static let identityPatterns: [NSRegularExpression] = [
        try! NSRegularExpression(
            pattern: #"(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"#),
        try! NSRegularExpression(
            pattern: #"(?i)[a-z0-9][a-z0-9.-]*\.mal[1-9][0-9]*-[0-9a-f]{8}"#),
    ]

    public init(fileURL: URL?, minimumLevel: Level = .info, echoToStandardError: Bool = false) {
        self.fileURL = fileURL
        self.minimumLevel = minimumLevel
        self.echoToStandardError = echoToStandardError
        if let fileURL {
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            // `FileManager.createFile` truncates when another process creates the file
            // between an existence check and this call. O_CREAT without O_TRUNC, under
            // the same advisory lock used everywhere else, makes concurrent GUI/CLI
            // startup lossless.
            try? withFileLock(for: fileURL, operation: LOCK_EX) {
                try ensureLogFileExists(fileURL)
                try scrubPersistedRedactions(from: fileURL)
            }
        }
    }

    public static let silent = MALLog(fileURL: nil, minimumLevel: .error)

    public func debug(_ m: @autoclosure () -> String) { log(.debug, m()) }
    public func info(_ m: @autoclosure () -> String)  { log(.info, m()) }
    public func warn(_ m: @autoclosure () -> String)  { log(.warn, m()) }
    public func error(_ m: @autoclosure () -> String) { log(.error, m()) }

    public func log(_ level: Level, _ message: String) {
        guard level >= minimumLevel else { return }
        // One physical line is one record. Besides keeping diagnostics readable, this
        // gives instance-uninstall scrubbing an unambiguous record boundary.
        let safeMessage = message
            .replacingOccurrences(of: "\r\n", with: " ⏎ ")
            .replacingOccurrences(of: "\n", with: " ⏎ ")
            .replacingOccurrences(of: "\r", with: " ⏎ ")
        // `ISO8601DateFormatter` is mutable and is not safe to share across the GUI and
        // concurrent CLI writers. The value-type format style has the same output shape
        // without shared mutable state, and is accepted under Swift 6 strict concurrency.
        let timestamp = Date().formatted(
            Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        let line = "\(timestamp) \(level.tag) \(safeMessage)\n"
        // Synchronous serial appends avoid an unbounded queue during a noisy failure and
        // guarantee a short-lived CLI process does not exit with records still pending.
        queue.sync {
            guard let url = fileURL else {
                if echoToStandardError {
                    FileHandle.standardError.write(Data(line.utf8))
                }
                return
            }
            do {
                try withFileLock(for: url, operation: LOCK_EX) {
                    try ensureLogFileExists(url)
                    // Deliberately *not* a whole-file scrub. Suppressing this one record
                    // is enough, and re-reading and re-matching the entire log on every
                    // write made logging O(log size): once any instance had been
                    // uninstalled the sidecar was non-empty forever, and a single
                    // `doctor` went from 0.00s to 0.27s on an 18,000-record log.
                    //
                    // The guarantee survives because every writer takes this same lock
                    // and loads the sidecar inside it. A record either lands before the
                    // uninstall acquires the lock — and that scrub removes it — or after,
                    // and this check suppresses it. There is no third case. Whole-file
                    // scrubbing remains where it is cheap and where a log from an older
                    // build or an outside edit is actually caught: at rotation, which
                    // runs on every process start, and at uninstall itself.
                    let redactions = try cachedRedactionFingerprints(for: url)
                    guard !Self.record(line, matchesAny: redactions) else {
                        return
                    }
                    if echoToStandardError {
                        FileHandle.standardError.write(Data(line.utf8))
                    }
                    let h = try FileHandle(forWritingTo: url)
                    defer { try? h.close() }
                    _ = try h.seekToEnd()
                    try h.write(contentsOf: Data(line.utf8))
                }
            } catch {
                if echoToStandardError {
                    let diagnostic = "LaunchAgain log write failed: \(error)\n"
                    FileHandle.standardError.write(Data(diagnostic.utf8))
                }
            }
        }
    }

    /// Truncates the log to the most recent `keepBytes`, called at startup so logs
    /// cannot grow without bound on a machine that is never cleaned up.
    public func rotate(keepBytes: Int = 512 * 1024) {
        guard let url = fileURL else { return }
        queue.sync {
            try? withFileLock(for: url, operation: LOCK_EX) {
                try ensureLogFileExists(url)
                try scrubPersistedRedactions(from: url)
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                      let size = attrs[.size] as? Int, size > keepBytes * 2,
                      let data = try? Data(contentsOf: url) else { return }
                let tail = data.suffix(keepBytes)
                try AtomicFile.write(Data(tail), to: url, keepBackup: false)
            }
        }
    }

    public func readTail(_ bytes: Int = 64 * 1024) -> String {
        guard let url = fileURL else { return "" }
        return queue.sync {
            (try? withFileLock(for: url, operation: LOCK_EX) {
                try ensureLogFileExists(url)
                try scrubPersistedRedactions(from: url)
                guard let data = try? Data(contentsOf: url) else { return "" }
                return String(decoding: data.suffix(bytes), as: UTF8.self)
            }) ?? ""
        }
    }

    /// Removes complete log records carrying a deleted instance's durable identity.
    ///
    /// The queue barrier first drains this process's writes, then atomically replaces the
    /// shared log under an advisory lock also honoured by other LaunchAgain processes.
    /// A bounded sidecar stores only non-plaintext fingerprints of removed identities:
    /// if another current-version process had an append queued, that append is suppressed
    /// after the scrub rather than putting the identity back. Only the UUID and generated
    /// bundle identifier are accepted; broad user-controlled paths can never erase
    /// unrelated records.
    public func removeInstanceEntries(
        id: UUID,
        cloneIdentifier: String,
        additionalFiles: [URL] = []
    ) throws {
        let tokens = [id.uuidString, cloneIdentifier]
            .filter { $0.utf8.count >= 12 }
            .map { $0.lowercased() }
        guard !tokens.isEmpty else { return }
        try queue.sync {
            var targets: [URL] = []
            if let fileURL { targets.append(fileURL) }
            targets.append(contentsOf: additionalFiles.filter {
                FileManager.default.fileExists(atPath: $0.path)
            })
            var seenPaths: Set<String> = []
            targets = targets.filter {
                seenPaths.insert($0.standardizedFileURL.path).inserted
            }
            for url in targets {
                try withFileLock(for: url, operation: LOCK_EX) {
                    try ensureLogFileExists(url)
                    try persistRedactionFingerprints(
                        tokens.map(Self.fingerprint),
                        for: url)
                    let data = try Data(contentsOf: url)
                    let retained = Self.records(in: data).filter { record in
                        let folded = record.lowercased()
                        return !tokens.contains(where: { folded.contains($0) })
                    }
                    var output = retained.joined(separator: "\n")
                    if !output.isEmpty { output.append("\n") }
                    try AtomicFile.write(
                        Data(output.utf8),
                        to: url,
                        keepBackup: false)
                }
            }
        }
    }

    /// Synchronizes this logger's file after all preceding writes. Primarily useful to
    /// diagnostics and tests; normal application code does not need to call it.
    public func flush() {
        guard let url = fileURL else { return }
        queue.sync {
            try? withFileLock(for: url, operation: LOCK_EX) {
                try ensureLogFileExists(url)
                let h = try FileHandle(forWritingTo: url)
                defer { try? h.close() }
                try h.synchronize()
            }
        }
    }

    /// Groups old multiline log messages with their timestamped first line. Version 1.1
    /// writes one-line records, but this preserves correct deletion semantics for logs
    /// created by earlier versions.
    private static func records(in data: Data) -> [String] {
        let lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        var records: [String] = []
        for line in lines {
            if isTimestampedRecordStart(line) || records.isEmpty {
                records.append(line)
            } else {
                records[records.count - 1].append("\n" + line)
            }
        }
        return records
    }

    private static func isTimestampedRecordStart(_ line: String) -> Bool {
        // Be deliberately liberal about the suffix. Older diagnostics can reasonably
        // contain no fractional seconds, six fractional digits or a numeric time-zone.
        // Treating any ISO-like prefix as a new record is conservative: an unfamiliar
        // timestamp can never be swallowed as a continuation and deleted with its
        // neighbour.
        let bytes = Array(line.utf8.prefix(19))
        guard bytes.count == 19 else { return false }
        let digitOffsets: Set<Int> = [
            0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18,
        ]
        for (index, byte) in bytes.enumerated() where digitOffsets.contains(index) {
            guard byte >= 48, byte <= 57 else { return false }
        }
        return bytes[4] == 45 && bytes[7] == 45
            && (bytes[10] == 84 || bytes[10] == 116)
            && bytes[13] == 58 && bytes[16] == 58
    }

    private func ensureLogFileExists(_ url: URL) throws {
#if canImport(Darwin) || canImport(Glibc)
        let fd = open(url.path, O_CREAT | O_WRONLY, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw MALError.invalidPath(
                url.path,
                reason: "could not create the shared log without truncating it")
        }
        close(fd)
#else
        if !FileManager.default.fileExists(atPath: url.path) {
            _ = FileManager.default.createFile(atPath: url.path, contents: Data())
        }
#endif
    }

    private func redactionURL(for url: URL) -> URL {
        url.appendingPathExtension("redactions")
    }

    /// The sidecar, re-read only when it has actually changed.
    ///
    /// Another process appends to it when the user uninstalls an instance, so it cannot
    /// simply be read once. Keying the cache on size and modification date re-reads on
    /// exactly that event and on no other write. Always called under the log's file lock.
    private func cachedRedactionFingerprints(for url: URL) throws -> Set<String> {
        let sidecar = redactionURL(for: url)
        let attributes = try? FileManager.default.attributesOfItem(atPath: sidecar.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? -1
        let modified = attributes?[.modificationDate] as? Date
        let stamp = RedactionCache.Stamp(size: size, modified: modified)
        if let cached = redactionCache, cached.stamp == stamp {
            return cached.fingerprints
        }
        let fingerprints = Set(try loadRedactionFingerprints(for: url))
        redactionCache = RedactionCache(stamp: stamp, fingerprints: fingerprints)
        return fingerprints
    }

    private struct RedactionCache {
        struct Stamp: Equatable {
            let size: Int
            let modified: Date?
        }
        let stamp: Stamp
        let fingerprints: Set<String>
    }

    private func loadRedactionFingerprints(for url: URL) throws -> [String] {
        let sidecar = redactionURL(for: url)
        guard FileManager.default.fileExists(atPath: sidecar.path) else { return [] }
        let data = try Data(contentsOf: sidecar)
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter {
                $0.count == 16 && $0.unicodeScalars.allSatisfy {
                    CharacterSet(charactersIn: "0123456789abcdef").contains($0)
                }
            }
    }

    private func persistRedactionFingerprints(
        _ additions: [String],
        for url: URL
    ) throws {
        var ordered = try loadRedactionFingerprints(for: url)
        var known = Set(ordered)
        for fingerprint in additions where known.insert(fingerprint).inserted {
            ordered.append(fingerprint)
        }
        if ordered.count > Self.maximumRedactionFingerprints {
            ordered.removeFirst(ordered.count - Self.maximumRedactionFingerprints)
        }
        let output = ordered.isEmpty ? "" : ordered.joined(separator: "\n") + "\n"
        try AtomicFile.write(
            Data(output.utf8),
            to: redactionURL(for: url),
            keepBackup: false)
    }

    /// A whole-file scrub, skipped when the sidecar has not changed since the last one.
    ///
    /// Reading and re-matching every record is inherently O(log size), so the thing that
    /// has to be bounded is how often it runs. The marker records which sidecar state was
    /// last applied to this log in full. Startup rotation therefore costs one `stat` on
    /// the ordinary path and a real scan only after an uninstall has added a fingerprint,
    /// which is exactly when there is something new to remove.
    ///
    /// Records appended *after* the last full scrub are handled by the per-write
    /// suppression check in `log()`, which every current writer performs under this same
    /// lock. Always called under that lock.
    private func scrubPersistedRedactions(from url: URL, force: Bool = false) throws {
        let sidecar = redactionURL(for: url)
        let attributes = try? FileManager.default.attributesOfItem(atPath: sidecar.path)
        let stamp = "\((attributes?[.size] as? NSNumber)?.intValue ?? -1)"
            + "/\(((attributes?[.modificationDate] as? Date)?.timeIntervalSince1970).map { String(format: "%.6f", $0) } ?? "none")"

        let markerURL = url.appendingPathExtension("scrubbed")
        if !force,
           let applied = try? String(contentsOf: markerURL, encoding: .utf8),
           applied.trimmingCharacters(in: .whitespacesAndNewlines) == stamp {
            return
        }

        let redactions = Set(try loadRedactionFingerprints(for: url))
        guard !redactions.isEmpty,
              FileManager.default.fileExists(atPath: url.path) else {
            try? Data(stamp.utf8).write(to: markerURL)
            return
        }
        let data = try Data(contentsOf: url)
        let records = Self.records(in: data)
        let retained = records.filter { !Self.record($0, matchesAny: redactions) }
        if retained.count != records.count {
            var output = retained.joined(separator: "\n")
            if !output.isEmpty { output.append("\n") }
            try AtomicFile.write(Data(output.utf8), to: url, keepBackup: false)
        }
        try? Data(stamp.utf8).write(to: markerURL)
    }

    private static func fingerprint(_ token: String) -> String {
        // FNV-1a is used as a compact non-plaintext suppression key, not for
        // authentication or as a claim of cryptographic secrecy.
        // The input is a random UUID or generated clone identifier; storing the original
        // identity would itself leave the metadata this mechanism exists to remove.
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in token.lowercased().utf8 {
            hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }

    private static func record(
        _ record: String,
        matchesAny fingerprints: Set<String>
    ) -> Bool {
        guard !fingerprints.isEmpty else { return false }
        let searchRange = NSRange(record.startIndex..<record.endIndex, in: record)
        for pattern in identityPatterns {
            for match in pattern.matches(in: record, range: searchRange) {
                guard let range = Range(match.range, in: record) else { continue }
                if fingerprints.contains(fingerprint(String(record[range]))) {
                    return true
                }
            }
        }
        return false
    }

    private func withFileLock<T>(
        for url: URL,
        operation: Int32,
        _ body: () throws -> T
    ) throws -> T {
#if canImport(Darwin) || canImport(Glibc)
        let lockURL = url.appendingPathExtension("lock")
        let fd = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw MALError.invalidPath(
                lockURL.path,
                reason: "could not open the cross-process log lock")
        }
        guard flock(fd, operation) == 0 else {
            let reason = String(cString: strerror(errno))
            close(fd)
            throw MALError.invalidPath(
                lockURL.path,
                reason: "could not lock the shared log: \(reason)")
        }
        defer {
            _ = flock(fd, LOCK_UN)
            close(fd)
        }
        return try body()
#else
        return try body()
#endif
    }
}
