import Foundation
import DeviceCore
import Testing
@testable import MtpKit

@Test func ptpStringDecodes() throws {
    // count 4 (incl NUL): "Hi!" UTF-16LE + NUL
    var r = PTPReader([4, 0x48, 0, 0x69, 0, 0x21, 0, 0, 0])
    #expect(try r.string() == "Hi!")
    var empty = PTPReader([0])
    #expect(try empty.string() == "")
}

@Test func commandContainerLayout() {
    let bytes = ptpCommand(0x1007, transaction: 5, params: [1, 0, 0xFFFF_FFFF])
    #expect(bytes.count == 24)
    #expect(Array(bytes[0..<4]) == [24, 0, 0, 0])
    #expect(Array(bytes[4..<8]) == [1, 0, 0x07, 0x10])
    #expect(Array(bytes[8..<12]) == [5, 0, 0, 0])
}

@Test func ptpDates() {
    let utc = parsePTPDate("20250602T154908Z")
    #expect(utc == ISO8601DateFormatter().date(from: "2025-06-02T15:49:08Z"))
    let offset = parsePTPDate("20250602T154908+0900")
    #expect(offset == ISO8601DateFormatter().date(from: "2025-06-02T06:49:08Z"))
    #expect(parsePTPDate("2025") == nil)
}

@Test func ptpStringRoundTrip() throws {
    for name in ["a.jpg", "한글 파일.txt", "emoji 📷.png", ""] {
        var reader = PTPReader(try ptpString(name))
        #expect(try reader.string() == name)
    }
}

@Test func ptpReaderIntegersAndTruncation() throws {
    var reader = PTPReader([0x01, 0x02, 0x03, 0x04, 0x05, 0x06])
    #expect(try reader.u16() == 0x0201)
    #expect(try reader.u32() == 0x0605_0403)
    #expect(throws: (any Error).self) { try reader.u16() }
}

@Test func ptpDateWithoutZoneIsLocal() {
    let local = parsePTPDate("20250602T154908")
    var components = DateComponents()
    (components.year, components.month, components.day, components.hour, components.minute, components.second) = (2025, 6, 2, 15, 49, 8)
    #expect(local == Calendar.current.date(from: components))
}

@Test func samsungDeviceStatus() {
    var info = MtpDeviceInfo()
    info.vendorExtension = "microsoft.com: 1.0; samsung.com/kies: 6.0; samsung.com/devicestatus: 4;"
    #expect(info.samsungDeviceStatus == 4)
    info.vendorExtension = "microsoft.com: 1.0; android.com: 1.0;"
    #expect(info.samsungDeviceStatus == nil)
}

@Test func ptpStringRefusesWhatItCantSay() throws {
    #expect(throws: DeviceFSError.self) { try ptpString(String(repeating: "a", count: 255)) }
    #expect(try ptpString(String(repeating: "a", count: 254)).first == 255)
}

/// The same results as the DateFormatter this replaced, in zones with daylight saving (so the
/// test doesn't depend on the Mac's zone), including the hour a change repeats or skips.
@Test(arguments: ["America/New_York", "Europe/Berlin", "Asia/Seoul", "Australia/Lord_Howe"])
func ptpDatesReadAsDateFormatterDid(zoneID: String) {
    let zone = TimeZone(identifier: zoneID)!
    func formatter(_ zone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        f.timeZone = zone
        return f
    }
    let samples = ["20250602T064908", "20240229T235959", "19991231T000000", "20380119T031408",
                   "20251102T013000", "20250309T023000",   // New York: repeated, skipped
                   "20251026T023000", "20250330T023000",   // Berlin: repeated, skipped
                   "20250406T014500", "20251005T021500"]   // Lord Howe (half-hour change)
    for sample in samples {
        if let expected = formatter(zone).date(from: sample) {
            #expect(parsePTPDate(sample, in: zone) == expected, "\(sample) \(zoneID)")
        } else {
            // Skipped by the change: DateFormatter gives up; a close time is kept instead.
            #expect(parsePTPDate(sample, in: zone) != nil, "\(sample) \(zoneID), skipped")
        }
        #expect(parsePTPDate(sample + ".0Z", in: zone) == formatter(TimeZone(identifier: "UTC")!).date(from: sample), "\(sample)Z")
        #expect(parsePTPDate(sample + "+0930", in: zone) == formatter(TimeZone(secondsFromGMT: 34_200)!).date(from: sample), "\(sample)+0930")
        #expect(parsePTPDate(sample + "+09:30", in: zone) == formatter(TimeZone(secondsFromGMT: 34_200)!).date(from: sample), "\(sample)+09:30")
        #expect(parsePTPDate(sample + "-0500", in: zone) == formatter(TimeZone(secondsFromGMT: -18_000)!).date(from: sample), "\(sample)-0500")
    }
    for bad in ["2025", "20251301T000000", "20250230T000000", "20250101X000000", "2025010aT000000", "20250101T246000",
                "20250101T000000+09"] {
        #expect(parsePTPDate(bad, in: zone) == nil, "\(bad)")
    }
}

