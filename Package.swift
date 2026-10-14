// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Explorer",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Explorer", targets: ["ExplorerApp"])],
    targets: [
        .target(name: "ExplorerCore"),
        .executableTarget(name: "ExplorerApp", dependencies: ["ExplorerCore"]),
        .testTarget(name: "ExplorerCoreTests", dependencies: ["ExplorerCore"]),
        .testTarget(name: "ExplorerAppTests", dependencies: ["ExplorerApp"])
    ]
)
