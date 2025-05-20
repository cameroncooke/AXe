// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "AXe",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "AXe",
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
                "IDBCompanionUtilities",
                "CompanionLib",
                "XCTestBootstrap"
            ],
            path: "Sources/AXe",
            linkerSettings: [
                // Use specific linker flags to statically link the XCFrameworks
                .unsafeFlags([
                    "-Xlinker", "-dead_strip",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path"
                ])
            ]
        ),
        .binaryTarget(
            name: "FBControlCore",
            path: "Artifacts/FBControlCore.xcframework"
        ),
        .binaryTarget(
            name: "FBDeviceControl",
            path: "Artifacts/FBDeviceControl.xcframework"
        ),
        .binaryTarget(
            name: "FBSimulatorControl",
            path: "Artifacts/FBSimulatorControl.xcframework"
        ),
        .binaryTarget(
            name: "IDBCompanionUtilities",
            path: "Artifacts/IDBCompanionUtilities.xcframework"
        ),
        .binaryTarget(
            name: "CompanionLib",
            path: "Artifacts/CompanionLib.xcframework"
        ),
        .binaryTarget(
            name: "XCTestBootstrap",
            path: "Artifacts/XCTestBootstrap.xcframework"
        ),
    ]
)
