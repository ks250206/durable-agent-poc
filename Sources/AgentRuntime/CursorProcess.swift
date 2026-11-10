import Foundation
import Darwin

public enum CursorRuntimeError: Error, Equatable, Sendable, LocalizedError {
    case unavailable, unsupportedCLI, launch, cancelled, timedOut, invalidOutput, processFailed(Int32), storage

    public var errorDescription: String? {
        switch self {
        case .unavailable: "Cursor CLI was not found. Install it or set an executable path."
        case .unsupportedCLI: "Cursor CLI lacks the required read-only print protocol. Update Cursor CLI."
        case .launch: "Cursor CLI could not be launched."
        case .cancelled: "Cursor operation was cancelled."
        case .timedOut: "Cursor CLI timed out."
        case .invalidOutput: "Cursor CLI returned an invalid or incomplete response."
        case .processFailed(let code): "Cursor CLI failed (exit \(code)). Check Cursor login, subscription, and limits."
        case .storage: "Cursor conversation storage is unavailable."
        }
    }
}

/// One invocation, no shell. Cancellation owns only the new Process's verified process group.
public final class CursorProcess: @unchecked Sendable {
    public static var defaultStorageDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DurableChat/Cursor", isDirectory: true)
    }

    public static func discover(executablePath: String? = nil, searchPath: String? = nil) throws -> URL {
        let manager = FileManager.default
        if let executablePath {
            guard executablePath.hasPrefix("/"), manager.isExecutableFile(atPath: executablePath),
                  (try? URL(fileURLWithPath: executablePath).resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == false else {
                throw CursorRuntimeError.unavailable
            }
            return URL(fileURLWithPath: executablePath)
        }
        let paths = (searchPath ?? ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + [manager.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin"]
        for name in ["cursor-agent", "agent"] {
            for path in paths where path.hasPrefix("/") {
                let candidate = URL(fileURLWithPath: path).appendingPathComponent(name)
                if manager.isExecutableFile(atPath: candidate.path),
                   (try? candidate.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == false { return candidate }
            }
        }
        throw CursorRuntimeError.unavailable
    }

    private let executable: URL
    private let directory: URL
    private let lock = NSLock()
    private var process: Process?
    private var cancellation: CursorRuntimeError?
    private var used = false

    public init(executable: URL, workingDirectory: URL) {
        self.executable = executable
        self.directory = workingDirectory
    }

    public func cancel() { cancel(reason: .cancelled) }

    private func cancel(reason: CursorRuntimeError) {
        lock.withLock {
            guard cancellation == nil else { return }
            cancellation = reason
            if let process {
                let pid = process.processIdentifier
                guard pid > 1, pid != getpgrp() else { return }
                // A vanished leader cannot have been reused; its remaining group still belongs to us.
                // If Foundation reports exit but the PID exists again, refuse to signal a reused PID.
                let group = getpgid(pid)
                if (process.isRunning && group == pid) || (group == -1 && errno == ESRCH) {
                    kill(-pid, SIGKILL)
                } else if process.isRunning { process.terminate() }
            }
        }
    }

    /// stdout is bounded NDJSON/text lines; stderr is drained and discarded, never exposed as a UI error.
    /// stdin uses an immediately unlinked private file, avoiding pipe backpressure and SIGPIPE races.
    public func run(
        arguments: [String], input: String = "", timeout: TimeInterval = 600,
        onLine: @escaping @Sendable (Data) async throws -> Void
    ) async throws {
        try await withTaskCancellationHandler {
            try await Task.detached { [self] in
                try await execute(arguments: arguments, input: input, timeout: timeout, onLine: onLine)
            }.value
        } onCancel: { self.cancel() }
    }

    private static func read(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: handle.availableData)
            }
        }
    }

    private func execute(
        arguments: [String], input: String, timeout: TimeInterval,
        onLine: @escaping @Sendable (Data) async throws -> Void
    ) async throws {
        let child = Process()
        // waitUntilExit spins the calling thread's RunLoop. Async line delivery can resume
        // on another thread, so use the Process termination callback instead.
        let exited = CursorTermination()
        child.terminationHandler = { _ in exited.signal() }
        let output = Pipe()
        let errors = Pipe()
        let inputURL = directory.appendingPathComponent(".stdin-\(UUID().uuidString)")
        guard input.utf8.count <= 8 * 1024 * 1024 else { throw CursorRuntimeError.invalidOutput }
        try CursorFiles.prepare(directory)
        guard FileManager.default.createFile(atPath: inputURL.path, contents: Data(input.utf8),
                                             attributes: [.posixPermissions: 0o600]) else { throw CursorRuntimeError.storage }
        let stdin: FileHandle
        do { stdin = try FileHandle(forReadingFrom: inputURL) }
        catch { try? FileManager.default.removeItem(at: inputURL); throw CursorRuntimeError.storage }
        try? FileManager.default.removeItem(at: inputURL)
        defer { try? stdin.close(); try? output.fileHandleForReading.close(); try? errors.fileHandleForReading.close() }
        child.executableURL = executable
        child.arguments = arguments
        child.currentDirectoryURL = directory
        let allowed = Set(["HOME", "USER", "LOGNAME", "PATH", "TMPDIR", "LANG", "LC_ALL", "XDG_CONFIG_HOME", "XDG_DATA_HOME"])
        child.environment = ProcessInfo.processInfo.environment.filter { allowed.contains($0.key) }
        child.standardInput = stdin
        child.standardOutput = output
        child.standardError = errors
        try lock.withLock {
            if let cancellation { throw cancellation }
            guard !used else { throw CursorRuntimeError.launch }
            used = true
            do { try child.run() } catch { throw CursorRuntimeError.launch }
            process = child
            guard !child.isRunning || (child.processIdentifier > 1 && getpgid(child.processIdentifier) == child.processIdentifier) else {
                child.terminate()
                throw CursorRuntimeError.launch
            }
        }
        let deadline = DispatchWorkItem { [weak self] in self?.cancel(reason: .timedOut) }
        DispatchQueue.global().asyncAfter(deadline: .now() + max(0.01, timeout), execute: deadline)
        defer { deadline.cancel() }
        let stderr = Task.detached { while !(await Self.read(errors.fileHandleForReading)).isEmpty {} }
        do {
            var pending = Data()
            while true {
                let chunk = await Self.read(output.fileHandleForReading)
                if chunk.isEmpty { break }
                pending.append(chunk)
                while let newline = pending.firstIndex(of: 10) {
                    guard newline <= 2 * 1024 * 1024 else { throw CursorRuntimeError.invalidOutput }
                    let line = Data(pending[..<newline])
                    pending.removeSubrange(...newline)
                    if !line.isEmpty { try await onLine(line) }
                }
                guard pending.count <= 2 * 1024 * 1024 else { throw CursorRuntimeError.invalidOutput }
            }
            if !pending.isEmpty { try await onLine(pending) }
        } catch {
            cancel()
            await exited.wait()
            await stderr.value
            lock.withLock { process = nil }
            throw error
        }
        await exited.wait()
        await stderr.value
        let reason = lock.withLock { () -> CursorRuntimeError? in process = nil; return cancellation }
        if let reason { throw reason }
        guard child.terminationReason == .exit, child.terminationStatus == 0 else {
            throw CursorRuntimeError.processFailed(child.terminationStatus)
        }
    }
}

/// Only app-owned, noncredential data. Callers must not pass a source workspace as this root.
enum CursorFiles {
    static func prepare(_ directory: URL) throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch { throw CursorRuntimeError.storage }
    }

    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        do {
            let data = try JSONEncoder().encode(value)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { throw CursorRuntimeError.storage }
    }
}

actor CursorOutput {
    private var data = Data()
    func append(_ line: Data) throws {
        guard data.count + line.count < 1024 * 1024 else { throw CursorRuntimeError.invalidOutput }
        data.append(line); data.append(10)
    }
    func value() -> Data { data }
}

/// Handles exit-before-wait and wait-before-exit without blocking a Swift executor or a RunLoop.
private final class CursorTermination: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        let continuations = lock.withLock {
            finished = true
            let result = waiters
            waiters.removeAll()
            return result
        }
        for continuation in continuations { continuation.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let alreadyFinished = lock.withLock {
                if finished { return true }
                waiters.append(continuation)
                return false
            }
            if alreadyFinished { continuation.resume() }
        }
    }
}
