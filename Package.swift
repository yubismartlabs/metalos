// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "MetalOS",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MetalOS", targets: ["MetalOS"])],
    targets: [.executableTarget(name: "MetalOS"), .testTarget(name: "MetalOSTests", dependencies: ["MetalOS"])],
    swiftLanguageModes: [.v5]
)
