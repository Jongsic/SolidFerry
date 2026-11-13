import DeviceCore
import Foundation

public struct PlannedFile: Sendable, Hashable, Codable {
    public let entry: RemoteEntry
    /// Path below the destination folder, e.g. "Camera/a.jpg".
    public let relativePath: String

    public init(entry: RemoteEntry, relativePath: String) {
        self.entry = entry
        self.relativePath = relativePath
    }
}

/// Everything a download job will touch, expanded from the user's selection.
public struct TransferPlan: Sendable, Codable {
    public var files: [PlannedFile] = []
    /// Folders to create below the destination (also empty ones), parents first.
    public var directories: [String] = []
    public var totalBytes: UInt64 = 0

    public init() {}
}

extension TransferPlan {
    /// With `.keepBoth`, selected folders whose name is taken at `destination` are copied
    /// into "name (1)" instead; with `.merge` the plan is unchanged.
    public func applyingFolderPolicy(_ policy: ExistingFolderPolicy, destination: URL) -> TransferPlan {
        guard policy == .keepBoth else { return self }
        var reserved = FolderNames()
        var renames: [String: String] = [:]
        for dir in directories where !dir.contains("/") {
            let url = destination.appendingPathComponent(dir)
            if FileManager.default.fileExists(atPath: url.path) {
                renames[dir] = uniqueDestination(for: url, reserved: &reserved, isDirectory: true).lastPathComponent
            }
        }
        return renamingTopFolders(renames)
    }

    /// Folder policy against a device folder's existing names (device-to-device copies).
    public func applyingFolderPolicy(_ policy: ExistingFolderPolicy, existingNames: FolderNames) -> TransferPlan {
        guard policy == .keepBoth else { return self }
        return renamingTopFolders(keepBothRenames(of: directories, taken: existingNames))
    }

    private func renamingTopFolders(_ renames: [String: String]) -> TransferPlan {
        guard !renames.isEmpty else { return self }
        var copy = self
        copy.directories = directories.map { remappingTop($0, renames) }
        copy.files = files.map { PlannedFile(entry: $0.entry, relativePath: remappingTop($0.relativePath, renames)) }
        return copy
    }
}

/// New names ("name (1)") for the top-level folders among `directories` whose name is taken.
func keepBothRenames(of directories: [String], taken existingNames: FolderNames) -> [String: String] {
    var taken = existingNames
    var renames: [String: String] = [:]
    for dir in directories where !dir.contains("/") && existingNames.contains(dir) {
        renames[dir] = uniqueName(dir, taken: &taken, isDirectory: true)
    }
    return renames
}

/// `path` with its top-level folder renamed as `renames` says.
func remappingTop(_ path: String, _ renames: [String: String]) -> String {
    let top = path.split(separator: "/", maxSplits: 1).first.map(String.init) ?? path
    guard let renamed = renames[top] else { return path }
    return renamed + path.dropFirst(top.count)
}

public enum TransferPlanner {
    /// Walks selected folders on the device. Symlinks and special files are skipped so a
    /// link back up the tree can't loop. A selected folder `expanding` says no to is planned as
    /// the folder alone, without what's inside (one that goes over whole within the phone).
    public static func expand(_ sources: [RemoteEntry], in fs: any DeviceFileSystem,
                              expanding: @Sendable (RemoteEntry) -> Bool = { _ in true },
                              progress: @escaping @Sendable (Int) -> Void = { _ in }) async throws -> TransferPlan {
        var plan = TransferPlan()
        var roots: [RemoteRef] = []
        /// Device path of each folder → its path below the destination.
        var relative: [String: String] = [:]

        // A selection made while a slow listing was still filling in sizes and dates (MTP shows
        // names first) lacks them; look them up rather than plan with none.
        // Names joined below the destination stay inside it (the backends list only such names).
        for entry in try await fs.completingDetails(sources) where FileNames.isOnePathComponent(entry.name) {
            switch entry.kind {
            case .file:
                plan.files.append(PlannedFile(entry: entry, relativePath: entry.name))
                plan.totalBytes += entry.size ?? 0
            case .directory:
                plan.directories.append(entry.name)
                guard expanding(entry) else { continue }
                roots.append(entry.ref)
                relative[entry.ref.path] = entry.name
            case .symlink, .other:
                continue
            }
        }

        guard !roots.isEmpty else { return plan }
        for try await (dir, entries) in fs.listTree(roots) {
            guard let base = relative[dir.path] else { continue }
            for entry in entries where FileNames.isOnePathComponent(entry.name) {
                let childPath = base + "/" + entry.name
                switch entry.kind {
                case .file:
                    plan.files.append(PlannedFile(entry: entry, relativePath: childPath))
                    plan.totalBytes += entry.size ?? 0
                case .directory:
                    plan.directories.append(childPath)
                    relative[entry.ref.path] = childPath
                case .symlink, .other:
                    continue
                }
            }
            progress(plan.files.count)
        }
        // A cancelled listing just ends the stream; don't mistake it for a short tree.
        try Task.checkCancellation()
        return plan
    }
}

extension TransferPlan {
    /// For a copy or move within one phone: the selected items that go over whole (one
    /// Copy/MoveObject or shell command each, rather than file by file) because nothing has
    /// their name at the destination. `name` is the item's name in `placed`, this plan after the
    /// folder policy (which may have renamed a folder, "Camera" → "Camera (1)"; folders keep
    /// their order); `bytes` is a folder's total (nil when it wasn't walked or has no files).
    public func wholeItems(_ selected: [RemoteEntry], placedAs placed: TransferPlan,
                           takenAtDestination taken: FolderNames) -> [(source: RemoteEntry, name: String, bytes: UInt64?)] {
        selected.compactMap { source in
            let name = directories.firstIndex(of: source.name).map { placed.directories[$0] } ?? source.name
            guard !taken.contains(name) else { return nil }
            guard source.isDirectory else { return (source, name, source.size) }
            // Nil for a folder that wasn't walked (TransferPlanner.expand's `expanding`).
            let inside = placed.files.filter { $0.relativePath.hasPrefix(name + "/") }
            return (source, name, inside.isEmpty ? nil : inside.reduce(UInt64(0)) { $0 + ($1.entry.size ?? 0) })
        }
    }
}
