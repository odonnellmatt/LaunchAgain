#if canImport(Darwin)
import Foundation
import MALCore

/// Ad-hoc re-signing of a cloned bundle.
///
/// Why any of this is necessary: editing `Info.plist` inside a signed bundle
/// invalidates the signature, and macOS refuses to launch a Hardened Runtime binary
/// whose signature does not verify. So a clone must be re-signed. We have no Apple
/// Developer identity for someone else's app and would not use one if we did, so the
/// clone is signed **ad hoc** (`--sign -`): a self-generated signature, valid only on
/// this machine, carrying no Team ID and impersonating nobody.
///
/// The consequences, stated plainly because the product refuses to hide them:
///   • The clone is no longer signed by the original developer. It is not represented
///     as such anywhere — `MALGeneratedBy` is written into its Info.plist.
///   • It cannot read Keychain items the original app created, because Keychain ACLs
///     are bound to the signing identity. This is why each instance signs in fresh,
///     and it is a security property working correctly, not a bug to route around.
///   • Team-bound entitlements are dropped (see EntitlementsPatch).
///
/// The original application is never signed, modified, or moved by this type.
public final class CodeSigner {

    private let log: MALLog
    public init(log: MALLog = .silent) { self.log = log }

    // MARK: - Nested code discovery

    /// Bundle extensions that `codesign` treats as independent code.
    private static let codeBundleExtensions: Set<String> = [
        "framework", "app", "xpc", "appex", "bundle", "plugin", "kext", "systemextension"
    ]

    /// Everything inside `bundle` that must be signed before `bundle` itself, deepest
    /// first. Apple deprecated `--deep` precisely because it signs nested code with the
    /// wrong entitlements; doing the walk ourselves is the supported replacement.
    public func nestedCodeItems(in bundle: URL) -> [URL] {
        let fm = FileManager.default
        var items: [URL] = []

        guard let e = fm.enumerator(at: bundle,
                                    includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                                    options: []) else { return [] }

        for case let url as URL in e {
            let ext = url.pathExtension.lowercased()
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false

            if isDir, Self.codeBundleExtensions.contains(ext) {
                items.append(url)
                // Do not descend: codesign signs a nested bundle as a unit, and its own
                // internals are handled by signing that bundle's nested items separately
                // below via a recursive call.
                e.skipDescendants()
                items.append(contentsOf: nestedCodeItems(in: url))
                continue
            }

            if !isDir {
                if ext == "dylib" || ext == "so" || Self.isMachO(url) {
                    // The bundle's own main executable is signed last, with the outer bundle.
                    items.append(url)
                }
            }
        }

        // Deepest first, so a framework's contents are sealed before the framework is.
        return items.sorted { $0.pathComponents.count > $1.pathComponents.count }
    }

    /// Reads the first four bytes and checks for a Mach-O or universal-binary magic
    /// number. Cheaper and more reliable than trusting the executable bit.
    static func isMachO(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        guard let d = try? h.read(upToCount: 4), d.count == 4 else { return false }
        let m = d.withUnsafeBytes { $0.load(as: UInt32.self) }
        switch m {
        case 0xFEEDFACE, 0xCEFAEDFE,      // 32-bit Mach-O, both endians
             0xFEEDFACF, 0xCFFAEDFE,      // 64-bit Mach-O
             0xCAFEBABE, 0xBEBAFECA,      // universal ("fat")
             0xCAFEBABF, 0xBFBAFECA:      // fat64
            return true
        default:
            return false
        }
    }

    // MARK: - Signing

    public struct SignReport {
        public var signedItemCount: Int
        public var removedEntitlements: [String]
        public var addedEntitlements: [String]
        public var verifyOutput: String
        public var gatekeeperOutput: String
    }

