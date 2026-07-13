// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RunnerMenu",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "RunnerMenu", targets: ["RunnerMenu"])
    ],
    targets: [
        .executableTarget(
            name: "RunnerMenu",
            path: "Sources/RunnerMenu",
            swiftSettings: [
                // Pragmatic: use the Swift 5 language mode to avoid strict-concurrency
                // churn while still building with the Swift 6 toolchain. UI state is
                // isolated to @MainActor where it matters.
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "RunnerMenuTests",
            dependencies: ["RunnerMenu"],
            path: "Tests/RunnerMenuTests"
        )
    ]
)
