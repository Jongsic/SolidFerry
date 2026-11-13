import DeviceCore
import Foundation

/// PTP/MTP wire constants (PTP 15740, MTP 1.1). Little-endian throughout.
public enum PTPOp: UInt16, Sendable {
    case getDeviceInfo = 0x1001
    case openSession = 0x1002
    case closeSession = 0x1003
    case getStorageIDs = 0x1004
    case getStorageInfo = 0x1005
    case getObjectHandles = 0x1007
    case getObjectInfo = 0x1008
    case getThumb = 0x100A
    case deleteObject = 0x100B
    case sendObjectInfo = 0x100C
    case sendObject = 0x100D
    case moveObject = 0x1019
    case copyObject = 0x101A
    case getObjectPropValue = 0x9803
    case setObjectPropValue = 0x9804
    case getObjectPropList = 0x9805
    case getPartialObject64 = 0x95C1
}

public enum PTPContainerType: UInt16, Sendable {
    case command = 1, data = 2, response = 3, event = 4
}

public enum PTPResponse {
    public static let ok: UInt16 = 0x2001
    public static let generalError: UInt16 = 0x2002
    public static let invalidObjectHandle: UInt16 = 0x2009
    public static let storeFull: UInt16 = 0x200C
    public static let objectWriteProtected: UInt16 = 0x200D
    public static let accessDenied: UInt16 = 0x200F
    public static let noThumbnailPresent: UInt16 = 0x2010
    public static let sessionNotOpen: UInt16 = 0x2003
    public static let sessionAlreadyOpen: UInt16 = 0x201E
}

public enum MTPProp {
    public static let storageID: UInt16 = 0xDC01
    public static let objectFormat: UInt16 = 0xDC02
    public static let objectSize: UInt16 = 0xDC04
    public static let objectFileName: UInt16 = 0xDC07
    public static let dateModified: UInt16 = 0xDC09
    public static let parentObject: UInt16 = 0xDC0B
}

/// Folder format code ("Association").
public let ptpFormatAssociation: UInt16 = 0x3001

/// Sequential little-endian reader over a PTP dataset.
public struct PTPReader {
    private let bytes: [UInt8]
    public private(set) var offset = 0

    public init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    public var remaining: Int { bytes.count - offset }

    public enum Failure: Error { case truncated }

    private mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
        guard remaining >= n else { throw Failure.truncated }
        defer { offset += n }
        return bytes[offset..<offset + n]
    }

    public mutating func u8() throws -> UInt8 { try take(1).first! }

    public mutating func u16() throws -> UInt16 {
        let s = try take(2)
        return UInt16(s[s.startIndex]) | UInt16(s[s.startIndex + 1]) << 8
    }

    public mutating func u32() throws -> UInt32 {
        let s = try take(4)
        return s.enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
    }

    public mutating func u64() throws -> UInt64 {
        let s = try take(8)
        return s.enumerated().reduce(0) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
    }

    /// PTP string: u8 count of UTF-16 code units including the terminating NUL (0 = empty).
    public mutating func string() throws -> String {
        let count = Int(try u8())
        guard count > 0 else { return "" }
        var units: [UInt16] = []
        units.reserveCapacity(count)
        for _ in 0..<count { units.append(try u16()) }
        if units.last == 0 { units.removeLast() }
        return String(decoding: units, as: UTF16.self)
    }

    /// The count comes from the phone; one larger than what's left can't be right, and
    /// isn't allocated for.
    public mutating func u16Array() throws -> [UInt16] {
        let count = Int(try u32())
        guard count <= remaining / 2 else { throw Failure.truncated }
        return try (0..<count).map { _ in try u16() }
    }

    public mutating func u32Array() throws -> [UInt32] {
        let count = Int(try u32())
        guard count <= remaining / 4 else { throw Failure.truncated }
        return try (0..<count).map { _ in try u32() }
    }

    /// Skips or reads a property value of the given PTP datatype.
    public mutating func value(ofType type: UInt16) throws -> PTPValue {
        switch type {
        case 0x0001, 0x0002: return .int(UInt64(try u8()))
        case 0x0003, 0x0004: return .int(UInt64(try u16()))
        case 0x0005, 0x0006: return .int(UInt64(try u32()))
        case 0x0007, 0x0008: return .int(try u64())
        case 0x0009, 0x000A: _ = try take(16); return .other
        case 0xFFFF: return .string(try string())
        default:
            if type & 0x4000 != 0 { // array of the base type
                let count = Int(try u32())
                for _ in 0..<count { _ = try value(ofType: type & ~0x4000) }
                return .other
            }
            throw Failure.truncated
        }
    }
}

public enum PTPValue: Equatable {
    case int(UInt64)
    case string(String)
    case other

