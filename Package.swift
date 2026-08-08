// swift-tools-version: 5.9
// LaunchAgain
//
// Deliberately ZERO external dependencies. Everything ships in this repository or
// comes from the OS. The built application makes no network requests at all.
//
// Build universal (Apple Silicon + Intel):
//   swift build -c release --arch arm64 --arch x86_64
// Or just run Scripts/build-app.sh which also assembles the .app bundle.

import PackageDescription

let package = Package(
    name: "LaunchAgain",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "MALCore", targets: ["MALCore"]),
        .library(name: "MALKit", targets: ["MALKit"]),
        // NOTE: these two names must not differ only by case. macOS filesystems are
        // case-insensitive by default, so a `launchagain` CLI and a `LaunchAgain` app
        // are the *same file* in the build directory — whichever links last wins, and
        // running one silently runs the other. The .app bundle's GUI executable is
        // renamed to `LaunchAgainGUI` when Scripts/build-app.sh assembles it.
        .executable(name: "launchagain", targets: ["MALCLI"]),
        .executable(name: "mal-shim", targets: ["MALShim"]),
        .executable(name: "LaunchAgainApp", targets: ["MALApp"]),
    ],
    targets: [
        // Portable, dependency-free logic. Compiles and unit-tests on any platform,
        // which is what lets the risky parts (numbering, atomicity, argv escaping)
        // be verified without a Mac in the loop.
        .target(name: "MALCore"),

        // macOS-only engine. Every file is guarded with #if canImport(AppKit) so the
        // package still builds on Linux for CI of MALCore.
        .target(name: "MALKit", dependencies: ["MALCore"]),

        // Exec shim planted inside each cloned bundle. It repairs a recognised Electron
        // window-state file before replacing itself with the real application, so a
        // window saved on a disconnected display can be reached again. `execv` replaces
        // the whole address space; Foundation/AppKit loaded by the shim do not remain in
        // the target application.
        .executableTarget(name: "MALShim", dependencies: ["MALCore"]),

        // Headless production CLI. Historical feasibility code remains in the source
        // tree for auditability but is explicitly excluded below.
        .executableTarget(
            name: "MALCLI",
            dependencies: ["MALCore", "MALKit"]),

        // SwiftUI interface.
        .executableTarget(name: "MALApp", dependencies: ["MALCore", "MALKit"]),

        // Pure logic: numbering, atomicity, plist and entitlement patching, argv
        // construction, compatibility rules. Runs anywhere.
        .testTarget(name: "MALCoreTests", dependencies: ["MALCore"]),

        // The macOS engine: icon rendering, cloning, signing, the whole build pipeline
        // against a synthetic application bundle.
        .testTarget(name: "MALKitTests", dependencies: ["MALKit", "MALCore"]),

        // The real SwiftUI dashboard hosted in an NSWindow against an isolated store.
        // Dynamic row changes exercise the same view graph as the shipping app.
        .testTarget(name: "MALAppTests", dependencies: ["MALApp", "MALKit", "MALCore"]),
    ]
)
