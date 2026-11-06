import Foundation
import Darwin

/// Internal process boundary also used by local child-lifecycle checks.
/// The public reader always supplies the exact devicectl command.
struct ActivePanelChildCommand: Sendable {
    let executable: URL
    let arguments: [String]
    let environment: [String: String]
    let directory: URL
    let responseURL: URL
    let timeout: TimeInterval
    let maximumBytes: Int
}

/// Mutable lifecycle state is confined to queue. posix_spawn is on a separate worker so
/// a stalled launch cannot prevent the owner from reporting unconfirmed cleanup.
/// A late launch retains this owner and is stopped; it is never reported as not launched.
final class OwnedActivePanelChild: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.camsoft.axe.active-panel-child", qos: .userInitiated)
    private let command: ActivePanelChildCommand
    private let errorPipe = Pipe()
    private var continuation: CheckedContinuation<ActivePanelChildReceipt, Error>?
    private var timer: DispatchSourceTimer?
    private var errorSource: DispatchSourceRead?
    private var started = 0.0
    private var launchReturned = false
    private var launchAttempted = false
    private var processIdentifier: pid_t?
    private var launched = false
    private var exited = false
    private var exitStatus: Int32?
    private var exitReason: String?
    private var stopReason: ActivePanelChildFailure?
    private var detail: String?
    private var stopAt: Double?
    private var sentTerminate = false
    private var sentKill = false
    private var returned = false
    private var disposed = false
    private var directoryCreated = false
    private var stderr = Data()

    init(command: ActivePanelChildCommand) { self.command = command }

    func run() async throws -> ActivePanelChildReceipt {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    self.continuation = continuation
                    self.start()
                }
            }
        } onCancel: {
            self.queue.async { self.stop(.cancelled) }
        }
    }

    private func start() {
        started = ProcessInfo.processInfo.systemUptime
        guard stopReason == nil else { finishBeforeLaunch(); return }
        do {
            guard mkdir(command.directory.path, 0o700) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            directoryCreated = true
            let descriptor = errorPipe.fileHandleForReading.fileDescriptor
            guard fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) != -1 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            source.setEventHandler { [self] in readStderr() }
            source.setCancelHandler { [errorPipe] in try? errorPipe.fileHandleForReading.close() }
            errorSource = source
            source.resume()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(10))
            timer.setEventHandler { [self] in tick() }
            self.timer = timer
            timer.resume()
            launchAttempted = true
            let readFD = errorPipe.fileHandleForReading.fileDescriptor
            let writeFD = errorPipe.fileHandleForWriting.fileDescriptor
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let result = Self.spawn(command: command, readFD: readFD, writeFD: writeFD)
                queue.async { self.didLaunch(result) }
            }
        } catch {
            stopReason = .ioFailure
            detail = String(describing: error)
            finishBeforeLaunch()
        }
    }

    private func didLaunch(_ result: SpawnResult) {
        launchReturned = true
        try? errorPipe.fileHandleForWriting.close()
        if result.code != 0 {
            if stopReason == nil { stopReason = .launchFailed }
            detail = "posix_spawn error \(result.code)"
            finishBeforeLaunch()
            return
        }
        launched = true
        processIdentifier = result.pid
        tick()
    }

    private func readStderr() {
        guard errorSource != nil else { return }
        var bytes = [UInt8](repeating: 0, count: 8192)
        // Bound work per callback; the source remains readable if more data is pending.
        for _ in 0..<32 {
            let count = Darwin.read(errorPipe.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
            if count > 0 {
                let room = max(0, command.maximumBytes - stderr.count)
                stderr.append(contentsOf: bytes.prefix(min(count, room)))
                if count > room { stop(.outputLimit); return }
            } else if count == 0 {
                errorSource?.cancel()
                errorSource = nil
                return
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else {
                detail = "stderr read errno \(errno)"
                stop(.ioFailure)
                return
            }
        }
    }

    private func stop(_ reason: ActivePanelChildFailure) {
        if stopReason == nil {
            stopReason = reason
            stopAt = ProcessInfo.processInfo.systemUptime
        }
        // Cancellation can arrive before the continuation/start block.
        if continuation != nil { queue.async { self.tick() } }
    }

    private func tick() {
        guard !disposed, continuation != nil || returned else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let pid = processIdentifier, !exited {
            var status: Int32 = 0
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid {
                // Darwin sys/wait.h: WIFEXITED = (status & 127) == 0;
                // WEXITSTATUS = (status >> 8) & 255; WTERMSIG = status & 127.
                exited = true
                exitReason = (status & 127) == 0 ? "exit" : "signal"
                exitStatus = (status & 127) == 0 ? ((status >> 8) & 255) : (status & 127)
            } else if result == -1, errno != EINTR {
                detail = "waitpid error \(errno); direct child exit not confirmed"
                stopReason = stopReason ?? .cleanupUnconfirmed
                let result = receipt(json: Data())
                // Ownership is no longer proved. Never signal a PID that may have been reaped elsewhere.
                dispose(removeFiles: false)
                finish(.failure(ActivePanelReadError(childFailure: .cleanupUnconfirmed, receipt: result)))
                return
            }
        }
        if !exited, stopReason == nil, now - started >= command.timeout {
            stopReason = .deadline
            stopAt = now
        }
        if stopReason == nil {
            var info = stat()
            if lstat(command.responseURL.path, &info) == 0 {
                if (info.st_mode & S_IFMT) != S_IFREG {
                    stopReason = .ioFailure
                    detail = "JSON output is not a regular file"
                    stopAt = now
                } else if info.st_size > command.maximumBytes {
                    stopReason = .outputLimit
                    stopAt = now
                }
            } else if errno != ENOENT {
                stopReason = .ioFailure
                detail = "JSON output lstat error \(errno)"
                stopAt = now
            }
        }
        if launched, exited {
            readStderr()
            finishExited()
            return
        }
        if let stopAt {
            if let pid = processIdentifier, !sentTerminate {
                _ = Darwin.kill(pid, SIGTERM)
                sentTerminate = true
            }
            if let pid = processIdentifier, !sentKill, now - stopAt >= 0.2 {
                // waitpid is owned by this queue. An unreaped child PID cannot be reused.
                _ = Darwin.kill(pid, SIGKILL)
                sentKill = true
            }
            if !returned, now - stopAt >= 1.2 {
                finish(.failure(ActivePanelReadError(childFailure: .cleanupUnconfirmed, receipt: receipt(json: Data()))))
                // Keep the launch and exit owner alive for a late result. No success is claimed.
            }
        }
    }

    private func finishBeforeLaunch() {
        try? errorPipe.fileHandleForWriting.close()
        let result = receipt(json: Data())
        dispose()
        finish(.failure(ActivePanelReadError(childFailure: stopReason ?? .launchFailed, receipt: result)))
    }

    private func finishExited() {
        var json = Data()
        do {
            let descriptor = Darwin.open(command.responseURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? file.close() }
            var info = stat()
            guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
                throw POSIXError(.EINVAL)
            }
            json = try file.read(upToCount: command.maximumBytes + 1) ?? Data()
            if json.count > command.maximumBytes {
                json = Data(json.prefix(command.maximumBytes))
                if stopReason == nil { stopReason = .outputLimit }
            }
        } catch {
            if stopReason == nil, exitStatus == 0 {
                stopReason = .missingJSON
                detail = String(describing: error)
            }
        }
        if stopReason == nil, exitStatus != 0 || exitReason != "exit" { stopReason = .nonzeroExit }
        let result = receipt(json: json)
        dispose()
        if let stopReason {
            finish(.failure(ActivePanelReadError(childFailure: stopReason, receipt: result)))
        } else {
            finish(.success(result))
        }
    }

    private func receipt(json: Data) -> ActivePanelChildReceipt {
        ActivePanelChildReceipt(executable: command.executable.path, arguments: command.arguments,
            startedUptime: started, finishedUptime: ProcessInfo.processInfo.systemUptime,
            processIdentifier: processIdentifier, launchAttempted: launchAttempted,
            launchReturned: launchReturned, exitConfirmed: launched && exited,
            terminationStatus: exitStatus, terminationReason: exitReason,
            stopReason: stopReason, detail: detail, sentTerminate: sentTerminate, sentKill: sentKill,
            json: json, stderr: stderr)
    }

    private func finish(_ result: Result<ActivePanelChildReceipt, Error>) {
        guard !returned else { return }
        returned = true
        let saved = continuation
        continuation = nil
        saved?.resume(with: result)
    }

    private func dispose(removeFiles: Bool = true) {
        guard !disposed else { return }
        disposed = true
        timer?.cancel()
        timer = nil
        errorSource?.cancel()
        errorSource = nil
        if errorSource == nil { try? errorPipe.fileHandleForReading.close() }
        try? errorPipe.fileHandleForWriting.close()
        // Only this invocation's private directory, after confirmed exit or failed launch.
        if removeFiles, directoryCreated { try? FileManager.default.removeItem(at: command.directory) }
    }

    private struct SpawnResult: Sendable { let pid: pid_t; let code: Int32 }

    static func configureSignalDefaults(_ attributes: inout posix_spawnattr_t?) -> Int32 {
        var defaults = sigset_t()
        guard sigemptyset(&defaults) == 0,
              sigaddset(&defaults, SIGINT) == 0,
              sigaddset(&defaults, SIGTERM) == 0 else { return errno }
        let result = posix_spawnattr_setsigdefault(&attributes, &defaults)
        guard result == 0 else { return result }
        return posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF))
    }

    private static func spawn(command: ActivePanelChildCommand, readFD: Int32, writeFD: Int32) -> SpawnResult {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        let actionResult = posix_spawn_file_actions_init(&actions)
        guard actionResult == 0 else { return SpawnResult(pid: 0, code: actionResult) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        let attributeResult = posix_spawnattr_init(&attributes)
        guard attributeResult == 0 else { return SpawnResult(pid: 0, code: attributeResult) }
        defer { posix_spawnattr_destroy(&attributes) }
        // SignalObserver ignores these signals in the parent. Do not pass that ignored
        // disposition into an exec child that this owner stops with SIGTERM.
        let signalResult = configureSignalDefaults(&attributes)
        guard signalResult == 0 else { return SpawnResult(pid: 0, code: signalResult) }
        // Close unrelated inherited descriptors; retain only explicit child file actions.
        let operations = [
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0),
            posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0),
            posix_spawn_file_actions_adddup2(&actions, writeFD, STDERR_FILENO),
            posix_spawn_file_actions_addclose(&actions, readFD),
            posix_spawn_file_actions_addclose(&actions, writeFD)
        ]
        if let error = operations.first(where: { $0 != 0 }) { return SpawnResult(pid: 0, code: error) }
        let argumentStrings = [command.executable.path] + command.arguments
        let environmentStrings = command.environment.sorted(by: { $0.key < $1.key }).map { $0.key + "=" + $0.value }
        var argv = argumentStrings.map { strdup($0) }
        var envp = environmentStrings.map { strdup($0) }
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        guard argv.allSatisfy({ $0 != nil }), envp.allSatisfy({ $0 != nil }) else {
            return SpawnResult(pid: 0, code: ENOMEM)
        }
        argv.append(nil)
        envp.append(nil)
        var pid: pid_t = 0
        let result = argv.withUnsafeMutableBufferPointer { args in
            envp.withUnsafeMutableBufferPointer { environment in
                posix_spawn(&pid, command.executable.path, &actions, &attributes, args.baseAddress!, environment.baseAddress!)
            }
        }
        return SpawnResult(pid: pid, code: result)
    }
}
