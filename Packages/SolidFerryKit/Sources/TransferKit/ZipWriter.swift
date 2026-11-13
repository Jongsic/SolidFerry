import Foundation
import zlib

/// One item of a zip archive.
public struct ZipItem: Sendable, Hashable {
    /// Path inside the archive ("Trip/Day 1/a.jpg"); folders without the trailing slash.
    public let path: String
    /// The file's contents; nil for a folder.
    public let source: URL?
    public let modified: Date

    public init(path: String, source: URL?, modified: Date) {
        self.path = path
        self.source = source
        self.modified = modified
    }

    public var isDirectory: Bool { source == nil }
}

/// Writes "stored" (uncompressed) zip archives: for sending files to a phone whose file
/// manager unpacks them with their dates, when the connection itself can't set dates (Galaxy
/// over MTP; QUIRKS G6, G7). Photos and videos are compressed already, so storing costs little.
///
/// Choices made for phone file managers:
/// - Sizes and CRC are in each local header (filled in after the data), no data descriptors:
///   Java's ZipInputStream can't read stored entries that rely on one.
/// - UTF-8 names (flag bit 11), and an extended timestamp (0x5455) next to the 2-second DOS
///   time: Samsung's My Files restores file dates to the second from it (measured).
/// - Folders are written after their contents, for unpackers that set a folder's date when
///   they reach its entry (files created inside afterwards would change it). Samsung's My
///   Files doesn't restore folder dates in either order (measured), so there they're lost.
/// - Zip64 only where a value doesn't fit 32 bits (a file of 4 GB or more, an archive past
///   4 GB, 65,535 entries or more), so smaller archives stay readable by the oldest unzippers.
///   Samsung's My Files and Android 14's Files unpack Zip64; Android 11's Files doesn't
///   (QUIRKS G9, S5). The zip is offered for any phone that doesn't keep upload dates; the
///   upload dialog says when a zip that large may not open in every file manager.
public enum ZipWriter {
    /// Values from this up need Zip64.
    public static let plainLimit: UInt64 = 0xFFFF_FFFF

    public enum Failure: Error, Equatable {
        /// The file grew past 4 GB while it was being zipped.
        case tooLarge(String)
        case unreadable(String)
    }

    /// `progress` gets byte counts and may throw to stop (e.g. when the job is cancelled).
    public static func write(_ items: [ZipItem], to url: URL, progress: (Int) throws -> Void = { _ in }) throws {
        try write(items, to: url, beyond: plainLimit, progress: progress)
    }

