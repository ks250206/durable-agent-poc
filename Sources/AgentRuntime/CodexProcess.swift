import Foundation
import Darwin

public enum CodexRuntimeError: Error, Equatable, Sendable, LocalizedError {
    case unavailable, launch, cancelled, timedOut, invalidOutput, rpc, exited, storage, closed
    public var errorDescription: String? {
        switch self {
        case .unavailable: "Codex CLI was not found. Install it or set an absolute executable path."
        case .launch: "Codex CLI could not be launched safely."
        case .cancelled: "Codex operation was cancelled."
        case .timedOut: "Codex CLI timed out."
        case .invalidOutput: "Codex CLI returned an incompatible or oversized response."
        case .rpc: "Codex rejected the request. Check CLI compatibility, ChatGPT login, access, and limits."
        case .exited: "Codex CLI exited unexpectedly."
        case .storage: "Codex conversation storage is unavailable."
        case .closed: "Codex runtime is shut down."
        }
    }
}

/// A bounded, Sendable JSON representation. No raw server errors/stderr escape this module.
indirect enum CodexJSON: Codable, Sendable, Equatable {
    case object([String: CodexJSON]), array([CodexJSON]), string(String), number(Int), bool(Bool), null
    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .number(v) }
        else if let v = try? c.decode(Double.self) { _ = v; self = .null } // unused numeric telemetry
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([CodexJSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: CodexJSON].self)) }
    }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    subscript(_ key: String) -> CodexJSON { if case .object(let v) = self { v[key] ?? .null } else { .null } }
    var string: String? { if case .string(let v) = self { v } else { nil } }
    var array: [CodexJSON]? { if case .array(let v) = self { v } else { nil } }
    var integer: Int? { if case .number(let v) = self { v } else { nil } }
}

