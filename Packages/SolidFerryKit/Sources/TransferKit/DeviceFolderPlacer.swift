import DeviceCore
import Foundation

/// Decides each file going into a folder on a phone from what's already there: one listing
/// per folder, the policy and the user's per-file choices. "Keep both" names avoid what's
/// there and each other. The queue uses it for uploads and for copies between phones.
public struct DeviceFolderPlacer: Sendable {
    public struct Placement: Sendable {
        /// Where the file goes (renamed for "keep both").
        public let target: RemoteRef
        public let decision: FileDecision
        /// What's at the planned path now.
        public let existing: RemoteEntry?
    }

    public let destination: RemoteRef
    public let policy: TransferPolicy
    public let choices: [String: ConflictChoice]
    /// Sizes from one side are modulo 2³² (QUIRKS A2).
    public let sizesWrap: Bool
    private let list: @Sendable (RemoteRef) async throws -> [String: RemoteEntry]
    private let details: (@Sendable ([RemoteEntry]) async throws -> [RemoteEntry])?
    /// Each folder's listing, by path, as read for placing; within a folder by
    /// `FolderNames.key`, as the phone tells names apart.
    private var listings: [String: [String: RemoteEntry]] = [:]
    /// Entries `details` gave, by path; given to the next placer for the same files (the
    /// queue's after the dialog's) so they aren't asked for again.
    public private(set) var lookedUp: [String: RemoteEntry]
    private var taken: [String: FolderNames] = [:]
    /// Names this job writes in each folder (`reserve`), which "keep both" doesn't pick.
    private var reserved: [String: FolderNames] = [:]

    /// `listing` reads one folder (name → entry; empty when it doesn't exist yet). It may give
    /// names only for big folders (`DeviceFileSystem.listNames`): `details` then fills in sizes
    /// and dates (`DeviceFileSystem.completingDetails`; one still without them is gone since),
    /// only for the names files are coming to, all of them at once where it can.
    public init(destination: RemoteRef, policy: TransferPolicy = TransferPolicy(), choices: [String: ConflictChoice] = [:],
                sizesWrap: Bool, details: (@Sendable ([RemoteEntry]) async throws -> [RemoteEntry])? = nil,
                lookedUp: [String: RemoteEntry] = [:],
                listing: @escaping @Sendable (RemoteRef) async throws -> [String: RemoteEntry]) {
        self.lookedUp = lookedUp
        self.destination = destination
        self.policy = policy
        self.choices = choices
        self.sizesWrap = sizesWrap
        self.details = details
        self.list = listing
    }

    /// Placing on `fs`: its folders as `folderListing` reads them, sizes and dates from
    /// `completingDetails`. The queue `tidying` first (`tidyLeftovers`: a restored original is
    /// planned as the file it is); the dialogs compare only. Both place the same way.
    public init(on fs: any DeviceFileSystem, destination: RemoteRef, policy: TransferPolicy = TransferPolicy(),
                choices: [String: ConflictChoice] = [:], sizesWrap: Bool, lookedUp: [String: RemoteEntry] = [:],
                tidying: Bool = false) {
        self.init(destination: destination, policy: policy, choices: choices, sizesWrap: sizesWrap,
                  details: { try await fs.completingDetails($0) }, lookedUp: lookedUp) { folder in
            let listing = try await fs.folderListing(folder)
            return tidying ? await fs.tidyLeftovers(listing) : listing
        }
    }

    /// Names in each folder: what was there, what "keep both" has taken and what's reserved.
    public var names: [String: FolderNames] {
        listings.mapValues { FolderNames($0.values.map(\.name)) }.merging(taken) { $1 }.merging(reserved) { $0.union($1) }
    }

    /// Holds the places of all of the job's files (paths below the destination) before any is
    /// placed, so a "keep both" name such as "a (1).jpg" is never where another of them goes.
    public mutating func reserve(_ relativePaths: some Sequence<String>) {
        for path in relativePaths {
            let target = destination.appending(path)
            reserved[target.parentPath ?? destination.path, default: FolderNames()].insert(target.name)
        }
    }