    /// `beyond`: values from this up are written as Zip64 (lowered by tests, which can't
    /// write 4 GB).
    static func write(_ items: [ZipItem], to url: URL, beyond: UInt64,
                      progress: (Int) throws -> Void = { _ in }) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw Failure.unreadable(url.path)
        }
        let out = try FileHandle(forWritingTo: url)
        defer { try? out.close() }
        var central = Data()
        var count = 0
        // Files first, then folders deepest first (see above).
        let ordered = items.filter { !$0.isDirectory }
            + items.filter(\.isDirectory).sorted { $0.path.split(separator: "/").count > $1.path.split(separator: "/").count }
        for item in ordered {
            let offset = try out.offset()
            let name = Data((item.isDirectory ? item.path + "/" : item.path).utf8)
            let (dosTime, dosDate) = dosDateTime(item.modified)
            let unixTime = UInt32(clamping: Int(item.modified.timeIntervalSince1970))
            var timestamp = Data()
            timestamp.append16(0x5455)  // extended timestamp
            timestamp.append16(5)
            timestamp.append(0x01)      // modification time present
            timestamp.append32(unixTime)
            // A file this big says its sizes in a Zip64 field; decided before the data goes
            // out, since the header comes first.
            let expected = item.source.flatMap {
                (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init)
            } ?? 0
            let bigFile = expected >= beyond
            let version: UInt16 = bigFile || offset >= beyond ? 45 : item.isDirectory ? 20 : 10

            var header = Data()
            header.append32(0x0403_4B50)
            header.append16(version)                     // version needed
            header.append16(0x0800)                      // UTF-8 names
            header.append16(0)                           // stored
            header.append16(dosTime)
            header.append16(dosDate)
            header.append32(0)                           // CRC, filled in below
            header.append32(bigFile ? 0xFFFF_FFFF : 0)   // compressed size
            header.append32(bigFile ? 0xFFFF_FFFF : 0)   // size
            var localExtra = Data()
            if bigFile {
                localExtra.append16(0x0001)              // Zip64: size, compressed size
                localExtra.append16(16)
                localExtra.append64(0)
                localExtra.append64(0)
            }
            localExtra.append(timestamp)
            header.append16(UInt16(name.count))
            header.append16(UInt16(localExtra.count))
            try out.write(contentsOf: header + name + localExtra)

            var crc = CRC32()
            var size: UInt64 = 0
            if let source = item.source {
                guard let input = try? FileHandle(forReadingFrom: source) else { throw Failure.unreadable(source.path) }
                defer { try? input.close() }
                while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                    crc.update(chunk)
                    size += UInt64(chunk.count)
                    guard bigFile || size < beyond else { throw Failure.tooLarge(item.path) }
                    try out.write(contentsOf: chunk)
                    try progress(chunk.count)
                }
                // Fill in CRC and sizes now that they're known.
                let end = try out.offset()
                try out.seek(toOffset: offset + 14)
                var sizes = Data()
                sizes.append32(crc.value)
                if !bigFile {
                    sizes.append32(UInt32(size))
                    sizes.append32(UInt32(size))
                }
                try out.write(contentsOf: sizes)
                if bigFile {
                    try out.seek(toOffset: offset + 30 + UInt64(name.count) + 4)
                    var big = Data()
                    big.append64(size)
                    big.append64(size)
                    try out.write(contentsOf: big)
                }
                try out.seek(toOffset: end)
            }

            // Zip64 in the directory: only the values that don't fit, in this order.
            var zip64 = Data()
            if bigFile {
                zip64.append64(size)
                zip64.append64(size)
            }
            if offset >= beyond { zip64.append64(offset) }
            var centralExtra = Data()
            if !zip64.isEmpty {
                centralExtra.append16(0x0001)
                centralExtra.append16(UInt16(zip64.count))
                centralExtra.append(zip64)
            }
            centralExtra.append(timestamp)

            central.append32(0x0201_4B50)
            central.append16(0x0300 | max(20, version))  // made by: Unix
            central.append16(version)
            central.append16(0x0800)
            central.append16(0)
            central.append16(dosTime)
            central.append16(dosDate)
            central.append32(crc.value)
            central.append32(bigFile ? 0xFFFF_FFFF : UInt32(size))
            central.append32(bigFile ? 0xFFFF_FFFF : UInt32(size))
            central.append16(UInt16(name.count))
            central.append16(UInt16(centralExtra.count))
            central.append16(0)                          // comment
            central.append16(0)                          // disk
            central.append16(0)                          // internal attributes
            let mode: UInt32 = item.isDirectory ? 0o040755 : 0o100644
            central.append32(mode << 16 | (item.isDirectory ? 0x10 : 0))
            central.append32(offset >= beyond ? 0xFFFF_FFFF : UInt32(offset))
            central.append(name)
            central.append(centralExtra)
            count += 1
        }
        let centralOffset = try out.offset()
        let centralSize = UInt64(central.count)
        let manyEntries = UInt64(count) >= min(0xFFFF, beyond)
        var end = Data()
        if manyEntries || centralOffset >= beyond || centralSize >= beyond {
            let record = centralOffset + centralSize
            end.append32(0x0606_4B50)                    // Zip64 end of central directory
            end.append64(44)
            end.append16(0x032D)
            end.append16(45)
            end.append32(0)
            end.append32(0)
            end.append64(UInt64(count))
            end.append64(UInt64(count))
            end.append64(centralSize)
            end.append64(centralOffset)
            end.append32(0x0706_4B50)                    // its locator
            end.append32(0)
            end.append64(record)
            end.append32(1)
        }
        end.append32(0x0605_4B50)
        end.append16(0)
        end.append16(0)
        end.append16(manyEntries ? 0xFFFF : UInt16(count))
        end.append16(manyEntries ? 0xFFFF : UInt16(count))
        end.append32(centralSize >= beyond ? 0xFFFF_FFFF : UInt32(centralSize))
        end.append32(centralOffset >= beyond ? 0xFFFF_FFFF : UInt32(centralOffset))
        end.append16(0)
        try out.write(contentsOf: central + end)
    }

    /// MS-DOS time and date (local time, 2-second steps; 1980 at the earliest).
    static func dosDateTime(_ date: Date) -> (UInt16, UInt16) {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year: Int = min(max((c.year ?? 1980) - 1980, 0), 127)
        let hour: Int = c.hour ?? 0, minute: Int = c.minute ?? 0, second: Int = c.second ?? 0
        let month: Int = c.month ?? 1, day: Int = c.day ?? 1
        let time: Int = hour << 11 | minute << 5 | second / 2
        let dayBits: Int = year << 9 | month << 5 | day
        return (UInt16(time), UInt16(dayBits))
    }
}