/// One stdio app-server connection. shutdown() awaits readers, writers and owned process-group exit.
/// Authentication stays entirely in the official CLI. No auth-file or token APIs exist here.
public actor CodexProcess {
    public static var defaultStorageDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DurableChat/Codex", isDirectory: true)
    }
    public static func discover(executablePath: String? = nil, searchPath: String? = nil) throws -> URL {
        if let executablePath {
            guard executablePath.hasPrefix("/"), executable(executablePath) else { throw CodexRuntimeError.unavailable }
            return URL(fileURLWithPath: executablePath)
        }
        let paths = (searchPath ?? ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path,
               "/opt/homebrew/bin", "/usr/local/bin"]
        for path in paths where path.hasPrefix("/") {
            let candidate = URL(fileURLWithPath: path).appendingPathComponent("codex")
            if executable(candidate.path) { return candidate }
        }
        throw CodexRuntimeError.unavailable
    }
    private static func executable(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path) &&
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == false
    }

    private let transport: CodexTransport
    private let requestTimeout: TimeInterval
    private var reader: Task<Void, Never>?
    private var errorReader: Task<Void, Never>?
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<CodexJSON, any Error>] = [:]
    private var timers: [Int: Task<Void, Never>] = [:]
    private var failure: CodexRuntimeError?
    private var started = false
    private var initialized = false
    private let stream: AsyncThrowingStream<CodexJSON, any Error>
    private let events: AsyncThrowingStream<CodexJSON, any Error>.Continuation

    public init(executable: URL, workingDirectory: URL, requestTimeout: TimeInterval = 20) {
        transport = CodexTransport(executable: executable, directory: workingDirectory)
        self.requestTimeout = requestTimeout
        (stream, events) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingOldest(512))
    }
    deinit { transport.cancel(); reader?.cancel(); errorReader?.cancel(); for t in timers.values { t.cancel() } }

    func start() async throws {
        guard !started else { throw CodexRuntimeError.launch }
        started = true
        try Task.checkCancellation()
        do { try transport.launch() } catch { fail(.launch); throw CodexRuntimeError.launch }
        errorReader = Task { [transport] in await transport.drainErrors() }
        reader = Task { [weak self, transport] in
            do {
                try await transport.readLines { [weak self] data in try await self?.receive(data) }
                await self?.fail(.exited)
            } catch { await self?.fail((error as? CodexRuntimeError) ?? .invalidOutput) }
        }
        let response = try await request("initialize", .object([
            "clientInfo": .object(["name": .string("durable_chat"), "title": .string("Durable Chat"), "version": .string("0.1.0")]),
            "capabilities": .object(["experimentalApi": .bool(false)])
        ]))
        guard response["userAgent"].string != nil, response["platformFamily"].string != nil,
              response["platformOs"].string != nil, response["codexHome"].string?.hasPrefix("/") == true else {
            fail(.invalidOutput); throw CodexRuntimeError.invalidOutput
        }
        try await transport.write(.object(["method": .string("initialized")]))
        initialized = true
    }

    func notifications() -> AsyncThrowingStream<CodexJSON, any Error> { stream }

    func request(_ method: String, _ params: CodexJSON, timeout: TimeInterval? = nil) async throws -> CodexJSON {
        if let failure { throw failure }
        guard started, initialized || method == "initialize" else { throw CodexRuntimeError.launch }
        try Task.checkCancellation()
        nextID += 1
        let id = nextID
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                timers[id] = Task { [weak self, delay = timeout ?? requestTimeout] in
                    do { try await Task.sleep(for: .seconds(max(0.01, delay))) } catch { return }
                    await self?.fail(.timedOut)
                }
                Task { [weak self, transport] in
                    do { try await transport.write(.object(["id": .number(id), "method": .string(method), "params": params])) }
                    catch { await self?.fail(.exited) }
                }
            }
        } onCancel: { [weak self, transport] in
            transport.cancel()
            Task { await self?.fail(.cancelled) }
        }
    }

    private func receive(_ data: Data) async throws {
        guard failure == nil else { return }
        guard let frame = try? JSONDecoder().decode(CodexJSON.self, from: data), case .object(let object) = frame else {
            throw CodexRuntimeError.invalidOutput
        }
        if let method = frame["method"].string {
            if let id = object["id"] {
                // Every server-initiated approval, tool, token-refresh and future request is unsupported.
                guard id.string != nil || id.integer != nil else { throw CodexRuntimeError.invalidOutput }
                try await transport.write(.object(["id": id, "error": .object([
                    "code": .number(-32601), "message": .string("Client requests are unsupported; no permission granted.")
                ])]))
                return
            }
            guard !method.isEmpty else { throw CodexRuntimeError.invalidOutput }
            if case .dropped = events.yield(frame) { throw CodexRuntimeError.invalidOutput }
            return
        }
        guard let id = frame["id"].integer else { throw CodexRuntimeError.invalidOutput }
        // Duplicate responses cannot resume a continuation twice.
        guard let continuation = pending.removeValue(forKey: id) else { return }
        timers.removeValue(forKey: id)?.cancel()
        if object["error"] != nil {
            continuation.resume(throwing: CodexRuntimeError.rpc)
        } else if let result = object["result"] {
            continuation.resume(returning: result)
        } else {
            continuation.resume(throwing: CodexRuntimeError.invalidOutput)
            throw CodexRuntimeError.invalidOutput
        }
    }

    private func fail(_ error: CodexRuntimeError) {
        guard failure == nil else { return }
        failure = error
        transport.cancel()
        for timer in timers.values { timer.cancel() }; timers.removeAll()
        let continuations = pending.values; pending.removeAll()
        for continuation in continuations { continuation.resume(throwing: error) }
        events.finish(throwing: error)
    }

    public func shutdown() async {
        fail(.closed)
        transport.cancel()
        await reader?.value
        await errorReader?.value
        await transport.waitForExit()
        await transport.closeInput()
        reader = nil; errorReader = nil
    }
}

