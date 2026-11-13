import Foundation

/// What a backend can do. UI and the transfer engine branch on these, never on the backend type.
public struct FSCapabilities: Sendable, Hashable {
    /// Folders are listed the fastest way this connection has (shown as "Fast mode"): ADB with
    /// `ls_v2` (QUIRKS A1), MTP with per-property listings (M1).
    public var fastListing: Bool
    /// Several transfers can run concurrently.
    public var parallelTransfers: Bool
    /// Content hashes can be computed on the device.
    public var deviceHashing: Bool
    /// Sizes of 4 GB and more are reported exactly. False when the protocol only has 32 bits
    /// for them (old adb without `ls_v2`): sizes then wrap around and only compare modulo 2³².
    public var exactLargeSizes: Bool
    /// Uploaded files keep the date they had on this Mac. False once a phone was seen to stamp
    /// them with the upload time instead (Galaxy over MTP); dates then can't tell whether an
    /// uploaded file changed.
    public var keepsUploadDates: Bool
    /// Files can be read into, and uploaded from, a stream (`read(_:into:)`,
    /// `upload(from:size:…)`): a copy to another device goes straight across.
    public var streamsFiles: Bool
    /// Any part of a file can be read (`read(_:range:chunk:)`), for playing media while it's
    /// read.
    public var readsRanges: Bool

    public init(fastListing: Bool, parallelTransfers: Bool, deviceHashing: Bool,
                exactLargeSizes: Bool = true, keepsUploadDates: Bool = true, streamsFiles: Bool = false,
                readsRanges: Bool = false) {
        self.keepsUploadDates = keepsUploadDates
        self.streamsFiles = streamsFiles
        self.readsRanges = readsRanges
        self.fastListing = fastListing
        self.parallelTransfers = parallelTransfers
        self.deviceHashing = deviceHashing
        self.exactLargeSizes = exactLargeSizes
    }
}

public protocol DeviceFileSystem: AnyObject, Sendable {
    var capabilities: FSCapabilities { get }
    /// The kind of connection (what a phone remembers per connection, like whether it keeps
    /// upload dates, is kept per kind).
    var transport: TransportKind { get }
    var roots: [RemoteLocation] { get }

    /// Streams the directory's entries in batches as they arrive. A later batch may repeat
    /// entries (same `id`) with more filled in — e.g. names first, then sizes and dates — so
    /// consumers replace by id. Cancelling the consuming task stops the listing.
    func list(_ directory: RemoteRef) -> AsyncThrowingStream<[RemoteEntry], Error>

    func entry(at ref: RemoteRef) async throws -> RemoteEntry

    /// Hint: these rows are on screen; fetch their missing details first. No-op when a
    /// listing delivers everything at once.
    func prioritizeDetails(_ refs: [RemoteRef])

    /// Snapshot of in-flight work (nil for backends that don't queue, like ADB).
    func currentActivity() -> FSActivity?

    /// Downloads a single file to `destination` (written atomically, original mtime kept).
    /// `replacing`: whether the file there was planned to be replaced; planned as new
    /// (`false`), one that turned up since stays (`alreadyExists`). nil: a file there when the
    /// download starts is replaced (see `PartialDownload`). `progress` receives byte deltas.
    func download(_ entry: RemoteEntry, to destination: URL, replacing: Bool?,
                  progress: @escaping @Sendable (Int) -> Void) async throws

    /// Downloads several files, reporting each through `completed` (its index and error, if
    /// any) as soon as it's done. Transports with per-file overhead do them over one
    /// connection; throws only when the whole batch can't go on (cancelled, connection lost),
    /// leaving the items not yet reported undone.
    func downloadMany(_ items: [DownloadItem],
                      progress: @escaping @Sendable (Int) -> Void,
                      completed: @escaping @Sendable (Int, Error?) -> Void) async throws

    /// Like `downloadMany`, but the device sends the files as one stream where it can
    /// (the "bundle small files" setting).
    func downloadBundled(_ items: [DownloadItem],
                         progress: @escaping @Sendable (Int) -> Void,
                         completed: @escaping @Sendable (Int, Error?) -> Void) async throws

    /// Lists every folder below `roots` (roots included), breadth-first. Symlinked folders
    /// aren't followed. Yields each folder with its entries.
    func listTree(_ roots: [RemoteRef]) -> AsyncThrowingStream<(RemoteRef, [RemoteEntry]), Error>

