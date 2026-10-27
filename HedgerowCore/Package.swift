// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HedgerowCore",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "HedgerowCore", targets: ["HedgerowCore"]),
    ],
    targets: [
        .target(name: "HedgerowCore"),
        .testTarget(
            name: "HedgerowCoreTests",
            dependencies: ["HedgerowCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
