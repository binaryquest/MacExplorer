// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Explorer",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Explorer", targets: ["ExplorerApp"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: [
        .target(name: "ExplorerCore"),
        .executableTarget(name: "ExplorerApp", dependencies: ["ExplorerCore", .product(name: "Sparkle", package: "Sparkle")],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "ExplorerCoreTests", dependencies: ["ExplorerCore"]),
        .testTarget(name: "ExplorerAppTests", dependencies: ["ExplorerApp"])
    ]
)
