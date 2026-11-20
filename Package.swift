// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "nethernet",
    products: [
        .library(name: "NetherNet", targets: ["NetherNet"]),
        .executable(name: "nethernet-demo", targets: ["NetherNetDemo"])
    ],
    dependencies: [.package(url: "https://github.com/krzyzanowskim/CryptoSwift.git", exact: "1.9.0")],
    targets: [
        .target(
            name: "NetherNet", dependencies: ["CryptoSwift"],
            linkerSettings: [.linkedLibrary("ws2_32", .when(platforms: [.windows]))]
        ),
        .executableTarget(name: "NetherNetDemo", dependencies: ["NetherNet"]),
        .testTarget(name: "NetherNetTests", dependencies: ["NetherNet"])
    ]
)
