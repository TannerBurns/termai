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
        .package(path: "Vendor/SwiftTerm"),
        .package(path: "Vendor/Down")
    ],
    targets: [
        .executableTarget(
            name: "TermAI",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Down", package: "Down")
            ],
            path: "Sources/TermAI",
            resources: []
        )
    ]
)


