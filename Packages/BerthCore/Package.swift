// swift-tools-version: 6.2
import PackageDescription

let strict: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("ImmutableWeakCaptures"),
    .treatAllWarnings(as: .error),
]

let package = Package(
    name: "BerthCore",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "BerthCore", targets: ["BerthCore"]),
        .executable(name: "berth-host", targets: ["berth-host"]),
    ],
    targets: [
        .target(name: "BerthCore", swiftSettings: strict),
        .executableTarget(name: "berth-host", dependencies: ["BerthCore"], swiftSettings: strict),
        .testTarget(name: "BerthCoreTests", dependencies: ["BerthCore"], resources: [.copy("Fixtures")], swiftSettings: strict),
    ]
)
