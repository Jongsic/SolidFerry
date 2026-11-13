import Foundation

/// A phone's favorite folders: the paths, which of them weren't found, and how they follow
/// renames and deletes made in the app.
public struct FavoritePaths: Equatable, Sendable {
    public private(set) var paths: [String]
    /// Favorites that weren't found on the phone the last time they were looked for.
    public private(set) var missing: Set<String> = []

    public init(_ paths: [String] = []) {
        self.paths = paths
    }

    public func contains(_ path: String) -> Bool { paths.contains(path) }

    public mutating func add(_ path: String) {
        guard !paths.contains(path) else { return }
        paths.append(path)
        missing.remove(path)
    }

    public mutating func remove(_ path: String) {
        paths.removeAll { $0 == path }
        missing.remove(path)
    }

    /// A folder (or one above it) was renamed in the app: favorites follow it.
    public mutating func followRename(from old: String, to new: String) {
        func moved(_ path: String) -> String {
            path == old ? new : path.hasPrefix(old + "/") ? new + path.dropFirst(old.count) : path
        }
        paths = paths.map(moved)
        missing = Set(missing.map(moved))
    }

    /// Favorites that were deleted, or were inside something deleted, in the app go.
    public mutating func followDelete(_ deleted: [String]) {
        func gone(_ path: String) -> Bool { deleted.contains { path == $0 || path.hasPrefix($0 + "/") } }
        paths.removeAll(where: gone)
        missing = missing.filter { !gone($0) }
    }

    /// A favorite failed to open.
    public mutating func markMissing(_ path: String) {
        if paths.contains(path) { missing.insert(path) }
    }

    /// What looking them all up on the phone found missing.
    public mutating func setMissing(_ found: Set<String>) {
        missing = found.intersection(paths)
    }
}
