// swift-tools-version:5.10
import Foundation
import PackageDescription

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
// AXe's own copy of the IDB frameworks it uses; scripts/build.sh builds their XCFrameworks.
let idbKitDirectory = packageRoot.appendingPathComponent("Packages/IDBKit", isDirectory: true)
let idbPrivateHeadersDirectory = idbKitDirectory.appendingPathComponent(
    "PrivateHeaders",
    isDirectory: true
)
// Compile-only module-map inputs: never copy these headers into release artifacts or runtime rpaths.
let idbPrivateHeaderSearchFlags = [
    idbPrivateHeadersDirectory,
    idbPrivateHeadersDirectory.appendingPathComponent("AccessibilityPlatformTranslation", isDirectory: true),
    idbPrivateHeadersDirectory.appendingPathComponent("AXRuntime", isDirectory: true),
    idbPrivateHeadersDirectory.appendingPathComponent("CoreSimDeviceIO", isDirectory: true),
    idbPrivateHeadersDirectory.appendingPathComponent("CoreSimulator", isDirectory: true),
    idbPrivateHeadersDirectory.appendingPathComponent("CoreSimulatorUtilities", isDirectory: true),
    idbPrivateHeadersDirectory.appendingPathComponent("SimulatorKit", isDirectory: true),
// Keep each search path in one token. SwiftPM can otherwise drop the path while propagating
// unsafe flags to its generated test runner, leaving a bare `-I` that consumes the next option.
].map { "-I\($0.path)" }

let package = Package(
    name: "AXe",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "AXeCore",
            targets: ["AXeCore"]
        ),
        .executable(
            name: "axe",
            targets: ["AXe"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "AXeCore",
            path: "Sources/AXeCore"
        ),
        .executableTarget(
            name: "AXe",
            dependencies: [
                "AXeCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "FBSimulatorControl",
                "FBControlCore"
            ],
            path: "Sources/AXe",
            resources: [
                .copy("Resources/skills"),
                .copy("Resources/licenses")
            ],
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"] + idbPrivateHeaderSearchFlags)
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-dead_strip",
                    "-Xlinker", "-headerpad_max_install_names",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path",
                    // The isolated Slider read worker uses declared AXP bridge types.
                    // This is a compile input; its headers are not distributed.
                    "-Xlinker", "-weak_library", "-Xlinker",
                    idbPrivateHeadersDirectory.appendingPathComponent(
                        "AccessibilityPlatformTranslation/AccessibilityPlatformTranslation.tbd").path
                ])
            ],
            plugins: ["VersionPlugin"]
        ),
        .testTarget(
            name: "AXeTests",
            dependencies: ["AXe", "AXeCore"],
            path: "Tests",
            swiftSettings: [
                .unsafeFlags(idbPrivateHeaderSearchFlags)
            ]
        ),
        .plugin(
            name: "VersionPlugin",
            capability: .buildTool(),
            path: "Plugins/VersionPlugin"
        ),
        .binaryTarget(
            name: "FBControlCore",
            path: "build_products/XCFrameworks/FBControlCore.xcframework"
        ),
        .binaryTarget(
            name: "FBSimulatorControl",
            path: "build_products/XCFrameworks/FBSimulatorControl.xcframework"
        ),
    ]
)
