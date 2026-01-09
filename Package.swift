// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "PiSwift",
    platforms: [.macOS(.v14), .iOS(.v18)],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "PiSwift",
            targets: ["PiSwift"]
        ),
        .library(
            name: "PiSwiftAI",
            targets: ["PiSwiftAI"]
        ),
        .library(
            name: "PiSwiftAgent",
            targets: ["PiSwiftAgent"]
        ),
        .library(
            name: "PiSwiftCodingAgent",
            targets: ["PiSwiftCodingAgent"]
        ),
        .library(
            name: "PiSwiftCodingAgentTui",
            targets: ["PiSwiftCodingAgentTui"]
        ),
        .library(
            name: "PiSwiftSyntaxHighlight",
            targets: ["PiSwiftSyntaxHighlight"]
        ),
        .executable(
            name: "pi-ai",
            targets: ["PiSwiftAICLI"]
        ),
        .executable(
            name: "pi-coding-agent",
            targets: ["PiSwiftCodingAgentCLI"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/MacPaw/OpenAI.git", branch: "main"),
        .package(url: "https://github.com/jamesrochabrun/SwiftAnthropic.git", branch: "main"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.4.0"),
        .package(path: "../MiniTui"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "PiSwift"
        ),
        .target(
            name: "PiSwiftAI",
            dependencies: [
                .product(name: "OpenAI", package: "OpenAI"),
                .product(name: "SwiftAnthropic", package: "SwiftAnthropic"),
            ]
        ),
        .target(
            name: "PiSwiftAgent",
            dependencies: ["PiSwiftAI"]
        ),
        .target(
            name: "PiSwiftCodingAgent",
            dependencies: [
                "PiSwiftAI",
                "PiSwiftAgent",
            ],
            resources: [
                .process("Resources")
            ]
        ),
        .target(
            name: "PiSwiftCodingAgentTui",
            dependencies: [
                "PiSwiftAI",
                "PiSwiftAgent",
                "PiSwiftCodingAgent",
                "PiSwiftSyntaxHighlight",
                .product(name: "MiniTui", package: "MiniTui"),
            ]
        ),
        .target(
            name: "PiSwiftSyntaxHighlight"
        ),
        .executableTarget(
            name: "PiSwiftAICLI",
            dependencies: [
                "PiSwiftAI",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "PiSwiftCodingAgentCLI",
            dependencies: [
                "PiSwiftCodingAgent",
                "PiSwiftCodingAgentTui",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "PiSwiftAITests",
            dependencies: ["PiSwiftAI"]
        ),
        .testTarget(
            name: "PiSwiftAgentTests",
            dependencies: ["PiSwiftAgent"]
        ),
        .testTarget(
            name: "PiSwiftCodingAgentTests",
            dependencies: [
                "PiSwiftCodingAgent",
                "PiSwiftAI",
                "PiSwiftAgent",
            ],
            resources: [
                .copy("fixtures")
            ]
        ),
        .testTarget(
            name: "PiSwiftCodingAgentCLITests",
            dependencies: [
                "PiSwiftCodingAgent",
                "PiSwiftCodingAgentCLI",
            ],
            resources: [
                .copy("fixtures")
            ]
        ),
        .testTarget(
            name: "PiSwiftCodingAgentTuiTests",
            dependencies: [
                "PiSwiftCodingAgent",
                "PiSwiftCodingAgentTui",
                .product(name: "MiniTui", package: "MiniTui"),
            ]
        ),
        .testTarget(
            name: "PiSwiftTests",
            dependencies: ["PiSwift"]
        ),
    ]
)