/// CRC-32 as zip uses it, through the system's zlib (a byte-at-a-time loop in Swift would be
/// the slowest part of building a large zip).
struct CRC32 {
    private(set) var value: UInt32 = 0

    mutating func update(_ data: Data) {
        data.withUnsafeBytes { bytes in
            guard let base = bytes.bindMemory(to: Bytef.self).baseAddress else { return }
            value = UInt32(zlib.crc32(uLong(value), base, uInt(bytes.count)))
        }
    }
}

private extension Data {
    mutating func append16(_ v: UInt16) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    mutating func append32(_ v: UInt32) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    mutating func append64(_ v: UInt64) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
}

/// What an upload becomes when sent as one zip archive.
public struct ZipPackage: Sendable {
    /// The archive's file name ("Trip.zip").
    public let fileName: String
    public let items: [ZipItem]
    public let totalBytes: UInt64

    /// Big enough that it'll be written with Zip64 (or close to it), which not every file
    /// manager opens (QUIRKS S5).
    public var isLarge: Bool {
        totalBytes + UInt64(items.count) * 512 >= ZipWriter.plainLimit || items.count >= 0xFFFF
    }
}

extension UploadPlan {
    /// The plan as one archive, laid out so that a phone's file manager (which unpacks into a
    /// folder named after the archive) recreates it: a single folder "Trip" becomes "Trip.zip"
    /// holding Trip's contents; anything else goes into `otherwiseNamed`.zip as is.
    public func zipPackage(sources: [URL], otherwiseNamed name: String) -> ZipPackage {
        let sourceByTop = Dictionary(sources.map { ($0.lastPathComponent, $0) }, uniquingKeysWith: { a, _ in a })
        let tops = Set(files.map(\.relativePath).map(Self.top) + directories.map(Self.top))
        let single = tops.count == 1 && directories.contains(tops.first!) ? tops.first : nil

        func inner(_ path: String) -> String? {
            guard let single else { return path }
            return path == single ? nil : String(path.dropFirst(single.count + 1))
        }
        func folderDate(_ relative: String) -> Date {
            let top = Self.top(relative)
            guard let source = sourceByTop[top] else { return Date() }
            let url = relative == top ? source : source.appendingPathComponent(String(relative.dropFirst(top.count + 1)))
            return (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        }
        var items: [ZipItem] = []
        for dir in directories {
            guard let path = inner(dir) else { continue }
            items.append(ZipItem(path: path, source: nil, modified: folderDate(dir)))
        }
        for file in files {
            guard let path = inner(file.relativePath) else { continue }
            items.append(ZipItem(path: path, source: file.url, modified: file.modified ?? Date()))
        }
        return ZipPackage(fileName: (single ?? name) + ".zip", items: items, totalBytes: totalBytes)
    }

    private static func top(_ path: String) -> String {
        path.split(separator: "/", maxSplits: 1).first.map(String.init) ?? path
    }
}
