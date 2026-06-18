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
            dependencies: [
                "UsageMeterCore",
                "Sparkle"
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks"
                ])
            ]
        ),
        .binaryTarget(
            name: "Sparkle",
            url: "https://github.com/sparkle-project/Sparkle/releases/download/2.9.3/Sparkle-for-Swift-Package-Manager.zip",
            checksum: "3a5d7fd698acc39c122e75764ed3614b472b284cc483f32ae7006d86c513370c"
        ),
        .testTarget(
            name: "UsageMeterTests",
            dependencies: ["UsageMeterCore"]
        )
    ]
)
