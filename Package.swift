// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "UsageMeter",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "UsageMeterCore", targets: ["UsageMeterCore"]),
        .executable(name: "UsageMeter", targets: ["UsageMeter"])
    ],
    dependencies: [],
    targets: [
        .target(name: "UsageMeterCore"),
        .executableTarget(
            name: "UsageMeter",
            dependencies: ["UsageMeterCore"]
        ),
        .testTarget(
            name: "UsageMeterTests",
            dependencies: ["UsageMeterCore"]
        )
    ]
)
