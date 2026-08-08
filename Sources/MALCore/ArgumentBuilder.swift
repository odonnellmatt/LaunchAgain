import Foundation

/// Builds the argument vector handed to an instance.
///
/// Nothing here ever produces a shell command string. Callers pass the resulting
/// array straight to `posix_spawn`/`Process.arguments`/`NSWorkspace`, so quoting is
/// not a concern and cannot become one.
public enum ArgumentBuilder {

    public static let userDataDirFlag = "--user-data-dir"

    /// Flags a user is not allowed to set by hand, because they would break the
    /// isolation guarantee the instance exists to provide.
    public static let reservedFlags: Set<String> = [
        "--user-data-dir",
        "--profile-directory",   // Chromium sub-profile: would re-share the parent dir
    ]

    /// The canonical launch arguments for an instance.
    ///
    /// `--user-data-dir` is placed first so that if a target app naively takes the
    /// first occurrence of a repeated flag, ours wins.
    public static func launchArguments(dataPath: String,
                                       extraArguments: [String] = []) throws -> [String] {
        try Validation.validateAbsolutePath(dataPath, label: "data directory")
        var args = ["\(userDataDirFlag)=\(dataPath)"]
        args.append(contentsOf: try sanitizeExtraArguments(extraArguments))
        return args
    }

    /// Rejects user-supplied arguments that would defeat isolation, and rejects
    /// anything containing a null byte or newline (the shim's config is line-based).
    public static func sanitizeExtraArguments(_ args: [String]) throws -> [String] {
        var out: [String] = []
        for a in args {
            let trimmed = a.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            guard !trimmed.contains("\0"), !trimmed.contains("\n"), !trimmed.contains("\r") else {
                throw MALError.invalidName(a, reason: "argument contains a control character")
            }
            let flagName = trimmed.split(separator: "=", maxSplits: 1).first.map(String.init) ?? trimmed
            if reservedFlags.contains(flagName) {
                throw MALError.invalidName(a, reason: "\(flagName) is managed by the launcher and cannot be overridden")
            }
            out.append(trimmed)
        }
        return out
    }

    public static func sanitizeEnvironment(_ env: [String: String]) throws -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in env {
            let key = k.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty { continue }
            guard !key.contains("="), !key.contains("\0"), !key.contains("\n") else {
                throw MALError.invalidName(k, reason: "environment variable name is malformed")
            }
            guard !v.contains("\0"), !v.contains("\n"), !v.contains("\r") else {
                throw MALError.invalidName(k, reason: "value for \(key) contains a control character")
            }
            // HOME redirection is a classic way to "isolate" an app and a classic way
            // to break macOS. We refuse it; --user-data-dir is the supported mechanism.
            if key == "HOME" {
                throw MALError.invalidName(k, reason: "HOME cannot be redirected — it breaks Keychain, TCC and sandbox lookups. Use the data directory instead.")
            }
            out[key] = v
        }
        return out
    }
}

/// What a launcher bundle actually launches.
public enum InstanceKind: String, Codable, Sendable {
    /// A desktop application, isolated with `--user-data-dir`.
    case app
    /// A command line tool, isolated with a configuration-directory environment
    /// variable and opened in a terminal.
    case tool
}

/// The file planted at `Contents/Resources/MALInstance.conf` inside every launcher
/// bundle. The shim parses it with plain C I/O.
///
/// Format is intentionally trivial — one `key=value` per line, UTF-8, no escaping:
///
///     kind=app
///     mode=full
///     udd=/Users/x/Library/Application Support/LaunchAgain/instances/<id>/userdata
///     exec=Claude.real
///     target=/Applications/Claude.app
///     arg=--some-flag
///     env=SOME_KEY=value
///
/// Values can contain `=` and spaces (everything after the first `=` is the value).
/// They cannot contain newlines, which `Validation` and `ArgumentBuilder` enforce at
/// the point of entry rather than by inventing an escaping scheme in the shim.
public struct InstanceConfig: Equatable, Sendable {
    public var kind: InstanceKind
    public var mode: InstanceMode
    /// The instance's own directory: `--user-data-dir` for an app, the value of the
    /// tool's config variable (e.g. `CODEX_HOME`) for a tool.
    public var dataPath: String
    /// `full` only: filename (not path) of the real executable inside `Contents/MacOS`.
    public var realExecutableName: String
    /// `lite` only: absolute path of the original .app to open.
    public var targetAppPath: String
    /// `tool` only: absolute path of the generated `.command` script to open.
    public var scriptPath: String
    /// `tool` only: the terminal application to open the script with.
    public var terminalApp: String
    public var extraArguments: [String]
    public var extraEnvironment: [String: String]

