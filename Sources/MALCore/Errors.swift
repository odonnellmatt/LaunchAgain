import Foundation

public enum MALError: Error, CustomStringConvertible, Equatable {
    case invalidPath(String, reason: String)
    case invalidName(String, reason: String)
    case sourceNotFound(String)
    case sourceNotABundle(String)
    case appNotManaged(String)
    case instanceNotFound(UUID)
    case duplicateInstanceNumber(Int)
    case registryCorrupt(String)
    case registrySchemaTooNew(found: Int, supported: Int)
    case notSupported(reason: String)
    case buildFailed(step: String, underlying: String)
    case rollbackIncomplete(original: String, rollbackFailures: [String])
    case signingFailed(String)
    case verificationFailed(String)
    case iconGenerationFailed(String)
    case launchFailed(String)
    case alreadyRunning(dataPath: String)
    case toolMissing(String)
    case processFailed(tool: String, status: Int32, stderr: String)
    /// A Lite instance of an app whose session lives outside the redirected profile.
    /// Not a build failure — a refusal, because building it silently is how a user ends
    /// up signed out of every copy of an app at once.
    case sharedCredentialStoreNotAcknowledged(appName: String, detail: String)

    public var description: String {
        switch self {
        case .invalidPath(let p, let r):
            return "Invalid path \"\(p)\": \(r)"
        case .invalidName(let n, let r):
            return "Invalid name \"\(n)\": \(r)"
        case .sourceNotFound(let p):
            return "Source application not found at \(p)"
        case .sourceNotABundle(let p):
            return "\(p) is not a .app bundle"
        case .appNotManaged(let k):
            return "No managed app with key \(k)"
        case .instanceNotFound(let id):
            return "No instance with id \(id.uuidString)"
        case .duplicateInstanceNumber(let n):
            return "Instance number \(n) is already in use"
        case .registryCorrupt(let d):
            return "Registry is unreadable: \(d)"
        case .registrySchemaTooNew(let f, let s):
            return "Registry schema v\(f) is newer than this build supports (v\(s)). Update the app."
        case .notSupported(let r):
            return r
        case .buildFailed(let step, let u):
            return "Build failed at \"\(step)\": \(u)"
        case .rollbackIncomplete(let o, let f):
            return "Build failed (\(o)) AND rollback was incomplete: \(f.joined(separator: "; "))"
        case .signingFailed(let d):
            return "Code signing failed: \(d)"
        case .verificationFailed(let d):
            return "Signature verification failed: \(d)"
        case .iconGenerationFailed(let d):
            return "Icon generation failed: \(d)"
        case .launchFailed(let d):
            return "Launch failed: \(d)"
        case .alreadyRunning(let p):
            return "Another process is already using this instance's data directory (\(p)). Quit it first."
        case .toolMissing(let t):
            return "Required system tool not found: \(t)"
        case .processFailed(let tool, let status, let err):
            let tail = err.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(tool) exited \(status)\(tail.isEmpty ? "" : ": \(tail)")"
        case .sharedCredentialStoreNotAcknowledged(_, let detail):
            return detail
        }
    }

    /// The build steps whose failure degrades to Lite rather than failing the build.
    ///
    /// **Exact labels, matched exactly.** This used to be a `hasPrefix` test against
    /// `["sign", "verify", "icon", "shim"]`, matched against two different vocabularies
    /// that nobody had reconciled:
    ///
    /// · the short names a few sites throw by hand — `"shim"`, `"clone"`, `"move"`,
    ///   `"integrity check"` — of which `"shim"` matched;
    /// · the `tx.add(…)` labels `Transaction` wraps a non-`MALError` failure in, which
    ///   are verb phrases: `"generate numbered icon"`, `"install launcher shim"`,
    ///   `"re-sign clone"`, `"verify signature"`. Only `"verify signature"` matched.
    ///
    /// So a signing failure wrapped as `buildFailed("re-sign clone", …)` was not
    /// degradable and an icon failure wrapped as `buildFailed("generate numbered icon",
    /// …)` failed the build outright. It was fail-safe rather than harmful, and the
    /// direct `MALError` cases above still degraded because `Transaction` rethrows those
    /// unwrapped — which is exactly how it went unnoticed for so long. An unreachable
    /// branch is where the next real bug hides.
    ///
    /// Both vocabularies are listed, and the strings must stay equal to the ones the
    /// code actually throws. `MinorRegressionTests` asserts them against the real step
    /// names rather than against invented ones.
    ///
    /// Only the **Full** path's steps belong here: degradation runs on a Full build, so
    /// a Lite-only label like `"sign launcher"` is deliberately absent rather than
    /// listed and unreachable. `"clone"`, `"move"` and `"integrity check"` are absent
    /// because a build that cannot copy the app, cannot move it into place, or has just
    /// failed its integrity check is a failed build, not a Lite one.
    public static let degradableBuildSteps: Set<String> = [
        // Thrown by name.
        "shim",
        // Transaction step labels.
        "install launcher shim",
        "generate numbered icon",
        "re-sign clone",
        "verify signature",
    ]

    /// Whether an instance build hitting this error should be retried in Lite mode
    /// rather than surfaced as a hard failure. This is the core of the
    /// "robust and stable" requirement: signing problems degrade, they don't fail.
    public var isDegradable: Bool {
        switch self {
        case .signingFailed, .verificationFailed, .iconGenerationFailed:
            return true
        case .buildFailed(let step, _):
            return MALError.degradableBuildSteps.contains(step)
        default:
            return false
        }
    }
}
