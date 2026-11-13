import Darwin
import DeviceCore
import Foundation

/// Wire layout of the adb sync protocol (AOSP `file_sync_protocol.h`). All fields little-endian, packed.
enum SyncID {
    static let lstatV1 = fourCC("STAT")
    static let statV2 = fourCC("STA2")
    static let listV1 = fourCC("LIST")
    static let listV2 = fourCC("LIS2")
    static let dentV1 = fourCC("DENT")
    static let dentV2 = fourCC("DNT2")
    static let recvV1 = fourCC("RECV")
    static let send = fourCC("SEND")
    static let done = fourCC("DONE")
    static let data = fourCC("DATA")
    static let okay = fourCC("OKAY")
    static let fail = fourCC("FAIL")
    static let quit = fourCC("QUIT")

    static func fourCC(_ s: String) -> UInt32 {
        var value: UInt32 = 0
        for (i, byte) in s.utf8.prefix(4).enumerated() {
            value |= UInt32(byte) << (8 * UInt32(i))
        }
        return value
    }
}

enum SyncLimits {
    static let maxPathLength = 1024
    static let maxDataLength = 64 * 1024
}

public struct SyncStat: Sendable, Equatable {
    public var mode: UInt32
    public var size: UInt64
    public var mtime: Int64
    /// Non-zero when the device couldn't stat the entry (v2 only).
    public var error: UInt32

    public var isDirectory: Bool { mode & 0o170000 == 0o040000 }
    public var isRegularFile: Bool { mode & 0o170000 == 0o100000 }
    public var isSymlink: Bool { mode & 0o170000 == 0o120000 }
}

public struct SyncDirEntry: Sendable, Equatable {
    public var name: String
    public var stat: SyncStat
}

enum SyncWire {
    /// id, mode, size, mtime, namelen
    static let dentV1Size = 20
    /// id, error, dev, ino, mode, nlink, uid, gid, size, atime, mtime, ctime, namelen
    static let dentV2Size = 76
    /// id, mode, size, mtime
    static let statV1Size = 16
    /// dent v2 without namelen
    static let statV2Size = 72

    static func parseDentV1(_ p: UnsafeRawPointer) -> (SyncStat, nameLength: Int) {
        (SyncStat(mode: p.le32(4), size: UInt64(p.le32(8)), mtime: Int64(p.le32(12)), error: 0), Int(p.le32(16)))
    }

    static func parseDentV2(_ p: UnsafeRawPointer) -> (SyncStat, nameLength: Int) {
        (parseStatV2(p), Int(p.le32(72)))
    }

    static func parseStatV1(_ p: UnsafeRawPointer) -> SyncStat {
        SyncStat(mode: p.le32(4), size: UInt64(p.le32(8)), mtime: Int64(p.le32(12)), error: 0)
    }

    static func parseStatV2(_ p: UnsafeRawPointer) -> SyncStat {
        SyncStat(mode: p.le32(24), size: p.le64(40), mtime: p.leInt64(56), error: p.le32(4))
    }
}

/// A `sync:` service connection to one device. Requests on one connection are processed in order.
final class SyncConnection {
    let socket: AdbSocket

    init(socket: AdbSocket) {
        self.socket = socket
    }

    private func sendRequest(_ id: UInt32, _ path: String) throws {
        try socket.write(Self.request(id, path))
    }

    private static func request(_ id: UInt32, _ path: String) throws -> [UInt8] {
        let pathBytes = Array(path.utf8)
        guard pathBytes.count <= SyncLimits.maxPathLength else {
            throw AdbError.pathTooLong(path)
        }
        var message = [UInt8]()
        message.reserveCapacity(8 + pathBytes.count)
        withUnsafeBytes(of: id.littleEndian) { message.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(pathBytes.count).littleEndian) { message.append(contentsOf: $0) }
        message.append(contentsOf: pathBytes)
        return message
    }

    /// Reads the FAIL message whose id is at `head` and throws it.
    private func throwFail() throws -> Never {
        try socket.ensure(8)
        let length = Int(socket.head.le32(4))
        socket.consume(8)
        throw AdbError.failed(try socket.readString(length))
    }

