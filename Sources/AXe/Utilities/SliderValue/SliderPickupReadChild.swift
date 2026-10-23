import Darwin
import Foundation

/// Owns read-only child phases and the host descendants that it observes.
@MainActor
final class SliderPickupReadChild {
    enum Failure: Error { case rejected(String) }
    struct Identity: Codable, Equatable {
        let pid: pid_t
        let parent: pid_t
        let startSeconds: UInt64
        let startMicroseconds: UInt64
    }
    struct Receipt: Codable {
        let leader: Identity?
        let observedDescendants: [Identity]
        let childReaped: Bool
        let observedDescendantsExited: Bool
        let processGroupAbsent: Bool
        let signals: [String]
    }
    private var process: Process?
    private var group: pid_t?
    private var leader: Identity?
    private var descendants: [pid_t: Identity] = [:]
    private var signals: [String] = []
    private(set) var receipt: Receipt?

    private func identity(_ pid: pid_t) -> Identity? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Identity(pid: pid, parent: pid_t(info.pbi_ppid),
            startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec)
    }

    private func sameProcess(_ expected: Identity) -> Bool {
        guard let current = identity(expected.pid) else { return false }
        return current.pid == expected.pid && current.startSeconds == expected.startSeconds
            && current.startMicroseconds == expected.startMicroseconds
    }

    private func captureDescendants() throws {
        guard let leader else { return }
        // Same public libproc pattern as scripts/duo-resource-probe.c; no external monitor.
        let count = proc_listallpids(nil, 0)
        guard count > 0, count < 20000 else { throw Failure.rejected("Cannot bound the child identity read") }
        var pids = [pid_t](repeating: 0, count: Int(count) + 1024)
        let received = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard received > 0, received < pids.count else { throw Failure.rejected("Child identity read exceeded its bound") }
        let rows = pids.prefix(Int(received)).compactMap { $0 > 0 ? identity($0) : nil }
        var parents = Set(descendants.values.filter(sameProcess).map(\.pid))
        if sameProcess(leader) { parents.insert(leader.pid) }
        for _ in 0..<32 {
            let next = rows.filter { parents.contains($0.parent) && !parents.contains($0.pid) }
            if next.isEmpty { return }
            guard descendants.count + next.count <= 64 else { throw Failure.rejected("Read child has too many descendants") }
            for row in next { descendants[row.pid] = row; parents.insert(row.pid) }
        }
        throw Failure.rejected("Read child descendant depth exceeded its bound")
    }

    private func groupAbsent() -> Bool {
        guard let group else { return true }
        return Darwin.kill(-group, 0) == -1 && errno == ESRCH
    }

    func run(executable: URL, arguments: [String], directory: URL, name: String,
             environment: [String: String], deadline: Double) async throws -> Data {
        guard process == nil, ProcessInfo.processInfo.systemUptime < deadline else {
            throw Failure.rejected("Read child is active or the action deadline expired")
        }
        let stdoutURL = directory.appendingPathComponent(name + ".stdout")
        let stderrURL = directory.appendingPathComponent(name + ".stderr")
        let outFD = open(stdoutURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard outFD >= 0 else { throw Failure.rejected("Cannot create read stdout") }
        let errFD = open(stderrURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard errFD >= 0 else { Darwin.close(outFD); throw Failure.rejected("Cannot create read stderr") }
        let out = FileHandle(fileDescriptor: outFD, closeOnDealloc: true)
        let err = FileHandle(fileDescriptor: errFD, closeOnDealloc: true)
        defer { try? out.close(); try? err.close() }
        func checkSize() throws {
            for file in [stdoutURL, stderrURL] {
                let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 1_048_576 else { throw Failure.rejected("Read phase output exceeds 1 MiB") }
            }
        }
        let child = Process()
        child.executableURL = executable; child.arguments = arguments
        child.environment = environment; child.standardInput = FileHandle.nullDevice
        child.standardOutput = out; child.standardError = err
        try child.run()
        process = child; leader = identity(child.processIdentifier)
        descendants = [:]; signals = []; receipt = nil
        let ownGroup = getpgid(child.processIdentifier) == child.processIdentifier
        group = ownGroup ? child.processIdentifier : nil
        do {
            guard ownGroup, leader != nil else { throw Failure.rejected("Read child has no separate identified process group") }
            while child.isRunning {
                try Task.checkCancellation()
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    throw Failure.rejected("The shared action deadline expired during a read phase")
                }
                try captureDescendants(); try checkSize()
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            child.waitUntilExit()
            try captureDescendants(); try checkSize()
            guard child.terminationReason == .exit, child.terminationStatus == 0 else {
                throw Failure.rejected("Read phase failed; no input or replay")
            }
            guard await close() else { throw Failure.rejected("Read child cleanup is incomplete") }
            try checkSize()
            let data = try Data(contentsOf: stdoutURL)
            guard !data.isEmpty, data.count <= 1_048_576 else { throw Failure.rejected("Read phase returned no bounded result") }
            return data
        } catch {
            _ = await close()
            throw error
        }
    }

    func close() async -> Bool {
        guard let child = process else { return true }
        try? captureDescendants()
        let stages: [(Int32, Double)] = [(SIGTERM, 3), (SIGKILL, 3)]
        for (number, wait) in stages {
            let alive = descendants.values.filter(sameProcess)
            if !child.isRunning && alive.isEmpty && groupAbsent() { break }
            // Signal the private group only while its exact leader is still ours.
            if let group, let leader, sameProcess(leader) {
                _ = Darwin.kill(-group, number); signals.append("group:" + String(group) + ":" + String(number))
            } else if child.isRunning {
                _ = Darwin.kill(child.processIdentifier, number); signals.append("child:" + String(child.processIdentifier) + ":" + String(number))
            }
            for item in alive where sameProcess(item) {
                _ = Darwin.kill(item.pid, number); signals.append("descendant:" + String(item.pid) + ":" + String(number))
            }
            let until = ProcessInfo.processInfo.systemUptime + wait
            while ProcessInfo.processInfo.systemUptime < until {
                if !child.isRunning && descendants.values.allSatisfy({ !sameProcess($0) }) && groupAbsent() { break }
                await Task.detached { try? await Task.sleep(nanoseconds: 25_000_000) }.value
            }
        }
        let descendantsExited = descendants.values.allSatisfy { !sameProcess($0) }
        let absent = groupAbsent()
        if !child.isRunning { child.waitUntilExit() }
        receipt = Receipt(leader: leader, observedDescendants: descendants.values.sorted { $0.pid < $1.pid },
            childReaped: !child.isRunning, observedDescendantsExited: descendantsExited,
            processGroupAbsent: absent, signals: signals)
        guard !child.isRunning, descendantsExited, absent else { return false }
        process = nil; group = nil; leader = nil; descendants = [:]
        return true
    }
}
