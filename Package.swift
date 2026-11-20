// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "nethernet",
    products: [
        .library(name: "NetherNet", targets: ["NetherNet"]),
        .executable(name: "nethernet-demo", targets: ["NetherNetDemo"])
    ],
    dependencies: [
        .package(url: "https://github.com/krzyzanowskim/CryptoSwift.git", exact: "1.9.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.5.2")
    ],
    targets: [
        .target(
            name: "NetherNet",
            dependencies: ["CryptoSwift", .product(name: "Crypto", package: "swift-crypto")],
            linkerSettings: [.linkedLibrary("ws2_32", .when(platforms: [.windows]))]
        ),
        .executableTarget(name: "NetherNetDemo", dependencies: ["NetherNet"]),
        .testTarget(name: "NetherNetTests", dependencies: ["NetherNet"])
    ]
)
