import Darwin
import Foundation
@testable import AdbKit
import Testing

// The sync protocol and tar reader against fixed bytes: the phone's side of a socketpair is
// written up front and closed, so every reply is exactly what's given here.

/// A socket whose phone side has already sent `reply` and stopped sending. The phone side
/// stays open for reading what was asked (`requests(from:)`).
private final class FakePhone {
    let socket: AdbSocket
    private let peer: Int32

    init(replying reply: [UInt8]) throws {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw AdbError.io("socketpair") }
        var size: Int32 = 1 << 20
        // Room both ways, so neither side has to read before the other finishes writing.
        for (fd, option) in [(fds[1], SO_SNDBUF), (fds[0], SO_RCVBUF), (fds[0], SO_SNDBUF), (fds[1], SO_RCVBUF)] {
            setsockopt(fd, SOL_SOCKET, option, &size, socklen_t(MemoryLayout<Int32>.size))
        }
        var offset = 0
        while offset < reply.count {
            let n = reply[offset...].withUnsafeBytes { Darwin.write(fds[1], $0.baseAddress, $0.count) }
            guard n > 0 else { throw AdbError.io("write") }
            offset += n
        }
        shutdown(fds[1], SHUT_WR)
        socket = AdbSocket(fd: fds[0], bufferSize: 128 * 1024)
        peer = fds[1]
    }

    deinit { close(peer) }

    /// Everything received so far, as sent.
    func received() -> [UInt8] {
        fcntl(peer, F_SETFL, fcntl(peer, F_GETFL) | O_NONBLOCK)
        var bytes: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(peer, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            bytes += buffer[..<n]
        }
        return bytes
    }

    /// The sync requests received so far: (id, path).
    func requests() -> [(String, String)] {
        let bytes = received()
        var out: [(String, String)] = []
        var i = 0
        while i + 8 <= bytes.count {
            let id = String(decoding: bytes[i..<i + 4], as: UTF8.self)
            let length = Int(bytes[i + 4]) | Int(bytes[i + 5]) << 8 | Int(bytes[i + 6]) << 16 | Int(bytes[i + 7]) << 24
            out.append((id, String(decoding: bytes[i + 8..<i + 8 + length], as: UTF8.self)))
            i += 8 + length
        }
        return out
    }
}

private func le32(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }
private func le64(_ v: UInt64) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }
private func message(_ id: String, _ payload: [UInt8] = []) -> [UInt8] {
    le32(SyncID.fourCC(id)) + le32(UInt32(payload.count)) + payload
}
private func data(_ text: String) -> [UInt8] { message("DATA", Array(text.utf8)) }
private let done = message("DONE")
private func fail(_ text: String) -> [UInt8] { message("FAIL", Array(text.utf8)) }

/// A DNT2 entry (or, with id DONE, the listing's end, which comes at the same size).
private func dentV2(_ name: String, mode: UInt32 = 0o100644, size: UInt64 = 0, mtime: UInt64 = 0,
                    id: String = "DNT2") -> [UInt8] {
    let ids = le32(SyncID.fourCC(id)) + le32(0) + le64(0) + le64(0)           // id, error, dev, ino
    let stat = le32(mode) + le32(1) + le32(0) + le32(0) + le64(size)          // mode, nlink, uid, gid, size
    let times = le64(0) + le64(mtime) + le64(0)                               // atime, mtime, ctime
    return ids + stat + times + le32(UInt32(name.utf8.count)) + Array(name.utf8)
}

/// Reads everything written to a pipe once its write end is closed.
private func drain(_ fds: [Int32]) -> String {
    close(fds[1])
    var bytes: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = buffer.withUnsafeMutableBytes { Darwin.read(fds[0], $0.baseAddress, $0.count) }
        if n <= 0 { break }
        bytes += buffer[..<n]
    }
    close(fds[0])
    return String(decoding: bytes, as: UTF8.self)
}

private func makePipe() -> [Int32] {
    var fds: [Int32] = [0, 0]
    _ = pipe(&fds)
    return fds
}

// MARK: RECV

@Test func receiveManyResumesAfterARefusedFile() throws {
    // QUIRKS A9: after a FAIL the daemon drops the connection, so the requests sent ahead are
    // lost and the rest is asked for again from the next index.
    let phone = try FakePhone(replying: data("ab") + data("c") + done + fail("open failed: No such file or directory"))
    let sync = SyncConnection(socket: phone.socket)
    let pipes = [makePipe(), makePipe(), makePipe()]
    var finished: [(Int, AdbError?)] = []
    var received = 0
    let resume = try sync.receiveMany(["/a", "/b", "/c"], open: { pipes[$0][1] },
                                      finish: { i, error in finished.append((i, error as? AdbError)) },
                                      progress: { received += $0 })
    #expect(resume == 2)
    #expect(finished.map(\.0) == [0, 1])
    #expect(finished[0].1 == nil)
    #expect(finished[1].1 == .failed("open failed: No such file or directory"))
    #expect(received == 3)
    #expect(drain(pipes[0]) == "abc")
    #expect(phone.requests().map(\.1) == ["/a", "/b", "/c"]) // all sent ahead within one window
}

