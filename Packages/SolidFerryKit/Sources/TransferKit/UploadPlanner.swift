import DeviceCore
import Foundation

/// A local file to upload.
public struct LocalFile: Sendable, Hashable, Codable {
    public let url: URL
    /// Path below the destination folder, e.g. "Trip/a.jpg".
    public let relativePath: String
    public let size: UInt64
    public let modified: Date?

    public init(url: URL, relativePath: String, size: UInt64, modified: Date?) {
        self.url = url
        self.relativePath = relativePath
        self.size = size
        self.modified = modified
    }
}

/// Everything an upload job will send, expanded from the dropped files and folders.
public struct UploadPlan: Sendable, Codable {
    public var files: [LocalFile] = []
    /// Folders to create on the device (also empty ones), parents first.
    public var directories: [String] = []
    /// The folders' dates on this Mac, by the same paths (nil in a plan saved before they were
    /// kept).
    public var directoryDates: [String: Date]?
    public var totalBytes: UInt64 = 0

    public init() {}

    /// With `.keepBoth`, top-level folders whose name is taken in `existingNames` go into
    /// "name (1)" instead.
    public func applyingFolderPolicy(_ policy: ExistingFolderPolicy, existingNames: FolderNames) -> UploadPlan {
        guard policy == .keepBoth else { return self }
        let renames = keepBothRenames(of: directories, taken: existingNames)
        guard !renames.isEmpty else { return self }
        var copy = self
        copy.directories = directories.map { remappingTop($0, renames) }
        copy.directoryDates = directoryDates.map { dates in
            Dictionary(dates.map { (remappingTop($0.key, renames), $0.value) }, uniquingKeysWith: { a, _ in a })
        }
        copy.files = files.map { LocalFile(url: $0.url, relativePath: remappingTop($0.relativePath, renames), size: $0.size, modified: $0.modified) }
        return copy
    }
}

public enum UploadPlanner {
    /// Walks dropped files and folders. Skips Finder's `.DS_Store` and anything that isn't a
    /// regular file or folder (links, packages are walked as folders).
    /// `stop` is asked for every item and ends the walk with `CancellationError`.
    public static func expand(_ urls: [URL], stop: () -> Bool = { false }) throws -> UploadPlan {
        var plan = UploadPlan()
        plan.directoryDates = [:]
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        func add(_ url: URL, relative: String) throws {
            if stop() { throw CancellationError() }
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isDirectory == true {
                plan.directories.append(relative)
                plan.directoryDates?[relative] = values.contentModificationDate
                let children = try FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: keys, options: [])
                for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
                where child.lastPathComponent != ".DS_Store" {
                    try add(child, relative: relative + "/" + child.lastPathComponent)
                }
            } else if values.isRegularFile == true {
                let size = UInt64(values.fileSize ?? 0)
                plan.files.append(LocalFile(url: url, relativePath: relative, size: size, modified: values.contentModificationDate))
                plan.totalBytes += size
            }
        }
        for url in urls { try add(url, relative: url.lastPathComponent) }
        return plan
    }
}

extension ExistingItem {
    /// Compares a local file about to be uploaded with what's at its device path.
    public static func remote(_ entry: RemoteEntry?, localSize: UInt64, localModified: Date?,
                              remoteSizeWraps: Bool = false) -> ExistingItem {
        guard let entry else { return .none }
        if entry.isDirectory { return .directory }
        let sizeMatches = sameSize(entry.size, localSize, wraps: remoteSizeWraps)
        let dateMatches: Bool = {
            guard let remote = entry.modified, let local = localModified else { return false }
            return abs(remote.timeIntervalSince(local)) <= dateTolerance
        }()
        return .file(sizeMatches: sizeMatches, dateMatches: dateMatches)
    }
}
