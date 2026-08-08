#if canImport(Darwin)
import Foundation
import MALCore

/// Read-only proof that a bundle is one LaunchAgain generated for a specific instance.
///
/// This verifier is deliberately shared by recovery, uninstall and orphan cleanup.
/// A path merely being inside `~/Applications/LaunchAgain` is not ownership evidence.
public enum LauncherIdentityVerifier {

    public struct Verified: Sendable {
        public var bundle: URL
        public var infoIdentifier: String
        public var config: InstanceConfig
        public var manifest: LauncherRecoveryManifest?
    }

    public static func verify(
        bundle: URL,
        paths: MALPaths,
        expected: Instance? = nil,
        requireManifest: Bool = false
    ) throws -> Verified {
        try paths.assertLauncherBundlePath(bundle.path)

        let standardized = bundle.standardizedFileURL
        let values = try standardized.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw MALError.invalidPath(
                bundle.path,
                reason: "a launcher must be a real directory, not a symlink")
        }

        let info = try BundleAssembler.readInfoPlist(bundle: standardized)
        guard info["MALGeneratedBy"] as? String == "LaunchAgain",
              let infoIdentifier = info["CFBundleIdentifier"] as? String else {
            throw MALError.invalidPath(
                bundle.path,
                reason: "the bundle does not carry LaunchAgain ownership metadata")
        }
        let config = try BundleAssembler.readInstanceConfig(from: standardized)

        let manifest = try? BundleAssembler.readRecoveryManifest(from: standardized)
        if requireManifest, manifest == nil {
            throw MALError.registryCorrupt(
                "the launcher has no durable LaunchAgain recovery manifest")
        }
        // A sealed signature is required, and required *unconditionally*.
        //
        // This used to read `if hasSignature { verify }`, with only the sweeper's
        // `requireManifest: true` path insisting the signature existed at all. The
        // uninstall path passed false, so deleting `Contents/_CodeSignature` made a
        // bundle **easier** to delete rather than harder — a check that gets weaker when
        // evidence is removed, which is backwards. It was reproduced: a planted
        // third-party application with copied ownership metadata was refused until its
        // signature was stripped, after which `delete` uninstalled it.
        //
        // Everything LaunchAgain builds is ad-hoc signed before it is moved into place,
        // so this costs a legitimate launcher nothing. A launcher whose signature has
        // been destroyed by something else is reported by `doctor` and can be removed in
        // Finder; it is not silently deleted by a tool that cannot prove it made it.
        let signatureDirectory = standardized
            .appendingPathComponent("Contents/_CodeSignature")
        guard FileManager.default.fileExists(atPath: signatureDirectory.path) else {
            throw MALError.verificationFailed(
                "this bundle has no sealed code signature, so LaunchAgain cannot prove it created it. "
                    + "Nothing was removed. If this is a launcher whose signature was damaged, rebuild it, "
                    + "or remove it in Finder.")
        }
        _ = try CodeSigner(log: .silent).verify(bundle: standardized)

        if let manifest {
            try validate(
                manifest: manifest,
                info: info,
                infoIdentifier: infoIdentifier,
                config: config,
                bundle: standardized)
        }

        if let expected {
            try validate(
                expected: expected,
                manifest: manifest,
                infoIdentifier: infoIdentifier,
                config: config,
                bundle: standardized)
        } else if manifest == nil {
            throw MALError.registryCorrupt(
                "legacy launchers require an authoritative registry instance for ownership verification")
        }

        return Verified(
            bundle: standardized,
            infoIdentifier: infoIdentifier,
            config: config,
            manifest: manifest)
    }

    private static func validate(
        manifest: LauncherRecoveryManifest,
        info: [String: Any],
        infoIdentifier: String,
        config: InstanceConfig,
        bundle: URL
    ) throws {
        let instance = manifest.instance
        let expectedMechanism: IsolationMechanism =
            config.kind == .app ? .userDataDir : .configEnvironment
        guard manifest.schemaVersion <= LauncherRecoveryManifest.currentSchemaVersion,
              !manifest.appKey.isEmpty,
              instance.number > 0,
              instance.mechanism == expectedMechanism,
              Validation.isCloneBundleIdentifier(
                  infoIdentifier,
                  forNumber: instance.number,
                  instanceID: instance.id),
              instance.clonedBundleIdentifier == infoIdentifier,
              Validation.pathsReferToSameLocation(instance.dataPath, config.dataPath),
              instance.mode == config.mode,
              instance.extraArguments == config.extraArguments,
              instance.extraEnvironment == config.extraEnvironment else {
            throw MALError.registryCorrupt(
                "the launcher recovery manifest, Info.plist and instance configuration do not describe one identity")
        }

        if config.kind == .tool {
            let script = URL(fileURLWithPath: config.scriptPath).standardizedFileURL
            let resources = bundle.appendingPathComponent("Contents/Resources")
                .standardizedFileURL
            guard script.deletingLastPathComponent().path == resources.path,
                  script.pathExtension == "command" else {
                throw MALError.registryCorrupt(
                    "the legacy Terminal launch script is not owned by this launcher")
            }
            return
        }

        switch config.mode {
        case .full:
            guard info["MALOriginalBundleIdentifier"] as? String == manifest.appKey,
                  !config.realExecutableName.isEmpty else {
                throw MALError.registryCorrupt(
                    "the full launcher does not match its original application identity")
            }
        case .lite:
            guard Validation.pathsReferToSameLocation(
                config.targetAppPath, manifest.sourcePath) else {
                throw MALError.registryCorrupt(
                    "the Lite launcher target does not match its recovery source")
            }
        }
    }

    private static func validate(
        expected: Instance,
        manifest: LauncherRecoveryManifest?,
        infoIdentifier: String,
        config: InstanceConfig,
        bundle: URL
    ) throws {
        let expectedMechanism: IsolationMechanism =
            config.kind == .app ? .userDataDir : .configEnvironment
        guard expected.number > 0,
              expected.mechanism == expectedMechanism,
              Validation.pathsReferToSameLocation(expected.bundlePath, bundle.path),
              Validation.isCloneBundleIdentifier(
                infoIdentifier,
                forNumber: expected.number,
                instanceID: expected.id),
              expected.clonedBundleIdentifier.isEmpty
                || expected.clonedBundleIdentifier == infoIdentifier,
              Validation.pathsReferToSameLocation(expected.dataPath, config.dataPath),
              expected.mode == config.mode,
              expected.extraArguments == config.extraArguments,
              expected.extraEnvironment == config.extraEnvironment else {
            throw MALError.invalidPath(
                bundle.path,
                reason: "the launcher does not belong to the selected registry instance")
        }

        if let manifest {
            guard manifest.instance.id == expected.id,
                  manifest.instance.number == expected.number else {
                throw MALError.invalidPath(
                    bundle.path,
                    reason: "the launcher's durable UUID/number do not match the selected instance")
            }
        } else {
            // Compatibility for pre-manifest launchers: the generated identifier and
            // UUID-derived default profile still bind the bundle to the registry row.
            let components = URL(fileURLWithPath: config.dataPath)
                .standardizedFileURL.pathComponents
            guard let index = components.lastIndex(of: "instances"),
                  components.indices.contains(index + 1),
                  UUID(uuidString: components[index + 1]) == expected.id else {
                throw MALError.invalidPath(
                    bundle.path,
                    reason: "the legacy launcher is not bound to this instance UUID")
            }
        }
    }
}
#endif
