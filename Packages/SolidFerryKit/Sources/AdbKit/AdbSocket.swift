import Darwin
import DeviceCore
import Foundation

/// Blocking TCP connection to the local adb server with an internal read buffer, so that
/// parsing thousands of small directory entries doesn't cost a syscall each.
///
/// One thread drives reads and writes; `cancel()` may be called from any thread and makes
/// the blocked call fail.
final class AdbSocket: @unchecked Sendable {
    private let fd: Int32
    private let buffer: UnsafeMutableRawPointer
    private let capacity: Int
    private var start = 0
    private var end = 0

    convenience init(port: UInt16, bufferSize: Int = 512 * 1024) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AdbError.io("socket: \(errnoDescription())") }

        var one: Int32 = 1
        let optSize = socklen_t(MemoryLayout<Int32>.size)
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, optSize)
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, optSize)
        var rcvbuf = Int32(bufferSize)
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, optSize)

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc != 0 {
            let reason = errnoDescription()
            Darwin.close(fd)
            throw AdbError.serverUnavailable(reason)
        }

        self.init(fd: fd, bufferSize: bufferSize)
    }

    /// Takes over a connected socket (tests use one end of a `socketpair`).
    init(fd: Int32, bufferSize: Int = 512 * 1024) {
        self.fd = fd
        self.capacity = bufferSize
        self.buffer = .allocate(byteCount: bufferSize, alignment: 16)
    }

    deinit {
        Darwin.close(fd)
        buffer.deallocate()
    }

    /// Unblocks any pending read/write. The fd stays open until deinit so it can't be reused
    /// under a reader's feet.
    func cancel() {
        Darwin.shutdown(fd, SHUT_RDWR)
    }

    // MARK: Writing

    func write(_ bytes: UnsafeRawBufferPointer) throws {
        guard let base = bytes.baseAddress else { return }
        var offset = 0
        while offset < bytes.count {
            let n = Darwin.write(fd, base + offset, bytes.count - offset)
            if n < 0 {
                if errno == EINTR { continue }
                throw AdbError.io("write: \(errnoDescription())")
            }
            offset += n
        }
    }

    func write(_ bytes: [UInt8]) throws {
        try bytes.withUnsafeBytes { try write($0) }
    }

    // MARK: Reading

    /// Bytes currently buffered, starting at `head`.
    var available: Int { end - start }

    /// Start of the unread buffered bytes. Valid until the next read call.
    var head: UnsafeRawPointer { UnsafeRawPointer(buffer + start) }

    /// Makes at least `n` bytes available contiguously at `head`.
    func ensure(_ n: Int) throws {
        if end - start >= n { return }
        guard n <= capacity else { throw AdbError.protocolViolation("message too large (\(n) bytes)") }
        if capacity - start < n {
            let pending = end - start
            if pending > 0 { memmove(buffer, buffer + start, pending) }
            start = 0
            end = pending
        }
        while end - start < n {
            let r = Darwin.read(fd, buffer + end, capacity - end)
            if r < 0 {
                if errno == EINTR { continue }
                throw AdbError.io("read: \(errnoDescription())")
            }
            if r == 0 { throw AdbError.connectionClosed }
            end += r
        }
    }

    func consume(_ n: Int) {
        start += n
        if start == end {
            start = 0
            end = 0
        }
    }

    func readString(_ n: Int) throws -> String {
        try ensure(n)
        let s = String(decoding: UnsafeRawBufferPointer(start: head, count: n), as: UTF8.self)
        consume(n)
        return s
    }

    /// Reads until the peer closes the connection.
    func readToEnd() throws -> [UInt8] {
        var out: [UInt8] = []
        try readUntilClosed { out.append(contentsOf: $0) }
        return out
    }

    /// Hands what arrives to `body` piece by piece until the peer closes the connection.
    func readUntilClosed(_ body: (UnsafeRawBufferPointer) throws -> Void) throws {
        if available > 0 {
            try body(UnsafeRawBufferPointer(start: head, count: available))
            consume(available)
        }
        while true {
            let r = Darwin.read(fd, buffer, capacity)
            if r < 0 {
                if errno == EINTR { continue }
                throw AdbError.io("read: \(errnoDescription())")
            }
            if r == 0 { return }
            try body(UnsafeRawBufferPointer(start: buffer, count: r))
        }
    }
}

// MARK: - adb host protocol (4-hex-digit length prefix, OKAY/FAIL status)

extension AdbSocket {
    func sendHostRequest(_ request: String) throws {
        let payload = Array(request.utf8)
        guard payload.count <= 0xFFFF else { throw AdbError.protocolViolation("request too long") }
        try write(Array(String(format: "%04x", payload.count).utf8) + payload)
    }

    func readStatus() throws {
        let status = try readString(4)
        switch status {
        case "OKAY": return
        case "FAIL": throw AdbError.failed(try readHexLengthString())
        default: throw AdbError.protocolViolation("unexpected status \(status.debugDescription)")
        }
    }

    func readHexLengthString() throws -> String {
        let lengthText = try readString(4)
        guard let length = Int(lengthText, radix: 16) else {
            throw AdbError.protocolViolation("bad length \(lengthText.debugDescription)")
        }
        return try readString(length)
    }
}

// MARK: - Little-endian loads

extension UnsafeRawPointer {
    @inline(__always) func le32(_ offset: Int) -> UInt32 {
        UInt32(littleEndian: loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }

    @inline(__always) func le64(_ offset: Int) -> UInt64 {
        UInt64(littleEndian: loadUnaligned(fromByteOffset: offset, as: UInt64.self))
    }

    @inline(__always) func leInt64(_ offset: Int) -> Int64 {
        Int64(littleEndian: loadUnaligned(fromByteOffset: offset, as: Int64.self))
    }
}

/// Holds the socket of an in-flight operation so another thread can cancel it, including
/// the race where cancellation arrives before the socket is created.
final class SocketCanceller: @unchecked Sendable {
    private let lock = NSLock()
    private var socket: AdbSocket?
    private var cancelled = false

    func attach(_ socket: AdbSocket) {
        let alreadyCancelled = lock.withLock {
            self.socket = socket
            return cancelled
        }
        if alreadyCancelled { socket.cancel() }
    }

    func cancel() {
        let socket = lock.withLock {
            cancelled = true
            return self.socket
        }
        socket?.cancel()
    }
}

/// Blocking adb socket work, off the cooperative pool, that cancelling the task stops: `body`
/// attaches each socket it opens to the canceller, which shuts them down. A call that fails
/// once cancelled throws `CancellationError`. With `endsAtClose` (an answer read until the
/// connection closes, like a shell command's output) it also does when the work returned: a
/// socket shut down mid-read looks like that normal end, and what was read would pass for
/// the whole answer. Sync transfers end with their own message, so a finished one counts.
func cancellableBlocking<T: Sendable>(endsAtClose: Bool = false,
                                      _ body: @escaping @Sendable (SocketCanceller) throws -> T) async throws -> T {
    let canceller = SocketCanceller()
    do {
        let result = try await withTaskCancellationHandler {
            try await blocking { try body(canceller) }
        } onCancel: {
            canceller.cancel()
        }
        if endsAtClose { try Task.checkCancellation() }
        return result
    } catch {
        if Task.isCancelled { throw CancellationError() }
        throw error
    }
}

/// Runs blocking socket work off the cooperative thread pool.
func blocking<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(with: Result(catching: body))
        }
    }
}
