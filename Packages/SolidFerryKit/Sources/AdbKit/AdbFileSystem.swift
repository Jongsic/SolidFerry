import Darwin
import DeviceCore
import Foundation
import os

let adbLog = Logger(subsystem: WorkNames.subsystem, category: "adb")

public final class AdbFileSystem: DeviceFileSystem {
    public let serial: String
    public let client: AdbClient
    public let features: Set<String>
    public let capabilities: FSCapabilities
    public var transport: TransportKind { .adb }

    let lsV2: Bool
    let statV2: Bool
    /// Internal storage, then the cards and USB drives mounted when it connected.
    public let roots: [RemoteLocation]
    /// The phone's tar, checked once ("toybox tar" on Android 9 and later).
    let tarAvailable = TarProbe()
    /// Set once the media library's thumbnail lookup has failed on this phone (not merely not
    /// found a file): the rest of the connection doesn't ask again (QUIRKS A20).
    let mediaLibraryFails = OSAllocatedUnfairLock(initialState: false)

    /// `readsRanges`: whether the phone's `dd` reads a part of a file (QUIRKS A19), checked by
    /// `connect`.
    public init(client: AdbClient, serial: String, features: Set<String>, readsRanges: Bool = true,
                removable: [RemoteLocation] = []) {
        self.roots = [RemoteLocation(ref: RemoteRef(path: "/sdcard"), name: "sdcard", kind: .internalStorage)] + removable
        self.client = client
        self.serial = serial
        self.features = features
        let lsV2 = features.contains(AdbFeature.lsV2)
        self.lsV2 = lsV2
        self.statV2 = features.contains(AdbFeature.statV2)
        self.capabilities = FSCapabilities(
            fastListing: lsV2, // the newer listing with 64-bit sizes
            parallelTransfers: true,
            deviceHashing: true,
            exactLargeSizes: lsV2, // v1 listings carry 32-bit sizes (QUIRKS A2)
            streamsFiles: true,
            readsRanges: readsRanges
        )
    }

    public func isConnectionLoss(_ error: Error) -> Bool {
        guard let adb = error as? AdbError else { return false }
        switch adb {
        case .serverUnavailable, .connectionClosed, .io: return true
        case .failed(let message): return message.contains("not found") || message.contains("offline")
        default: return false
        }
    }

    /// A stat answers a missing path with errno 2 (ENOENT).
    public func isNotFound(_ error: Error) -> Bool {
        if case DeviceFSError.notFound = error { return true }
        if case AdbError.remoteError(_, 2) = error { return true }
        return false
    }

    public static func connect(client: AdbClient = AdbClient(), serial: String) async throws -> AdbFileSystem {
        let features = try await client.features(serial: serial)
        let ranges = try await readsRanges(client: client, serial: serial)
        if !ranges { adbLog.info("\(serial, privacy: .public): dd can't read part of a file (QUIRKS A19)") }
        let removable = await removableStorages(client: client, serial: serial)
        return AdbFileSystem(client: client, serial: serial, features: features, readsRanges: ranges, removable: removable)
    }

    /// Cards and USB drives the phone has mounted, browsed at /storage/<volume ID>. Nothing if
    /// the mount table can't be read.
    static func removableStorages(client: AdbClient, serial: String) async -> [RemoteLocation] {
        guard let data = try? await client.exec(serial: serial, "cat /proc/mounts") else { return [] }
        return removableStorages(mounts: String(decoding: data, as: UTF8.self))
    }