    func list(_ path: String, v2: Bool, _ onEntry: (SyncDirEntry) throws -> Void) throws {
        try sendRequest(v2 ? SyncID.listV2 : SyncID.listV1, path)
        try readListing(v2: v2, onEntry)
    }

    /// Sends every listing request up front, then reads the answers in order: the daemon
    /// handles one connection's requests sequentially, so this costs one round trip
    /// instead of one per folder. Keep batches modest so requests never fill the socket.
    func listMany(_ paths: [String], v2: Bool, _ onEntry: (Int, SyncDirEntry) throws -> Void) throws {
        var message = [UInt8]()
        for path in paths {
            message += try Self.request(v2 ? SyncID.listV2 : SyncID.listV1, path)
        }
        try socket.write(message)
        for index in paths.indices {
            try readListing(v2: v2) { try onEntry(index, $0) }
        }
    }

    private func readListing(v2: Bool, _ onEntry: (SyncDirEntry) throws -> Void) throws {
        let headerSize = v2 ? SyncWire.dentV2Size : SyncWire.dentV1Size
        let expected = v2 ? SyncID.dentV2 : SyncID.dentV1
        while true {
            // Peek the id first: a FAIL is shorter than a dent header.
            try socket.ensure(8)
            let id = socket.head.le32(0)
            if id == SyncID.fail { try throwFail() }
            try socket.ensure(headerSize)
            if id == SyncID.done {
                socket.consume(headerSize)
                return
            }
            guard id == expected else { throw AdbError.protocolViolation("unexpected list id \(id)") }
            let (stat, nameLength) = v2 ? SyncWire.parseDentV2(socket.head) : SyncWire.parseDentV1(socket.head)
            socket.consume(headerSize)
            let name = try socket.readString(nameLength)
            if name == "." || name == ".." { continue }
            try onEntry(SyncDirEntry(name: name, stat: stat))
        }
    }

    /// Follows symlinks on v2; v1 only has lstat.
    func stat(_ path: String, v2: Bool) throws -> SyncStat {
        try sendRequest(v2 ? SyncID.statV2 : SyncID.lstatV1, path)
        try socket.ensure(8)
        let id = socket.head.le32(0)
        if id == SyncID.fail { try throwFail() }
        if v2 {
            guard id == SyncID.statV2 else { throw AdbError.protocolViolation("unexpected stat id \(id)") }
            try socket.ensure(SyncWire.statV2Size)
            let stat = SyncWire.parseStatV2(socket.head)
            socket.consume(SyncWire.statV2Size)
            if stat.error != 0 { throw AdbError.remoteError(path: path, errno: stat.error) }
            return stat
        } else {
            guard id == SyncID.lstatV1 else { throw AdbError.protocolViolation("unexpected stat id \(id)") }
            try socket.ensure(SyncWire.statV1Size)
            let stat = SyncWire.parseStatV1(socket.head)
            socket.consume(SyncWire.statV1Size)
            // v1 reports a missing file as all zeros.
            if stat.mode == 0 { throw AdbError.remoteError(path: path, errno: 2) }
            return stat
        }
    }

    /// Streams the file's contents into `fd`. `progress` gets byte deltas.
    func receive(_ path: String, to fd: Int32, progress: (Int) -> Void) throws {
        try sendRequest(SyncID.recvV1, path)
        while true {
            try socket.ensure(8)
            let id = socket.head.le32(0)
            let length = Int(socket.head.le32(4))
            if id == SyncID.done {
                socket.consume(8)
                return
            }
            if id == SyncID.fail { try throwFail() }
            guard id == SyncID.data, length <= SyncLimits.maxDataLength else {
                throw AdbError.protocolViolation("unexpected recv message \(id) (\(length) bytes)")
            }
            socket.consume(8)
            try socket.ensure(length)
            try writeFully(fd, UnsafeRawBufferPointer(start: socket.head, count: length))
            socket.consume(length)
            progress(length)
        }
    }