// MARK: Datasets, against fixed bytes

private let zero4: [UInt8] = [0, 0, 0, 0]

/// Joins byte groups (one long `+` chain is too slow for the type checker).
private func joined(_ groups: [UInt8]...) -> [UInt8] { groups.flatMap { $0 } }

@Test func objectInfoDatasetForAFile() throws {
    let bytes = try objectInfoDataset(name: "a", folder: false, size: 5, storage: 0x0001_0001, parent: 7, date: "")
    let expected = joined([0x01, 0x00, 0x01, 0x00, 0x00, 0x30, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00], // storage, format, protection, size
        [0, 0], zero4, zero4, zero4, // thumb format, size, w, h
        zero4, zero4, zero4, // image w, h, depth
        [0x07, 0x00, 0x00, 0x00, 0x00, 0x00], zero4, zero4, // parent, association type, desc, sequence
        [0x02, 0x61, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]) // "a", created, modified, keywords
    #expect(bytes == expected)
}

@Test func objectInfoDatasetForAFolder() throws {
    let bytes = try objectInfoDataset(name: "a", folder: true, size: 0, storage: 1, parent: 0xFFFF_FFFF, date: "")
    #expect(Array(bytes[4..<6]) == [0x01, 0x30])       // association
    #expect(Array(bytes[8..<12]) == zero4)
    #expect(Array(bytes[38..<44]) == [0xFF, 0xFF, 0xFF, 0xFF, 0x01, 0x00]) // parent, generic folder
}

@Test func objectInfoDatasetSaysLargeSizesAsMax() throws {
    let bytes = try objectInfoDataset(name: "a", folder: false, size: 5_000_000_000, storage: 1, parent: 0, date: "")
    #expect(Array(bytes[8..<12]) == [0xFF, 0xFF, 0xFF, 0xFF])
}

@Test func objectInfoReadsWhatIsSent() throws {
    let bytes = try objectInfoDataset(name: "사진.jpg", folder: false, size: 1234, storage: 0x0001_0001, parent: 42,
                                      date: "20260109T081500Z")
    let info = try MtpObjectInfo(dataset: bytes, handle: 9)
    #expect(info.handle == 9 && info.storageID == 0x0001_0001 && info.parent == 42)
    #expect(info.name == "사진.jpg" && info.size == 1234 && !info.isFolder)
    #expect(info.modified == Date(timeIntervalSince1970: 1_767_946_500))
}

@Test func deviceInfoDataset() throws {
    let bytes = joined([0x64, 0x00, 0x06, 0x00, 0x00, 0x00, 0x64, 0x00], // standard version, vendor id, version
        [0x02, 0x6D, 0x00, 0x00, 0x00, 0x00, 0x00], // "m", functional mode
        [0x02, 0x00, 0x00, 0x00, 0x01, 0x10, 0x02, 0x10], // operations
        zero4, zero4, zero4, zero4, // events, properties, capture, playback
        [0x02, 0x47, 0x00, 0x00, 0x00, 0x02, 0x50, 0x00, 0x00, 0x00], // "G", "P"
        [0x00, 0x02, 0x53, 0x00, 0x00, 0x00]) // "", "S"
    let info = try MtpDeviceInfo(dataset: bytes)
    #expect(info.vendorExtension == "m" && info.operations == [0x1001, 0x1002])
    #expect(info.manufacturer == "G" && info.model == "P" && info.version == "" && info.serial == "S")
    #expect(throws: PTPReader.Failure.self) { try MtpDeviceInfo(dataset: Array(bytes.dropLast())) }
}