    func makeDirectory(_ ref: RemoteRef) async throws

    /// Renames within the same folder. Fails if `newName` is taken (never overwrites).
    func rename(_ ref: RemoteRef, to newName: String) async throws -> RemoteRef

    /// Deletes files and folders (recursively). Permanent.
    func delete(_ refs: [RemoteRef]) async throws

    /// A folder's items with at least names and kinds, for deciding where files go. Sizes and
    /// dates may be missing (`isPartial`) where getting them for everything costs much more
    /// than the names (MTP, big folders); then ask `entry(at:)` for the few that matter.
    func listNames(_ dir: RemoteRef) async throws -> [RemoteEntry]

    /// `entries` with the sizes and dates of files that came without them (`isPartial`, picked
    /// before a slow listing had them) filled in, in the same order. One that's gone stays as it
    /// was.
    func completingDetails(_ entries: [RemoteEntry]) async throws -> [RemoteEntry]

    /// Makes these folders, parents listed before their children; ones already there are
    /// fine. A job's folders, made together where the connection can (one shell command).
    func makeDirectories(_ refs: [RemoteRef]) async throws

    /// Whether `error`, from this connection, means the connection is gone (unplugged, adb
    /// restarted) rather than one operation failing. Each backend knows its own errors.
    func isConnectionLoss(_ error: Error) -> Bool

    /// Whether `error` says the path doesn't exist (rather than any other failure to look).
    func isNotFound(_ error: Error) -> Bool

    /// Lets go of the device when the connection is dropped (MTP holds the USB interface;
    /// ADB has nothing to let go of).
    func close()

    /// Uploads one local file to `destination` (a full path on the device), keeping `modified`
    /// when the transport allows. `progress` gets byte deltas.
    ///
    /// `replacing` is what the caller found there when it planned the transfer: `true`, a file
    /// it means to replace; `false`, nothing (a file that turned up since isn't overwritten:
    /// `DeviceFSError.alreadyExists`); `nil`, unknown, so the backend looks (one listing).
    /// Knowing saves listing the folder for every file, which in a folder of thousands is most
    /// of the time an upload takes.
    func upload(_ source: URL, to destination: RemoteRef, modified: Date?, replacing: Bool?,
                writing: UploadWriting, progress: @escaping @Sendable (Int) -> Void) async throws

    /// Writes a file's contents to `fd` from start to end (one end of a `LocalPipe`; not
    /// closed here). Only when `capabilities.streamsFiles`. `progress` gets byte deltas.
    func read(_ entry: RemoteEntry, into fd: Int32, progress: @escaping @Sendable (Int) -> Void) async throws

    /// The bytes in `range` of a file whose size `entry` gives (the range must lie within it),
    /// handed to `chunk` in order as they arrive. Fewer than asked for is an error. Cancelling
    /// stops it. Only when `capabilities.readsRanges`.
    func read(_ entry: RemoteEntry, range: Range<UInt64>, chunk: @escaping @Sendable (Data) -> Void) async throws

    /// `upload`, with the contents read from `fd` (the other end of a `LocalPipe`): exactly
    /// `size` bytes, then the end. If it ends sooner (the other side stopped) or goes on
    /// longer, it fails with `DeviceFSError.localRead` and nothing is put in place. Only when
    /// `capabilities.streamsFiles`.
    func upload(from fd: Int32, size: UInt64, to destination: RemoteRef, modified: Date?, replacing: Bool?,
                writing: UploadWriting, progress: @escaping @Sendable (Int) -> Void) async throws

    /// Copies a file or folder within the device to `destination` (full path, new name
    /// included), replacing a file already there. No data crosses USB. `replacing`, as for
    /// `upload`: what the caller found at `destination` when it planned (nil: not known).
    func copyOnDevice(_ source: RemoteRef, to destination: RemoteRef, replacing: Bool?) async throws

    /// Moves a file or folder within the device to `destination`, replacing a file there.
    func moveOnDevice(_ source: RemoteRef, to destination: RemoteRef, replacing: Bool?) async throws

    /// MD5 of each file, keyed by path. Files that can't be hashed are left out.
    /// Only when `capabilities.deviceHashing`.
    func contentHashes(_ refs: [RemoteRef]) async throws -> [String: String]

    /// The small picture the device keeps for a picture file (JPEG or PNG data): ADB asks the
    /// media library, MTP the file's thumbnail. nil when there's none — a file in a folder with
    /// `.nomedia`, one not scanned yet, a kind the device makes none for.
    func storedThumbnail(of entry: RemoteEntry) async throws -> Data?
}