/// Foundation creates a new process group on this platform; verify before using group signals.
private final class CodexTransport: @unchecked Sendable {
    private let executable: URL
    private let directory: URL
    private let lock = NSLock()
    private let writer = DispatchQueue(label: "DurableChat.Codex.stdin")
    private var process: Process?
    private var cancelled = false
    private let input = Pipe(), output = Pipe(), errors = Pipe()
    private let exited = CodexExit()
    init(executable: URL, directory: URL) { self.executable = executable; self.directory = directory }
    deinit {
        cancel()
        try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close(); try? errors.fileHandleForReading.close()
    }
    func launch() throws {
        try lock.withLock {
            guard !cancelled else { throw CodexRuntimeError.cancelled }
            let child = Process()
            child.executableURL = executable
            // Command-line overrides are app-owned; never inherit CODEX_*, API keys or injection variables.
            child.arguments = ["-c", "sandbox_mode=\"read-only\"", "-c", "approval_policy=\"never\"",
                               "-c", "model_provider=\"openai\"", "app-server", "--listen", "stdio://"]
            child.currentDirectoryURL = directory
            let allowed: Set<String> = ["HOME", "USER", "LOGNAME", "PATH", "TMPDIR", "LANG", "LC_ALL"]
            child.environment = ProcessInfo.processInfo.environment.filter { allowed.contains($0.key) }
            child.standardInput = input; child.standardOutput = output; child.standardError = errors
            child.terminationHandler = { [exited] _ in exited.signal() }
            _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            do { try child.run() } catch { exited.signal(); throw CodexRuntimeError.launch }
            process = child
            guard child.processIdentifier > 1,
                  !child.isRunning || getpgid(child.processIdentifier) == child.processIdentifier else {
                child.terminate(); throw CodexRuntimeError.launch
            }
        }
    }
    func cancel() {
        lock.withLock {
            cancelled = true
            guard let child = process else { exited.signal(); return }
            let pid = child.processIdentifier
            guard pid > 1, pid != getpgrp() else { return }
            let group = getpgid(pid)
            if (child.isRunning && group == pid) || (group == -1 && errno == ESRCH) {
                kill(-pid, SIGKILL)
            } else if child.isRunning { child.terminate() }
        }
    }
    func write(_ frame: CodexJSON) async throws {
        var data = try JSONEncoder().encode(frame); data.append(10)
        guard data.count <= 2 * 1024 * 1024 else { throw CodexRuntimeError.invalidOutput }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            writer.async { [self, data] in
                do {
                    guard !lock.withLock({ cancelled }) else { throw CodexRuntimeError.cancelled }
                    try input.fileHandleForWriting.write(contentsOf: data)
                    continuation.resume()
                } catch { continuation.resume(throwing: CodexRuntimeError.exited) }
            }
        }
    }
    private func read(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { continuation.resume(returning: handle.availableData) }
        }
    }
    func readLines(_ onLine: @escaping @Sendable (Data) async throws -> Void) async throws {
        defer { try? output.fileHandleForReading.close() }
        var pending = Data(), total = 0
        while true {
            let data = await read(output.fileHandleForReading)
            if data.isEmpty { break }
            total += data.count
            guard total <= 32 * 1024 * 1024 else { throw CodexRuntimeError.invalidOutput }
            pending.append(data)
            while let newline = pending.firstIndex(of: 10) {
                guard newline <= 2 * 1024 * 1024 else { throw CodexRuntimeError.invalidOutput }
                let line = Data(pending[..<newline]); pending.removeSubrange(...newline)
                guard !line.isEmpty else { continue }
                try await onLine(line)
            }
            guard pending.count <= 2 * 1024 * 1024 else { throw CodexRuntimeError.invalidOutput }
        }
        guard pending.isEmpty else { throw CodexRuntimeError.invalidOutput }
    }
    func drainErrors() async {
        // Drain without retaining possibly secret diagnostics. Bound the total flood too.
        var total = 0
        while true {
            let data = await read(errors.fileHandleForReading)
            if data.isEmpty { break }
            total += data.count
            if total > 8 * 1024 * 1024 { cancel() }
        }
        try? errors.fileHandleForReading.close()
    }
    func waitForExit() async { await exited.wait() }
    func closeInput() async {
        await withCheckedContinuation { continuation in
            writer.async { [self] in
                try? input.fileHandleForWriting.close(); try? input.fileHandleForReading.close()
                try? output.fileHandleForReading.close(); try? output.fileHandleForWriting.close()
                try? errors.fileHandleForReading.close(); try? errors.fileHandleForWriting.close()
                continuation.resume()
            }
        }
    }
}

private final class CodexExit: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func signal() {
        let continuations = lock.withLock { finished = true; let result = waiters; waiters.removeAll(); return result }
        for c in continuations { c.resume() }
    }
    func wait() async {
        await withCheckedContinuation { c in
            let done = lock.withLock { if finished { return true }; waiters.append(c); return false }
            if done { c.resume() }
        }
    }
}
