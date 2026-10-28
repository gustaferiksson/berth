// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "BerthCore",
  platforms: [.macOS("26.0")],
  products: [
    .library(name: "BerthCore", targets: ["BerthCore"])
  ],
  targets: [
    .target(name: "BerthCore"),
    .testTarget(name: "BerthCoreTests", dependencies: ["BerthCore"], resources: [.copy("Fixtures")]),
  ]
)