    public init(kind: InstanceKind = .app,
                mode: InstanceMode,
                dataPath: String,
                realExecutableName: String = "",
                targetAppPath: String = "",
                scriptPath: String = "",
                terminalApp: String = "Terminal",
                extraArguments: [String] = [],
                extraEnvironment: [String: String] = [:]) {
        self.kind = kind
        self.mode = mode
        self.dataPath = dataPath
        self.realExecutableName = realExecutableName
        self.targetAppPath = targetAppPath
        self.scriptPath = scriptPath
        self.terminalApp = terminalApp
        self.extraArguments = extraArguments
        self.extraEnvironment = extraEnvironment
    }

    public func serialized() throws -> String {
        try Validation.validateAbsolutePath(dataPath, label: "data directory")
        let args = try ArgumentBuilder.sanitizeExtraArguments(extraArguments)
        let env = try ArgumentBuilder.sanitizeEnvironment(extraEnvironment)

        var lines: [String] = []
        lines.append("# Generated by LaunchAgain. Do not edit by hand.")
        lines.append("kind=\(kind.rawValue)")
        lines.append("mode=\(mode.rawValue)")
        lines.append("udd=\(dataPath)")

        if kind == .tool {
            try Validation.validateAbsolutePath(scriptPath, label: "launch script")
            guard !terminalApp.isEmpty, !terminalApp.contains("\n") else {
                throw MALError.invalidName(terminalApp, reason: "terminal application name is malformed")
            }
            lines.append("script=\(scriptPath)")
            lines.append("term=\(terminalApp)")
            for a in args { lines.append("arg=\(a)") }
            for k in env.keys.sorted() { lines.append("env=\(k)=\(env[k]!)") }
            return lines.joined(separator: "\n") + "\n"
        }

        switch mode {
        case .full:
            guard !realExecutableName.isEmpty else {
                throw MALError.invalidName(realExecutableName, reason: "full mode requires a real executable name")
            }
            guard !realExecutableName.contains("/") else {
                throw MALError.invalidName(realExecutableName, reason: "must be a filename, not a path")
            }
            lines.append("exec=\(realExecutableName)")
        case .lite:
            try Validation.validateAbsolutePath(targetAppPath, label: "target application")
            lines.append("target=\(targetAppPath)")
        }
        for a in args { lines.append("arg=\(a)") }
        for k in env.keys.sorted() { lines.append("env=\(k)=\(env[k]!)") }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Round-trip parser. Exists so the tests can prove serialisation is lossless for
    /// adversarial names — the shim's C parser mirrors this exactly.
    public static func parse(_ text: String) throws -> InstanceConfig {
        var kind: InstanceKind = .app
        var mode: InstanceMode = .full
        var udd = "", exec = "", target = "", script = "", term = "Terminal"
        var args: [String] = []
        var env: [String: String] = [:]

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<eq])
            let value = String(line[line.index(after: eq)...])
            switch key {
            case "kind":   kind = InstanceKind(rawValue: value) ?? .app
            case "mode":   mode = InstanceMode(rawValue: value) ?? .full
            case "udd":    udd = value
            case "exec":   exec = value
            case "target": target = value
            case "script": script = value
            case "term":   term = value
            case "arg":    args.append(value)
            case "env":
                if let e = value.firstIndex(of: "=") {
                    env[String(value[value.startIndex..<e])] = String(value[value.index(after: e)...])
                }
            default: continue
            }
        }
        guard !udd.isEmpty else {
            throw MALError.registryCorrupt("instance config has no data directory")
        }
        return InstanceConfig(kind: kind, mode: mode, dataPath: udd, realExecutableName: exec,
                              targetAppPath: target, scriptPath: script, terminalApp: term,
                              extraArguments: args, extraEnvironment: env)
    }
}
