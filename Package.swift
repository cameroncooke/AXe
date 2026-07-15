// swift-tools-version:5.10
import Foundation
import PackageDescription

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let idbCheckoutDirectory = ProcessInfo.processInfo.environment["IDB_CHECKOUT_DIR"]
    .map { URL(fileURLWithPath: $0) }
    ?? packageRoot.appendingPathComponent("idb_checkout", isDirectory: true)
let idbPrivateHeadersDirectory = idbCheckoutDirectory.appendingPathComponent(
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
].flatMap { ["-I", $0.path] }

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
                "FBDeviceControl",
                "FBControlCore",
                "XCTestBootstrap"
            ],
            path: "Sources/AXe",
            resources: [
                .copy("Resources/skills")
            ],
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"] + idbPrivateHeaderSearchFlags)
            ],
            linkerSettings: [
                // For XCFrameworks, rpath can often be just @executable_path
                // if SPM handles embedding correctly, or you might need to adjust
                // if you manually copy them later for distribution.
                .unsafeFlags([
                    "-Xlinker", "-dead_strip",
                    "-Xlinker", "-headerpad_max_install_names",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path" // Simpler rpath for SPM-handled XCFrameworks
                ])
            ],
            plugins: ["VersionPlugin"]
        ),
        .testTarget(
            name: "AXeTests",
            dependencies: ["AXe", "AXeCore"],
            path: "Tests",
            exclude: ["Goldens"],
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
            path: "build_products/XCFrameworks/FBControlCore.xcframework" // Updated path
        ),
        .binaryTarget(
            name: "FBDeviceControl",
            path: "build_products/XCFrameworks/FBDeviceControl.xcframework" // Updated path
        ),
        .binaryTarget(
            name: "FBSimulatorControl",
            path: "build_products/XCFrameworks/FBSimulatorControl.xcframework" // Updated path
        ),
        .binaryTarget(
            name: "XCTestBootstrap",
            path: "build_products/XCFrameworks/XCTestBootstrap.xcframework" // Updated path
        ),
    ]
)
