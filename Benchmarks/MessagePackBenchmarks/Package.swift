// swift-tools-version: 6.4

import PackageDescription

// Standalone package so that ordo-one/benchmark (and its jemalloc system
// library) never enters the dependency graph of MessagePack-Swift's own
// consumers. Run from this directory:
//
//     swift package benchmark run
//
let package = Package(
    name: "MessagePackBenchmarks",
    // Benchmarks only ever run on the host.
    platforms: [
        .macOS(.v15),
    ],
    dependencies: [
        .package(path: "../.."),
        .package(url: "https://github.com/ordo-one/benchmark", from: "1.29.0"),
    ],
    targets: [
        .executableTarget(
            name: "MessagePackBenchmarks",
            dependencies: [
                .product(name: "Benchmark", package: "benchmark"),
                .product(name: "MessagePack", package: "MessagePack-Swift"),
            ],
            path: "Benchmarks/MessagePackBenchmarks",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
            plugins: [
                .plugin(name: "BenchmarkPlugin", package: "benchmark"),
            ],
        ),
    ],
    swiftLanguageModes: [.v6]
)
