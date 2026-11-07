// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Yaku",
    // `.v26` requires PackageDescription 6.2; the string form is the same
    // deployment target and keeps the tools version at 6.0 (SPEC 16).
    platforms: [.macOS("26.0")],
    targets: [
        .target(
            name: "YakuCore",
            path: "Sources/YakuCore"
        ),
        .executableTarget(
            name: "Yaku",
            dependencies: ["YakuCore"],
            path: "Sources/Yaku"
        ),
        .testTarget(
            name: "YakuCoreTests",
            dependencies: ["YakuCore"],
            path: "Tests/YakuCoreTests"
        ),
    ]
)
