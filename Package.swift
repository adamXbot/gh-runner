// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RunnerMenu",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "RunnerMenu", targets: ["RunnerMenu"]),
        .executable(name: "RunnerAgent", targets: ["RunnerAgent"]),
        .library(name: "RunnerAgentProtocol", targets: ["RunnerAgentProtocol"])
    ],
    dependencies: [
        // Sparkle ships as an XCFramework binary target. It is linked here and
        // *embedded* by build-app.sh — SwiftPM does not assemble .app bundles,
        // so nothing else would copy it into Contents/Frameworks.
        //
        // Pinned to the same 2.9.5 the release pipeline's Sparkle CLI uses, so
        // the framework that ships and the tool that signs the appcast come
        // from one release.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.5")
    ],
    targets: [
        .target(
            name: "RunnerAgentProtocol",
            path: "Sources/RunnerAgentProtocol",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("Security")]
        ),
        .executableTarget(
            name: "RunnerMenu",
            dependencies: [
                "RunnerAgentProtocol",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/RunnerMenu",
            swiftSettings: [
                // Pragmatic: use the Swift 5 language mode to avoid strict-concurrency
                // churn while still building with the Swift 6 toolchain. UI state is
                // isolated to @MainActor where it matters.
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                // The framework lives in Contents/Frameworks of the assembled
                // bundle, which is ../Frameworks relative to the executable.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        .executableTarget(
            name: "RunnerAgent",
            dependencies: ["RunnerAgentProtocol"],
            path: "Sources/RunnerAgent",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "RunnerMenuTests",
            dependencies: ["RunnerMenu", "RunnerAgent", "RunnerAgentProtocol"],
            path: "Tests/RunnerMenuTests"
        )
    ]
)
