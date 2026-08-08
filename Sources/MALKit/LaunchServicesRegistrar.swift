#if canImport(Darwin)
import Foundation
import CoreServices
import AppKit
import MALCore

/// Tells macOS that a newly created bundle exists.
///
/// Without this, a clone can sit in `~/Applications` and still show the *original's*
/// icon in Finder, or fail to appear in Spotlight, because Launch Services has not
/// re-read its `Info.plist`.
///
/// Two mechanisms, in order of preference:
///
///  1. `LSRegisterURL`, the public Launch Services C function. Deprecated by Apple but
///     still present and still functional, and reached through `dlsym` so a future
///     removal degrades to (2) rather than failing to link.
///  2. The `lsregister` tool. It lives at an undocumented path inside
///     CoreServices.framework, so we probe for it rather than assuming it is there.
public final class LaunchServicesRegistrar {

    private let log: MALLog
    public init(log: MALLog = .silent) { self.log = log }

    private static let lsregisterPath =
        "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"

    public func register(bundle: URL) {
        // Touch the bundle first: Launch Services and IconServices both key their
        // caches partly on modification date, and a clone inherits the source's.
        try? FileManager.default.setAttributes([.modificationDate: Date()],
                                               ofItemAtPath: bundle.path)

        if registerViaAPI(bundle: bundle, update: true) {
            log.debug("registered \(bundle.lastPathComponent) via LSRegisterURL")
            return
        }
        if runLSRegister(["-f", bundle.path]) {
            log.debug("registered \(bundle.lastPathComponent) via lsregister")
            return
        }
        log.warn("could not register \(bundle.lastPathComponent) with Launch Services; it may not appear in Spotlight until the next login")
    }

    public func unregister(bundle: URL) {
        if runLSRegister(["-u", bundle.path]) { return }
        _ = registerViaAPI(bundle: bundle, update: false)
    }

    // MARK: - Mechanism 1: public API via dlsym

    private typealias LSRegisterURLFn = @convention(c) (CFURL, Bool) -> OSStatus

    private func registerViaAPI(bundle: URL, update: Bool) -> Bool {
        guard let handle = dlopen(nil, RTLD_NOW) else { return false }
        defer { dlclose(handle) }
        guard let sym = dlsym(handle, "LSRegisterURL") else { return false }
        let fn = unsafeBitCast(sym, to: LSRegisterURLFn.self)
        let status = fn(bundle as CFURL, update)
        return status == noErr
    }

    // MARK: - Mechanism 2: lsregister

    @discardableResult
    private func runLSRegister(_ arguments: [String]) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: Self.lsregisterPath) else { return false }
        guard let r = try? ProcessRunner.run(executable: Self.lsregisterPath,
                                             arguments, timeout: 120) else { return false }
        return r.succeeded
    }

    /// Nudges the Dock and Finder to re-read icons.
    ///
    /// Called after every install, not only after a rebuild. IconServices caches by
    /// path, and creating a second instance at a path a previous one occupied — which is
    /// exactly what happens when someone deletes an instance and makes another with the
    /// same name — is the case where macOS reliably shows the icon it saw last time.
    ///
    /// All three modification dates are bumped because they are separate cache keys: the
    /// bundle, the `Info.plist` that names the icon, and the icon file itself.
    public func refreshIconCaches(for bundle: URL) {
        let now = Date()
        for path in [bundle.path,
                     bundle.appendingPathComponent("Contents/Info.plist").path,
                     bundle.appendingPathComponent("Contents/Resources/MALAppIcon.icns").path]
        where FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.setAttributes([.modificationDate: now],
                                                   ofItemAtPath: path)
        }
        register(bundle: bundle)
        // Ask NSWorkspace to drop its cached icon for this path.
        NSWorkspace.shared.noteFileSystemChanged(bundle.path)
    }
}
#endif