    public var int: UInt64? { if case .int(let v) = self { v } else { nil } }
    public var string: String? { if case .string(let v) = self { v } else { nil } }
}

/// PTP string: u8 count of UTF-16 units including NUL, then the units. Longer than 254 units
/// can't be said; it's an error rather than a name cut short on the phone.
func ptpString(_ s: String) throws -> [UInt8] {
    guard !s.isEmpty else { return [0] }
    let units = Array(s.utf16) + [0]
    guard units.count <= 255 else { throw DeviceFSError.invalidName(s) }
    var out: [UInt8] = [UInt8(units.count)]
    for unit in units { withUnsafeBytes(of: unit.littleEndian) { out.append(contentsOf: $0) } }
    return out
}

/// "YYYYMMDDThhmmss[.s][Z|±hhmm|±hh:mm]"; without a zone it's local time in `zone` (the
/// Mac's). Read by hand: it runs for every item of a listing, and a DateFormatter per call
/// cost more than the rest. Near a daylight-saving change, where a local time can be missing
/// or happen twice, it's left to DateFormatter so those read as they always have.
public func parsePTPDate(_ s: String, in zone: TimeZone = .current) -> Date? {
    let chars = Array(s.utf8)
    guard chars.count >= 15, chars[8] == UInt8(ascii: "T") else { return nil }
    func isDigit(_ c: UInt8) -> Bool { c >= 48 && c <= 57 }
    func number(_ range: Range<Int>) -> Int? {
        var value = 0
        for c in chars[range] {
            guard isDigit(c) else { return nil }
            value = value * 10 + Int(c - 48)
        }
        return value
    }
    guard let year = number(0..<4), let month = number(4..<6), let day = number(6..<8),
          let hour = number(9..<11), let minute = number(11..<13), let second = number(13..<15),
          (1...12).contains(month), (1...daysIn(month: month, year: year)).contains(day),
          hour < 24, minute < 60, second < 60 else { return nil }
    let wall = Double(daysFromCivil(year, month, day) * 86_400 + hour * 3_600 + minute * 60 + second)
    let rest = Array(chars.dropFirst(15).drop { $0 == UInt8(ascii: ".") || isDigit($0) })
    if rest.first == UInt8(ascii: "Z") { return Date(timeIntervalSince1970: wall) }
    if let sign = rest.first, sign == UInt8(ascii: "+") || sign == UInt8(ascii: "-") {
        let digits = rest.dropFirst().filter { $0 != UInt8(ascii: ":") }.prefix(4)
        guard digits.count == 4, digits.allSatisfy(isDigit) else { return nil }
        let d = digits.map { Int($0 - 48) }
        let offset = (d[0] * 10 + d[1]) * 3_600 + (d[2] * 10 + d[3]) * 60
        return Date(timeIntervalSince1970: wall - Double(sign == UInt8(ascii: "-") ? -offset : offset))
    }
    // Local time: the zone's offset at that moment, unless a change is near.
    let guess = wall - Double(zone.secondsFromGMT(for: Date(timeIntervalSince1970: wall)))
    let before = zone.secondsFromGMT(for: Date(timeIntervalSince1970: guess - 43_200))
    let after = zone.secondsFromGMT(for: Date(timeIntervalSince1970: guess + 43_200))
    if before == after { return Date(timeIntervalSince1970: wall - Double(before)) }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = zone
    formatter.dateFormat = "yyyyMMdd'T'HHmmss"
    // A time the change skips: DateFormatter has no answer; keep a close one, not lose the date.
    return formatter.date(from: String(decoding: chars[0..<15], as: UTF8.self)) ?? Date(timeIntervalSince1970: guess)
}

/// Days from 1970-01-01 to a Gregorian date (H. Hinnant's days_from_civil).
private func daysFromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int {
    let y = month <= 2 ? year - 1 : year
    let era = (y >= 0 ? y : y - 399) / 400
    let yearOfEra = y - era * 400
    let dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
    let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
    return era * 146_097 + dayOfEra - 719_468
}

private func daysIn(month: Int, year: Int) -> Int {
    switch month {
    case 2: year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) ? 29 : 28
    case 4, 6, 9, 11: 30
    default: 31
    }
}

/// IOKit return codes seen from IOUSBHost (the C macros aren't imported into Swift).
enum IOReturnCode {
    /// kIOReturnTimeout: the device didn't take or give data in time.
    static let timeout: UInt32 = 0xE000_02D6
    /// kUSBHostReturnPipeStalled: the endpoint is halted until cleared.
    static let pipeStalled: UInt32 = 0xE000_5000

    static func of(_ error: Error) -> UInt32 {
        UInt32(truncatingIfNeeded: (error as NSError).code)
    }
}
