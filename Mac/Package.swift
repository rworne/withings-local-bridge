// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "WithingsLocalBridge", platforms: [.macOS(.v13)],
    products: [.executable(name: "WithingsLocalBridge", targets: ["WithingsLocalBridge"]),
               .executable(name: "withings-bridge", targets: ["BridgeCLI"]),
               .library(name: "BridgeCore", targets: ["BridgeCore"])],
    targets: [.target(name: "BridgeCore", linkerSettings: [.linkedLibrary("sqlite3")]),
              .executableTarget(name: "WithingsLocalBridge", dependencies: ["BridgeCore"]),
              .executableTarget(name: "BridgeCLI", dependencies: ["BridgeCore"]),
              .testTarget(name: "BridgeCoreTests", dependencies: ["BridgeCore"])])
