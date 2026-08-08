#if canImport(Darwin)
import Foundation
import AppKit
import Darwin
import MALCore

/// Starts, tracks and stops instances.
public final class LaunchSupervisor {

    public struct RunningInfo: Equatable {
        public var pid: pid_t
        public var bundleIdentifier: String
        public var launchedAt: Date?
    }

    private let paths: MALPaths
    private let log: MALLog

    public init(paths: MALPaths, log: MALLog = .silent) {
        self.paths = paths
        self.log = log
    }

    // MARK: - Launching

    /// Launches an instance and returns once macOS has accepted the request.
    ///
    /// `NSWorkspace.openApplication` is used rather than `Process` because the target
    /// is a GUI application: Launch Services has to own the activation, the Dock tile
    /// and the process's session, and spawning it directly would produce an app that
    /// cannot be activated properly.
    public func launch(_ instance: Instance, activate: Bool = true) async throws -> pid_t {
        guard instance.mechanism == .userDataDir else {
            throw MALError.notSupported(
                reason: "LaunchAgain opens GUI applications only. Legacy Terminal launchers can be uninstalled or replaced with a GUI instance.")
        }
        let bundle = URL(fileURLWithPath: instance.bundlePath)
        guard FileManager.default.fileExists(atPath: bundle.path) else {
            throw MALError.launchFailed("the launcher for instance #\(instance.number) is missing. Rebuild it.")
        }

        // Refuse to point two processes at one profile. Chromium's own SingletonLock
        // would usually catch this, but by then the second process has already started
        // and may have written to the profile.
        if let running = runningProcess(for: instance) {
            log.info(
                "instance #\(instance.number) [instance=\(instance.id.uuidString)] "
                    + "already running as pid \(running.pid); activating")
            if activate, let app = NSRunningApplication(processIdentifier: running.pid) {
                app.activate(options: [.activateAllWindows])
            }
            return running.pid
        }
        try assertProfileNotInUse(instance)

        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = (instance.mode == .lite)
        config.activates = activate
        config.environment = try ArgumentBuilder.sanitizeEnvironment(instance.extraEnvironment)
        // The shim adds --user-data-dir itself; anything passed here is passthrough.
        config.arguments = []

        do {
            let app = try await NSWorkspace.shared.openApplication(at: bundle, configuration: config)
            let pid = app.processIdentifier
            log.info(
                "launched instance #\(instance.number) "
                    + "[instance=\(instance.id.uuidString)] as pid \(pid)")
            try? writeLockFile(for: instance, pid: pid)
            return pid
        } catch {
            throw MALError.launchFailed("\(error.localizedDescription)")
        }
    }

    // MARK: - Tracking

    /// Finds the process belonging to an instance.
    ///
    /// Full mode is easy: the clone has a unique bundle identifier, so a bundle-id match
    /// is exact. Lite mode shares the original app's identifier, so instead we match on
    /// the data directory that the shim exported into the process environment.
    public func runningProcess(for instance: Instance) -> RunningInfo? {
        // A command line tool's session is a shell inside a terminal, not an application
        // macOS can tell us about. The generated script writes its own pid into the
        // instance's lock file and removes it on exit, so that file is the signal.
        if instance.mechanism == .configEnvironment {
            return terminalSession(for: instance)
        }

        let apps = NSWorkspace.shared.runningApplications

        if instance.mode == .full, !instance.clonedBundleIdentifier.isEmpty {
            if let a = apps.first(where: { $0.bundleIdentifier == instance.clonedBundleIdentifier }) {
                return RunningInfo(pid: a.processIdentifier,
                                   bundleIdentifier: a.bundleIdentifier ?? "",
                                   launchedAt: a.launchDate)
            }
            // An Electron app takes a few seconds to register with Launch Services, and
            // in that window NSWorkspace does not know about it yet. The lock file is
            // written the moment we launch, so it closes the gap — without it, deleting
            // an instance you launched seconds ago removes the bundle out from under a
            // live process, and its Dock tile hangs around with nothing behind it.
            return lockedSession(for: instance)
        }

        for a in apps {
            guard let url = a.bundleURL else { continue }
            // Candidate: the original app, or our lite launcher.
            if ProcessInspector.dataDirectory(ofPID: a.processIdentifier) == instance.dataPath {
                return RunningInfo(pid: a.processIdentifier,
                                   bundleIdentifier: a.bundleIdentifier ?? url.lastPathComponent,
                                   launchedAt: a.launchDate)
            }
        }
        return nil
    }

