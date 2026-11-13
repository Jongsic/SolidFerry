import Foundation

/// Names of what gets made on the side: hidden temporary files on the phone, scratch files on
/// this Mac, test folders. All carry `tag`, so they're recognizable for cleanup and the tag
/// is the one place to change.
public enum WorkNames {
    public static let tag = "xfer"

    /// For logs and other per-app identifiers: the running app's bundle ID (the CLI has none).
    public static let subsystem = Bundle.main.bundleIdentifier ?? tag

    /// ".photo.jpg.xfer-part": a download being written on this Mac, renamed into place when
    /// complete; the same for the same name, so a stopped one can be found and removed. A name
    /// too long to take the additions gets a fixed one made from it.
    public static func partial(_ name: String) -> String {
        let full = ".\(name).\(tag)-part"
        return fits(full) ? full : ".\(tag)-part-\(stableID(name))"
    }

    /// ".photo.jpg.xfer-old-1a2b3c4d": the original, moved aside while it's replaced. A name
    /// too long to carry along gets ".xfer-old-…": still kept, but not given back its name by
    /// `tidyLeftovers` (it can't tell which it was).
    public static func aside(_ name: String) -> String { carrying(name, "old") }

    /// ".photo.jpg.xfer-move-1a2b3c4d": an item being moved on the phone, hidden in between
    /// (MoveObject keeps the name, which may be taken where it goes; QUIRKS M15). Cut off there,
    /// `tidyLeftovers` gives it its name back. Too long to carry along: ".xfer-move-…".
    public static func moving(_ name: String) -> String { carrying(name, "move") }

    private static func carrying(_ name: String, _ purpose: String) -> String {
        let full = ".\(name).\(tag)-\(purpose)-\(shortID())"
        return fits(full) ? full : step(purpose)
    }

    /// Whether a name fits on a phone: 255 bytes (Android's limit) and 254 UTF-16 units (MTP's).
    public static func fits(_ name: String) -> Bool { name.utf8.count <= 255 && name.utf16.count <= 254 }

    /// "photo.jpg" for an `aside` name, nil for anything else.
    public static func originalName(ofAside name: String) -> String? { originalName(of: name, "old") }

    /// "photo.jpg" for a `moving` name, nil for anything else.
    public static func originalName(ofMoving name: String) -> String? { originalName(of: name, "move") }

    private static func originalName(of name: String, _ purpose: String) -> String? {
        guard name.hasPrefix("."), let marker = name.range(of: ".\(tag)-\(purpose)-", options: .backwards),
              marker.lowerBound > name.startIndex,
              name.distance(from: marker.upperBound, to: name.endIndex) == 8 else { return nil }
        let original = String(name[name.index(after: name.startIndex)..<marker.lowerBound])
        return original.isEmpty ? nil : original
    }

    /// ".xfer-move-1a2b3c4d", ".xfer-rename-…", ".xfer-dateprobe-…": a hidden in-between name.
    public static func step(_ purpose: String, _ suffix: String = shortID()) -> String { ".\(tag)-\(purpose)-\(suffix)" }

    /// Whether a name on the phone is an upload's partial file: never the user's data, so it
    /// can go once no upload is writing it. (An `aside` name holds the user's original.)
    public static func isPartial(_ name: String) -> Bool { name.hasPrefix(".") && name.contains(".\(tag)-part") }

    /// Whether a name on the phone is one of the above.
    public static func isWorkFile(_ name: String) -> Bool { name.hasPrefix(".") && name.contains(".\(tag)-") }

    /// A scratch file or folder on this Mac: "$TMPDIR/xfer-zip-<uuid>".
    public static func scratch(_ purpose: String? = nil) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent([tag, purpose, UUID().uuidString].compactMap { $0 }.joined(separator: "-"))
    }

    /// Whether a name in the Mac's temporary folder is one of `scratch`'s.
    public static func isScratch(_ name: String) -> Bool { name.hasPrefix("\(tag)-") }

    public static func shortID() -> String { String(UUID().uuidString.prefix(8)) }

    /// The same 16 hex digits for the same name (FNV-1a).
    static func stableID(_ s: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in s.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return String(format: "%016llx", hash)
    }
}
