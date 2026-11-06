// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Brise",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Brise", targets: ["Brise"]),
        .executable(name: "brise-helper", targets: ["brise-helper"]),
    ],
    targets: [
        .target(name: "CSMC", linkerSettings: [.linkedFramework("IOKit")]),
        .target(name: "BriseCore", dependencies: ["CSMC"]),
        .executableTarget(name: "Brise", dependencies: ["BriseCore"]),
        .executableTarget(name: "brise-helper", dependencies: ["BriseCore"]),
    ]
)
