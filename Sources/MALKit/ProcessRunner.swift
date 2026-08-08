#if canImport(Darwin)
import Foundation
import MALCore

/// Runs the handful of Apple-supplied command line tools this project needs.
///
/// Every call passes an argument *array*. There is no shell anywhere in this project:
/// no `sh -c`, no string interpolation into a command line, no `NSAppleScript`. An
/// application named `Foo"; rm -rf ~ ;".app` is just a string here.
public enum ProcessRunner {

    /// Dispatch closures are `@Sendable` under Swift 6. Keep pipe results behind an
    /// explicitly synchronized reference instead of mutating captured local variables;
    /// the previous code was locked at runtime but still expressed an unsafe capture to
    /// the compiler.
    private final class LockedData: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func store(_ newValue: Data) {
            lock.lock()
            data = newValue
            lock.unlock()
        }

        func load() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }
    }

    public struct Output {
        public let status: Int32
        public let stdout: String
        public let stderr: String
        public var succeeded: Bool { status == 0 }
    }

    /// Absolute paths only. Resolving tools via `PATH` would let a modified environment
    /// substitute a different binary.
    public enum Tool: String, CaseIterable {
        case codesign = "/usr/bin/codesign"
        case iconutil = "/usr/bin/iconutil"
        case cp       = "/bin/cp"
        case lipo     = "/usr/bin/lipo"
        case xattr    = "/usr/bin/xattr"
        case spctl    = "/usr/sbin/spctl"
        case pluginkit = "/usr/bin/pluginkit"
        case open     = "/usr/bin/open"
        case hdiutil  = "/usr/bin/hdiutil"

        public var exists: Bool { FileManager.default.isExecutableFile(atPath: rawValue) }
    }

    @discardableResult
    public static func run(_ tool: Tool,
                           _ arguments: [String],
                           timeout: TimeInterval = 300,
                           currentDirectory: URL? = nil) throws -> Output {
        guard tool.exists else { throw MALError.toolMissing(tool.rawValue) }
        return try run(executable: tool.rawValue, arguments,
                       timeout: timeout, currentDirectory: currentDirectory)
    }

    @discardableResult
    public static func run(executable: String,
                           _ arguments: [String],
                           timeout: TimeInterval = 300,
                           currentDirectory: URL? = nil) throws -> Output {
        for a in arguments where a.contains("\0") {
            throw MALError.invalidName(a, reason: "argument contains a null byte")
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        if let currentDirectory { p.currentDirectoryURL = currentDirectory }

        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        // Read both pipes concurrently. Reading them serially after `waitUntilExit`
        // deadlocks as soon as a tool writes more than one pipe buffer, which
        // `codesign --verify --verbose` on a large Electron bundle certainly does.
        let outData = LockedData(), errData = LockedData()
        let group = DispatchGroup()
        let ioQueue = DispatchQueue(label: "com.mal.proc.io", attributes: .concurrent)

        // Spawn before starting readers. If `run()` throws, no closures have been
        // submitted that can wait forever for EOF from a process that never existed.
        // Once spawned, `Process.run()` returns immediately; readers are installed before
        // a child blocked on a full pipe can make further progress.
        try p.run()

        group.enter()
        ioQueue.async {
            defer { group.leave() }
            let d = outPipe.fileHandleForReading.readDataToEndOfFile()
            outData.store(d)
        }
        group.enter()
        ioQueue.async {
            defer { group.leave() }
            let d = errPipe.fileHandleForReading.readDataToEndOfFile()
            errData.store(d)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline {
            usleep(20_000)
        }
        if p.isRunning {
            p.terminate()
            usleep(200_000)
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            _ = group.wait(timeout: .now() + 2)
            throw MALError.processFailed(tool: executable, status: -1,
                                         stderr: "timed out after \(Int(timeout))s")
        }

        p.waitUntilExit()
        _ = group.wait(timeout: .now() + 5)

        let out = String(decoding: outData.load(), as: UTF8.self)
        let err = String(decoding: errData.load(), as: UTF8.self)

        return Output(status: p.terminationStatus, stdout: out, stderr: err)
    }

    /// Runs and throws on a non-zero exit.
    @discardableResult
    public static func check(_ tool: Tool,
                             _ arguments: [String],
                             timeout: TimeInterval = 300) throws -> String {
        let r = try run(tool, arguments, timeout: timeout)
        guard r.succeeded else {
            throw MALError.processFailed(tool: tool.rawValue, status: r.status,
                                         stderr: r.stderr.isEmpty ? r.stdout : r.stderr)
        }
        return r.stdout
    }
}
#endif
