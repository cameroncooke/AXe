// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "AXe",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "axe",
            targets: ["AXe"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "AXe",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "FBSimulatorControl",
                "FBDeviceControl",
                "FBControlCore",
                "XCTestBootstrap"
            ],
            path: "Sources/AXe",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
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
            dependencies: ["AXe"],
            path: "Tests",
            resources: [
                .copy("README.md")
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
