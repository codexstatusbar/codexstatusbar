import Darwin
import Dispatch
import Foundation
import os

public enum ControlServerError: Error, Equatable {
    case pathTooLong, inUse, unsafePath, socketFailed
}

/// One request per line, one reply per line, over a Unix socket that only this user can reach.
/// The content of a line belongs to the handler; this type only moves bytes and guards the connection.
public final class ControlServer: Sendable {
    public typealias Handler = @Sendable (Data) async -> Data
    public static let maximumRequestBytes = 64 * 1024
    public static let maximumConnections = 8

    private let path: String
    private let listener: DispatchSourceRead
    private let handler: Handler
    private let idleSeconds: Int
    private let connections = OSAllocatedUnfairLock(initialState: 0)

    public init(path: String, idleSeconds: Int = 30, handler: @escaping Handler) throws {
        var address = try Self.address(path)
        try Self.removeStaleSocket(path)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ControlServerError.socketFailed }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else {
            let failure = errno
            close(descriptor)
            throw failure == EADDRINUSE ? ControlServerError.inUse : ControlServerError.socketFailed
        }
        guard chmod(path, 0o600) == 0, fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0, listen(descriptor, 16) == 0 else {
            close(descriptor)
            unlink(path)
            throw ControlServerError.socketFailed
        }
        self.path = path
        self.handler = handler
        self.idleSeconds = idleSeconds
        listener = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .global())
        listener.setEventHandler { [self] in accept(from: descriptor) }
        listener.setCancelHandler { close(descriptor) }
        listener.resume()
    }

    public func stop() {
        listener.cancel()
        unlink(path)
    }

    private static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        // The zeroed tail is the terminator.
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw ControlServerError.pathTooLong }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }

    /// A crash leaves the socket file behind. Only our own socket that nobody answers on may be replaced.
    private static func removeStaleSocket(_ path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            if errno == ENOENT { return }
            throw ControlServerError.unsafePath
        }
        guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid() else { throw ControlServerError.unsafePath }
        if answers(path) { throw ControlServerError.inUse }
        guard unlink(path) == 0 else { throw ControlServerError.unsafePath }
    }

    private static func answers(_ path: String) -> Bool {
        guard var address = try? self.address(path) else { return false }
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { return false }
        defer { close(probe) }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        } == 0
    }

    private func accept(from descriptor: Int32) {
        let client = Darwin.accept(descriptor, nil, nil)
        guard client >= 0 else { return }
        var user = uid_t(), group = gid_t()
        // An accepted socket inherits the listener's non-blocking flag; the timeouts below need blocking calls.
        guard fcntl(client, F_SETFL, 0) == 0, getpeereid(client, &user, &group) == 0, user == getuid(),
              connections.withLock({ count in
                  guard count < Self.maximumConnections else { return false }
                  count += 1
                  return true
              }) else {
            close(client)
            return
        }
        var noSignal: Int32 = 1
        var timeout = timeval(tv_sec: idleSeconds, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        serve(client, buffered: Data())
    }

    /// Reads block, so they stay on dispatch threads; the handler runs on Swift concurrency between them.
    private func serve(_ client: Int32, buffered: Data) {
        DispatchQueue.global().async { [self] in
            var pending = buffered
            var chunk = [UInt8](repeating: 0, count: 4096)
            while !pending.contains(10) {
                guard pending.count <= Self.maximumRequestBytes else { return finish(client) }
                let count = read(client, &chunk, chunk.count)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return finish(client) }
                pending.append(contentsOf: chunk[..<count])
            }
            guard let end = pending.firstIndex(of: 10), end - pending.startIndex <= Self.maximumRequestBytes else { return finish(client) }
            let line = Data(pending[..<end])
            let rest = Data(pending[pending.index(after: end)...])
            Task { [self] in
                let reply = await handler(line)
                DispatchQueue.global().async { [self] in
                    guard send(reply + [10], to: client) else { return finish(client) }
                    serve(client, buffered: rest)
                }
            }
        }
    }

    private func send(_ data: Data, to client: Int32) -> Bool {
        data.withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                let count = write(client, bytes.baseAddress! + sent, bytes.count - sent)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                sent += count
            }
            return true
        }
    }

    private func finish(_ client: Int32) {
        close(client)
        connections.withLock { $0 -= 1 }
    }
}