    /// From the mount table: each volume vold mounts at /mnt/media_rw/<ID>. Its block device
    /// tells a card (MMC, major 179) from a USB drive (SCSI disk, major 8).
    static func removableStorages(mounts: String) -> [RemoteLocation] {
        var seen = Set<String>()
        return mounts.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ")
            guard fields.count >= 2, fields[1].hasPrefix("/mnt/media_rw/") else { return nil }
            let id = String(fields[1].dropFirst("/mnt/media_rw/".count))
            guard !id.isEmpty, !id.contains("/"), seen.insert(id).inserted else { return nil }
            let kind: RemoteLocation.Kind = fields[0].contains(":179,") ? .sdCard : fields[0].contains(":8,") ? .usbDrive : .other
            return RemoteLocation(ref: RemoteRef(path: "/storage/\(id)"), name: id, kind: kind)
        }
    }

    /// Whether `dd` reads a part of a file the way `read(_:range:chunk:)` asks (QUIRKS A19):
    /// 2 bytes from the second of "abcd".
    static func readsRanges(client: AdbClient, serial: String) async throws -> Bool {
        let output = try await client.exec(serial: serial, "echo abcd | dd \(rangeFlags) skip=1 count=2 bs=262144 2>/dev/null")
        return output == Data("bc".utf8)
    }

    /// `dd` operands that make `skip` and `count` bytes rather than blocks (toybox).
    static let rangeFlags = "iflag=skip_bytes,count_bytes"

    public func list(_ directory: RemoteRef) -> AsyncThrowingStream<[RemoteEntry], Error> {
        let client = client, serial = serial, v2 = lsV2, statV2 = statV2
        return AsyncThrowingStream { continuation in
            let canceller = SocketCanceller()
            continuation.onTermination = { _ in canceller.cancel() }
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let socket = try client.openService(serial: serial, "sync:")
                    canceller.attach(socket)
                    let sync = SyncConnection(socket: socket)
                    // Small first batch so the first rows paint immediately, bigger ones after.
                    var batchLimit = 256
                    var batch: [RemoteEntry] = []
                    batch.reserveCapacity(batchLimit)
                    var total = 0
                    try sync.list(directory.path, v2: v2) { raw in
                        batch.append(Self.makeEntry(raw.stat, name: raw.name, ref: directory.appending(raw.name)))
                        total += 1
                        if batch.count >= batchLimit {
                            continuation.yield(batch)
                            batch.removeAll(keepingCapacity: true)
                            batchLimit = 4096
                        }
                    }
                    if !batch.isEmpty { continuation.yield(batch) }
                    // The daemon answers a missing path or a file with an empty listing;
                    // only then pay for one stat to tell those apart from an empty folder.
                    if total == 0 {
                        let stat = try sync.stat(directory.path, v2: statV2)
                        if !stat.isDirectory { throw AdbError.notADirectory(directory.path) }
                    }
                    sync.quit()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// One sync connection for the whole walk, each depth level's folders requested at once.
    public func listTree(_ roots: [RemoteRef]) -> AsyncThrowingStream<(RemoteRef, [RemoteEntry]), Error> {
        let client = client, serial = serial, v2 = lsV2
        return AsyncThrowingStream { continuation in
            let canceller = SocketCanceller()
            continuation.onTermination = { _ in canceller.cancel() }
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let socket = try client.openService(serial: serial, "sync:")
                    canceller.attach(socket)
                    let sync = SyncConnection(socket: socket)
                    var frontier = roots
                    while !frontier.isEmpty {
                        var next: [RemoteRef] = []
                        for start in stride(from: 0, to: frontier.count, by: 64) {
                            let chunk = Array(frontier[start..<min(start + 64, frontier.count)])
                            var listings = Array(repeating: [RemoteEntry](), count: chunk.count)
                            try sync.listMany(chunk.map(\.path), v2: v2) { index, raw in
                                listings[index].append(Self.makeEntry(raw.stat, name: raw.name, ref: chunk[index].appending(raw.name)))
                            }
                            for (index, dir) in chunk.enumerated() {
                                continuation.yield((dir, listings[index]))
                                next += listings[index].filter(\.isDirectory).map(\.ref)
                            }
                        }
                        frontier = next
                    }
                    sync.quit()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public func entry(at ref: RemoteRef) async throws -> RemoteEntry {
        let client = client, serial = serial, v2 = statV2
        let stat = try await blocking {
            let sync = SyncConnection(socket: try client.openService(serial: serial, "sync:"))
            defer { sync.quit() }
            return try sync.stat(ref.path, v2: v2)
        }
        return Self.makeEntry(stat, name: ref.name, ref: ref)
    }

    static func makeEntry(_ stat: SyncStat, name: String, ref: RemoteRef) -> RemoteEntry {
        guard stat.error == 0 else {
            return RemoteEntry(ref: ref, name: name, kind: .other, size: nil, modified: nil)
        }
        let kind: EntryKind = stat.isDirectory ? .directory : stat.isRegularFile ? .file : stat.isSymlink ? .symlink : .other
        return RemoteEntry(
            ref: ref,
            name: name,
            kind: kind,
            size: kind == .file ? stat.size : nil,
            modified: Date(timeIntervalSince1970: TimeInterval(stat.mtime))
        )
    }
}

/// adbd feature names (`host-serial:…:features`) this code looks at.
public enum AdbFeature {
    /// LIS2/STA2: listings and stats with 64-bit sizes (QUIRKS A2).
    public static let lsV2 = "ls_v2"
    public static let statV2 = "stat_v2"
}
