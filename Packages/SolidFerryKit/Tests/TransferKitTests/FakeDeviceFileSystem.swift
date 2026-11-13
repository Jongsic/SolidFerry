import DeviceCore
import Foundation

/// An in-memory phone for planning tests. Listings come the way MTP sends them: names first
/// (no size or date yet), then the same entries again with their details.
final class FakeDeviceFileSystem: DeviceFileSystem, @unchecked Sendable {
    private var entries: [String: RemoteEntry] = [:]

    /// Files can be streamed to another device (`read(_:into:)`, `upload(from:…)`).
    var streams = false
    var capabilities: FSCapabilities {
        FSCapabilities(fastListing: false, parallelTransfers: false, deviceHashing: false, exactLargeSizes: true,
                       streamsFiles: streams)
    }
    let transport = TransportKind.mtp
    var roots: [RemoteLocation] { [RemoteLocation(ref: RemoteRef(path: "/sdcard"), name: "sdcard")] }

    /// Adds a file or folder (its parents are implied); `name`: what the listing calls it, if
    /// not the last part of its path.
    @discardableResult
    func add(_ path: String, kind: EntryKind = .file, size: UInt64? = nil, modified: Date? = nil, name: String? = nil) -> RemoteEntry {
        let ref = RemoteRef(path: path)
        let entry = RemoteEntry(ref: ref, name: name ?? ref.name, kind: kind, size: kind == .file ? size ?? 0 : nil, modified: modified)
        entries[path] = entry
        return entry
    }

    func list(_ directory: RemoteRef) -> AsyncThrowingStream<[RemoteEntry], Error> {
        let children = entries.values.filter { $0.ref.parentPath == directory.path }.sorted { $0.name < $1.name }
        return AsyncThrowingStream { continuation in
            continuation.yield(children.map {
                RemoteEntry(ref: $0.ref, name: $0.name, kind: $0.kind, size: nil, modified: nil, isPartial: $0.kind == .file)
            })
            continuation.yield(children)
            continuation.finish()
        }
    }

    func entry(at ref: RemoteRef) async throws -> RemoteEntry {
        guard let entry = entries[ref.path] else { throw DeviceFSError.notFound(ref.path) }
        return entry
    }

    /// Files come and go in pieces this big, so progress arrives in uneven steps.
    var chunk = 7

    func download(_ entry: RemoteEntry, to destination: URL, replacing: Bool?, progress: @escaping @Sendable (Int) -> Void) async throws {
        guard let size = entries[entry.ref.path]?.size else { throw DeviceFSError.notFound(entry.ref.path) }
        var left = Int(size)
        var data = Data()
        while left > 0 {
            let n = min(chunk, left)
            data.append(Data(repeating: 0x61, count: n))
            progress(n)
            left -= n
        }
        try data.write(to: destination)
    }

    func upload(_ source: URL, to destination: RemoteRef, modified: Date?, replacing: Bool?, writing: UploadWriting,
                progress: @escaping @Sendable (Int) -> Void) async throws {
        let size = try Data(contentsOf: source).count
        var left = size
        while left > 0 {
            let n = min(chunk + 2, left)
            progress(n)
            left -= n
        }
        add(destination.path, size: UInt64(size), modified: modified)
    }

    /// Paths whose delete fails (a batch still deletes the others before throwing, as
    /// `rm -rf` and MTP item-by-item do).
    var undeletable: Set<String> = []

    func delete(_ refs: [RemoteRef]) async throws {
        var failed = false
        for ref in refs {
            if undeletable.contains(ref.path) { failed = true; continue }
            entries = entries.filter { $0.key != ref.path && !$0.key.hasPrefix(ref.path + "/") }
        }
        if failed { throw DeviceFSError.unsupported }
    }

    func rename(_ ref: RemoteRef, to newName: String) async throws -> RemoteRef {
        guard let entry = entries[ref.path], let parent = ref.parentPath else { throw DeviceFSError.notFound(ref.path) }
        let target = RemoteRef(path: parent).appending(newName)
        guard entries[target.path] == nil else { throw DeviceFSError.alreadyExists(newName) }
        entries[ref.path] = nil
        entries[target.path] = RemoteEntry(ref: target, name: newName, kind: entry.kind, size: entry.size, modified: entry.modified)
        return target
    }

    var paths: Set<String> { Set(entries.keys) }

    // MARK: Streaming

    /// Reading stops with this error after this many bytes (the phone was unplugged).
    var readFailsAfter: Int?
    /// A streamed upload stops with this error after this many bytes.
    var uploadFailsAfter: Int?
    struct Unplugged: Error {}

    func read(_ entry: RemoteEntry, into fd: Int32, progress: @escaping @Sendable (Int) -> Void) async throws {
        guard let size = entries[entry.ref.path]?.size else { throw DeviceFSError.notFound(entry.ref.path) }
        let failAfter = readFailsAfter, chunk = chunk
        try await offPool {
            var sent = 0
            while sent < Int(size) {
                if let failAfter, sent >= failAfter { throw Unplugged() }
                let n = min(chunk, Int(size) - sent)
                try [UInt8](repeating: 0x61, count: n).withUnsafeBytes { try writeFully(fd, $0) }
                sent += n
                progress(n)
            }
        }
    }

    func upload(from fd: Int32, size: UInt64, to destination: RemoteRef, modified: Date?, replacing: Bool?,
                writing: UploadWriting, progress: @escaping @Sendable (Int) -> Void) async throws {
        let failAfter = uploadFailsAfter
        try await offPool {
            var total = 0
            var buffer = [UInt8](repeating: 0, count: 64)
            while true {
                if let failAfter, total >= failAfter { throw Unplugged() }
                let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                guard n >= 0 else { throw DeviceFSError.localRead("read") }
                if n == 0 { break }
                total += n
                progress(n)
            }
            guard total == Int(size) else { throw DeviceFSError.localRead("ended after \(total) of \(size) bytes") }
        }
        add(destination.path, size: size, modified: modified)
    }

    /// Blocking pipe work off the cooperative pool, as the real connections do it.
    private func offPool(_ body: @escaping @Sendable () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global().async { continuation.resume(with: Result(catching: body)) }
        }
    }
}