/// What a backend is doing right now, for "still working" feedback while the user waits.
public struct FSActivity: Sendable, Equatable {
    public enum Work: Sendable, Equatable {
        case browsing, details, transfer
    }

    /// The request the device is working on, and since when.
    public var current: Work?
    public var since: Date?
    /// Browsing requests waiting behind it.
    public var queuedBrowsing: Int
    /// The phone is still working through a request another program made before we took it
    /// over (macOS's photo service asking for every photo), so ours wait.
    public var finishingEarlierRequest: Bool

    public init(current: Work?, since: Date?, queuedBrowsing: Int, finishingEarlierRequest: Bool = false) {
        self.current = current
        self.since = since
        self.queuedBrowsing = queuedBrowsing
        self.finishingEarlierRequest = finishingEarlierRequest
    }
}

public enum DeviceFSError: Error, Sendable {
    case unsupported
    case alreadyExists(String)
    case invalidName(String)
    case notFound(String)
    case notADirectory(String)
    /// Writing the local destination file failed.
    case localWrite(String)
    /// Reading a local file to send failed.
    case localRead(String)
}

extension DeviceFileSystem {
    public func prioritizeDetails(_ refs: [RemoteRef]) {}

    /// Default: no bundling.
    public func downloadBundled(_ items: [DownloadItem],
                                progress: @escaping @Sendable (Int) -> Void,
                                completed: @escaping @Sendable (Int, Error?) -> Void) async throws {
        try await downloadMany(items, progress: progress, completed: completed)
    }

    /// Default: one `download` after another.
    public func downloadMany(_ items: [DownloadItem],
                             progress: @escaping @Sendable (Int) -> Void,
                             completed: @escaping @Sendable (Int, Error?) -> Void) async throws {
        for (index, item) in items.enumerated() {
            try Task.checkCancellation()
            do {
                try await download(item.entry, to: item.destination, replacing: item.replacing, progress: progress)
                completed(index, nil)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                completed(index, error)
            }
        }
    }

    public func currentActivity() -> FSActivity? { nil }

    /// Default: one `listAll` per folder.
    public func listTree(_ roots: [RemoteRef]) -> AsyncThrowingStream<(RemoteRef, [RemoteEntry]), Error> {
        walkTree(roots) { try await self.listAll($0) }
    }

    public func contentHashes(_ refs: [RemoteRef]) async throws -> [String: String] {
        throw DeviceFSError.unsupported
    }

    public func storedThumbnail(of entry: RemoteEntry) async throws -> Data? { nil }

    public func makeDirectory(_ ref: RemoteRef) async throws {
        throw DeviceFSError.unsupported
    }

    public func close() {}

    public func isConnectionLoss(_ error: Error) -> Bool { false }

    public func isNotFound(_ error: Error) -> Bool {
        if case DeviceFSError.notFound = error { true } else { false }
    }

    public func listNames(_ dir: RemoteRef) async throws -> [RemoteEntry] {
        try await listAll(dir)
    }

    /// Default: `entry(at:)` for each file that needs it.
    public func completingDetails(_ entries: [RemoteEntry]) async throws -> [RemoteEntry] {
        var result: [RemoteEntry] = []
        for entry in entries {
            let needed = entry.kind == .file && (entry.isPartial || entry.size == nil)
            result.append(needed ? try await entryIfExists(entry.ref) ?? entry : entry)
        }
        return result
    }

    /// Entries of a folder by name (empty if the folder doesn't exist yet); big MTP folders come
    /// by name only (`listNames`). Any other failure is thrown: treating it as "empty" would make
    /// every file look new and replace files the policy said to keep.
    public func folderListing(_ dir: RemoteRef) async throws -> [String: RemoteEntry] {
        let entries: [RemoteEntry]
        do {
            entries = try await listNames(dir)
        } catch {
            if try await entryIfExists(dir) == nil { return [:] }
            throw error
        }
        return Dictionary(entries.map { ($0.name, $0) }, uniquingKeysWith: { _, later in later })
    }

    /// `entry(at:)`, or nil when nothing is there; any other failure is thrown.
    public func entryIfExists(_ ref: RemoteRef) async throws -> RemoteEntry? {
        do {
            return try await entry(at: ref)
        } catch where isNotFound(error) {
            return nil
        }
    }

