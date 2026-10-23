// swift-tools-version: 6.0
import PackageDescription

// The app itself is built from project.yml (XcodeGen). This package holds the
// UI-free core (layout tree, control protocol, CLI parser), the `lterm` CLI and the tests.
let package = Package(
    name: "Lterm",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LtermCore", targets: ["LtermCore"]),
        .executable(name: "lterm", targets: ["lterm"]),
    ],
    targets: [
        .target(name: "LtermCore", path: "Sources/LtermCore"),
        .executableTarget(name: "lterm", dependencies: ["LtermCore"], path: "Sources/lterm"),
        .testTarget(name: "LtermCoreTests", dependencies: ["LtermCore"], path: "Tests/LtermCoreTests"),
    ]
)
