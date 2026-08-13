// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MorrowNavigator",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MorrowNavigator", targets: ["MorrowNavigator"]),
        .executable(name: "morrow", targets: ["MorrowNavigatorCLI"]),
        .executable(name: "MorrowNavigatorCoreSelfTest", targets: ["MorrowNavigatorCoreSelfTest"])
    ],
    targets: [
        .target(
            name: "MorrowNavigatorCore"
        ),
        .executableTarget(
            name: "MorrowNavigator",
            dependencies: ["MorrowNavigatorCore"]
        ),
        .executableTarget(
            name: "MorrowNavigatorCLI",
            dependencies: ["MorrowNavigatorCore"]
        ),
        .executableTarget(
            name: "MorrowNavigatorCoreSelfTest",
            dependencies: ["MorrowNavigatorCore"]
        )
    ]
)
