import Foundation

/// Which names a file or folder can have on the phone. One rule for every transport and for
/// previews (batch rename, upload plans), so a name that passes here doesn't fail later.
public enum FileNames {
    /// Android's shared storage (/sdcard) refuses these, FAT-style, with "Operation not
    /// permitted" (measured on a Tab P11, Android 11). QUIRKS S3.
    public static let disallowedCharacters: Set<Character> = ["\"", ":", "*", "?", "<", ">", "|", "\\"]

    public static func isAllowed(_ name: String) -> Bool {
        isOnePathComponent(name) && name.utf8.count <= 255
            && !name.contains(where: disallowedCharacters.contains)
    }

    /// A name that stays inside its folder when joined to a path: not empty, ".", "..", and
    /// without "/" or NUL. A name a device lists is used only if it is one.
    public static func isOnePathComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }
}

/// Names in one folder, compared the way phone storage (and macOS) compares them: case and
/// Unicode normalization don't matter, so "Photo.JPG" is where "photo.jpg" is, and a Korean
/// name composed differently is the same name (QUIRKS S7). Every "is this name taken" check on
/// a device folder goes through this.
public struct FolderNames: Sendable, Equatable, Codable, ExpressibleByArrayLiteral {
    private var keys: Set<String>

    /// The form two names share when they're the same name on the phone.
    public static func key(_ name: String) -> String {
        name.folding(options: .caseInsensitive, locale: nil).precomposedStringWithCanonicalMapping
    }

    public static func same(_ a: String, _ b: String) -> Bool { key(a) == key(b) }

    public init() { keys = [] }
    public init(_ names: some Sequence<String>) { keys = Set(names.map(Self.key)) }
    public init(arrayLiteral names: String...) { self.init(names) }

    public func contains(_ name: String) -> Bool { keys.contains(Self.key(name)) }
    public mutating func insert(_ name: String) { keys.insert(Self.key(name)) }
    public func union(_ other: FolderNames) -> FolderNames {
        var result = self
        result.keys.formUnion(other.keys)
        return result
    }

    public init(from decoder: Decoder) throws { self.init(try [String](from: decoder)) }
    public func encode(to encoder: Encoder) throws { try keys.sorted().encode(to: encoder) }
}

/// "name (1).ext", "name (2).ext", … not in `taken`; the result is added to `taken`.
public func uniqueName(_ name: String, taken: inout FolderNames, isDirectory: Bool = false) -> String {
    let ns = name as NSString
    let ext = isDirectory ? "" : ns.pathExtension
    let base = ext.isEmpty ? name : ns.deletingPathExtension
    var n = 1
    while true {
        let candidate = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
        if !taken.contains(candidate) {
            taken.insert(candidate)
            return candidate
        }
        n += 1
    }
}