@Test func receiveManyTopsUpTheWindow() throws {
    let phone = try FakePhone(replying: done + done + done + done + done)
    let sync = SyncConnection(socket: phone.socket)
    let paths = ["/1", "/2", "/3", "/4", "/5"]
    var finished: [Int] = []
    let resume = try sync.receiveMany(paths, window: 2, open: { _ in -1 }, finish: { i, _ in finished.append(i) }, progress: { _ in })
    #expect(resume == nil)
    #expect(finished == [0, 1, 2, 3, 4])
    let requests = phone.requests()
    #expect(requests.map(\.0) == Array(repeating: "RECV", count: 5))
    #expect(requests.map(\.1) == paths)
}

@Test func receiveStopsWhenTheConnectionEndsMidFile() throws {
    // DATA says 10 bytes; 3 arrive and the stream ends.
    let phone = try FakePhone(replying: le32(SyncID.data) + le32(10) + Array("abc".utf8))
    let sync = SyncConnection(socket: phone.socket)
    let fds = makePipe()
    #expect(throws: AdbError.connectionClosed) { try sync.receive("/a", to: fds[1], progress: { _ in }) }
    _ = drain(fds)
}

@Test func receiveRefusesOversizedData() throws {
    let phone = try FakePhone(replying: le32(SyncID.data) + le32(UInt32(SyncLimits.maxDataLength + 1)))
    let sync = SyncConnection(socket: phone.socket)
    #expect(throws: AdbError.self) { try sync.receive("/a", to: -1, progress: { _ in }) }
}

// MARK: LIST and STAT

@Test func listingSkipsDotsAndKeeps64BitSizes() throws {
    let reply = dentV2(".", mode: 0o040755) + dentV2("..", mode: 0o040755)
        + dentV2("big.mp4", size: 5_000_000_000, mtime: 1_700_000_000) + dentV2("", id: "DONE")
    let phone = try FakePhone(replying: reply)
    var entries: [SyncDirEntry] = []
    try SyncConnection(socket: phone.socket).list("/sdcard/Movies", v2: true) { entries.append($0) }
    #expect(entries.map(\.name) == ["big.mp4"])
    #expect(entries.first?.stat.size == 5_000_000_000)
    #expect(entries.first?.stat.mtime == 1_700_000_000)
    #expect(entries.first?.stat.isRegularFile == true)
    #expect(phone.requests().first?.0 == "LIS2")
}

@Test func listingStopsAtAFail() throws {
    let phone = try FakePhone(replying: dentV2("a") + fail("Permission denied"))
    var names: [String] = []
    #expect(throws: AdbError.failed("Permission denied")) {
        try SyncConnection(socket: phone.socket).list("/data", v2: true) { names.append($0.name) }
    }
    #expect(names == ["a"])
}

@Test func statReportsMissingFiles() throws {
    // v2 carries the errno; v1 says "missing" with all zeros.
    var statV2 = dentV2("", id: "STA2")
    statV2.removeLast(4)                       // a stat is a dent without the name length
    statV2.replaceSubrange(4..<8, with: le32(2)) // error: ENOENT
    let v2 = try FakePhone(replying: statV2)
    #expect(throws: AdbError.remoteError(path: "/x", errno: 2)) { try SyncConnection(socket: v2.socket).stat("/x", v2: true) }

    let v1 = try FakePhone(replying: le32(SyncID.lstatV1) + le32(0) + le32(0) + le32(0))
    #expect(throws: AdbError.remoteError(path: "/x", errno: 2)) { try SyncConnection(socket: v1.socket).stat("/x", v2: false) }
}

// MARK: Tar

/// One 512-byte tar header.
private func tarHeader(_ name: String, size: Int, mtime: Int = 0, type: Character = "0") -> [UInt8] {
    var h = [UInt8](repeating: 0, count: 512)
    func put(_ text: String, at offset: Int) { for (i, b) in text.utf8.enumerated() { h[offset + i] = b } }
    put(name, at: 0)
    put(String(format: "%011o", size), at: 124)
    put(String(format: "%011o", mtime), at: 136)
    h[156] = type.asciiValue!
    put("ustar", at: 257)
    put("00", at: 263)
    let sum = h.enumerated().reduce(0) { $0 + ((148..<156).contains($1.offset) ? 32 : Int($1.element)) }
    put(String(format: "%06o", sum), at: 148)
    h[154] = 0
    h[155] = 0x20
    return h
}