    /// The folder's listing (name → entry), read once.
    public mutating func listing(of folder: RemoteRef) async throws -> [String: RemoteEntry] {
        Dictionary(try await indexed(folder).values.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// What's in the folder under `name` as the phone sees it (another case or composition is
    /// the same name).
    private mutating func there(_ name: String, in folder: String) async throws -> RemoteEntry? {
        try await indexed(RemoteRef(path: folder))[FolderNames.key(name)]
    }

    private mutating func indexed(_ folder: RemoteRef) async throws -> [String: RemoteEntry] {
        if let known = listings[folder.path] { return known }
        let read = try await list(folder)
        let index = Dictionary(read.values.map { (FolderNames.key($0.name), $0) }, uniquingKeysWith: { a, _ in a })
        listings[folder.path] = index
        return index
    }

    /// Gets the sizes and dates of what's at these paths below the destination together, before
    /// they're placed one by one: in a big folder, asked for all at once rather than per file.
    public mutating func prepare(_ relativePaths: [String]) async throws {
        guard details != nil else { return }
        var wanted: [RemoteEntry] = []
        for path in relativePaths {
            let target = destination.appending(path)
            let folder = target.parentPath ?? destination.path
            if let there = try await there(target.name, in: folder), there.isPartial, !there.isDirectory,
               lookedUp[there.ref.path] == nil {
                wanted.append(there)
            }
        }
        try await lookUp(wanted)
    }

    private mutating func lookUp(_ entries: [RemoteEntry]) async throws {
        guard !entries.isEmpty, let details else { return }
        // A failed lookup stops the planning: without a size the file would count as different.
        for entry in try await details(entries) { lookedUp[entry.ref.path] = entry }
    }

    /// What's at `relativePath` below the destination, with its size and date.
    public mutating func entry(at relativePath: String) async throws -> RemoteEntry? {
        let target = destination.appending(relativePath)
        let folder = target.parentPath ?? destination.path
        guard let there = try await there(target.name, in: folder) else { return nil }
        guard there.isPartial, !there.isDirectory, details != nil else { return there }
        if lookedUp[there.ref.path] == nil { try await lookUp([there]) }
        // Still without details: it's gone since the folder was listed.
        let full = lookedUp[there.ref.path].flatMap { $0.isPartial ? nil : $0 }
        listings[folder]?[FolderNames.key(target.name)] = full
        return full
    }

    /// The dialog's rows for `files` (path below the destination, size, date), telling
    /// `progress` how many are done every 200. Compares only; deciding is the policy's.
    public mutating func rows(_ files: [(relativePath: String, size: UInt64?, modified: Date?)],
                              progress: @Sendable (Int) -> Void) async throws -> [FileRow] {
        try await prepare(files.map(\.relativePath))
        var result: [FileRow] = []
        result.reserveCapacity(files.count)
        for (index, file) in files.enumerated() {
            let there = try await entry(at: file.relativePath)
            let existing = ExistingItem.remote(there, localSize: file.size ?? 0, localModified: file.modified, remoteSizeWraps: sizesWrap)
            result.append(FileRow(relativePath: file.relativePath, existing: existing, incomingSize: file.size,
                                  incomingDate: file.modified, existingSize: there?.size, existingDate: there?.modified))
            if index % 200 == 199 {
                try Task.checkCancellation()
                progress(index + 1)
            }
        }
        return result
    }

    /// Decides the file at `relativePath` below the destination.
    public mutating func place(_ relativePath: String, size: UInt64, modified: Date?) async throws -> Placement {
        let target = destination.appending(relativePath)
        let folder = target.parentPath ?? destination.path
        let there = try await entry(at: relativePath)
        let decision = FileDecision.decide(.remote(there, localSize: size, localModified: modified, remoteSizeWraps: sizesWrap),
                                           policy, choice: choices[relativePath])
        var placed = target
        if decision == .keepBoth {
            var names = (taken[folder] ?? FolderNames(listings[folder]?.values.map(\.name) ?? [])).union(reserved[folder] ?? FolderNames())
            placed = RemoteRef(path: folder).appending(uniqueName(target.name, taken: &names))
            taken[folder] = names
        }
        return Placement(target: placed, decision: decision, existing: there)
    }
}