@Test func storageInfoDataset() throws {
    let bytes = joined([0x03, 0x00, 0x02, 0x00, 0x00, 0x00], // type, filesystem, access
        [0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00], // capacity 4 GiB
        [0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00], // free 4 KiB
        [0xFF, 0xFF, 0xFF, 0xFF, 0x02, 0x49, 0x00, 0x00, 0x00, 0x00]) // free objects, "I", ""
    let info = try MtpSession.StorageInfo(dataset: bytes, id: 0x0001_0001)
    #expect(info.capacity == 1 << 32 && info.free == 4096)
    #expect(info.description == "I" && info.volumeIdentifier == "")
}

@Test func propListDatasetMergesPerObjectAndDropsTheParent() throws {
    let bytes = joined([0x03, 0x00, 0x00, 0x00],
        [0x05, 0x00, 0x00, 0x00, 0x07, 0xDC, 0xFF, 0xFF, 0x02, 0x78, 0x00, 0x00, 0x00], // 5: name "x"
        [0x05, 0x00, 0x00, 0x00, 0x04, 0xDC, 0x08, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00], // 5: size
        [0x09, 0x00, 0x00, 0x00, 0x07, 0xDC, 0xFF, 0xFF, 0x02, 0x70, 0x00, 0x00, 0x00]) // 9 (the parent): "p"
    let items = try MtpObjectInfo.list(propListDataset: bytes, parent: 9)
    #expect(items.count == 1)
    #expect(items.first?.handle == 5 && items.first?.name == "x" && items.first?.size == 4_294_967_297)
}

@Test func containerHeaders() {
    #expect(ptpHeader(.data, code: 0x100D, transaction: 7, bodyLength: 5_000_000_000)
        == [0xFF, 0xFF, 0xFF, 0xFF, 0x02, 0x00, 0x0D, 0x10, 0x07, 0x00, 0x00, 0x00])
    #expect(ptpHeader(.data, code: 0x100C, transaction: 1, bodyLength: 4)
        == [0x10, 0x00, 0x00, 0x00, 0x02, 0x00, 0x0C, 0x10, 0x01, 0x00, 0x00, 0x00])
    let response = PTPContainer(type: 3, code: 0x2001, transaction: 1, body: [1, 0, 0, 0, 2, 0, 0, 0, 3])
    #expect(response.params == [1, 2])
}

// MARK: Path cache and details chunks

private func node(_ handle: UInt32, folder: Bool = false) -> MtpPathCache.Node {
    MtpPathCache.Node(storage: 1, handle: handle, isDirectory: folder)
}

@Test func pathCacheForgetsWhatAListingNoLongerHas() {
    let cache = MtpPathCache(roots: [("/sdcard", node(0xFFFF_FFFF, folder: true))])
    cache.remember([("/sdcard/A", node(1, folder: true)), ("/sdcard/A/x.jpg", node(2)), ("/sdcard/A/Old", node(3, folder: true)),
                    ("/sdcard/A/Old/y.jpg", node(4)), ("/sdcard/AB", node(5, folder: true)), ("/sdcard/AB/z.jpg", node(6))])
    // A listed again: Old is gone (with what was under it), x.jpg has a new handle, n.jpg is new.
    cache.rememberListing(of: "/sdcard/A", [("/sdcard/A/x.jpg", node(12)), ("/sdcard/A/n.jpg", node(13))])
    #expect(cache.node(at: "/sdcard/A/x.jpg") == node(12))
    #expect(cache.node(at: "/sdcard/A/n.jpg") == node(13))
    #expect(cache.node(at: "/sdcard/A/Old") == nil)
    #expect(cache.node(at: "/sdcard/A/Old/y.jpg") == nil)
    // A sibling whose name starts the same is another folder.
    #expect(cache.node(at: "/sdcard/AB/z.jpg") == node(6))
    #expect(cache.node(at: "/sdcard") == node(0xFFFF_FFFF, folder: true))
}

@Test func pathCacheForgetsASubtreeOnly() {
    let cache = MtpPathCache(roots: [])
    cache.remember([("/sdcard/A", node(1, folder: true)), ("/sdcard/A/x", node(2)), ("/sdcard/AB", node(3))])
    cache.forget("/sdcard/A")
    #expect(cache.node(at: "/sdcard/A") == nil)
    #expect(cache.node(at: "/sdcard/A/x") == nil)
    #expect(cache.node(at: "/sdcard/AB") == node(3))
}