private func padded(_ text: String) -> [UInt8] {
    let bytes = Array(text.utf8)
    return bytes + [UInt8](repeating: 0, count: (512 - bytes.count % 512) % 512)
}

@Test func tarReaderFollowsLongNamesAndPaxPaths() throws {
    let longName = "sdcard/" + String(repeating: "긴이름", count: 20) + ".txt" // over 100 bytes
    let paxRecord = "30 path=sdcard/pax/name.txt\n"
    var archive = tarHeader("././@LongLink", size: longName.utf8.count + 1, type: "L") + padded(longName + "\0")
    archive += tarHeader("cut-short", size: 5, mtime: 1_700_000_000) + padded("hello")
    archive += tarHeader("sdcard/pax", size: 0, type: "5")                        // a folder: skipped
    archive += tarHeader("PaxHeader", size: paxRecord.utf8.count, type: "x") + padded(paxRecord)
    archive += tarHeader("ignored", size: 600) + padded(String(repeating: "z", count: 600))
    archive += [UInt8](repeating: 0, count: 1024)
    let phone = try FakePhone(replying: archive)

    let first = makePipe()
    var opened: [String] = [], finished: [Int] = []
    var received = 0
    try TarReader(socket: phone.socket).read(open: { entry in
        opened.append(entry.name)
        return entry.name == longName ? first[1] : nil // the second is dropped, not written
    }, finish: { entry in finished.append(entry.mtime) }, progress: { received += $0 })
    #expect(opened == [longName, "sdcard/pax/name.txt"])
    #expect(finished == [1_700_000_000])
    #expect(received == 5)
    #expect(drain(first) == "hello")
}

@Test func tarReaderStopsWhenTheStreamEndsEarly() throws {
    let phone = try FakePhone(replying: tarHeader("a", size: 1000) + Array(repeating: 0x61, count: 10))
    #expect(throws: AdbError.connectionClosed) {
        try TarReader(socket: phone.socket).read(open: { _ in nil }, finish: { _ in }, progress: { _ in })
    }
}

@Test func tarReaderRefusesAHeaderThatDoesntCheckOut() throws {
    var header = tarHeader("a", size: 5)
    header[0] = UInt8(ascii: "b")                  // a byte changed after the checksum was made
    let phone = try FakePhone(replying: header + padded("hello") + [UInt8](repeating: 0, count: 1024))
    #expect(throws: AdbError.protocolViolation("tar header checksum")) {
        try TarReader(socket: phone.socket).read(open: { _ in nil }, finish: { _ in }, progress: { _ in })
    }
}

// MARK: SEND and listing several folders

@Test func sendFramesTheFileAndEndsWithItsDate() throws {
    let phone = try FakePhone(replying: message("OKAY"))
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("send-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: url) }
    let content = [UInt8]((0..<70_000).map { UInt8($0 % 251) })   // more than one 64 KB DATA
    try Data(content).write(to: url)
    let fd = open(url.path, O_RDONLY)
    defer { close(fd) }
    var progressed = 0
    try SyncConnection(socket: phone.socket).send(from: fd, to: "/sdcard/a.bin", mode: 0o100644, mtime: 1_700_000_000) { progressed += $0 }
    #expect(progressed == content.count)
    let path = Array("/sdcard/a.bin,\(0o100644)".utf8)
    let first = SyncLimits.maxDataLength
    let expected: [UInt8] = message("SEND", path)
        + message("DATA", Array(content[..<first])) + message("DATA", Array(content[first...]))
        + le32(SyncID.done) + le32(1_700_000_000)
    #expect(phone.received() == expected)
}

@Test func sendReportsThePhonesRefusal() throws {
    let phone = try FakePhone(replying: fail("Read-only file system"))
    let fd = open("/dev/null", O_RDONLY)
    defer { close(fd) }
    #expect(throws: AdbError.failed("Read-only file system")) {
        try SyncConnection(socket: phone.socket).send(from: fd, to: "/system/x", mtime: 0) { _ in }
    }
}

@Test func listingSeveralFoldersKeepsEachAnswerWithItsFolder() throws {
    let reply = dentV2("a.jpg") + dentV2("", id: "DONE") + dentV2("b.jpg") + dentV2("c.jpg") + dentV2("", id: "DONE")
    let phone = try FakePhone(replying: reply)
    var found: [(Int, String)] = []
    try SyncConnection(socket: phone.socket).listMany(["/sdcard/A", "/sdcard/B"], v2: true) { found.append(($0, $1.name)) }
    #expect(found.map(\.0) == [0, 1, 1] && found.map(\.1) == ["a.jpg", "b.jpg", "c.jpg"])
    #expect(phone.requests().map(\.1) == ["/sdcard/A", "/sdcard/B"]) // both asked up front
}
