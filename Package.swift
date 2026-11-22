// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "MetalOS",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MetalOS", targets: ["MetalOS"]),
        .executable(name: "NXProcessRunner", targets: ["NXProcessRunner"])
    ],
    targets: [
        .executableTarget(name: "MetalOS", resources: [.process("Resources")]),
        .executableTarget(name: "NXProcessRunner", path: "Sources/NXProcessRunner"),
        .testTarget(name: "MetalOSTests", dependencies: ["MetalOS"])
    ],
    swiftLanguageModes: [.v5]
)