@Test func pathCacheDropsWhatWasInAFolderThatGotAnotherHandle() {
    let cache = MtpPathCache(roots: [])
    cache.remember([("/sdcard/A", node(1, folder: true)), ("/sdcard/A/x", node(2))])
    // Deleted and made again on the phone: what was cached inside the old one is stale.
    cache.rememberListing(of: "/sdcard", [("/sdcard/A", node(7, folder: true))])
    #expect(cache.node(at: "/sdcard/A") == node(7, folder: true))
    #expect(cache.node(at: "/sdcard/A/x") == nil)
    cache.remember([("/sdcard/A/x", node(8))])
    cache.remember([("/sdcard/A", node(9, folder: true))])
    #expect(cache.node(at: "/sdcard/A/x") == nil)
}

@Test func detailsChunksFollowThePhonesPace() {
    var chunker = DetailsChunker()
    #expect(chunker.size == MtpTuning.detailsChunkStart)
    chunker.answered(20, in: 0.06)       // 3 ms each → about 0.15 s worth
    #expect(chunker.size == 50)
    chunker.answered(50, in: 0.01)       // very fast: capped
    #expect(chunker.size == MtpTuning.detailsChunkRange.upperBound)
    chunker.answered(10, in: 2)          // very slow: at least a few
    #expect(chunker.size == MtpTuning.detailsChunkRange.lowerBound)
    chunker.answered(0, in: 1)           // nothing asked: unchanged
    #expect(chunker.size == MtpTuning.detailsChunkRange.lowerBound)
}

@Test func readChunksTakeAboutTheSameTimeOnAnyLink() {
    let mb: UInt64 = 1 << 20
    var usb3 = ReadChunker()
    #expect(usb3.size(browsing: false) == 8 * mb && usb3.size(browsing: true) == 8 * mb) // speed unknown yet
    usb3.read(8 * mb, of: 8 * mb, in: 0.04)            // 200 MB/s
    #expect(usb3.size(browsing: false) == 40 * mb)     // 0.2 s
    #expect(usb3.size(browsing: true) == 8 * mb)       // 0.05 s would be 10 MB: capped at 8
    usb3.read(40 * mb, of: 40 * mb, in: 0.1)           // 400 MB/s
    #expect(usb3.size(browsing: false) == 64 * mb)     // capped
    usb3.read(1 * mb, of: 64 * mb, in: 0.5)            // a file's short last piece: ignored
    #expect(usb3.size(browsing: false) == 64 * mb)

    var usb2 = ReadChunker()
    usb2.read(8 * mb, of: 8 * mb, in: 0.2)             // 40 MB/s
    #expect(usb2.size(browsing: false) == 8 * mb)      // 0.2 s already
    #expect(usb2.size(browsing: true) == 2 * mb)       // 0.05 s
    usb2.read(2 * mb, of: 2 * mb, in: 0.5)             // 4 MB/s: never below 1 MB
    #expect(usb2.size(browsing: true) == 1 * mb && usb2.size(browsing: false) == 8 * mb)
}

@Test func aFilesLastPieceNeverEndsOnAFullPacket() {
    // 1024-byte packets (USB 3); 512 matters too.
    let mb: UInt64 = 1 << 20
    // A middle piece is whatever was asked for.
    #expect(MtpPackets.readLength(size: 100 * mb, offset: 0, maxLength: 8 * mb, maxPacket: 1024) == 8 * mb)
    // The last piece: 500 bytes + 12 = 512, a full USB 2 packet → one byte short, then that byte.
    #expect(MtpPackets.readLength(size: 8 * mb + 500, offset: 8 * mb, maxLength: 8 * mb, maxPacket: 1024) == 499)
    #expect(MtpPackets.readLength(size: 8 * mb + 500, offset: 8 * mb + 499, maxLength: 8 * mb, maxPacket: 1024) == 1)
    // 1012 + 12 = 1024: a full packet of this endpoint.
    #expect(MtpPackets.readLength(size: 1012, offset: 0, maxLength: 8 * mb, maxPacket: 1024) == 1011)
    // Not on a boundary: as asked.
    #expect(MtpPackets.readLength(size: 1013, offset: 0, maxLength: 8 * mb, maxPacket: 1024) == 1013)
    // A one-byte last piece can't be shortened (and 13 bytes isn't a full packet anyway).
    #expect(MtpPackets.readLength(size: 1, offset: 0, maxLength: 8 * mb, maxPacket: 512) == 1)
    #expect(MtpPackets.endsOnFullPacket(bodyLength: 2036, maxPacket: 1024)) // 2048
    #expect(!MtpPackets.endsOnFullPacket(bodyLength: 2037, maxPacket: 1024))
}