    /// Signs `bundle` inside-out with an ad-hoc identity.
    ///
    /// `mainEntitlements` should already have been through `EntitlementsPatch.patch`.
    ///
    /// `entitlementsFor` decides what each nested item is signed with. This matters more
    /// than it looks: an Electron app's renderer and GPU helpers each carry their own
    /// entitlements (JIT, unsigned executable memory, dyld environment variables), and a
    /// helper signed without them starts and then dies the moment it tries to allocate
    /// executable memory. Giving every nested item one generic entitlement set was not
    /// enough; giving it the patched version of *its own* original set is.
    public func adHocSign(bundle: URL,
                          mainEntitlements: [String: Any],
                          hardenedRuntime: Bool,
                          entitlementsFor: ((URL) -> [String: Any]?)? = nil) throws -> Int {
        let nested = nestedCodeItems(in: bundle)
        log.info("signing \(nested.count) nested items inside \(bundle.lastPathComponent)")

        // Fallback for nested executable bundles when the caller supplies no provider:
        // library validation off, which is the minimum that lets a helper load its
        // sibling frameworks under a team-less signature.
        let fallbackEntitlements: [String: Any] = [EntitlementsPatch.libraryValidationKey: true]
        var temporaryFiles: [URL] = []
        defer { for u in temporaryFiles { try? FileManager.default.removeItem(at: u) } }

        for item in nested {
            let isExecutableBundle = ["app", "xpc", "appex"].contains(item.pathExtension.lowercased())
            let entitlements = entitlementsFor?(item) ?? (isExecutableBundle ? fallbackEntitlements : nil)

            var args = ["--force", "--sign", "-", "--timestamp=none"]
            if hardenedRuntime { args += ["--options", "runtime"] }
            if let entitlements {
                let url = try writeTemporaryEntitlements(entitlements)
                temporaryFiles.append(url)
                args += ["--entitlements", url.path, "--generate-entitlement-der"]
            }
            args.append(item.path)

            let r = try ProcessRunner.run(.codesign, args, timeout: 180)
            guard r.succeeded else {
                throw MALError.signingFailed("\(item.lastPathComponent): \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }

        let mainEntitlementsURL = try writeTemporaryEntitlements(mainEntitlements)
        defer { try? FileManager.default.removeItem(at: mainEntitlementsURL) }

        var args = ["--force", "--sign", "-", "--timestamp=none"]
        if hardenedRuntime { args += ["--options", "runtime"] }
        args += ["--entitlements", mainEntitlementsURL.path, "--generate-entitlement-der"]
        args.append(bundle.path)

        let r = try ProcessRunner.run(.codesign, args, timeout: 300)
        guard r.succeeded else {
            throw MALError.signingFailed("outer bundle: \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        log.info("signed \(bundle.lastPathComponent) (\(nested.count) nested items)")
        return nested.count
    }

    /// Re-seals a bundle after one of its resource files changed, without touching the
    /// nested code.
    ///
    /// Editing anything inside a signed bundle invalidates its resource seal, but the
    /// nested frameworks and helpers are still validly signed — re-signing all of them
    /// is minutes of work for no benefit. (It is also what made migration appear to hang:
    /// a full re-sign of an Electron clone walks several hundred megabytes.) This does
    /// the one call that is actually needed, preserving the entitlements and the hardened
    /// runtime flag the bundle already carries.
    public func reseal(bundle: URL) throws {
        let existing = readEntitlementsFromSignature(of: bundle)
        let hardened = hasHardenedRuntime(bundle)

        var args = ["--force", "--sign", "-", "--timestamp=none"]
        if hardened { args += ["--options", "runtime"] }
        var temporary: URL?
        if !existing.isEmpty {
            let url = try writeTemporaryEntitlements(existing)
            temporary = url
            args += ["--entitlements", url.path, "--generate-entitlement-der"]
        }
        defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
        args.append(bundle.path)

        let r = try ProcessRunner.run(.codesign, args, timeout: 300)
        guard r.succeeded else {
            throw MALError.signingFailed("re-seal \(bundle.lastPathComponent): \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        log.info("re-sealed \(bundle.lastPathComponent)")
    }

    /// Reads the entitlements out of a bundle's existing signature. Works even when the
    /// resource seal is broken, which is exactly the situation `reseal` is called in.
    public func readEntitlementsFromSignature(of bundle: URL) -> [String: Any] {
        guard let r = try? ProcessRunner.run(.codesign,
                                             ["-d", "--entitlements", ":-", "--xml", bundle.path],
                                             timeout: 60),
              r.succeeded else { return [:] }
        let data = Data(r.stdout.utf8)
        guard !data.isEmpty,
              let obj = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = obj as? [String: Any] else { return [:] }
        return dict
    }

    public func hasHardenedRuntime(_ bundle: URL) -> Bool {
        guard let r = try? ProcessRunner.run(.codesign, ["-dvvv", bundle.path], timeout: 60) else {
            return false
        }
        return (r.stderr + r.stdout).contains("runtime")
    }

    /// `codesign --verify --deep --strict` is the right check *for verification* even
    /// though `--deep` is wrong for signing.
    public func verify(bundle: URL) throws -> String {
        let r = try ProcessRunner.run(.codesign,
                                      ["--verify", "--deep", "--strict", "--verbose=2", bundle.path],
                                      timeout: 300)
        let text = (r.stderr + r.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
        guard r.succeeded else {
            throw MALError.verificationFailed(text.isEmpty ? "codesign exited \(r.status)" : text)
        }
        return text
    }

    /// Records what Gatekeeper thinks. An ad-hoc signed app is *expected* to be
    /// rejected by `spctl` — it is not notarised and never will be. We capture the
    /// output for diagnostics rather than treating it as a failure, because the clone
    /// is created locally and therefore carries no quarantine attribute.
    public func gatekeeperAssessment(bundle: URL) -> String {
        guard let r = try? ProcessRunner.run(.spctl, ["-a", "-vv", "-t", "exec", bundle.path],
                                             timeout: 120) else {
            return "spctl unavailable"
        }
        return (r.stderr + r.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Strips `com.apple.quarantine` from the clone. The clone is produced locally by
    /// copying an app the user already trusts and already runs, so it inherits no
    /// download provenance; leaving a stale quarantine flag on it would produce a
    /// misleading "downloaded from the internet" prompt for a file nobody downloaded.
    /// This does not disable Gatekeeper and does not affect any other file.
    public func clearQuarantine(bundle: URL) {
        _ = try? ProcessRunner.run(.xattr, ["-dr", "com.apple.quarantine", bundle.path], timeout: 120)
    }

    private func writeTemporaryEntitlements(_ dict: [String: Any]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mal-ent-\(UUID().uuidString).plist")
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try data.write(to: url, options: .atomic)
        return url
    }
}
#endif
