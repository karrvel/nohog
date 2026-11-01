// swift-tools-version:6.0
import PackageDescription

// Warnings are errors in CI and in scripts/release.sh (`-Xswiftc -warnings-as-errors`), not here:
// a newer Xcode adding a deprecation warning must not break a user's source build (e.g. Homebrew).
let package = Package(
    name: "nohog",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "NohogCore"),
        .executableTarget(name: "nohog", dependencies: ["NohogCore"]),
        .testTarget(name: "NohogCoreTests", dependencies: ["NohogCore"]),
    ]
)
