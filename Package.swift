// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MacGuard",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacGuard", targets: ["MacGuard"]),
    ],
    targets: [
        .target(name: "GuardCore"),
        .executableTarget(
            name: "MacGuard",
            dependencies: ["GuardCore"]
        ),
        .testTarget(
            name: "GuardCoreTests",
            dependencies: ["GuardCore"]
        ),
    ]
)
