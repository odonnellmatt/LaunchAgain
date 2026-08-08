//
//  mal-shim — the launcher stub planted inside every generated bundle.
//
//  Design constraints, in order of importance:
//
//  1. It must add no measurable latency. In `full` mode it `execv`s the real binary,
//     so after a few hundred microseconds this process *is* the target app: same PID,
//     same Dock tile, same process identity. A wrapper that forked and waited would
//     produce two processes and a wrong Dock entry.
//
//  2. It repairs a recognised Electron window-state file when the saved title bar is on
//     a display that is no longer connected. This needs AppKit briefly, before `execv`;
//     the replacement process gets a new address space, so none of the shim's frameworks
//     remain loaded in the target application.
//
//  3. It must fail loudly and legibly. If the config is missing or the real binary is
//     gone, print something a user can act on rather than silently doing nothing.
//
//  Config is read from  <bundle>/Contents/Resources/MALInstance.conf
//  (see InstanceConfig in MALCore — the two parsers must stay in step; the
//   round-trip is covered by InstanceConfigTests).
//

#if canImport(Darwin)
import Darwin
import Foundation
import AppKit
import CoreGraphics
import MALCore
// _NSGetExecutablePath lives in <mach-o/dyld.h>. This is the only import beyond libc,
// and it costs nothing: dyld is already mapped into every process.
import MachO

// MARK: - Small helpers

private func fail(_ message: String) -> Never {
    let s = "mal-shim: \(message)\n"
    s.withCString { p in _ = fputs(p, stderr) }
    exit(70) // EX_SOFTWARE
}

/// Absolute, symlink-resolved path of this executable.
private func executablePath() -> String {
    var size = UInt32(4096)
    var buf = [CChar](repeating: 0, count: Int(size))
    if _NSGetExecutablePath(&buf, &size) != 0 {
        buf = [CChar](repeating: 0, count: Int(size) + 1)
        if _NSGetExecutablePath(&buf, &size) != 0 { fail("could not determine executable path") }
    }
    var resolved = [CChar](repeating: 0, count: 4096)
    if realpath(buf, &resolved) != nil {
        return String(cString: resolved)
    }
    return String(cString: buf)
}

private func parentDirectory(_ path: String) -> String {
    guard let idx = path.lastIndex(of: "/") else { return "/" }
    if idx == path.startIndex { return "/" }
    return String(path[path.startIndex..<idx])
}

private func lastComponent(_ path: String) -> String {
    guard let idx = path.lastIndex(of: "/") else { return path }
    return String(path[path.index(after: idx)...])
}

private func fileExists(_ path: String) -> Bool {
    var st = stat()
    return stat(path, &st) == 0
}

// MARK: - Config parsing
//
// One `key=value` per line. Everything after the first `=` is the value, so values
// may contain `=` and spaces. Values may not contain newlines; MALCore's Validation
// enforces that at creation time rather than inventing an escaping scheme here.

struct Config {
    var kind = "app"
    var mode = "full"
    var dataDir = ""
    var realExecutable = ""
    var targetApp = ""
    var script = ""
    var terminal = "Terminal"
    var extraArgs: [String] = []
    var environment: [(String, String)] = []
}

func readConfig(_ path: String) -> Config {
    guard let fp = fopen(path, "r") else {
        fail("missing instance configuration at \(path). Rebuild this instance from LaunchAgain.")
    }
    defer { fclose(fp) }

    var cfg = Config()
    var linePtr: UnsafeMutablePointer<CChar>? = nil
    var cap = 0
    while getline(&linePtr, &cap, fp) > 0 {
        guard let lp = linePtr else { break }
        var line = String(cString: lp)
        while line.hasSuffix("\n") || line.hasSuffix("\r") { line.removeLast() }
        if line.isEmpty || line.hasPrefix("#") { continue }
        guard let eq = line.firstIndex(of: "=") else { continue }
        let key = String(line[line.startIndex..<eq])
        let value = String(line[line.index(after: eq)...])
        switch key {
        case "kind":   cfg.kind = value
        case "mode":   cfg.mode = value
        case "udd":    cfg.dataDir = value
        case "exec":   cfg.realExecutable = value
        case "target": cfg.targetApp = value
        case "script": cfg.script = value
        case "term":   cfg.terminal = value
        case "arg":    cfg.extraArgs.append(value)
        case "env":
            if let e = value.firstIndex(of: "=") {
                cfg.environment.append((String(value[value.startIndex..<e]),
                                        String(value[value.index(after: e)...])))
            }
        default: break
        }
    }
    if linePtr != nil { free(linePtr) }
    if cfg.dataDir.isEmpty { fail("instance configuration has no data directory") }
    return cfg
}

// MARK: - Process replacement

