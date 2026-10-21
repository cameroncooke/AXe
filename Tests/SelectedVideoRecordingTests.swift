import ArgumentParser
import CoreGraphics
import Foundation
import FBSimulatorControl
import Testing
@testable import AXe

@Suite("Selected video recording")
@MainActor
struct SelectedVideoRecordingTests {
    private let screenUUID = "769ED878-389B-4346-9C56-CB0703AB3E58"

    @Test func legacyDefaultsDoNotSelectAPanel() throws {
        let command = try RecordVideo.parse(["--udid", "TEST"])
        #expect(command.screenID == nil)
        #expect(command.screenUUID == nil)
        #expect(command.expectedBoot == nil)
        #expect(command.fps == 10)
        #expect(command.quality == 80)
        #expect(command.scale == 1)
    }

    @Test func explicitSelectionRetainsMeasuredIdentityAndEncodingOptions() throws {
        let command = try RecordVideo.parse([
            "--udid", "TEST", "--screen-id", "3", "--screen-uuid", screenUUID,
            "--expected-boot", "boot-1", "--fps", "5", "--quality", "75",
            "--scale", "0.5", "--output", "/tmp/selected-record.mp4"
        ])
        #expect(command.screenID == 3)
        #expect(command.screenUUID == screenUUID)
        #expect(command.expectedBoot == "boot-1")
        #expect(command.fps == 5)
        #expect(command.quality == 75)
        #expect(command.scale == 0.5)
        #expect(command.output == "/tmp/selected-record.mp4")
    }

    @Test(arguments: [
        ["--screen-id", "3"],
        ["--screen-uuid", "769ED878-389B-4346-9C56-CB0703AB3E58"],
        ["--screen-id", "3", "--screen-uuid", "invalid"],
        ["--expected-boot", "boot-1"],
        ["--screen-id", "3", "--screen-uuid", "769ED878-389B-4346-9C56-CB0703AB3E58", "--expected-boot", ""],
        ["--screen-id", "3", "--screen-uuid", "769ED878-389B-4346-9C56-CB0703AB3E58", "--expected-boot", "   "]
    ])
    func invalidSelectionFailsBeforeRecording(options: [String]) {
        #expect(throws: (any Error).self) {
            _ = try RecordVideo.parse(["--udid", "TEST"] + options)
        }
    }

    @Test(arguments: [0, 90, 180, 270])
    func unchangedMeasuredFramesAreAccepted(rotation: Int) throws {
        let initial = try observation(rotation: rotation)
        try SelectedMediaCapture.requireSameFrame(
            initial: initial, before: observation(rotation: rotation), after: observation(rotation: rotation))
    }

    @Test(arguments: ["device", "boot", "screenID", "screenUUID", "axID", "width", "height", "scale", "rotation", "pose", "hidTarget"])
    func changedFrameCannotRebaseTheRecording(field: String) throws {
        let initial = try observation()
        let changed = try observation(changing: field)
        // A frame that brackets the change, a later stable frame, and an apparent return
        // must all be compared with the original recording identity.
        for (before, after) in [(initial, changed), (changed, changed), (changed, initial)] {
            #expect(throws: (any Error).self) {
                try SelectedMediaCapture.requireSameFrame(initial: initial, before: before, after: after)
            }
        }
    }

    @Test func publicationCreatesExactBytesAndLeavesTemporaryForCaller() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let temporary = directory.appendingPathComponent("staged.mp4")
        let destination = directory.appendingPathComponent("record.mp4")
        let bytes = Data([0, 0, 0, 8, 0x66, 0x74, 0x79, 0x70])
        try bytes.write(to: temporary, options: .withoutOverwriting)
        try SelectedVideoRecording.publish(temporary: temporary, destination: destination)
        #expect(try Data(contentsOf: destination) == bytes)
        #expect(try Data(contentsOf: temporary) == bytes)
        try FileManager.default.removeItem(at: temporary)
        #expect(try Data(contentsOf: destination) == bytes)
    }

    @Test func publicationDoesNotReplaceExistingFile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let temporary = directory.appendingPathComponent("staged.mp4")
        let destination = directory.appendingPathComponent("record.mp4")
        let staged = Data("new recording".utf8)
        let original = Data("existing recording".utf8)
        try staged.write(to: temporary, options: .withoutOverwriting)
        try original.write(to: destination, options: .withoutOverwriting)
        #expect(throws: (any Error).self) {
            try SelectedVideoRecording.publish(temporary: temporary, destination: destination)
        }
        #expect(try Data(contentsOf: destination) == original)
        #expect(try Data(contentsOf: temporary) == staged)
    }

    @Test func publicationDoesNotFollowOrReplaceDestinationSymlink() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let temporary = directory.appendingPathComponent("staged.mp4")
        let target = directory.appendingPathComponent("original.mp4")
        let destination = directory.appendingPathComponent("record.mp4")
        let staged = Data("new recording".utf8)
        let original = Data("existing recording".utf8)
        try staged.write(to: temporary, options: .withoutOverwriting)
        try original.write(to: target, options: .withoutOverwriting)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: target)
        #expect(throws: (any Error).self) {
            try SelectedVideoRecording.publish(temporary: temporary, destination: destination)
        }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path) == target.path)
        #expect(try Data(contentsOf: target) == original)
        #expect(try Data(contentsOf: temporary) == staged)
    }

    @Test func failedPublicationKeepsTemporaryBytes() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let temporary = directory.appendingPathComponent("staged.mp4")
        let destination = directory.appendingPathComponent("missing/record.mp4")
        let staged = Data("completed recording".utf8)
        try staged.write(to: temporary, options: .withoutOverwriting)
        #expect(throws: (any Error).self) {
            try SelectedVideoRecording.publish(temporary: temporary, destination: destination)
        }
        #expect(try Data(contentsOf: temporary) == staged)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("axe-selected-record-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func observation(rotation: Int = 0, changing field: String? = nil) throws -> FBSimulatorHIDSessionObservation {
        let measuredRotation = try #require(FBSimulatorHIDDisplayRotation(rawValue: field == "rotation" ? 180 : rotation))
        return try FBSimulatorHIDSessionObservation(
            simulatorUDID: field == "device" ? "other-device" : "device",
            bootIdentity: field == "boot" ? "boot-2" : "boot-1",
            screenID: field == "screenID" ? 1 : 3,
            screenUniqueID: field == "screenUUID" ? "B2547548-07CE-4F39-AEF6-4492B242FD7C" : screenUUID,
            axDisplayID: field == "axID" ? 1 : 3,
            displayContext: FBSimulatorHIDDisplayContext(
                hidTarget: field == "hidTarget" ? 1 : 3,
                nativePixelSize: CGSize(width: field == "width" ? 2100 : 2007,
                                        height: field == "height" ? 2900 : 2853),
                scale: field == "scale" ? 2 : 3, rotation: measuredRotation),
            poseRevision: field == "pose" ? "mechanicalDegrees=90" : "mechanicalDegrees=180")
    }
}
