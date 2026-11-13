import Darwin
import os

/// A one-way stream of bytes inside this app, for a file going from one device straight to
/// another: one side writes what it reads from the source device, the other reads it to send
/// to the target. A few megabytes of buffer even out the two devices' different rhythms (an
/// MTP phone answers in chunks, an upload sends steadily).
///
/// Closing the writing end ends the stream: the reader gets the end of file. Closing the
/// reading end makes the writer's next write fail (EPIPE, without a signal), so a side that
/// stops never leaves the other waiting.
public final class LocalPipe: Sendable {
    public let readEnd: Int32
    public let writeEnd: Int32
    private let open = OSAllocatedUnfairLock(initialState: (read: true, write: true))

    public init(buffer: Int = 4 << 20) throws {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw DeviceFSError.localWrite("pipe: \(errnoDescription())")
        }
        readEnd = fds[0]
        writeEnd = fds[1]
        var size = Int32(buffer), one: Int32 = 1
        let length = socklen_t(MemoryLayout<Int32>.size)
        for fd in fds {
            // Best effort: a smaller buffer still works, only with more waiting in between.
            setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, length)
            setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, length)
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, length)
        }
        shutdown(readEnd, SHUT_WR)
        shutdown(writeEnd, SHUT_RD)
    }

    /// Ends the stream for the reader. Once only; later calls do nothing.
    public func closeWriteEnd() {
        let wasOpen = open.withLock { state in
            defer { state.write = false }
            return state.write
        }
        if wasOpen { close(writeEnd) }
    }

    /// Stops the writer. Once only; later calls do nothing.
    public func closeReadEnd() {
        let wasOpen = open.withLock { state in
            defer { state.read = false }
            return state.read
        }
        if wasOpen { close(readEnd) }
    }

    /// Wakes a reader waiting on the read end with the end of file, without closing it (closing
    /// a descriptor another thread is reading would let its number be reused under it). Close
    /// the read end afterwards to stop the writer.
    public func endReading() {
        open.withLock { state in
            if state.read { shutdown(readEnd, SHUT_RD) }
        }
    }

    deinit {
        closeWriteEnd()
        closeReadEnd()
    }
}

/// Writes all of `bytes` to `fd`; a failure is `DeviceFSError.localWrite`.
public func writeFully(_ fd: Int32, _ bytes: UnsafeRawBufferPointer) throws {
    var written = 0
    while written < bytes.count {
        let n = Darwin.write(fd, bytes.baseAddress! + written, bytes.count - written)
        if n < 0 {
            if errno == EINTR { continue }
            throw DeviceFSError.localWrite(errnoDescription())
        }
        written += n
    }
}