    public func isRunning(_ instance: Instance) -> Bool {
        runningProcess(for: instance) != nil
    }

    /// Reads the lock file, which both the launcher and a tool instance's script keep up
    /// to date. A PID alone is not identity: after a reboot macOS can reuse it for an
    /// unrelated process. The process must therefore carry the instance's data-directory
    /// breadcrumb, except for a very short interval while our just-opened shim is starting.
    private func lockedSession(for instance: Instance) -> RunningInfo? {
        terminalSession(for: instance)
    }

    private func terminalSession(for instance: Instance) -> RunningInfo? {
        let url = paths.instanceLockFile(instance.id)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        let fields = text.split(separator: "\n")
        guard let first = fields.first,
              let pid = pid_t(first.trimmingCharacters(in: .whitespaces)),
              pid > 0 else {
            clearLockFile(for: instance)
            return nil
        }
        guard kill(pid, 0) == 0 else {
            clearLockFile(for: instance)
            return nil
        }

        if ProcessInspector.dataDirectory(ofPID: pid) == instance.dataPath {
            return RunningInfo(
                pid: pid,
                bundleIdentifier: instance.clonedBundleIdentifier,
                launchedAt: nil)
        }

        // `openApplication` can return in the handful of milliseconds between dyld
        // starting our shim and the shim exporting MAL_INSTANCE_DATA_DIR. During only
        // that interval, accept a fresh lock when the executable itself is demonstrably
        // inside this instance's launcher bundle. An old lock after reboot cannot pass
        // either the timestamp or bundle-path check.
        let writtenAt = fields.count > 1
            ? TimeInterval(fields[1].trimmingCharacters(in: .whitespaces))
            : nil
        if isFreshLauncherProcess(pid: pid, instance: instance, writtenAt: writtenAt) {
            return RunningInfo(
                pid: pid,
                bundleIdentifier: instance.clonedBundleIdentifier,
                launchedAt: writtenAt.map(Date.init(timeIntervalSince1970:)))
        }

        log.warn(
            "cleared stale lock for instance #\(instance.number) "
                + "[instance=\(instance.id.uuidString)]: "
                + "pid \(pid) belongs to another process")
        clearLockFile(for: instance)
        return nil
    }

    private func isFreshLauncherProcess(pid: pid_t,
                                        instance: Instance,
                                        writtenAt: TimeInterval?) -> Bool {
        guard let writtenAt else { return false }
        let age = Date().timeIntervalSince1970 - writtenAt
        guard age >= -1, age <= 10,
              let executable = ProcessInspector.executablePath(ofPID: pid) else {
            return false
        }
        let launchExecutables = URL(fileURLWithPath: instance.bundlePath)
            .appendingPathComponent("Contents/MacOS")
            .standardizedFileURL.path
        return Validation.isPath(executable, within: launchExecutables)
    }

    // MARK: - Stopping

    /// Asks the application to quit, the same as Cmd-Q. Returns false if it did not
    /// exit within `timeout`, leaving force-quit as an explicit user decision.
    @discardableResult
    public func quit(_ instance: Instance, timeout: TimeInterval = 10) async -> Bool {
        guard let info = runningProcess(for: instance),
              let app = NSRunningApplication(processIdentifier: info.pid) else { return true }
        app.terminate()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.isTerminated { clearLockFile(for: instance); return true }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        return false
    }

    @discardableResult
    public func forceQuit(_ instance: Instance) -> Bool {
        guard let info = runningProcess(for: instance),
              let app = NSRunningApplication(processIdentifier: info.pid) else { return true }
        let ok = app.forceTerminate()
        if ok { clearLockFile(for: instance) }
        return ok
    }

    // MARK: - Profile locking

    /// A lock file recording which PID last claimed this profile. Advisory: it catches
    /// the common case of two launchers racing, and is ignored when the recorded PID is
    /// no longer alive (which happens after a crash).
    private func writeLockFile(for instance: Instance, pid: pid_t) throws {
        // A non-positive pid is not a process. Writing one would be worse than writing
        // nothing: `kill(0, 0)` addresses the caller's process group and `kill(-1, 0)`
        // addresses every process the user owns, so both report "alive" forever and the
        // instance could never be launched again.
        guard pid > 0 else { return }
        let url = paths.instanceLockFile(instance.id)
        let payload = "\(pid)\n\(Date().timeIntervalSince1970)\n"
        try AtomicFile.write(Data(payload.utf8), to: url, keepBackup: false)
    }

