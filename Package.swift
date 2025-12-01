// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TermAI",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "TermAI", targets: ["TermAI"])
    ],
    dependencies: [
        .package(path: "Vendor/SwiftTerm")
    ],
    targets: [
        .executableTarget(
            name: "TermAI",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            path: "Sources/TermAI",
            resources: [
                .copy("Resources")
            ]
        )
    ]
)
