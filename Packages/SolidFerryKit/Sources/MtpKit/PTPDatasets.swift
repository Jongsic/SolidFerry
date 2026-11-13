import Foundation

/// Sequential little-endian writer for PTP datasets and containers.
struct PTPWriter {
    private(set) var bytes: [UInt8] = []

    mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { bytes.append(contentsOf: $0) } }
    mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { bytes.append(contentsOf: $0) } }
    mutating func string(_ s: String) throws { bytes += try ptpString(s) }
}

/// One container read from the phone.
struct PTPContainer {
    let type: UInt16
    let code: UInt16
    let transaction: UInt32
    let body: [UInt8]

    /// A response's parameters.
    var params: [UInt32] {
        var reader = PTPReader(body)
        var out: [UInt32] = []
        while reader.remaining >= 4, let value = try? reader.u32() { out.append(value) }
        return out
    }
}

/// The 12-byte header of a container whose body is `bodyLength` long. Over 4 GB the length
/// field says 0xFFFFFFFF and the phone reads until the transfer ends.
func ptpHeader(_ type: PTPContainerType, code: UInt16, transaction: UInt32, bodyLength: UInt64) -> [UInt8] {
    var w = PTPWriter()
    let length = 12 + bodyLength
    w.u32(length > UInt64(UInt32.max) ? UInt32.max : UInt32(length))
    w.u16(type.rawValue)
    w.u16(code)
    w.u32(transaction)
    return w.bytes
}

/// Builds a command container.
func ptpCommand(_ op: UInt16, transaction: UInt32, params: [UInt32]) -> [UInt8] {
    var w = PTPWriter()
    params.forEach { w.u32($0) }
    return ptpHeader(.command, code: op, transaction: transaction, bodyLength: UInt64(w.bytes.count)) + w.bytes
}

// MARK: Datasets

/// ObjectInfo for SendObjectInfo: a file (format "undefined") or a folder ("association",
/// generic folder). `date` is a PTP date string or empty.
func objectInfoDataset(name: String, folder: Bool, size: UInt64, storage: UInt32, parent: UInt32,
                       date: String) throws -> [UInt8] {
    var w = PTPWriter()
    w.u32(storage)
    w.u16(folder ? ptpFormatAssociation : 0x3000)
    w.u16(0)                                                     // protection
    w.u32(size >= UInt64(UInt32.max) ? UInt32.max : UInt32(size)) // compressed size (32-bit)
    w.u16(0); w.u32(0); w.u32(0); w.u32(0)                       // thumb format, size, w, h
    w.u32(0); w.u32(0); w.u32(0)                                 // image w, h, depth
    w.u32(parent)
    w.u16(folder ? 0x0001 : 0)                                   // association type: generic folder
    w.u32(0); w.u32(0)                                           // association description, sequence
    try w.string(name)
    try w.string(date)                                           // created
    try w.string(date)                                           // modified
    try w.string("")                                             // keywords
    return w.bytes
}

extension MtpObjectInfo {
    /// From a GetObjectInfo dataset (its size field is 32-bit).
    init(dataset: [UInt8], handle: UInt32) throws {
        var r = PTPReader(dataset)
        let storage = try r.u32()
        let format = try r.u16()
        _ = try r.u16()                                   // protection
        let size = try r.u32()
        _ = try r.u16(); _ = try r.u32()                  // thumb format, size
        _ = try r.u32(); _ = try r.u32()                  // thumb w, h
        _ = try r.u32(); _ = try r.u32(); _ = try r.u32() // image w, h, depth
        let parent = try r.u32()
        _ = try r.u16(); _ = try r.u32(); _ = try r.u32() // association type, description, sequence
        let name = try r.string()
        _ = try r.string()                                // date created
        let modified = parsePTPDate(try r.string())
        self.init(handle: handle, storageID: storage, format: format, size: UInt64(size),
                  parent: parent, name: name, modified: modified)
    }

    /// From a GetObjectPropList dataset: one entry per object, in the order they first appear.
    /// Depth 1 may include `parent` itself; only its children are kept.
    static func list(propListDataset dataset: [UInt8], parent: UInt32) throws -> [MtpObjectInfo] {
        var r = PTPReader(dataset)
        let count = Int(try r.u32())
        var byHandle: [UInt32: MtpObjectInfo] = [:]
        var order: [UInt32] = []
        for _ in 0..<count {
            let handle = try r.u32()
            let prop = try r.u16()
            let type = try r.u16()
            let value = try r.value(ofType: type)
            if byHandle[handle] == nil {
                byHandle[handle] = MtpObjectInfo(handle: handle, storageID: 0, format: 0, size: 0, parent: 0, name: "", modified: nil)
                order.append(handle)
            }
            switch prop {
            case MTPProp.storageID: byHandle[handle]?.storageID = UInt32(truncatingIfNeeded: value.int ?? 0)
            case MTPProp.objectFormat: byHandle[handle]?.format = UInt16(truncatingIfNeeded: value.int ?? 0)
            case MTPProp.objectSize: byHandle[handle]?.size = value.int ?? 0
            case MTPProp.objectFileName: byHandle[handle]?.name = value.string ?? ""
            case MTPProp.dateModified: byHandle[handle]?.modified = value.string.flatMap { parsePTPDate($0) }
            case MTPProp.parentObject: byHandle[handle]?.parent = UInt32(truncatingIfNeeded: value.int ?? 0)
            default: break
            }
        }
        return order.compactMap { byHandle[$0] }.filter { $0.handle != parent }
    }
}

extension MtpDeviceInfo {
    /// From a GetDeviceInfo dataset.
    init(dataset: [UInt8]) throws {
        var r = PTPReader(dataset)
        self.init()
        _ = try r.u16()                       // standard version
        _ = try r.u32()                       // vendor extension id
        _ = try r.u16()                       // vendor extension version
        vendorExtension = try r.string()
        _ = try r.u16()                       // functional mode
        operations = Set(try r.u16Array())
        _ = try r.u16Array()                  // events
        _ = try r.u16Array()                  // device properties
        _ = try r.u16Array()                  // capture formats
        _ = try r.u16Array()                  // playback formats
        manufacturer = try r.string()
        model = try r.string()
        version = try r.string()
        serial = try r.string()
    }
}

extension MtpSession.StorageInfo {
    /// From a GetStorageInfo dataset.
    init(dataset: [UInt8], id: UInt32) throws {
        var r = PTPReader(dataset)
        _ = try r.u16(); _ = try r.u16(); _ = try r.u16() // type, filesystem, access
        let capacity = try r.u64()
        let free = try r.u64()
        _ = try r.u32()                                    // free objects
        let description = try r.string()
        let volume = try r.string()
        self.init(id: id, description: description, volumeIdentifier: volume, capacity: capacity, free: free)
    }
}
