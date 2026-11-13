import DeviceCore
import Foundation

/// Where paths are on the phone (storage and handle), learned from listings, so a path is
/// resolved without asking the phone each time. Paths are matched as the phone matches them:
/// another case or composition is the same path (`FolderNames.key`, QUIRKS S7). Thread-safe.
final class MtpPathCache: @unchecked Sendable {
    struct Node: Equatable, Sendable {
        let storage: UInt32
        let handle: UInt32 // 0xFFFFFFFF = storage root
        let isDirectory: Bool
    }

    private let lock = NSLock()
    /// Storage roots by path.
    private let roots: [String: Node]
    /// What's in each folder, by the folder's path and then by name: a listing replaces one
    /// folder's entry, and forgetting a folder drops only what's below it.
    private var children: [String: [String: Node]] = [:]

    init(roots: [(String, Node)]) {
        self.roots = Dictionary(roots.map { (FolderNames.key($0.0), $0.1) }, uniquingKeysWith: { a, _ in a })
    }

    func node(at path: String) -> Node? {
        if let root = roots[FolderNames.key(path)] { return root }
        let (folder, name) = Self.split(path)
        return lock.withLock { children[folder]?[name] }
    }

    /// How many items the folder had when it was last listed (nil: not listed yet).
    func count(in folder: String) -> Int? {
        lock.withLock { children[FolderNames.key(folder)]?.count }
    }

    func remember(_ entries: [(String, Node)]) {
        lock.withLock {
            for (path, node) in entries {
                let (folder, name) = Self.split(path)
                if let old = children[folder]?[name], old != node, old.isDirectory { dropContents(of: Self.join(folder, name)) }
                children[folder, default: [:]][name] = node
            }
        }
    }

    /// A folder's complete listing: its children as listed, and nothing cached under it that
    /// isn't there any more (a handle for something deleted or renamed on the phone would
    /// otherwise stay and be used). A subfolder that's gone or has another handle loses what
    /// was cached inside it.
    func rememberListing(of folder: String, _ entries: [(String, Node)]) {
        let folder = FolderNames.key(folder.count > 1 && folder.hasSuffix("/") ? String(folder.dropLast()) : folder)
        let listed = Dictionary(entries.map { (Self.split($0.0).name, $0.1) }, uniquingKeysWith: { _, b in b })
        lock.withLock {
            for (name, old) in children[folder] ?? [:] where old.isDirectory && listed[name] != old {
                dropContents(of: Self.join(folder, name))
            }
            children[folder] = listed
        }
    }

    /// Drops `path` and, if it's a folder, everything under it.
    func forget(_ path: String) {
        let (folder, name) = Self.split(path)
        lock.withLock {
            guard let node = children[folder]?.removeValue(forKey: name), node.isDirectory else { return }
            dropContents(of: Self.join(folder, name))
        }
    }

    /// Everything cached below the folder at `path`. Call with the lock held.
    private func dropContents(of path: String) {
        guard let inside = children.removeValue(forKey: path) else { return }
        for (name, node) in inside where node.isDirectory { dropContents(of: Self.join(path, name)) }
    }

    /// Folder and name, as keys.
    private static func split(_ path: String) -> (folder: String, name: String) {
        let path = FolderNames.key(path)
        guard let slash = path.lastIndex(of: "/") else { return ("", path) }
        let folder = slash == path.startIndex ? "/" : String(path[..<slash])
        return (folder, String(path[path.index(after: slash)...]))
    }

    private static func join(_ folder: String, _ name: String) -> String {
        folder.hasSuffix("/") ? folder + name : folder + "/" + name
    }
}
