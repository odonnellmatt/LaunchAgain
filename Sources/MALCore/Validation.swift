import Foundation

/// Input hardening. Every string that ends up in a path, a plist, an argv entry, or
/// the shim's config file passes through here first.
///
/// The threat model is not malice so much as ordinary reality: application names
/// contain spaces, apostrophes, em-dashes and emoji, and users will type anything
/// into a "name this instance" field. Nothing in this project builds a shell command
/// from a string, so the job here is to reject values that would corrupt a file
/// format or a filesystem operation.
public enum Validation {

    /// Characters that cannot appear in a filesystem component we create.
    /// `/` is a separator; `:` is displayed as `/` by Finder and confuses HFS-era APIs.
    public static let forbiddenNameCharacters = CharacterSet(charactersIn: "/:\0\n\r\t")

    public static let maxNameLength = 60
    public static let maxAccountLabelLength = 120

    // MARK: Instance names

    /// Sanitises a user-supplied instance name for display *and* for use in a
    /// bundle filename. Never throws — a name field should not be able to block
    /// the user — but the result is guaranteed safe.
    public static func sanitizeInstanceName(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.components(separatedBy: forbiddenNameCharacters).joined(separator: " ")
        s = s.replacingOccurrences(of: "  ", with: " ")
        // Leading dots create hidden files.
        while s.hasPrefix(".") { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespaces)
        if s.count > maxNameLength {
            s = String(s.prefix(maxNameLength)).trimmingCharacters(in: .whitespaces)
        }
        return s
    }

    public static func sanitizeAccountLabel(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.components(separatedBy: CharacterSet(charactersIn: "\0\n\r")).joined(separator: " ")
        if s.count > maxAccountLabelLength {
            s = String(s.prefix(maxAccountLabelLength))
        }
        return s
    }

    // MARK: Paths

    /// A path is usable by us if it is absolute, non-empty, and contains no
    /// character that would break the shim's line-based config file.
    ///
    /// Newlines are the important one: the shim parses `key=value` lines with
    /// `getline`, so a newline in a data path would silently truncate it. Rather
    /// than invent an escaping scheme in a 100-line C-style shim, we forbid it here
    /// and control every path we generate anyway.
    public static func validateAbsolutePath(_ path: String, label: String = "path") throws {
        guard !path.isEmpty else {
            throw MALError.invalidPath(path, reason: "\(label) is empty")
        }
        guard path.hasPrefix("/") else {
            throw MALError.invalidPath(path, reason: "\(label) must be absolute")
        }
        guard !path.contains("\0") else {
            throw MALError.invalidPath(path, reason: "\(label) contains a null byte")
        }
        guard !path.contains("\n"), !path.contains("\r") else {
            throw MALError.invalidPath(path, reason: "\(label) contains a newline, which the launcher shim cannot represent")
        }
        guard path.utf8.count < 1024 else {
            throw MALError.invalidPath(path, reason: "\(label) exceeds 1024 bytes")
        }
    }

    /// True when `child` is at or beneath `parent`, after normalising `..` and symlink-free
    /// lexical components. Used to guarantee we never delete outside our own directories.
    public static func isPath(_ child: String, within parent: String) -> Bool {
        let c = canonicalFilesystemPath(child)
        let p = canonicalFilesystemPath(parent)
        if c == p { return true }
        return c.hasPrefix(p.hasSuffix("/") ? p : p + "/")
    }

    /// A stable path identity that resolves every existing ancestor before appending
    /// any not-yet-created suffix. Resolving only the complete URL is insufficient on
    /// macOS: `/tmp/new/file` and `/private/tmp/new/file` remain textually different
    /// when `file` does not exist, even though they name the same future location.
    ///
    /// This is used for ownership checks and registry reconciliation. It deliberately
    /// does not require the final path to exist.
    public static func canonicalFilesystemPath(_ path: String) -> String {
        let manager = FileManager.default
        var cursor = URL(fileURLWithPath: path).standardizedFileURL
        var missingComponents: [String] = []

        while cursor.path != "/", !manager.fileExists(atPath: cursor.path) {
            missingComponents.append(cursor.lastPathComponent)
            cursor.deleteLastPathComponent()
        }

        var resolved = cursor.resolvingSymlinksInPath().standardizedFileURL
        for component in missingComponents.reversed() {
            resolved.appendPathComponent(component)
        }
        return resolved.standardizedFileURL.path
    }

