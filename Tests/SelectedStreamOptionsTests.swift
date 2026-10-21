import ArgumentParser
import Foundation
import Testing
@testable import AXe

@Suite("Selected stream options")
struct SelectedStreamOptionsTests {
    @Test func legacyDefaultsRemainUnselected() throws {
        let command = try StreamVideo.parse(["--udid", "TEST"])
        #expect(command.screenID == nil)
        #expect(command.screenUUID == nil)
        #expect(command.expectedBoot == nil)
        #expect(command.format == .mjpeg)
        #expect(command.fps == 10)
        #expect(command.quality == 80)
        #expect(command.scale == 1)
    }

    @Test(arguments: ["mjpeg", "raw", "ffmpeg", "bgra"])
    func selectedFormatsKeepExactIdentityAndEncodingOptions(format: String) throws {
        let uuid = "769ED878-389B-4346-9C56-CB0703AB3E58"
        let command = try StreamVideo.parse([
            "--udid", "TEST", "--screen-id", "3", "--screen-uuid", uuid,
            "--expected-boot", "boot-1", "--format", format,
            "--fps", "5", "--quality", "75", "--scale", "0.5"
        ])
        #expect(command.screenID == 3)
        #expect(command.screenUUID == uuid)
        #expect(command.expectedBoot == "boot-1")
        #expect(command.format.rawValue == format)
        #expect(command.fps == 5)
        #expect(command.quality == 75)
        #expect(command.scale == 0.5)
    }

    @Test(arguments: [
        ["--screen-id", "3"],
        ["--screen-uuid", "769ED878-389B-4346-9C56-CB0703AB3E58"],
        ["--screen-id", "3", "--screen-uuid", "invalid"],
        ["--expected-boot", "boot-1"],
        ["--screen-id", "3", "--screen-uuid", "769ED878-389B-4346-9C56-CB0703AB3E58", "--expected-boot", ""],
        ["--screen-id", "3", "--screen-uuid", "769ED878-389B-4346-9C56-CB0703AB3E58", "--expected-boot", "   "]
    ])
    func incompleteSelectionFailsBeforeStreamStart(options: [String]) {
        #expect(throws: (any Error).self) {
            _ = try StreamVideo.parse(["--udid", "TEST"] + options)
        }
    }
}
