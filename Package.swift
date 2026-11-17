// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "IPodManager",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "IPodManager", targets: ["IPodManager"]),
        .library(name: "IPodKit", targets: ["IPodKit"])
    ],
    targets: [
        .target(name: "IPodKit", path: "Sources/IPodKit"),
        .executableTarget(
            name: "IPodManager",
            dependencies: ["IPodKit"],
            path: "Sources/IPodManager"
        ),
        .testTarget(
            name: "IPodKitTests",
            dependencies: ["IPodKit"],
            path: "Tests/IPodKitTests"
        )
    ]
)
