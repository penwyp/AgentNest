// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AgentNest",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AgentNestCore", targets: ["AgentNestCore"]),
        .executable(name: "AgentNestApp", targets: ["AgentNestApp"]),
        .executable(name: "agentnest-cli", targets: ["AgentNestCLI"]),
        .executable(name: "agentnest-core-tests", targets: ["AgentNestCoreTests"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.5"),
    ],
    targets: [
        .target(
            name: "AgentNestCore",
            resources: [.process("Resources")],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("Network"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreText"),
                .linkedFramework("Security"),
                .linkedLibrary("sqlite3"),
            ]
        ),
        .executableTarget(
            name: "AgentNestApp",
            dependencies: [
                "AgentNestCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        .executableTarget(
            name: "AgentNestCLI",
            dependencies: ["AgentNestCore"]
        ),
        .executableTarget(
            name: "AgentNestCoreTests",
            dependencies: ["AgentNestCore"],
            path: "Tests/AgentNestCoreTests"
        ),
    ]
)
