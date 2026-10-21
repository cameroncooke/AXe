import ArgumentParser
import Foundation
import Testing
@testable import AXe

@Suite("Selected screenshot command")
struct SelectedScreenshotTests {
    @Test func legacyDefaultHasNoSelectedCapture() throws {
        let value = try Screenshot.parse(["--udid", "TEST"])
        #expect(value.screenID == nil && value.screenUUID == nil && value.expectedBoot == nil)
    }

    @Test func explicitPairAndBootAreRetained() throws {
        let value = try Screenshot.parse(["--udid", "TEST", "--screen-id", "3", "--screen-uuid",
            "769ED878-389B-4346-9C56-CB0703AB3E58", "--expected-boot", "boot-1"])
        #expect(value.screenID == 3 && value.expectedBoot == "boot-1")
    }

    @Test func partialOrInvalidSelectionIsRejected() {
        for arguments in [["--screen-id", "3"], ["--screen-uuid", "769ED878-389B-4346-9C56-CB0703AB3E58"],
                          ["--screen-id", "3", "--screen-uuid", "invalid"], ["--expected-boot", "boot-1"]] {
            #expect(throws: (any Error).self) { _ = try Screenshot.parse(["--udid", "TEST"] + arguments) }
        }
    }

    @Test func outputPublicationNeverReplacesExistingBytes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("image.png")
        let original = Data("original".utf8)
        try SelectedScreenshotOutput.publish(original, to: output)
        #expect(try Data(contentsOf: output) == original)
        #expect(throws: (any Error).self) {
            try SelectedScreenshotOutput.publish(Data("replacement".utf8), to: output)
        }
        #expect(try Data(contentsOf: output) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["image.png"])
    }
}
