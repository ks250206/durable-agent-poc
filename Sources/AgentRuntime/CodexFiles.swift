import Foundation
import Darwin

/// Private noncredential storage, never the CLI's state directory.
enum CodexFiles {
    static func canonicalPath(_ url: URL) throws -> String {
        guard let path = realpath(url.path, nil) else { throw CodexRuntimeError.storage }
        defer { free(path) }
        return String(cString: path)
    }
    static func prepare(_ directory: URL) throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var info = stat()
            guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else {
                throw CodexRuntimeError.storage
            }
            guard chmod(directory.path, 0o700) == 0 else { throw CodexRuntimeError.storage }
        } catch { throw CodexRuntimeError.storage }
    }
    static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            guard errno == ENOENT else { throw CodexRuntimeError.storage }
            return nil
        }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(), info.st_size <= 128 * 1024 * 1024 else {
            throw CodexRuntimeError.storage
        }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CodexRuntimeError.storage }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do { return try JSONDecoder().decode(type, from: file.readToEnd() ?? Data()) }
        catch { throw CodexRuntimeError.storage }
    }
    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".codex-\(UUID()).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CodexRuntimeError.storage }
        defer { close(fd); unlink(temporary.path) }
        do {
            let data = try JSONEncoder().encode(value)
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if n < 0 && errno == EINTR { continue }
                    guard n > 0 else { throw CodexRuntimeError.storage }
                    offset += n
                }
            }
            guard fsync(fd) == 0, rename(temporary.path, url.path) == 0 else { throw CodexRuntimeError.storage }
        } catch { throw CodexRuntimeError.storage }
    }
}

final class CodexStorageLock: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32
    init(directory: URL) throws {
        descriptor = open(directory.appendingPathComponent("runtime.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CodexRuntimeError.storage }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { close(descriptor); descriptor = -1; throw CodexRuntimeError.storage }
    }
    func release() { lock.withLock { if descriptor >= 0 { close(descriptor); descriptor = -1 } } }
    deinit { release() }
}
