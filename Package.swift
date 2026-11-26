// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwarfPath",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CAMCore", targets: ["CAMCore"]),
        .executable(name: "SwarfPath", targets: ["SwarfPathApp"]),
        .executable(name: "swarfpath-cli", targets: ["swarfpath-cli"]),
    ],
    targets: [
        .target(
            name: "CAMCore",
            swiftSettings: [.unsafeFlags(["-Ounchecked"], .when(configuration: .release))]
        ),
        .executableTarget(
            name: "SwarfPathApp",
            dependencies: ["CAMCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(name: "swarfpath-cli", dependencies: ["CAMCore"]),
        .testTarget(name: "CAMCoreTests", dependencies: ["CAMCore"]),
    ]
)
