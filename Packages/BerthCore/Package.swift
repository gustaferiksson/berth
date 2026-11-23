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
        .executable(name: "berth-cli", targets: ["berth-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/tree-sitter/swift-tree-sitter", exact: "0.25.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-typescript", exact: "0.23.2"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-javascript", exact: "0.23.1"),
    ],
    targets: [
        .target(name: "BerthCore", swiftSettings: strict),
        .executableTarget(name: "berth-host", dependencies: ["BerthCore"], swiftSettings: strict),
        .executableTarget(name: "berth-cli", dependencies: ["BerthCore"], swiftSettings: strict),
        .testTarget(
            name: "BerthCoreTests",
            dependencies: [
                "BerthCore",
                .product(name: "SwiftTreeSitter", package: "swift-tree-sitter"),
                .product(name: "TreeSitterTypeScript", package: "tree-sitter-typescript"),
                .product(name: "TreeSitterJavaScript", package: "tree-sitter-javascript"),
            ],
            resources: [.copy("Fixtures")],
            swiftSettings: strict
        ),
    ]
)