    /// Pipelined RECV: keeps up to `window` requests in flight on this connection, so many
    /// small files cost one round trip each window instead of one per file. `open(i)` gives
    /// the file to write item i into (-1 drops its data, e.g. when it can't be created
    /// locally), `finish(i, error)` is called when it's complete (or the device refused it). The daemon drops the connection after refusing a file, so
    /// this returns the index to resume from on a new connection; nil when all are done. QUIRKS A8, A9.
    func receiveMany(_ paths: [String], window: Int = 32, open: (Int) throws -> Int32,
                     finish: (Int, Error?) throws -> Void, progress: (Int) -> Void) throws -> Int? {
        var sent = 0
        func sendUpTo(_ limit: Int) throws {
            var message = [UInt8]()
            while sent < min(limit, paths.count) {
                message += try Self.request(SyncID.recvV1, paths[sent])
                sent += 1
            }
            if !message.isEmpty { try socket.write(message) }
        }
        try sendUpTo(window)
        for index in paths.indices {
            let fd = try open(index)
            var failure: Error?
            reading: while true {
                try socket.ensure(8)
                let id = socket.head.le32(0)
                let length = Int(socket.head.le32(4))
                switch id {
                case SyncID.done:
                    socket.consume(8)
                    break reading
                case SyncID.fail:
                    do { try throwFail() } catch { failure = error }
                    break reading
                case SyncID.data where length <= SyncLimits.maxDataLength:
                    socket.consume(8)
                    try socket.ensure(length)
                    if fd >= 0 {
                        try writeFully(fd, UnsafeRawBufferPointer(start: socket.head, count: length))
                        progress(length)
                    }
                    socket.consume(length)
                default:
                    throw AdbError.protocolViolation("unexpected recv message \(id) (\(length) bytes)")
                }
            }
            try finish(index, failure)
            if failure != nil { return index + 1 < paths.count ? index + 1 : nil }
            // Top up once half the window is answered, so the device never runs dry.
            if sent - index - 1 < window / 2 { try sendUpTo(index + 1 + window) }
        }
        return nil
    }

    /// SEND v1: "path,mode" request, DATA chunks, DONE carrying the mtime, then OKAY/FAIL.
    /// With `expected`, exactly that many bytes must come from `fd` before its end: otherwise
    /// it fails before DONE, so the device never completes the file (adbd removes it).
    func send(from fd: Int32, to path: String, mode: UInt32 = 0o100644, mtime: UInt32, expected: UInt64? = nil,
              progress: (Int) -> Void) throws {
        try sendRequest(SyncID.send, "\(path),\(mode)")
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 8 + SyncLimits.maxDataLength, alignment: 8)
        defer { buffer.deallocate() }
        var total: UInt64 = 0
        var ended = false
        while !ended {
            // Fill a whole DATA message: a pipe gives what's there so far, often much less.
            var n = 0
            while n < SyncLimits.maxDataLength {
                let got = Darwin.read(fd, buffer + 8 + n, SyncLimits.maxDataLength - n)
                if got < 0 {
                    if errno == EINTR { continue }
                    // Reading on this Mac failed, not writing anything.
                    throw DeviceFSError.localRead(errnoDescription())
                }
                if got == 0 { ended = true; break }
                n += got
            }
            total += UInt64(n)
            if let expected, total > expected { throw DeviceFSError.localRead("more than the \(expected) bytes expected") }
            if n == 0 { break }
            buffer.storeBytes(of: SyncID.data.littleEndian, toByteOffset: 0, as: UInt32.self)
            buffer.storeBytes(of: UInt32(n).littleEndian, toByteOffset: 4, as: UInt32.self)
            try socket.write(UnsafeRawBufferPointer(start: buffer, count: 8 + n))
            progress(n)
        }
        if let expected, total != expected { throw DeviceFSError.localRead("ended after \(total) of \(expected) bytes") }
        var done = [UInt8]()
        withUnsafeBytes(of: SyncID.done.littleEndian) { done.append(contentsOf: $0) }
        withUnsafeBytes(of: mtime.littleEndian) { done.append(contentsOf: $0) }
        try socket.write(done)
        try socket.ensure(8)
        let id = socket.head.le32(0)
        if id == SyncID.fail { try throwFail() }
        guard id == SyncID.okay else { throw AdbError.protocolViolation("unexpected send reply \(id)") }
        socket.consume(8)
    }

    func quit() {
        try? sendRequest(SyncID.quit, "")
    }
}