private func cArray(_ strings: [String]) -> UnsafeMutablePointer<UnsafeMutablePointer<CChar>?> {
    let buf = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: strings.count + 1)
    for (i, s) in strings.enumerated() { buf[i] = strdup(s) }
    buf[strings.count] = nil
    return buf // never freed: we are about to exec or exit
}

/// `mkdir -p`. Electron will create the profile itself, but the singleton lock is
/// only acquired reliably when the directory already exists.
private func makeDirectories(_ path: String) {
    var partial = ""
    for component in path.split(separator: "/") {
        partial += "/" + component
        _ = mkdir(partial, 0o700)
    }
}

/// Active displays in the coordinate system Electron persists in `window-state.json`.
/// `NSScreen.visibleFrame` is in AppKit's bottom-left coordinate system, so convert its
/// local insets onto the matching Core Graphics bounds (top-left, like Electron).
private func activeDisplays() -> [MALDisplayGeometry] {
    NSScreen.screens.compactMap { screen in
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? NSNumber else { return nil }
        let quartz = CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
        let frame = screen.frame
        let visible = screen.visibleFrame
        let left = visible.minX - frame.minX
        let right = frame.maxX - visible.maxX
        let top = frame.maxY - visible.maxY
        let bottom = visible.minY - frame.minY
        let bounds = MALScreenRect(
            x: quartz.minX, y: quartz.minY,
            width: quartz.width, height: quartz.height)
        let visibleFrame = MALScreenRect(
            x: quartz.minX + left,
            y: quartz.minY + top,
            width: quartz.width - left - right,
            height: quartz.height - top - bottom)
        return MALDisplayGeometry(bounds: bounds, visibleFrame: visibleFrame)
    }
}

// MARK: - Entry point

let shimPath = executablePath()                       // …/Foo.app/Contents/MacOS/mal-shim
let macOSDir = parentDirectory(shimPath)              // …/Foo.app/Contents/MacOS
let contentsDir = parentDirectory(macOSDir)           // …/Foo.app/Contents
let configPath = contentsDir + "/Resources/MALInstance.conf"

let config = readConfig(configPath)

makeDirectories(config.dataDir)

// Best effort and fail open. A malformed or unfamiliar vendor file is explicitly left
// untouched, and a repair failure must never prevent the application from launching.
_ = try? ElectronWindowStateRepairer.repairIfNeeded(
    profileDirectory: URL(fileURLWithPath: config.dataDir, isDirectory: true),
    displays: activeDisplays())

for (k, v) in config.environment {
    _ = k.withCString { kp in v.withCString { vp in setenv(kp, vp, 1) } }
}
// A breadcrumb so `ps -E` and our own diagnostics can tell which instance a process
// belongs to. Harmless to the host app.
_ = "MAL_INSTANCE_DATA_DIR".withCString { kp in
    config.dataDir.withCString { vp in setenv(kp, vp, 1) }
}

// Arguments the user or the app itself passed to the bundle (argv[1...]), preserved
// so that document opens and URL handoffs still work.
let passthrough = Array(CommandLine.arguments.dropFirst())

// Old releases could create command-line launchers that opened Terminal. The current
// product boundary is GUI applications only; the shipped shim fails closed even if a
// legacy config is copied into a newly built bundle.
if config.kind == "tool" {
    fail("legacy Terminal launchers are disabled. Uninstall this instance in LaunchAgain and create one from the installed macOS application.")
}

switch config.mode {
case "lite":
    // No clone exists. Ask Launch Services to start a *new* instance of the original
    // application with our data directory. `open -n` is the documented way to do this.
    guard fileExists(config.targetApp) else {
        fail("the original application is no longer at \(config.targetApp)")
    }
    var argv = ["/usr/bin/open", "-n", "-a", config.targetApp, "--args",
                "--user-data-dir=" + config.dataDir]
    argv.append(contentsOf: config.extraArgs)
    argv.append(contentsOf: passthrough)
    execv("/usr/bin/open", cArray(argv))
    fail("could not run /usr/bin/open: \(String(cString: strerror(errno)))")

default:
    // Full mode: become the real binary, in place.
    let realPath = macOSDir + "/" + config.realExecutable
    guard fileExists(realPath) else {
        fail("the application's real executable is missing at \(realPath). Rebuild this instance.")
    }
    // argv[0] is the real executable path: Electron derives its resources path from
    // the executable location, and keeping this honest avoids surprising it.
    var argv = [realPath, "--user-data-dir=" + config.dataDir]
    argv.append(contentsOf: config.extraArgs)
    argv.append(contentsOf: passthrough)
    execv(realPath, cArray(argv))
    fail("could not exec \(lastComponent(realPath)): \(String(cString: strerror(errno)))")
}

#else

// The shim is macOS-only by nature. This stub exists so the whole package still
// compiles on Linux, which is where MALCore's test suite runs.
print("mal-shim is only meaningful on macOS.")
exit(1)

#endif
