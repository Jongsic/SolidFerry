import Foundation

/// Reference to an object on the device.
/// `path` is always a "/"-joined display path; `handle` is a backend-specific object id
/// (MTP object handle). Path-based backends (ADB) leave `handle` nil.
public struct RemoteRef: Hashable, Sendable {
    public let path: String
    public let handle: UInt64?

    public init(path: String, handle: UInt64? = nil) {
        self.path = path
        self.handle = handle
    }

    public var name: String {
        path.split(separator: "/").last.map(String.init) ?? "/"
    }

    public var parentPath: String? {
        guard path != "/" else { return nil }
        let parts = path.split(separator: "/")
        return parts.count <= 1 ? "/" : "/" + parts.dropLast().joined(separator: "/")
    }

    public func appending(_ name: String, handle: UInt64? = nil) -> RemoteRef {
        RemoteRef(path: path.hasSuffix("/") ? path + name : path + "/" + name, handle: handle)
    }
}

public enum EntryKind: String, Sendable, Hashable, Codable {
    case file
    case directory
    case symlink
    case other
}

/// One listing row. Optional fields are nil when the backend's single listing request
/// doesn't provide them — we never issue extra requests to fill them.
public struct RemoteEntry: Sendable, Hashable, Identifiable, Codable {
    public let ref: RemoteRef
    public let name: String
    public let kind: EntryKind
    public let size: UInt64?
    public let modified: Date?
    /// Size and date are still being fetched; a later listing batch repeats this entry with
    /// them filled in.
    public let isPartial: Bool

    public init(ref: RemoteRef, name: String, kind: EntryKind, size: UInt64?, modified: Date?, isPartial: Bool = false) {
        self.ref = ref
        self.name = name
        self.kind = kind
        self.size = size
        self.modified = modified
        self.isPartial = isPartial
    }

    public var id: String { ref.path }
    public var isDirectory: Bool { kind == .directory }
    public var isHidden: Bool { name.hasPrefix(".") }

    /// Lowercased extension, empty for directories and extension-less names.
    public var fileExtension: String {
        guard kind != .directory, let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return name[name.index(after: dot)...].lowercased()
    }
}

/// A top-level place to browse (internal storage, SD card, MTP storage).
public struct RemoteLocation: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case internalStorage, sdCard, usbDrive
        /// Named by the device (an MTP storage).
        case other
    }

    public let ref: RemoteRef
    public let name: String
    public let kind: Kind

    public init(ref: RemoteRef, name: String, kind: Kind = .other) {
        self.ref = ref
        self.name = name
        self.kind = kind
    }

    public var id: String { ref.path }
}

/// Saved by path only: MTP object handles are valid for one session and are looked up
/// again from the path.
extension RemoteRef: Codable {
    public init(from decoder: Decoder) throws {
        self.init(path: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(path)
    }
}
