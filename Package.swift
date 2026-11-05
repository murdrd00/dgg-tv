// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "DGGTV",
    platforms: [.macOS(.v14), .tvOS(.v17)],
    products: [
        .library(name: "DGGKit", targets: ["DGGKit"]),
        .executable(name: "dggprobe", targets: ["dggprobe"]),
    ],
    targets: [
        .target(
            name: "DGGKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "dggprobe",
            dependencies: ["DGGKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
