// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "CodexHub",
    platforms: [.macOS(.v14)],
    products: [.library(name: "CodexHubCore", targets: ["CodexHubCore"]),
               .library(name: "CodexHubCollector", targets: ["CodexHubCollector"]),
               .executable(name: "CodexHubApp", targets: ["CodexHubApp"]),
               .executable(name: "codex-hub", targets: ["CodexHubHelper"])],
    dependencies: [.package(url: "https://github.com/swiftlang/swift-testing.git", exact: "6.2.4")],
    targets: [
        .target(name: "CodexHubCore"),
        .executableTarget(name: "CodexHubHelper", dependencies: ["CodexHubCore"], resources: [.copy("Resources")]),
        .executableTarget(name: "CodexHubApp", dependencies: ["CodexHubCore", "CodexHubCollector"]),
        .systemLibrary(name: "CSQLite"),
        .target(name: "CodexHubCollector", dependencies: ["CodexHubCore", "CSQLite"]),
        .testTarget(name: "CodexHubCollectorTests", dependencies: [
            "CodexHubCollector", .product(name: "Testing", package: "swift-testing")
        ]),
        .testTarget(name: "CodexHubCoreTests", dependencies: [
            "CodexHubCore", .product(name: "Testing", package: "swift-testing")
        ])
    ]
)