    public static func pathsReferToSameLocation(_ lhs: String, _ rhs: String) -> Bool {
        canonicalFilesystemPath(lhs) == canonicalFilesystemPath(rhs)
    }

    // MARK: Bundle identifiers

    private static let bundleIDAllowed = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.")

    /// Derives the clone's bundle identifier. This is the single most important
    /// value in the whole product: it is what makes LaunchServices treat the clone
    /// as a different application and therefore give it its own Dock tile.
    ///
    /// Format: `<original>.mal<number>-<8 hex of uuid>`
    /// The uuid fragment prevents a collision if the user deletes and recreates
    /// an instance while a stale LaunchServices record still exists.
    public static func cloneBundleIdentifier(original: String, number: Int, instanceID: UUID) -> String {
        let base = sanitizeBundleIDComponent(original.isEmpty ? "app.unknown" : original)
        let frag = instanceID.uuidString
            .replacingOccurrences(of: "-", with: "")
            .prefix(8)
            .lowercased()
        return "\(base).mal\(number)-\(frag)"
    }

    public static func sanitizeBundleIDComponent(_ raw: String) -> String {
        let scalars = raw.unicodeScalars.map { bundleIDAllowed.contains($0) ? Character($0) : "-" }
        var s = String(scalars)
        while s.hasPrefix(".") || s.hasPrefix("-") { s.removeFirst() }
        while s.hasSuffix(".") || s.hasSuffix("-") { s.removeLast() }
        return s.isEmpty ? "app.unknown" : s
    }

    public static func isValidBundleIdentifier(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 155 else { return false }
        guard !s.hasPrefix("."), !s.hasSuffix(".") else { return false }
        guard !s.contains("..") else { return false }
        return s.unicodeScalars.allSatisfy { bundleIDAllowed.contains($0) }
    }

    /// Proves that an identifier belongs to this exact generated instance before it is
    /// used to derive any cleanup path under the user's Library directory.
    public static func isCloneBundleIdentifier(_ identifier: String,
                                               forNumber number: Int,
                                               instanceID: UUID) -> Bool {
        guard number > 0,
              isValidBundleIdentifier(identifier),
              let first = identifier.unicodeScalars.first,
              CharacterSet.alphanumerics.contains(first) else { return false }
        let fragment = instanceID.uuidString
            .replacingOccurrences(of: "-", with: "")
            .prefix(8)
            .lowercased()
        return identifier.lowercased().hasSuffix(".mal\(number)-\(fragment)")
    }

    /// True when an identifier has the shape LaunchAgain generates for a clone —
    /// `<original>.mal<number>-<8 lowercase hex>` — without knowing which instance it
    /// belonged to.
    ///
    /// This is used for **reporting** residue whose registry entry is already gone. It
    /// is deliberately not sufficient authority to delete anything: deletion always
    /// requires the exact identifier derived from a known instance's number and UUID,
    /// which `isCloneBundleIdentifier` checks.
    public static func looksLikeCloneBundleIdentifier(_ identifier: String) -> Bool {
        guard isValidBundleIdentifier(identifier),
              let first = identifier.unicodeScalars.first,
              CharacterSet.alphanumerics.contains(first),
              let range = identifier.lowercased().range(of: ".mal", options: .backwards) else {
            return false
        }
        let suffix = identifier.lowercased()[range.upperBound...]
        guard let dash = suffix.firstIndex(of: "-") else { return false }
        let number = suffix[suffix.startIndex..<dash]
        let fragment = suffix[suffix.index(after: dash)...]
        // The prefix before `.mal` must be a real identifier, not an empty string.
        guard range.lowerBound != identifier.startIndex else { return false }
        return !number.isEmpty
            && number.allSatisfy(\.isNumber)
            && Int(number).map { $0 > 0 } == true
            && fragment.count == 8
            && fragment.allSatisfy(\.isHexDigit)
    }

    // MARK: Bundle filenames

    /// Produces a filesystem-safe `.app` name, resolving collisions against a set of
    /// names already taken in the destination directory.
    public static func uniqueBundleFilename(preferred: String, taken: Set<String>) -> String {
        let base = sanitizeInstanceName(preferred).isEmpty ? "Instance" : sanitizeInstanceName(preferred)
        var candidate = "\(base).app"
        var n = 2
        while taken.contains(candidate.lowercased()) {
            candidate = "\(base) (\(n)).app"
            n += 1
            if n > 999 { candidate = "\(base) \(UUID().uuidString.prefix(6)).app"; break }
        }
        return candidate
    }
}
