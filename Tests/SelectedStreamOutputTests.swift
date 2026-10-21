import Darwin
import Foundation
import Testing
@testable import AXe

@Suite("Selected stream descriptor output")
@MainActor
struct SelectedStreamOutputTests {
    @Test func startedPacketCompletesAcrossBackpressureEvenAfterStopRequest() async throws {
        let descriptors = try pipeDescriptors()
        defer { close(descriptors.read); close(descriptors.write) }
        let flags = fcntl(descriptors.read, F_GETFL)
        try #require(fcntl(descriptors.read, F_SETFL, flags | O_NONBLOCK) == 0)
        let output = try SelectedStreamOutput(descriptor: descriptors.write, writeTimeout: 5)
        defer { try? output.restore() }
        let payload = Data((0..<(2 * 1024 * 1024)).map { UInt8($0 % 251) })
        var stopped = false
        let reader = Task { @MainActor in
            var received = Data()
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            var buffer = [UInt8](repeating: 0, count: 4093)
            while received.count < payload.count {
                try Task.checkCancellation()
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw PipeFailure.deadline }
                let count = Darwin.read(descriptors.read, &buffer, min(buffer.count, payload.count - received.count))
                if count > 0 {
                    received.append(contentsOf: buffer.prefix(count))
                    stopped = true
                } else if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
                    try await Task.sleep(nanoseconds: 1_000_000)
                } else { throw PipeFailure.read }
                await Task.yield()
            }
            return received
        }
        do {
            let completed = try await output.write(payload, stopRequested: { stopped })
            #expect(completed)
            let received = try await reader.value
            #expect(stopped)
            #expect(received == payload)
        } catch {
            reader.cancel()
            _ = await reader.result
            throw error
        }
        try output.restore()
    }

    @Test func stopBeforeFirstByteWritesNothing() async throws {
        let descriptors = try pipeDescriptors()
        defer { close(descriptors.read); close(descriptors.write) }
        let output = try SelectedStreamOutput(descriptor: descriptors.write)
        defer { try? output.restore() }
        let completed = try await output.write(Data("frame".utf8), stopRequested: { true })
        #expect(!completed)
        #expect(try availableBytes(descriptors.read).isEmpty)
        try output.restore()
    }

    @Test func blockedPartialPacketThrowsInsteadOfReportingComplete() async throws {
        let descriptors = try pipeDescriptors()
        defer { close(descriptors.read); close(descriptors.write) }
        // Stabilize the kernel's write-history flag before the restoration baseline.
        var prime: UInt8 = 0x7f
        try #require(Darwin.write(descriptors.write, &prime, 1) == 1)
        try #require(try availableBytes(descriptors.read) == Data([prime]))
        let flags = fcntl(descriptors.write, F_GETFL)
        let noSIGPIPE = fcntl(descriptors.write, F_GETNOSIGPIPE)
        let output = try SelectedStreamOutput(descriptor: descriptors.write, writeTimeout: 0.02)
        defer { try? output.restore() }
        let packet = Data(repeating: 0x5a, count: 8 * 1024 * 1024)
        await #expect(throws: (any Error).self) { _ = try await output.write(packet) }
        let prefix = try availableBytes(descriptors.read)
        #expect(!prefix.isEmpty && prefix.count < packet.count)
        #expect(prefix == packet.prefix(prefix.count))
        try output.restore()
        #expect(fcntl(descriptors.write, F_GETFL) == flags)
        #expect(fcntl(descriptors.write, F_GETNOSIGPIPE) == noSIGPIPE)
    }

    @Test func closedConsumerThrowsWithoutClosingCallerDescriptor() async throws {
        let descriptors = try pipeDescriptors()
        close(descriptors.read)
        defer { close(descriptors.write) }
        let output = try SelectedStreamOutput(descriptor: descriptors.write)
        defer { try? output.restore() }
        await #expect(throws: POSIXError.self) { _ = try await output.write(Data([1, 2, 3])) }
        try output.restore()
        #expect(fcntl(descriptors.write, F_GETFL) >= 0)
    }

    @Test(arguments: [false, true])
    func restoresOriginalFlagsAndRejectsUseAfterRestore(initiallyNonblocking: Bool) async throws {
        let descriptors = try pipeDescriptors()
        defer { close(descriptors.read); close(descriptors.write) }
        if initiallyNonblocking {
            let flags = fcntl(descriptors.write, F_GETFL)
            try #require(fcntl(descriptors.write, F_SETFL, flags | O_NONBLOCK) == 0)
            try #require(fcntl(descriptors.write, F_SETNOSIGPIPE, Int32(1)) == 0)
        }
        let flags = fcntl(descriptors.write, F_GETFL)
        let noSIGPIPE = fcntl(descriptors.write, F_GETNOSIGPIPE)
        let output = try SelectedStreamOutput(descriptor: descriptors.write)
        defer { try? output.restore() }
        #expect((fcntl(descriptors.write, F_GETFL) & O_NONBLOCK) != 0)
        #expect(fcntl(descriptors.write, F_GETNOSIGPIPE) == 1)
        try output.restore()
        try output.restore()
        #expect(fcntl(descriptors.write, F_GETFL) == flags)
        #expect(fcntl(descriptors.write, F_GETNOSIGPIPE) == noSIGPIPE)
        await #expect(throws: (any Error).self) { _ = try await output.write(Data([1])) }
    }

    @Test(arguments: [0.0, -1.0, 6.0, Double.infinity, Double.nan])
    func invalidWriteDeadlineLeavesDescriptorUnchanged(timeout: Double) throws {
        let descriptors = try pipeDescriptors()
        defer { close(descriptors.read); close(descriptors.write) }
        let flags = fcntl(descriptors.write, F_GETFL)
        let noSIGPIPE = fcntl(descriptors.write, F_GETNOSIGPIPE)
        #expect(throws: (any Error).self) { _ = try SelectedStreamOutput(descriptor: descriptors.write, writeTimeout: timeout) }
        #expect(fcntl(descriptors.write, F_GETFL) == flags)
        #expect(fcntl(descriptors.write, F_GETNOSIGPIPE) == noSIGPIPE)
    }

    @Test func duplicatedDescriptorsRestoreSharedFlagsInReverseOrder() async throws {
        let descriptors = try pipeDescriptors()
        defer { close(descriptors.read); close(descriptors.write) }
        let duplicate = Darwin.dup(descriptors.write)
        try #require(duplicate >= 0)
        defer { close(duplicate) }
        // Stabilize the kernel's write-history flag before the restoration baseline.
        var prime: UInt8 = 0x7f
        try #require(Darwin.write(descriptors.write, &prime, 1) == 1)
        try #require(try availableBytes(descriptors.read) == Data([prime]))
        let flags = fcntl(descriptors.write, F_GETFL)
        let noSIGPIPE = fcntl(descriptors.write, F_GETNOSIGPIPE)
        try #require(flags >= 0 && noSIGPIPE >= 0)
        try #require((flags & O_NONBLOCK) == 0)
        let first = try SelectedStreamOutput(descriptor: descriptors.write)
        defer { try? first.restore() }
        let second = try SelectedStreamOutput(descriptor: duplicate)
        defer { try? second.restore() }

        // Both owners stay active until all media and diagnostic bytes are written.
        #expect(try await first.write(Data([1, 2, 3])))
        #expect(try await second.write(Data([4, 5])))
        #expect(try availableBytes(descriptors.read) == Data([1, 2, 3, 4, 5]))
        #expect((fcntl(descriptors.write, F_GETFL) & O_NONBLOCK) != 0)
        #expect(fcntl(duplicate, F_GETNOSIGPIPE) == 1)

        try second.restore()
        #expect((fcntl(descriptors.write, F_GETFL) & O_NONBLOCK) != 0)
        #expect(fcntl(duplicate, F_GETNOSIGPIPE) == 1)
        try first.restore()
        for descriptor in [descriptors.write, duplicate] {
            #expect(fcntl(descriptor, F_GETFL) == flags)
            #expect(fcntl(descriptor, F_GETNOSIGPIPE) == noSIGPIPE)
        }
    }

    private enum PipeFailure: Error { case deadline, read }

    private func pipeDescriptors() throws -> (read: Int32, write: Int32) {
        var descriptors = [Int32](repeating: -1, count: 2)
        try #require(Darwin.pipe(&descriptors) == 0)
        return (descriptors[0], descriptors[1])
    }

    private func availableBytes(_ descriptor: Int32) throws -> Data {
        let flags = fcntl(descriptor, F_GETFL)
        try #require(flags >= 0 && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0)
        defer { _ = fcntl(descriptor, F_SETFL, flags) }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 { result.append(contentsOf: buffer.prefix(count)); continue }
            if count == 0 || (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) { return result }
            if count < 0 && errno == EINTR { continue }
            throw PipeFailure.read
        }
    }
}
