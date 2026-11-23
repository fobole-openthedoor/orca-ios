// swift-tools-version: 6.0
import PackageDescription

// The protocol layer: pairing, encryption and RPC. No UIKit, so it builds and tests on macOS too.
let package = Package(
  name: "OrcaCore",
  platforms: [.iOS("26.0"), .macOS(.v14)],
  products: [.library(name: "OrcaCore", targets: ["OrcaCore"])],
  targets: [
    .target(name: "OrcaCore"),
    .testTarget(name: "OrcaCoreTests", dependencies: ["OrcaCore"]),
  ]
)