    private func clearLockFile(for instance: Instance) {
        try? FSOps.removeIfExists(paths.instanceLockFile(instance.id))
    }

    private func assertProfileNotInUse(_ instance: Instance) throws {
        if lockedSession(for: instance) != nil {
            throw MALError.alreadyRunning(dataPath: instance.dataPath)
        }
    }
}

/// Inspects a process's environment and launch arguments to discover which instance it belongs to.
///
/// The shim exports `MAL_INSTANCE_DATA_DIR` before exec'ing the real binary, so the
/// value survives into the target application's environment. It also supplies the
/// equivalent `--user-data-dir` argument for macOS versions that redact envp.
enum ProcessInspector {

    static func dataDirectory(ofPID pid: pid_t) -> String? {
        guard let info = processInfo(ofPID: pid) else { return nil }
        if let breadcrumb = info.environment["MAL_INSTANCE_DATA_DIR"] {
            return breadcrumb
        }

        // Recent macOS releases redact another process's environment from
        // KERN_PROCARGS2, even for another process owned by the same user. The shim also
        // passes this exact Chromium argument, so it is an equivalent, observable proof
        // when the environment is unavailable.
        let prefix = "--user-data-dir="
        return info.arguments.reversed().first(where: { $0.hasPrefix(prefix) })
            .map { String($0.dropFirst(prefix.count)) }
    }

    /// Kernel-reported executable path. Used only for the narrow launch-startup grace
    /// period before the shim's environment breadcrumb becomes observable.
    static func executablePath(ofPID pid: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE is a C expression macro Swift cannot import.
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = buffer.withUnsafeMutableBytes { bytes in
            proc_pidpath(pid, bytes.baseAddress, UInt32(bytes.count))
        }
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    /// `sysctl(KERN_PROCARGS2)` returns argv and, when macOS exposes it, envp for a
    /// process. Some releases redact envp even for same-user processes.
    static func environment(ofPID pid: pid_t) -> [String: String]? {
        processInfo(ofPID: pid)?.environment
    }

    private static func processInfo(ofPID pid: pid_t)
        -> (arguments: [String], environment: [String: String])? {
        var argMax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&mib, 2, &argMax, &size, nil, 0) == 0, argMax > 0 else { return nil }

        var buffer = [CChar](repeating: 0, count: Int(argMax))
        var bufferSize = Int(argMax)
        var mib2: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib2, 3, &buffer, &bufferSize, nil, 0) == 0, bufferSize > MemoryLayout<Int32>.size else {
            return nil
        }

        // Layout: [int argc][exec path]\0(padding)[argv[0..argc-1]\0…][envp…\0]\0
        var argc: Int32 = 0
        withUnsafeMutableBytes(of: &argc) { dst in
            buffer.withUnsafeBytes { src in
                dst.copyBytes(from: UnsafeRawBufferPointer(rebasing: src[0..<MemoryLayout<Int32>.size]))
            }
        }

        var cursor = MemoryLayout<Int32>.size
        func nextCString() -> String? {
            guard cursor < bufferSize else { return nil }
            let start = cursor
            while cursor < bufferSize && buffer[cursor] != 0 { cursor += 1 }
            guard cursor <= bufferSize else { return nil }
            let bytes = buffer[start..<cursor].map { UInt8(bitPattern: $0) }
            cursor += 1
            return String(decoding: bytes, as: UTF8.self)
        }

        _ = nextCString()                       // exec path
        while cursor < bufferSize && buffer[cursor] == 0 { cursor += 1 }  // alignment padding
        var arguments: [String] = []
        arguments.reserveCapacity(Int(max(argc, 0)))
        for _ in 0..<max(argc, 0) {
            if let argument = nextCString() { arguments.append(argument) }
        }
        // KERN_PROCARGS2 separates argv from envp with one or more additional NULs.
        // Without skipping them the first empty string ended environment parsing, so the
        // MAL_INSTANCE_DATA_DIR breadcrumb was never observable for another process.
        while cursor < bufferSize && buffer[cursor] == 0 { cursor += 1 }

        var env: [String: String] = [:]
        while let entry = nextCString(), !entry.isEmpty {
            guard let eq = entry.firstIndex(of: "=") else { continue }
            env[String(entry[entry.startIndex..<eq])] = String(entry[entry.index(after: eq)...])
        }
        return (arguments, env)
    }
}
#endif