    public func makeDirectories(_ refs: [RemoteRef]) async throws {
        for ref in refs {
            do { try await makeDirectory(ref) } catch DeviceFSError.alreadyExists {}
        }
    }

    public func upload(_ source: URL, to destination: RemoteRef, modified: Date?, replacing: Bool?,
                       writing: UploadWriting, progress: @escaping @Sendable (Int) -> Void) async throws {
        throw DeviceFSError.unsupported
    }

    /// Replaces whatever is there, through a temporary name.
    public func upload(_ source: URL, to destination: RemoteRef, modified: Date?,
                       progress: @escaping @Sendable (Int) -> Void) async throws {
        try await upload(source, to: destination, modified: modified, replacing: nil, writing: .safe, progress: progress)
    }

    public func read(_ entry: RemoteEntry, into fd: Int32, progress: @escaping @Sendable (Int) -> Void) async throws {
        throw DeviceFSError.unsupported
    }

    public func read(_ entry: RemoteEntry, range: Range<UInt64>, chunk: @escaping @Sendable (Data) -> Void) async throws {
        throw DeviceFSError.unsupported
    }

    public func upload(from fd: Int32, size: UInt64, to destination: RemoteRef, modified: Date?, replacing: Bool?,
                       writing: UploadWriting, progress: @escaping @Sendable (Int) -> Void) async throws {
        throw DeviceFSError.unsupported
    }

    public func copyOnDevice(_ source: RemoteRef, to destination: RemoteRef, replacing: Bool?) async throws {
        throw DeviceFSError.unsupported
    }

    public func moveOnDevice(_ source: RemoteRef, to destination: RemoteRef, replacing: Bool?) async throws {
        throw DeviceFSError.unsupported
    }

    public func copyOnDevice(_ source: RemoteRef, to destination: RemoteRef) async throws {
        try await copyOnDevice(source, to: destination, replacing: nil)
    }

    public func moveOnDevice(_ source: RemoteRef, to destination: RemoteRef) async throws {
        try await moveOnDevice(source, to: destination, replacing: nil)
    }

    public func rename(_ ref: RemoteRef, to newName: String) async throws -> RemoteRef {
        throw DeviceFSError.unsupported
    }

    public func delete(_ refs: [RemoteRef]) async throws {
        throw DeviceFSError.unsupported
    }
}

/// A file to download, where it goes on this Mac, and whether it was planned to replace the
/// file there (see `DeviceFileSystem.download`).
public struct DownloadItem: Sendable {
    public let entry: RemoteEntry
    public let destination: URL
    public let replacing: Bool?

    public init(_ entry: RemoteEntry, to destination: URL, replacing: Bool?) {
        self.entry = entry
        self.destination = destination
        self.replacing = replacing
    }
}

extension DeviceFileSystem {
    /// For tools: replaces a file there when the download starts.
    public func download(_ entry: RemoteEntry, to destination: URL, progress: @escaping @Sendable (Int) -> Void) async throws {
        try await download(entry, to: destination, replacing: nil, progress: progress)
    }
}

/// How an upload lands on the phone.
public enum UploadWriting: Sendable, Equatable {
    /// Under a hidden temporary name, renamed into place when complete: an interrupted upload
    /// leaves nothing under the real name, and a file being replaced stays until then.
    case safe
    /// New files straight under their name (no rename, faster for many small files; an
    /// interrupted one leaves a broken file); files being replaced the safe way.
    case directForNewFiles
    /// Every file straight under its name. A file being replaced is gone from the start, so
    /// an interrupted upload can't give it back.
    case direct

    /// Whether an upload goes straight under its name.
    public func isStraight(replacing: Bool) -> Bool {
        switch self {
        case .safe: false
        case .directForNewFiles: !replacing
        case .direct: true
        }
    }
}

