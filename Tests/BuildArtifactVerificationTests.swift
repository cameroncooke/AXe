import CryptoKit
import Foundation
import Testing

@Suite("Public build artifact verification", .serialized)
struct BuildArtifactVerificationTests {
    enum Variant: String, CaseIterable, Sendable {
        case current, swiftImport, swiftType, headerImport, headerType
        case missingCompiledModule, missingHeader, missingInterface, missingFeatureReference

        var expectedMessage: String? {
            switch self {
            case .current: return nil
            case .swiftImport, .swiftType, .headerImport, .headerType:
                return "leaks AccessibilityPlatformTranslation through its public interface"
            case .missingCompiledModule: return "compiled Swift module is missing"
            case .missingHeader, .missingInterface: return "public module artifact is missing"
            case .missingFeatureReference: return "missing required AXe feature evidence: setClientType:"
            }
        }
    }

    private struct XCFrameworkInfo: Decodable {
        struct Library: Decodable {
            let LibraryIdentifier: String
            let LibraryPath: String
            let SupportedArchitectures: [String]
        }
        let AvailableLibraries: [Library]
    }

    private var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private let products = ["FBControlCore", "FBSimulatorControl"]

    // Keep these public-command cases serial. They never compile, launch a simulator,
    // or change an original framework. Other products are read-only verification inputs.
    @Test(arguments: Variant.allCases)
    func publicVerifierKeepsArtifactBoundaries(variant: Variant) throws {
        let manager = FileManager.default
        let originals = repository.appendingPathComponent("build_products/XCFrameworks")
        let before = try fingerprints(originals)
        let directory = manager.temporaryDirectory.appendingPathComponent("axe-artifact-check-" + UUID().uuidString)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: directory) }

        do {
            let copies = directory.appendingPathComponent("XCFrameworks")
            try manager.createDirectory(at: copies, withIntermediateDirectories: true)
            for product in products {
                let name = product + ".xcframework"
                let original = originals.appendingPathComponent(name)
                let destination = copies.appendingPathComponent(name)
                try manager.copyItem(at: original, to: destination)
            }

            let copied = copies.appendingPathComponent("FBSimulatorControl.xcframework")
            let info = try PropertyListDecoder().decode(XCFrameworkInfo.self,
                from: Data(contentsOf: copied.appendingPathComponent("Info.plist")))
            let library = try #require(info.AvailableLibraries.first)
            try #require(info.AvailableLibraries.count == 1)
            try #require(library.SupportedArchitectures.contains("arm64"))
            let framework = copied.appendingPathComponent(library.LibraryIdentifier)
                .appendingPathComponent(library.LibraryPath)
            let modules = framework.appendingPathComponent("Modules/FBSimulatorControl.swiftmodule")
            let interface = try copiedFile(modules.appendingPathComponent("arm64-apple-macos.swiftinterface"), root: copied)
            let header = try copiedFile(framework.appendingPathComponent("Headers/FBSimulatorControl-Swift.h"), root: copied)

            switch variant {
            case .current: break
            case .swiftImport:
                try append("\nimport AccessibilityPlatformTranslation\n", to: interface)
            case .swiftType:
                try append("\npublic var leaked: AXPTranslationObject?\n", to: interface)
            case .headerImport:
                try append("\n#import <AccessibilityPlatformTranslation/AccessibilityPlatformTranslation.h>\n", to: header)
            case .headerType:
                try append("\nAXPTranslatorRequest *leaked;\n", to: header)
            case .missingCompiledModule:
                try manager.removeItem(at: copiedFile(modules.appendingPathComponent("arm64-apple-macos.swiftmodule"), root: copied))
            case .missingHeader:
                try manager.removeItem(at: header.resolvingSymlinksInPath())
            case .missingInterface:
                try manager.removeItem(at: interface)
            case .missingFeatureReference:
                let binary = try copiedFile(framework.appendingPathComponent("FBSimulatorControl"), root: copied)
                var bytes = try Data(contentsOf: binary)
                let needle = Data("setClientType:".utf8)
                let replacement = Data(repeating: 120, count: needle.count)
                var replaced = 0
                while let range = bytes.range(of: needle) {
                    bytes.replaceSubrange(range, with: replacement)
                    replaced += 1
                }
                try #require(replaced > 0)
                // Same-length text replacement leaves the Mach-O architecture readable.
                // This copied binary is inspected only, never loaded or executed.
                try bytes.write(to: binary)
            }

            let output = directory.appendingPathComponent("verify.log")
            try Data().write(to: output)
            let log = try FileHandle(forWritingTo: output)
            defer { try? log.close() }
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/bin/bash")
            child.arguments = [repository.appendingPathComponent("scripts/build.sh").path, "verify-xcframeworks"]
            child.currentDirectoryURL = repository
            var environment = ProcessInfo.processInfo.environment
            environment["AXE_ENV_FILE"] = "/dev/null"
            environment["AXE_BUILD_ARCHS"] = "arm64"
            environment["BUILD_OUTPUT_DIR"] = directory.path
            environment["TEMP_DIR"] = directory.path
            child.environment = environment
            child.standardOutput = log
            child.standardError = log
            try child.run()
            // No throwing work occurs after launch until the actual child is reaped.
            // File-backed output cannot fill a pipe while waitUntilExit owns the child.
            child.waitUntilExit()
            try log.synchronize()
            let text = try String(contentsOf: output, encoding: .utf8)
            #expect(child.terminationReason == .exit, "\(variant.rawValue): \(text)")
            #expect(child.terminationStatus == (variant == .current ? 0 : 1), "\(variant.rawValue): \(text)")
            if let message = variant.expectedMessage {
                #expect(text.contains(message), "\(variant.rawValue): \(text)")
            } else {
                #expect(text.contains("XCFramework inputs include requested slices: arm64"))
            }
        } catch {
            #expect(try fingerprints(originals) == before)
            throw error
        }
        #expect(try fingerprints(originals) == before)
    }

    private func copiedFile(_ file: URL, root: URL) throws -> URL {
        let resolved = file.resolvingSymlinksInPath()
        try #require(resolved.path.hasPrefix(root.resolvingSymlinksInPath().path + "/"))
        return resolved
    }

    private func append(_ text: String, to file: URL) throws {
        // Resolve only within the copied framework so a symlink is not replaced.
        let destination = file.resolvingSymlinksInPath()
        var bytes = try Data(contentsOf: destination)
        bytes.append(contentsOf: text.utf8)
        try bytes.write(to: destination)
    }

    private func fingerprints(_ directory: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        let manager = FileManager.default
        for product in products {
            let root = directory.appendingPathComponent(product + ".xcframework")
            let enumerator = try #require(manager.enumerator(at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]))
            for case let file as URL in enumerator {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if values.isSymbolicLink == true {
                    result[file.path] = "link:" + (try manager.destinationOfSymbolicLink(atPath: file.path))
                } else if values.isRegularFile == true {
                    result[file.path] = SHA256.hash(data: try Data(contentsOf: file))
                        .map { String(format: "%02x", $0) }.joined()
                }
            }
        }
        return result
    }
}
