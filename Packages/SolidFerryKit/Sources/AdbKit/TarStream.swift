import Darwin
import DeviceCore
import Foundation

/// One file in a tar stream.
struct TarEntry {
    let name: String
    let size: Int
    let mtime: Int
    let isFile: Bool
}

/// Reads a tar stream (ustar, with GNU long names and pax paths) as it arrives: each file's
/// data is handed to the caller in pieces, so nothing waits for the archive to finish.
struct TarReader {
    let socket: AdbSocket

    /// `open(entry)` returns where to write a file (nil skips it); `finish` is called when
    /// its data is complete. Returns when the archive ends.
    func read(open: (TarEntry) throws -> Int32?, finish: (TarEntry) throws -> Void,
              progress: (Int) -> Void) throws {
        var longName: String?
        while true {
            try socket.ensure(512)
            let header = UnsafeRawBufferPointer(start: socket.head, count: 512)
            if header.allSatisfy({ $0 == 0 }) {
                socket.consume(512)
                return // end of archive (a second zero block may follow; we stop here)
            }
            // A header whose checksum doesn't add up means the stream is out of step; its bytes
            // must not be taken for a file's.
            guard try Self.number(header, 148, 8) == Self.checksum(header) else {
                throw AdbError.protocolViolation("tar header checksum")
            }
            let type = header[156]
            let size = try Self.number(header, 124, 12)
            let mtime = (try? Self.number(header, 136, 12)) ?? 0
            var name = Self.string(header, 0, 100)
            if Self.string(header, 257, 5) == "ustar" {
                let prefix = Self.string(header, 345, 155)
                if !prefix.isEmpty { name = prefix + "/" + name }
            }
            socket.consume(512)

            switch type {
            case UInt8(ascii: "L"): // GNU: the next entry's long name
                longName = try readString(size).trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
                continue
            case UInt8(ascii: "x"): // pax: per-file attributes
                if let path = Self.paxPath(try readString(size)) { longName = path }
                continue
            default:
                break
            }
            let entry = TarEntry(name: longName ?? name, size: size, mtime: mtime,
                                 isFile: type == UInt8(ascii: "0") || type == 0)
            longName = nil
            let fd = entry.isFile ? try open(entry) : nil
            try copyData(size: size, to: fd, progress: progress)
            if fd != nil { try finish(entry) }
        }
    }

    /// Streams `size` bytes (plus padding to 512) into `fd`, or drops them.
    private func copyData(size: Int, to fd: Int32?, progress: (Int) -> Void) throws {
        var remaining = size
        while remaining > 0 {
            let chunk = min(remaining, 256 * 1024)
            try socket.ensure(chunk)
            if let fd {
                try writeFully(fd, UnsafeRawBufferPointer(start: socket.head, count: chunk))
                progress(chunk)
            }
            socket.consume(chunk)
            remaining -= chunk
        }
        let padding = (512 - size % 512) % 512
        if padding > 0 {
            try socket.ensure(padding)
            socket.consume(padding)
        }
    }

    private func readString(_ size: Int) throws -> String {
        var data = Data()
        var remaining = size
        while remaining > 0 {
            let chunk = min(remaining, 64 * 1024)
            try socket.ensure(chunk)
            data.append(socket.head.assumingMemoryBound(to: UInt8.self), count: chunk)
            socket.consume(chunk)
            remaining -= chunk
        }
        let padding = (512 - size % 512) % 512
        if padding > 0 {
            try socket.ensure(padding)
            socket.consume(padding)
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func string(_ header: UnsafeRawBufferPointer, _ offset: Int, _ length: Int) -> String {
        let field = header[offset..<offset + length]
        let end = field.firstIndex(of: 0) ?? field.endIndex
        return String(decoding: header[offset..<end], as: UTF8.self)
    }

    /// Octal, or base-256 when the high bit is set (sizes over 8 GB).
    static func number(_ header: UnsafeRawBufferPointer, _ offset: Int, _ length: Int) throws -> Int {
        if header[offset] & 0x80 != 0 {
            var value = Int(header[offset] & 0x7F)
            for i in offset + 1..<offset + length { value = value << 8 | Int(header[i]) }
            return value
        }
        let text = string(header, offset, length).trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return 0 }
        guard let value = Int(text, radix: 8) else { throw AdbError.protocolViolation("bad tar number \(text)") }
        return value
    }

    /// The header's bytes added up, its own checksum field counted as spaces.
    static func checksum(_ header: UnsafeRawBufferPointer) -> Int {
        header.enumerated().reduce(0) { sum, byte in sum + ((148..<156).contains(byte.offset) ? 32 : Int(byte.element)) }
    }

    /// "27 path=some/long/name\n" records → the path.
    static func paxPath(_ text: String) -> String? {
        for record in text.split(separator: "\n") {
            guard let space = record.firstIndex(of: " ") else { continue }
            let pair = record[record.index(after: space)...]
            if pair.hasPrefix("path=") { return String(pair.dropFirst(5)) }
        }
        return nil
    }
}
