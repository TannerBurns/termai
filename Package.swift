// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TermAI",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "TermAI", targets: ["TermAI"]),
        .library(name: "TermAIModels", targets: ["TermAIModels"])
    ],
    dependencies: [
        .package(path: "Vendor/SwiftTerm")
    ],
    targets: [
        // Models library containing testable types (no SwiftUI dependencies)
        .target(
            name: "TermAIModels",
            dependencies: [],
            path: "Sources/TermAIModels"
        ),
        // Main executable
        .executableTarget(
            name: "TermAI",
            dependencies: [
                "TermAIModels",
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            path: "Sources/TermAI",
            resources: [
                .copy("Resources")
            ]
        ),
        // Tests for the models and suggestion logic
        .testTarget(
            name: "TermAITests",
            dependencies: ["TermAI", "TermAIModels"],
            path: "Tests/TermAITests"
        ),
        // Structure/documentation tests for Settings views
        .testTarget(
            name: "TermAIViewTests",
            dependencies: ["TermAIModels"],
            path: "Tests/TermAIViewTests"
        )
    ]
)
