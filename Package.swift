// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "usage-query",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "UsageQuery", targets: ["UsageQueryApp"]),
        .executable(name: "UsageQueryCoreTests", targets: ["UsageQueryCoreTests"]),
        .library(name: "UsageQueryCore", targets: ["UsageQueryCore"])
    ],
    targets: [
        .target(
            name: "UsageQueryCore",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "UsageQueryApp",
            dependencies: ["UsageQueryCore"],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "UsageQueryCoreTests",
            dependencies: ["UsageQueryCore"],
            path: "Tests/UsageQueryCoreTests",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