/// `listTree` with `listing` reading each folder: breadth-first from `roots`, each folder
/// yielded with its entries. Symlinked folders aren't followed (they aren't `.directory`).
public func walkTree(_ roots: [RemoteRef], listing: @escaping @Sendable (RemoteRef) async throws -> [RemoteEntry])
    -> AsyncThrowingStream<(RemoteRef, [RemoteEntry]), Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            do {
                var frontier = roots
                while !frontier.isEmpty {
                    var next: [RemoteRef] = []
                    for dir in frontier {
                        let entries = try await listing(dir)
                        try Task.checkCancellation()
                        continuation.yield((dir, entries))
                        next += entries.filter(\.isDirectory).map(\.ref)
                    }
                    frontier = next
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

/// Where a download is written until it's complete; renamed into place at the end.
public func partialDownloadURL(for destination: URL) -> URL {
    destination.deletingLastPathComponent().appendingPathComponent(WorkNames.partial(destination.lastPathComponent))
}

/// A folder's listing put together from `list`'s batches: they come in parts, and an entry
/// can come again once its details (size, date) are in. The later one wins; the order is the
/// order names first appeared.
public struct ListingAccumulator: Sendable {
    public private(set) var entries: [RemoteEntry] = []
    private var index: [String: Int] = [:]

    public init() {}

    public mutating func add(_ batch: [RemoteEntry]) {
        for entry in batch {
            if let i = index[entry.id] { entries[i] = entry } else {
                index[entry.id] = entries.count
                entries.append(entry)
            }
        }
    }
}

extension DeviceFileSystem {
    /// Every entry in `dir`, details included, once the listing is complete.
    public func listAll(_ dir: RemoteRef) async throws -> [RemoteEntry] {
        var listing = ListingAccumulator()
        for try await batch in list(dir) { listing.add(batch) }
        return listing.entries
    }

    /// Tidies what interrupted uploads left in a folder, given its listing (name → entry), and
    /// returns the listing as it is afterwards. Call it only when nothing is uploading there.
    /// - Partial files go: never the user's data, the source still has it.
    /// - An original moved aside for a copy or move on the phone (QUIRKS M13) goes when that made
    ///   it (it was to be overwritten), and gets its name back when it didn't: then it's the
    ///   only copy.
    /// - An item cut off while it was being moved on the phone gets its name back; next to
    ///   something by that name, "name (1)", as the move would have named it.
    /// Whatever can't be tidied stays as it was.
    public func tidyLeftovers(_ listing: [String: RemoteEntry]) async -> [String: RemoteEntry] {
        var result = listing
        let partials = listing.values.filter { WorkNames.isPartial($0.name) && !$0.isDirectory }
        if !partials.isEmpty {
            if (try? await delete(partials.map(\.ref))) != nil {
                for entry in partials { result[entry.name] = nil }
            } else {
                // Some went, some didn't: one at a time, so the listing says what's left.
                for entry in partials where (try? await delete([entry.ref])) != nil { result[entry.name] = nil }
            }
        }
        for entry in listing.values where !entry.isDirectory {
            guard let original = WorkNames.originalName(ofAside: entry.name) else { continue }
            if let there = result[original] {
                // A file there is the replacement, so the original's no longer needed. A folder
                // there is something else: the original (maybe its only copy) stays aside.
                guard !there.isDirectory else { continue }
                if (try? await delete([entry.ref])) != nil { result[entry.name] = nil }
            } else if let restored = try? await rename(entry.ref, to: original) {
                result[entry.name] = nil
                result[original] = RemoteEntry(ref: restored, name: original, kind: entry.kind,
                                               size: entry.size, modified: entry.modified)
            }
        }
        for entry in listing.values {
            guard let original = WorkNames.originalName(ofMoving: entry.name) else { continue }
            var taken = FolderNames(result.keys)
            let name = taken.contains(original) ? uniqueName(original, taken: &taken, isDirectory: entry.isDirectory) : original
            if let restored = try? await rename(entry.ref, to: name) {
                result[entry.name] = nil
                result[name] = RemoteEntry(ref: restored, name: name, kind: entry.kind, size: entry.size, modified: entry.modified)
            }
        }
        return result
    }

    /// Whether files uploaded into `folder` keep their date: sends a 1-byte hidden file dated
    /// 2020-01-01, reads the date back and deletes the file. Some phones stamp uploads with
    /// the upload time instead (Galaxy over MTP), which only shows once something is sent.
    public func probeKeepsUploadDates(in folder: RemoteRef) async throws -> Bool {
        let date = Date(timeIntervalSince1970: 1_577_836_800)
        let local = WorkNames.scratch("dateprobe")
        try Data([0x20]).write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }
        let probe = folder.appending(WorkNames.step("dateprobe"))
        try await upload(local, to: probe, modified: date) { _ in }
        let entry: RemoteEntry
        do {
            entry = try await self.entry(at: probe)
        } catch {
            try? await delete([probe])
            throw error
        }
        try? await delete([probe])
        guard let stored = entry.modified else { return false }
        return abs(stored.timeIntervalSince(date)) <= 2
    }
}
