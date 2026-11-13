import Darwin
import DeviceCore
import Foundation

/// Why an MTP device can't be browsed yet, from what the device reports.
public enum MtpConnectError: Error, Sendable, Equatable, CustomStringConvertible {
    public var description: String {
        switch self {
        case .notFound: "MTP interface not found"
        case .busy(let owners): "MTP interface in use by \(owners.joined(separator: ", "))"
        case .chargingOnly: "USB is set to charging only"
        case .noStorage: "no storage exposed"
        case .unresponsive: "MTP server not responding"
        case .other(let message): message
        }
    }

    case notFound
    /// Another app (not ptpcamerad, which is cleared automatically) holds the interface.
    case busy(owners: [String])
    /// Samsung `devicestatus: 4`: USB is set to charging only (measured; undocumented; QUIRKS G2).
    case chargingOnly
    /// Session is open but no storage is exposed (locked, or "File transfer" not chosen).
    case noStorage
    /// The phone's MTP server stopped responding.
    case unresponsive
    case other(String)
}

/// `DeviceFileSystem` over MTP. Paths mirror ADB's so favorites and history work across
/// both: the first storage is `/sdcard`, others `/storage/<ID>`. MTP addresses objects by
/// handle, so paths are resolved through a cache filled by listings.
public final class MtpFileSystem: DeviceFileSystem, @unchecked Sendable {
    public var transport: TransportKind { .mtp }
    public let serial: String
    public let deviceInfo: MtpDeviceInfo
    public var capabilities: FSCapabilities {
        FSCapabilities(fastListing: true, parallelTransfers: false, deviceHashing: false,
                       keepsUploadDates: lock.withLock { !uploadDatesIgnored }, streamsFiles: true,
                       readsRanges: true)
    }
    /// Seen on an upload: the phone stamped the file with the upload time (Galaxy; it also
    /// refuses to set DateModified afterwards, 0xA80A). QUIRKS G6.
    private var uploadDatesIgnored = false
    public let roots: [RemoteLocation]
    /// macOS's photo service had the phone first and had to be cleared.
    public let tookOverFromPtpcamerad: Bool
    let connectedAt = Date()

    private struct Storage {
        let id: UInt32
        let path: String
    }

    private typealias Node = MtpPathCache.Node

    private let storages: [Storage]
    private let worker: MtpWorker
    private let lock = NSLock()
    private let paths: MtpPathCache

    private static let rootHandle: UInt32 = 0xFFFF_FFFF

    private init(serial: String, info: MtpDeviceInfo, storages: [(UInt32, String)], worker: MtpWorker, evicted: Bool) {
        self.serial = serial
        tookOverFromPtpcamerad = evicted
        self.deviceInfo = info
        self.worker = worker
        self.storages = storages.enumerated().map { index, item in
            Storage(id: item.0, path: index == 0 ? "/sdcard" : String(format: "/storage/%08X", item.0))
        }
        roots = zip(self.storages, storages).enumerated().map { index, pair in
            RemoteLocation(ref: RemoteRef(path: pair.0.path), name: pair.1.1, kind: index == 0 ? .internalStorage : .other)
        }
        paths = MtpPathCache(roots: self.storages.map { ($0.path, Node(storage: $0.id, handle: Self.rootHandle, isDirectory: true)) })
    }

    deinit {
        worker.close()
    }

    public func close() {
        worker.close()
    }

    /// Steps of connecting, reported so the UI can say what it's waiting for.
    public enum OpenStage: Sendable, Equatable {
        case claiming          // taking the USB interface (may clear ptpcamerad)
        case openingSession    // talking to the phone's MTP server
        case waitingForStorage // phone hasn't exposed storage yet
        case phoneBusy         // phone is finishing a request macOS's photo service started
    }

    /// Opens the device's MTP interface (clearing ptpcamerad if it holds it) and a session.
    /// Waits briefly for storage to appear: right after plugging in or switching to
    /// "File transfer" it is empty for a moment (QUIRKS M16).
    public static func open(serial: String, progress: @escaping @Sendable (OpenStage) -> Void = { _ in }) async throws -> MtpFileSystem {
        do {
            return try await openOnce(serial: serial, progress: progress)
        } catch MtpConnectError.unresponsive {
            // A phone left in the middle of an upload by a client that went away (app quit or
            // crashed) keeps waiting for the rest of the file and doesn't answer. Letting go of
            // the interface after that failed attempt clears it; the next attempt connects
            // (on a Tab P11, every time, however long the wait before it). QUIRKS M11.
            mtpLog.notice("phone didn't answer; reopening the interface once")
            return try await openOnce(serial: serial, progress: progress)
        }
    }

    /// A USB-level failure: IOUSBHost's own error, or `MtpError.usb` (how MtpSession reports
    /// an interface it couldn't create).
    private static func isUsbFailure(_ error: Error) -> Bool {
        if case MtpError.usb = error { return true }
        return (error as NSError).domain == usbErrorDomain
    }

    private static let usbErrorDomain = "IOUSBHostErrorDomain"

    private static func openOnce(serial: String, progress: @escaping @Sendable (OpenStage) -> Void) async throws -> MtpFileSystem {
        progress(.claiming)
        var opened: MtpSession?
        // Separate counts: retries for one reason mustn't use up the other's (QUIRKS M12).
        var busyAttempts = 0, unavailableAttempts = 0
        while opened == nil {
            do {
                opened = try MtpSession(serial: serial)
            } catch MtpError.deviceNotFound {
                throw MtpConnectError.notFound
            } catch MtpError.interfaceBusy(let owners) {
                // Often momentary (a just-closed session, macOS's image capture daemon
                // probing a new device); give it a couple of seconds before reporting.
                busyAttempts += 1
                if busyAttempts >= MtpTuning.interfaceBusy.attempts { throw MtpConnectError.busy(owners: owners.map(\.name)) }
                try await Task.sleep(for: MtpTuning.interfaceBusy.interval)
            } catch where isUsbFailure(error) {
                // The interface couldn't be opened: right after another client let go of the
                // phone (or was killed mid-transfer), it can be briefly unavailable while the
                // system tears that client down (QUIRKS M12). Look it up again shortly.
                unavailableAttempts += 1
                if unavailableAttempts >= MtpTuning.interfaceUnavailable.attempts { throw MtpConnectError.other("\(error)") }
                try await Task.sleep(for: MtpTuning.interfaceUnavailable.interval)
            }
        }
        let session = opened!
        progress(.openingSession)
        let worker = MtpWorker(session: session)
        do {
            // Opening can wait a long time for a busy phone (up to 90 s after taking it over);
            // a connection no longer wanted stops that wait at once.
            let abandonable = UnsafeSendable(value: session)
            let (info, storages) = try await withTaskCancellationHandler { try await worker.run(.interactive) { session -> (MtpDeviceInfo, [(UInt32, String)]) in
                try session.openSessionRecovering(patience: MtpTuning.sessionPatience(tookOverPhotoService: session.wasEvicted)) { progress(.phoneBusy) }
                let info = try session.deviceInfo()
                var ids: [UInt32] = []
                let wait = MtpTuning.storageWait
                for attempt in 1...wait.attempts {
                    ids = try session.storageIDs()
                    if !ids.isEmpty || info.samsungDeviceStatus == 4 { break }
                    if attempt == 1 { progress(.waitingForStorage) }
                    if attempt < wait.attempts { Thread.sleep(forTimeInterval: wait.interval / .seconds(1)) }
                }
                let storages = try ids.map { id -> (UInt32, String) in
                    let storage = try session.storageInfo(id)
                    return (id, storage.description.isEmpty ? "Storage" : storage.description)
                }
                return (info, storages)
            } } onCancel: {
                abandonable.value.abandon() // thread-safe: a flag and pipe aborts
            }
            guard !storages.isEmpty else {
                worker.close()
                throw info.samsungDeviceStatus == 4 ? MtpConnectError.chargingOnly : MtpConnectError.noStorage
            }
            return MtpFileSystem(serial: serial, info: info, storages: storages, worker: worker, evicted: session.wasEvicted)
        } catch let error as MtpConnectError {
            throw error
        } catch {
            worker.close()
            if Task.isCancelled { throw CancellationError() }
            throw Self.isTimeout(error) ? MtpConnectError.unresponsive : MtpConnectError.other("\(error)")
        }
    }

    static func isTimeout(_ error: Error) -> Bool {
        IOReturnCode.of(error) == IOReturnCode.timeout
    }

    // MARK: Path resolution

    private func resolve(_ ref: RemoteRef, token: CancelToken? = nil) async throws -> Node {
        let path = ref.path.count > 1 && ref.path.hasSuffix("/") ? String(ref.path.dropLast()) : ref.path
        if let node = paths.node(at: path) { return node }
        guard let parentPath = RemoteRef(path: path).parentPath, storages.contains(where: { path.hasPrefix($0.path + "/") }) else {
            throw DeviceFSError.notFound(path)
        }
        let parent = try await resolve(RemoteRef(path: parentPath), token: token)
        _ = try await listNames(parent, path: parentPath, token: token)
        guard let node = paths.node(at: path) else { throw DeviceFSError.notFound(path) }
        return node
    }

    // MARK: Listing

    /// Names and kinds of a folder's children (fast on Android: the media database).
    /// ObjectInfo, or nil when the item went away between listing and asking (the phone
    /// answers "invalid handle"; seen on a Galaxy while macOS's photo service had just used it;
    /// QUIRKS G4).
    /// The size is the full one: ObjectInfo's is 32-bit and reads 0xFFFFFFFF for files of
    /// 4 GB or more (QUIRKS M3), so those are asked again. Every path that turns ObjectInfo
    /// into an entry goes through here: a file believed to be 4 GB − 1 would be downloaded
    /// cut short, and reported as complete.
    private static func infoIfExists(_ session: MtpSession, _ handle: UInt32) throws -> MtpObjectInfo? {
        do {
            var info = try session.objectInfo(handle)
            if !info.isFolder, info.size == UInt64(UInt32.max) { info.size = try session.objectSize64(handle) }
            return info
        } catch MtpError.response(_, PTPResponse.invalidObjectHandle) {
            mtpLog.notice("skipped an item that no longer exists")
            return nil
        }
    }

    /// Names only for a folder too big to get sizes and dates in bulk (they'd come one object at
    /// a time, QUIRKS M2); a smaller folder's listing with them, which costs little more.
    public func listNames(_ dir: RemoteRef) async throws -> [RemoteEntry] {
        let node = try await resolve(dir)
        let names = try await listNames(node, path: dir.path, token: nil)
        guard names.count <= MtpTuning.bulkDetailsLimit, names.contains(where: \.isPartial) else { return names }
        return try await withDetails(names, of: node.handle, token: nil)
    }

    /// Planning a transfer: every folder with sizes and dates in bulk, however big. Browsing gets
    /// a big folder's in small chunks so other folders can be opened meanwhile (QUIRKS M2), but
    /// for a whole tree that's one request per file, several times slower in total.
    public func listTree(_ roots: [RemoteRef]) -> AsyncThrowingStream<(RemoteRef, [RemoteEntry]), Error> {
        walkTree(roots) { [self] dir in
            let node = try await resolve(dir)
            guard node.isDirectory else { throw DeviceFSError.notADirectory(dir.path) }
            let names = try await listNames(node, path: dir.path, token: nil)
            guard names.contains(where: \.isPartial) else { return names }
            return try await withDetails(names, of: node.handle, token: nil)
        }
    }

    /// A listing by name with every size and date filled in: two bulk requests for the folder.
    private func withDetails(_ names: [RemoteEntry], of folder: UInt32, token: CancelToken?) async throws -> [RemoteEntry] {
        let (sizes, dates) = try await bulkDetails(of: folder, token: token)
        return names.map { entry in
            let handle = entry.ref.handle.map { UInt32($0) } ?? 0
            return RemoteEntry(ref: entry.ref, name: entry.name, kind: entry.kind,
                               size: entry.isDirectory ? nil : sizes[handle],
                               modified: dates[handle] ?? nil)
        }
    }

    /// Sizes and dates of everything in a folder, by handle: two bulk requests.
    private func bulkDetails(of folder: UInt32, token: CancelToken?) async throws -> (sizes: [UInt32: UInt64], dates: [UInt32: Date?]) {
        let sizes = try await worker.run(.details, token: token) { session in
            Dictionary(try session.objectPropList(children: folder, property: UInt32(MTPProp.objectSize))
                .map { ($0.handle, $0.size) }, uniquingKeysWith: { a, _ in a })
        }
        let dates = try await worker.run(.details, token: token) { session in
            Dictionary(try session.objectPropList(children: folder, property: UInt32(MTPProp.dateModified))
                .map { ($0.handle, $0.modified) }, uniquingKeysWith: { a, _ in a })
        }
        return (sizes, dates)
    }

    /// Sizes and dates for files that came by name only (selected before a big folder's details
    /// were in). What browsing that folder got is used; while it's still getting them, the ones
    /// needed go first and are waited for rather than asked again. The rest come in bulk for the
    /// whole folder when they're many (`MtpTuning.bulkWhenMissing`), otherwise one by one.
    public func completingDetails(_ entries: [RemoteEntry]) async throws -> [RemoteEntry] {
        var filled: [String: RemoteEntry] = [:] // by path
        let missing = entries.filter { $0.kind == .file && ($0.isPartial || $0.size == nil) }
        for (folder, files) in Dictionary(grouping: missing, by: { $0.ref.parentPath ?? "/" }) {
            var byHandle: [UInt32: RemoteEntry] = [:]
            // From a listing they carry their handle; looked up by path only when they don't.
            for file in files {
                if let handle = file.ref.handle { byHandle[UInt32(handle)] = file } else { byHandle[try await resolve(file.ref).handle] = file }
            }
            func fill(_ handle: UInt32, size: UInt64?, modified: Date?) {
                guard let file = byHandle.removeValue(forKey: handle) else { return }
                filled[file.ref.path] = RemoteEntry(ref: file.ref, name: file.name, kind: file.kind, size: size, modified: modified)
            }
            for info in try await fromBrowsing(Set(byHandle.keys), in: folder).values {
                fill(info.handle, size: info.size, modified: info.modified)
            }
            guard !byHandle.isEmpty else { continue }
            let share = paths.count(in: folder).map { Double(byHandle.count) >= Double($0) * MtpTuning.bulkWhenMissingShare } ?? false
            if byHandle.count >= MtpTuning.bulkWhenMissing || share {
                let (sizes, dates) = try await bulkDetails(of: try await resolve(RemoteRef(path: folder)).handle, token: nil)
                for handle in Array(byHandle.keys) where sizes[handle] != nil {
                    fill(handle, size: sizes[handle], modified: dates[handle] ?? nil)
                }
            }
            // One by one (or what bulk left out), a few per request so browsing can go between.
            let rest = Array(byHandle.keys)
            for start in stride(from: 0, to: rest.count, by: 50) {
                let batch = Array(rest[start..<min(start + 50, rest.count)])
                let infos = try await worker.run(.interactive) { session in try batch.compactMap { try Self.infoIfExists(session, $0) } }
                for info in infos { fill(info.handle, size: info.size, modified: info.modified) }
            }
        }
        // One that's gone stays as it was; the transfer reports it.
        return entries.map { filled[$0.ref.path] ?? $0 }
    }

    /// Details browsing has got, or is getting, for these files of `folder`: they're moved to the
    /// front and waited for while it's at it.
    private func fromBrowsing(_ handles: Set<UInt32>, in folder: String) async throws -> [UInt32: MtpObjectInfo] {
        guard let pending = pendingDetails, pending.directory == folder else { return [:] }
        pending.prioritize(Array(handles))
        while true {
            let got = pending.filled(handles)
            if got.count == handles.count || pending.isFinished || pendingDetails !== pending { return got }
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    private func listNames(_ node: Node, path: String, token: CancelToken?) async throws -> [RemoteEntry] {
        // Listed again: what browsing got for it earlier may be out of date.
        if let pending = pendingDetails, pending.directory == path, pending.isFinished { pendingDetails = nil }
        let storage = node.storage, handle = node.handle
        let items = try await worker.run(.interactive, token: token) { session -> [MtpObjectInfo] in
            if handle == Self.rootHandle {
                // Storage roots are small; ObjectInfo gives everything at once.
                return try session.objectHandles(storage: storage, parent: handle).compactMap { try Self.infoIfExists(session, $0) }
            }
            let names = try session.objectPropList(children: handle, property: UInt32(MTPProp.objectFileName))
            let formats = Dictionary(
                try session.objectPropList(children: handle, property: UInt32(MTPProp.objectFormat)).map { ($0.handle, $0.format) },
                uniquingKeysWith: { a, _ in a })
            // Cross-check against the handle list; fetch anything the bulk reply left out.
            let all = try session.objectHandles(storage: storage, parent: handle)
            let listed = Set(names.map(\.handle))
            var result = names.map { item -> MtpObjectInfo in
                var item = item
                item.format = formats[item.handle] ?? 0
                item.size = UInt64.max // unknown yet
                return item
            }
            for missing in all where !listed.contains(missing) {
                if let info = try Self.infoIfExists(session, missing) { result.append(info) }
            }
            // A work file's name decides that tidying deletes it, and the bulk list can hold a
            // user's file under the name it had before a rename (QUIRKS G11): those are asked
            // one by one (there are seldom any).
            var gone = Set<UInt32>()
            for i in result.indices where WorkNames.isWorkFile(result[i].name) {
                if let name = try Self.currentName(session, result[i].handle) { result[i].name = name } else { gone.insert(result[i].handle) }
            }
            return result.filter { !gone.contains($0.handle) }
        }
        let isRoot = handle == Self.rootHandle
        var entries: [RemoteEntry] = []
        var remembered: [(String, Node)] = []
        let base = RemoteRef(path: path)
        // A name that isn't one path component would point outside this folder.
        for item in items where FileNames.isOnePathComponent(item.name) {
            let ref = base.appending(item.name, handle: UInt64(item.handle))
            let kind: EntryKind = item.isFolder ? .directory : .file
            remembered.append((ref.path, Node(storage: storage, handle: item.handle, isDirectory: item.isFolder)))
            let partial = !isRoot && item.size == UInt64.max
            entries.append(RemoteEntry(ref: ref, name: item.name, kind: kind,
                                       size: partial || item.isFolder ? nil : item.size,
                                       modified: partial ? nil : item.modified, isPartial: partial))
        }
        paths.rememberListing(of: path, remembered)
        return entries
    }

    public func list(_ directory: RemoteRef) -> AsyncThrowingStream<[RemoteEntry], Error> {
        AsyncThrowingStream { continuation in
            let token = CancelToken()
            let task = Task {
                do {
                    let listStart = ContinuousClock.now
                    let node = try await resolve(directory, token: token)
                    mtpLog.debug("list: resolved in \((ContinuousClock.now - listStart).formatted(.units(allowed: [.milliseconds])), privacy: .public)")
                    guard node.isDirectory else { throw DeviceFSError.notADirectory(directory.path) }
                    let started = ContinuousClock.now
                    let names = try await listNames(node, path: directory.path, token: token)
                    mtpLog.debug("names \(directory.path, privacy: .private(mask: .hash)) \(names.count) in \((ContinuousClock.now - started).formatted(.units(allowed: [.milliseconds])), privacy: .public)")
                    continuation.yield(names)
                    mtpLog.debug("list: names yielded")
                    guard names.contains(where: \.isPartial) else {
                        continuation.finish()
                        return
                    }
                    if names.count <= MtpTuning.bulkDetailsLimit {
                        // Small folder: two bulk requests (bounded even when the phone is slow).
                        continuation.yield(try await withDetails(names, of: node.handle, token: token))
                    } else {
                        try await fillDetailsInChunks(names, directory: directory.path, token: token, continuation: continuation)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                token.cancel()
                task.cancel()
            }
        }
    }

    /// Details of the big folder listed most recently: those still missing, in the order they're
    /// asked for (rows on screen jump the line), and those got, kept until the folder is listed
    /// again (a transfer planned from that listing uses them).
    private final class PendingDetails: @unchecked Sendable {
        let directory: String
        private let lock = NSLock()
        private var order: [UInt32]
        private var queued: Set<UInt32>
        private var got: [UInt32: MtpObjectInfo] = [:]
        private var finished = false

        init(directory: String, handles: [UInt32]) {
            self.directory = directory
            order = handles
            queued = Set(handles)
        }

        func prioritize(_ handles: [UInt32]) {
            lock.withLock {
                let wanted = handles.filter { queued.contains($0) }
                guard !wanted.isEmpty else { return }
                let set = Set(wanted)
                order = wanted + order.filter { !set.contains($0) }
            }
        }

        func next(_ count: Int) -> [UInt32] {
            lock.withLock {
                let batch = Array(order.prefix(count))
                order.removeFirst(batch.count)
                batch.forEach { queued.remove($0) }
                return batch
            }
        }

        func record(_ infos: [MtpObjectInfo]) {
            lock.withLock { for info in infos { got[info.handle] = info } }
        }

        func filled(_ handles: Set<UInt32>) -> [UInt32: MtpObjectInfo] {
            lock.withLock { got.filter { handles.contains($0.key) } }
        }

        /// Done, or stopped (the window went to another folder): nothing more will come.
        var isFinished: Bool { lock.withLock { finished } }
        func finish() { lock.withLock { finished = true } }
    }

    private var pendingDetails: PendingDetails? {
        get { lock.withLock { _pendingDetails } }
        set { lock.withLock { _pendingDetails = newValue } }
    }
    private var _pendingDetails: PendingDetails?

    public func currentActivity() -> FSActivity? {
        let (running, queued) = worker.snapshot()
        let work: FSActivity.Work? = running.map {
            switch $0.priority {
            case .interactive: .browsing
            case .details: .details
            case .transfer: .transfer
            }
        }
        // Right after taking the phone from macOS's photo service it's usually still listing
        // every photo for it (QUIRKS H1); a browse that's been waiting a while is waiting on that.
        let now = Date()
        let finishingEarlier = tookOverFromPtpcamerad && now.timeIntervalSince(connectedAt) < 90
            && work == .browsing && running.map { now.timeIntervalSince($0.since) > 1.5 } == true
        return FSActivity(current: work, since: running?.since, queuedBrowsing: queued,
                          finishingEarlierRequest: finishingEarlier)
    }

    public func prioritizeDetails(_ refs: [RemoteRef]) {
        guard let pending = pendingDetails else { return }
        pending.prioritize(refs.compactMap { ref in
            ref.parentPath == pending.directory ? ref.handle.map { UInt32($0) } : nil
        })
    }

    /// Per-object ObjectInfo in small chunks, visible rows first. Slower in total than one
    /// bulk request when the phone has the answers cached, but a bulk size request on a big,
    /// busy folder can take 20 s and can't be interrupted (QUIRKS M2).
    private func fillDetailsInChunks(_ names: [RemoteEntry], directory: String, token: CancelToken,
                                     continuation: AsyncThrowingStream<[RemoteEntry], Error>.Continuation) async throws {
        let byHandle = Dictionary(names.compactMap { entry in entry.ref.handle.map { (UInt32($0), entry) } },
                                  uniquingKeysWith: { a, _ in a })
        let pending = PendingDetails(directory: directory, handles: names.compactMap { $0.ref.handle.map { UInt32($0) } })
        pendingDetails = pending
        defer { pending.finish() }
        var chunker = DetailsChunker()
        while !token.isCancelled {
            let batch = pending.next(chunker.size)
            if batch.isEmpty { break }
            let started = ContinuousClock.now
            let infos = try await worker.run(.details, token: token) { session -> [MtpObjectInfo] in
                // An item deleted on the phone since the names were listed just drops out.
                try batch.compactMap { handle in
                    try Self.infoIfExists(session, handle)
                }
            }
            chunker.answered(batch.count, in: (ContinuousClock.now - started) / .seconds(1))
            pending.record(infos)
            continuation.yield(infos.compactMap { info in
                guard let entry = byHandle[info.handle] else { return nil }
                return RemoteEntry(ref: entry.ref, name: entry.name, kind: entry.kind,
                                   size: entry.isDirectory ? nil : info.size, modified: info.modified)
            })
        }
    }

    public func entry(at ref: RemoteRef) async throws -> RemoteEntry {
        let node = try await resolve(ref)
        if node.handle == Self.rootHandle {
            return RemoteEntry(ref: ref, name: ref.name, kind: .directory, size: nil, modified: nil)
        }
        let handle = node.handle
        guard let info = try await worker.run(.interactive, { try Self.infoIfExists($0, handle) }) else {
            paths.forget(ref.path)
            throw DeviceFSError.notFound(ref.path)
        }
        return RemoteEntry(ref: ref, name: info.name, kind: info.isFolder ? .directory : .file,
                           size: info.isFolder ? nil : info.size, modified: info.modified)
    }

    // MARK: Transfer

    public func download(_ entry: RemoteEntry, to destination: URL, replacing: Bool?,
                         progress: @escaping @Sendable (Int) -> Void) async throws {
        let node = try await resolve(entry.ref)
        let partial = try PartialDownload.open(for: destination, replacing: replacing)
        do {
            try await readContents(entry, node: node, sink: { try partial.write($0) }, progress: progress)
        } catch {
            partial.abandon()
            throw error
        }
        try partial.finish(modified: entry.modified)
    }

    public func read(_ entry: RemoteEntry, into fd: Int32, progress: @escaping @Sendable (Int) -> Void) async throws {
        let node = try await resolve(entry.ref)
        try await readContents(entry, node: node, sink: { try writeFully(fd, $0) }, progress: progress)
    }

    public func read(_ entry: RemoteEntry, range: Range<UInt64>, chunk: @escaping @Sendable (Data) -> Void) async throws {
        guard let size = entry.size, range.upperBound <= size else { throw DeviceFSError.notFound(entry.ref.path) }
        let handle = try await resolve(entry.ref).handle
        var offset = range.lowerBound
        while offset < range.upperBound {
            try Task.checkCancellation()
            let start = offset
            // Small pieces: a player waits for the first bytes, and asks for other parts
            // while it plays.
            let wanted = min(range.upperBound - start, MtpTuning.rangeChunk)
            let data = try await worker.run(.transfer) { session -> Data in
                var data = Data()
                _ = try session.readChunk(handle, size: size, offset: start, maxLength: wanted) { data.append(contentsOf: $0) }
                return data
            }
            offset += UInt64(data.count)
            chunk(data)
        }
    }

    public func storedThumbnail(of entry: RemoteEntry) async throws -> Data? {
        guard deviceInfo.operations.contains(PTPOp.getThumb.rawValue) else { return nil }
        let handle = try await resolve(entry.ref).handle
        do {
            let data = try await worker.run(.interactive) { try $0.thumbnail(handle) }
            return data.isEmpty ? nil : Data(data)
        } catch MtpError.response {
            return nil // none for this file
        }
    }

    /// The file's bytes in order, a chunk per job so browsing gets in between.
    private func readContents(_ entry: RemoteEntry, node: Node, sink: @escaping @Sendable (UnsafeRawBufferPointer) throws -> Void,
                              progress: @escaping @Sendable (Int) -> Void) async throws {
        let size: UInt64
        if let known = entry.size, !entry.isPartial { size = known } else { size = try await self.entry(at: entry.ref).size ?? 0 }
        var offset: UInt64 = 0
        let handle = node.handle
        var chunker = ReadChunker()
        while offset < size {
            try Task.checkCancellation() // pause/cancel lands between chunks
            let start = offset
            let chunk = chunker.size(browsing: worker.browsedRecently(within: MtpTuning.browsingQuiet))
            let (sent, seconds) = try await worker.run(.transfer) { session -> (UInt64, Double) in
                let began = ContinuousClock.now
                let sent = try session.readChunk(handle, size: size, offset: start, maxLength: chunk, sink: sink)
                return (sent, (ContinuousClock.now - began) / .seconds(1))
            }
            chunker.read(sent, of: chunk, in: seconds)
            offset += sent
            progress(Int(sent))
        }
    }

    /// SendObjectInfo + SendObject under a hidden name, renamed into place once complete:
    /// an interrupted upload (unplugged, app quit) leaves only that hidden partial file, never
    /// a truncated file under the real name, and a file being replaced stays until the new
    /// one is complete and checked. The whole file is one transaction, so browsing waits
    /// until it's done. Going straight
    /// (see `UploadWriting`) sends under the real name and, when replacing, deletes the
    /// original first: MTP has no overwrite.
    ///
    /// Nothing here lists the folder when the caller says what's there: a file to replace is
    /// found through the path cache (filled when the folder was listed for planning) and
    /// checked by name on the phone. Listing a folder of thousands for every file made
    /// uploads into it slower with every file.
    public func upload(_ source: URL, to destination: RemoteRef, modified: Date?, replacing: Bool?,
                       writing: UploadWriting, progress: @escaping @Sendable (Int) -> Void) async throws {
        let fd = Darwin.open(source.path, O_RDONLY)
        guard fd >= 0 else { throw DeviceFSError.localRead("\(source.path): \(errnoDescription())") }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw DeviceFSError.localRead("\(source.path): \(errnoDescription())") }
        try await send(fd, size: UInt64(info.st_size), streamed: false, to: destination, modified: modified,
                       replacing: replacing, writing: writing, progress: progress)
    }

    public func upload(from fd: Int32, size: UInt64, to destination: RemoteRef, modified: Date?, replacing: Bool?,
                       writing: UploadWriting, progress: @escaping @Sendable (Int) -> Void) async throws {
        try await send(fd, size: size, streamed: true, to: destination, modified: modified, replacing: replacing,
                       writing: writing, progress: progress)
    }

    /// `upload` from a file this Mac opened, or from a stream (`streamed`: another device's
    /// file on its way, `LocalPipe`). SendObject reads exactly `size` bytes; a stream that
    /// ends sooner gets the rest as zeros so the phone isn't left waiting (QUIRKS M11), and
    /// one that goes on longer (the file changed since it was listed) fails too; either way the
    /// partial file is deleted.
    private func send(_ fd: Int32, size: UInt64, streamed: Bool, to destination: RemoteRef, modified: Date?, replacing: Bool?,
                      writing: UploadWriting, progress: @escaping @Sendable (Int) -> Void) async throws {
        guard let parentPath = destination.parentPath, Self.fitsPTPString(destination.name), FileNames.isAllowed(destination.name) else {
            throw DeviceFSError.invalidName(destination.name)
        }
        let parent = try await resolve(RemoteRef(path: parentPath))
        let name = destination.name
        try Task.checkCancellation()
        if replacing == false, try await knownFile(destination, in: parent) { throw DeviceFSError.alreadyExists(name) }
        let original = replacing == false ? nil : try await existingFile(destination, in: parent)
        let straight = writing.isStraight(replacing: original != nil)
        // Going straight over a file, the original is deleted in the same job that sends the
        // new one: a cancel can't land in between and leave neither.
        let deleteFirst = straight ? original?.handle : nil
        if deleteFirst != nil { paths.forget(destination.path) }
        // Unique and independent of the name: never in the way of another upload, and never
        // longer than the name allows.
        let sentName = straight ? name : WorkNames.step("part")
        let handle: UInt32
        do {
            handle = try await worker.run(.transfer) { session -> UInt32 in
                if let deleteFirst { try session.delete(deleteFirst) }
                // SendObject must follow its SendObjectInfo with nothing in between.
                let handle: UInt32
                do {
                    handle = try Self.sendObjectInfo(session, name: sentName, size: size, parent: parent, modified: modified,
                                                     justFreed: straight && original != nil)
                } catch {
                    throw ObjectInfoRefused(underlying: error)
                }
                do {
                    try session.sendObject(from: fd, size: size) { progress($0) }
                    if streamed { try Self.expectEnd(fd, after: size) }
                    // It's renamed into place next; make sure the handle really is this file.
                    let info = try Self.verify(handle, isNamed: sentName, in: session)
                    if let modified, let stored = info.modified, abs(stored.timeIntervalSince(modified)) > 2 {
                        self.lock.withLock { self.uploadDatesIgnored = true }
                    }
                } catch {
                    // The object exists from SendObjectInfo on; don't leave a partial file on
                    // the phone when it can still be asked to delete it.
                    if !Self.isConnectionGone(error) { try? session.delete(handle) }
                    throw error
                }
                return handle
            }
        } catch let refused as ObjectInfoRefused {
            // Planned as a new file, but one turned up since: Android refuses a second object
            // of the same name (0x2002), and it isn't overwritten.
            if straight, original == nil, await isThere(destination, in: parent) {
                throw DeviceFSError.alreadyExists(name)
            }
            throw refused.underlying
        }
        let placed = Node(storage: parent.storage, handle: handle, isDirectory: false)
        if straight {
            paths.remember([(destination.path, placed)])
            return
        }
        if let original {
            // The new file is complete and checked; only now does the original go. MTP can't
            // rename onto a taken name (QUIRKS M13, M20), so it's deleted first. If the
            // connection drops in between, the new file waits under its partial name and
            // copying again finishes the job (the user chose to replace it anyway). Not dropped by
            // a pause arriving now, which would leave the new file under its partial name.
            try await Task { try await self.worker.run(.interactive) { session in
                // Still that file? Never delete through a handle that's changed (QUIRKS M19).
                var deleted = false
                if let info = try Self.infoIfExists(session, original.handle), FolderNames.same(info.name, name) {
                    try session.delete(original.handle)
                    deleted = true
                }
                // Only a name this delete freed is cleared again; anything else there stays.
                try Self.retryingFreedName(name, in: parent, session: session, enabled: deleted) {
                    try session.rename(handle, to: name)
                }
            } }.value
            paths.forget(destination.path)
        } else {
            do {
                // Not dropped by a pause either: SendObject can't be stopped halfway, so a pause
                // during it lands here, and the file it waited for would be thrown away and sent
                // all over again on resume.
                try await Task { try await self.worker.run(.interactive) { try $0.rename(handle, to: name) } }.value
            } catch {
                _ = await Task { try? await self.worker.run(.interactive) { try $0.delete(handle) } }.value
                // Planned as a new file, but one turned up since: it isn't overwritten.
                if await isThere(destination, in: parent) { throw DeviceFSError.alreadyExists(name) }
                throw error
            }
        }
        paths.remember([(destination.path, placed)])
    }

    /// Waits for the stream to end (the other device finishing its file): anything more
    /// means the file was longer than its listed size.
    private static func expectEnd(_ fd: Int32, after size: UInt64) throws {
        var byte: UInt8 = 0
        while true {
            let n = Darwin.read(fd, &byte, 1)
            if n == 0 { return }
            if n < 0, errno == EINTR { continue }
            throw DeviceFSError.localRead(n < 0 ? errnoDescription() : "more than the \(size) bytes expected")
        }
    }

    /// SendObjectInfo. With `justFreed` (the name's previous file was deleted just before), a
    /// refusal means that delete didn't take: on a Galaxy, deleting a file right after it was
    /// renamed can report success and leave it (QUIRKS G10). Then whatever the phone still
    /// has under the name is deleted again and the name tried once more.
    private static func sendObjectInfo(_ session: MtpSession, name: String, size: UInt64, parent: Node,
                                       modified: Date?, justFreed: Bool) throws -> UInt32 {
        try retryingFreedName(name, in: parent, session: session, enabled: justFreed) {
            try session.sendObjectInfo(name: name, size: size, storage: parent.storage,
                                       parent: parent.handle, modified: modified)
        }
    }

    /// Runs `body`, which puts something under `name` just freed by a delete. If the phone
    /// refuses the name (QUIRKS G10), deletes what it still lists under it and tries again.
    private static func retryingFreedName<T>(_ name: String, in parent: Node, session: MtpSession, enabled: Bool,
                                             _ body: () throws -> T) throws -> T {
        let wait = MtpTuning.freedNameWait
        var attempt = 1
        while true {
            do {
                let result = try body()
                if attempt > 1 { mtpLog.notice("name free after \(attempt, privacy: .public) tries") }
                return result
            } catch MtpError.response(_, PTPResponse.generalError) where enabled && attempt < wait.attempts {
                attempt += 1
                let left = try namedFiles(name, in: parent, session: session)
                if !left.isEmpty { mtpLog.notice("deleted file still listed; deleting it again") }
                for handle in left { try session.delete(handle) }
                Thread.sleep(forTimeInterval: wait.interval / .seconds(1))
            }
        }
    }

    /// Files called `name` directly in `parent`, from one request for the folder's names.
    private static func namedFiles(_ name: String, in parent: Node, session: MtpSession) throws -> [UInt32] {
        let items = parent.handle == rootHandle
            ? try session.objectHandles(storage: parent.storage, parent: parent.handle).compactMap { try infoIfExists(session, $0) }
            : try session.objectPropListByProperty(children: parent.handle, properties: [MTPProp.objectFileName, MTPProp.objectFormat])
        // Deleted by name, so the name is confirmed (QUIRKS G11).
        return try items.filter { FolderNames.same($0.name, name) && !$0.isFolder }.map(\.handle).filter { handle in
            try currentName(session, handle).map { FolderNames.same($0, name) } ?? false
        }
    }

    /// An item's name as the phone has it now (ObjectInfo); nil if it's gone. The bulk listing
    /// (GetObjectPropList) can still give the name from before a rename (QUIRKS G11).
    private static func currentName(_ session: MtpSession, _ handle: UInt32) throws -> String? {
        try infoIfExists(session, handle)?.name
    }

    /// The file at `ref` now, if any: from the path cache (or one listing of its folder),
    /// confirmed on the phone by name and folder before anything is done through its handle
    /// (QUIRKS M19). A cached handle that no longer matches is forgotten and looked up again.
    private func existingFile(_ ref: RemoteRef, in parent: Node) async throws -> Node? {
        for _ in 0..<2 {
            let node: Node
            do {
                node = try await resolve(ref)
            } catch DeviceFSError.notFound {
                return nil
            }
            if node.isDirectory { throw DeviceFSError.alreadyExists(ref.name) }
            let current = try await worker.run(.interactive) { session -> Bool in
                guard let info = try Self.infoIfExists(session, node.handle) else { return false }
                return Self.info(info, isNamed: ref.name, in: parent.handle)
            }
            if current { return node }
            paths.forget(ref.path)
        }
        return nil
    }

    /// After the phone refused to create `ref` (a name it holds, M20): whether something is
    /// there now, so the refusal is reported as "already exists" rather than as an error code.
    private func isThere(_ ref: RemoteRef, in parent: Node) async -> Bool {
        do {
            return try await existingFile(ref, in: parent) != nil
        } catch DeviceFSError.alreadyExists {
            return true // a folder
        } catch {
            return false
        }
    }

    /// The item is called `name` (as the phone compares names) directly in `parent`. Items at
    /// a storage's top report parent 0 (or the root handle on some phones), as Move/CopyObject
    /// take 0 for the top (QUIRKS M15).
    static func info(_ info: MtpObjectInfo, isNamed name: String, in parent: UInt32) -> Bool {
        let inParent = info.parent == parent || (parent == rootHandle && info.parent == 0)
        return FolderNames.same(info.name, name) && inParent
    }

    /// Planned as new, but a file of that name is in the path cache and still on the phone: an
    /// MTP rename or copy onto it would replace it when the name differs only in case (the
    /// phone's server tells them apart, its storage doesn't; QUIRKS S7). Asks the phone only
    /// when the cache knows the name, so planned uploads still don't list the folder.
    private func knownFile(_ ref: RemoteRef, in parent: Node) async throws -> Bool {
        guard paths.node(at: ref.path) != nil else { return false }
        return try await existingFile(ref, in: parent) != nil
    }

    /// Runs `body` to create `destination` in `parent`. What's there is taken from the plan
    /// when the caller knows it, otherwise from listing the folder.
    private func placing(_ destination: RemoteRef, in parent: Node, path parentPath: String, replacing: Bool?,
                         _ body: () async throws -> Void) async throws {
        switch replacing {
        case nil:
            try await self.replacing(destination.name, in: parent, path: parentPath, body)
        case true?:
            guard let original = try await existingFile(destination, in: parent) else { return try await body() }
            try await moveAside(original, named: destination.name, at: destination.path, body)
        case false?:
            if try await knownFile(destination, in: parent) { throw DeviceFSError.alreadyExists(destination.name) }
            do {
                try await body()
            } catch MtpError.response(let op, PTPResponse.generalError) {
                // Planned as free, but something turned up since: it isn't replaced (M20).
                if await isThere(destination, in: parent) { throw DeviceFSError.alreadyExists(destination.name) }
                throw MtpError.response(op: op, code: PTPResponse.generalError)
            }
        }
    }

    /// Runs `body` to create `name` in `parent`, finding what's there by listing the folder.
    private func replacing(_ name: String, in parent: Node, path parentPath: String,
                           _ body: () async throws -> Void) async throws {
        let siblings = try await listNames(parent, path: parentPath, token: nil)
        guard let existing = siblings.first(where: { FolderNames.same($0.name, name) }) else { return try await body() }
        if existing.isDirectory { throw DeviceFSError.alreadyExists(name) }
        try await moveAside(try await resolve(existing.ref), named: name, at: existing.ref.path, body)
    }

    /// Runs `body` to create `name` where `original` is, for copies and moves on the phone:
    /// Copy/MoveObject keep the item's name, so the name must be free before the new item
    /// exists. The original is renamed to a hidden name first and deleted only after `body`
    /// succeeds; if `body` fails it gets its name back (deleting first would lose it whenever
    /// the copy fails). If the connection drops inside `body`, the original stays under its
    /// hidden `WorkNames.aside` name; planning tidies it (`tidyLeftovers`). QUIRKS M13.
    /// (Uploads don't need this: the new file is complete under another name first.)
    private func moveAside(_ original: Node, named name: String, at path: String,
                           _ body: () async throws -> Void) async throws {
        let handle = original.handle
        let aside = WorkNames.aside(name)
        try await worker.run(.interactive) { try $0.rename(handle, to: aside) }
        paths.forget(path)
        do {
            try await body()
        } catch {
            _ = await Task { try? await self.worker.run(.interactive) { try $0.rename(handle, to: name) } }.value
            paths.remember([(path, original)])
            throw error
        }
        // Not dropped by a pause arriving now (that would leave the original hidden on the phone).
        _ = await Task { try? await self.worker.run(.interactive) { try $0.delete(handle) } }.value
    }

    /// PTP strings hold at most 254 UTF-16 units plus the terminator; a longer name would be
    /// cut short on the phone and no longer match what we asked for.
    static func fitsPTPString(_ name: String) -> Bool {
        name.utf16.count <= 254
    }

    /// A handle the phone returned for something we just created must name that thing before
    /// we rename or delete through it: a Galaxy returned an unrelated file's handle for
    /// CopyObject (QUIRKS G5, M19), and acting on such a handle would change the user's files.
    @discardableResult
    static func verify(_ handle: UInt32, isNamed name: String, in session: MtpSession) throws -> MtpObjectInfo {
        let info = try session.objectInfo(handle)
        guard info.name == name else {
            throw MtpError.protocolViolation("the phone returned a handle for “\(info.name)” instead of “\(name)”")
        }
        return info
    }

    public func isConnectionLoss(_ error: Error) -> Bool { Self.isConnectionGone(error) }

    /// The phone can't be reached any more, so there's no point asking it to clean up.
    public static func isConnectionGone(_ error: Error) -> Bool {
        isTimeout(error) || isUsbFailure(error)
    }

    /// CopyObject / MoveObject into the destination's folder, then a rename if the name
    /// changes. An existing file of that name is deleted first (MTP can't overwrite).
    /// Android's CopyObject only handles plain files into another folder under the same name
    /// (folders: 0x2002; same folder: it copies onto the original). Folders are copied item
    /// by item; renamed copies go through a temporary file on this Mac. QUIRKS M14.
    public func copyOnDevice(_ source: RemoteRef, to destination: RemoteRef, replacing: Bool?) async throws {
        let node = try await resolve(source)
        if node.isDirectory {
            try await makeDirectory(destination)
            // Names and kinds are all a copy needs; no sizes and dates to wait for.
            let children = try await listNames(node, path: source.path, token: nil)
            for child in children {
                try Task.checkCancellation()
                // Into a folder just made: nothing's in the way.
                try await copyOnDevice(child.ref, to: destination.appending(child.name), replacing: false)
            }
        } else if source.name == destination.name, source.parentPath != destination.parentPath {
            try await relocate(source, to: destination, copy: true, replacing: replacing)
        } else {
            try await copyThroughMac(source, to: destination, replacing: replacing)
        }
    }

    private func copyThroughMac(_ source: RemoteRef, to destination: RemoteRef, replacing: Bool?) async throws {
        let entry = try await self.entry(at: source)
        let temp = WorkNames.scratch()
        defer { try? FileManager.default.removeItem(at: temp) }
        try await download(entry, to: temp) { _ in }
        try await upload(temp, to: destination, modified: entry.modified, replacing: replacing, writing: .safe) { _ in }
    }

    public func moveOnDevice(_ source: RemoteRef, to destination: RemoteRef, replacing: Bool?) async throws {
        try await relocate(source, to: destination, copy: false, replacing: replacing)
    }

    /// `replacing`, when known, saves listing the destination folder for every file: as for
    /// uploads, in a folder of thousands that listing is most of what each copy costs.
    private func relocate(_ source: RemoteRef, to destination: RemoteRef, copy: Bool, replacing: Bool?) async throws {
        guard let parentPath = destination.parentPath else { throw DeviceFSError.invalidName(destination.path) }
        let node = try await resolve(source)
        let parent = try await resolve(RemoteRef(path: parentPath))
        let handle = node.handle
        // Android takes 0 as "the storage root" for Move/CopyObject (QUIRKS M15).
        let parentHandle = parent.handle == Self.rootHandle ? 0 : parent.handle
        try await placing(destination, in: parent, path: parentPath, replacing: replacing) {
            // MoveObject keeps the item's name, and the phone refuses it (0x2002) when the
            // destination folder already has something by that name, even though it's renamed
            // right after. Give it a temporary name in place first. (Copies under another name
            // don't come here; they go through this Mac.) QUIRKS M15. A planned move only gets
            // another name because its own is taken there ("keep both"), so with a plan there's
            // nothing to look up.
            var renamedInPlace = false
            var nameTaken = false
            if !copy, source.name != destination.name, source.parentPath != parentPath {
                nameTaken = replacing != nil
                    ? true : try await self.listNames(parent, path: parentPath, token: nil).contains(where: { $0.name == source.name })
            }
            if nameTaken {
                let temporary = WorkNames.moving(source.name)
                try await self.worker.run(.interactive) { try $0.rename(handle, to: temporary) }
                renamedInPlace = true
            }
            let result: UInt32
            do {
                result = try await self.worker.run(.transfer) { session -> UInt32 in
                    if copy {
                        return try session.copy(handle, storage: parent.storage, parent: parentHandle)
                    }
                    try session.move(handle, storage: parent.storage, parent: parentHandle)
                    return handle
                }
            } catch {
                if renamedInPlace {
                    let name = source.name
                    _ = await Task { try? await self.worker.run(.interactive) { try $0.rename(handle, to: name) } }.value
                }
                throw error
            }
            if copy {
                // Don't trust the handle CopyObject returns: a Galaxy (Z Flip5, Android 16)
                // answered with the handle of an unrelated file, which would then be read,
                // replaced or deleted in place of the copy (QUIRKS G5). Use it only when it
                // names the copy, in the copy's folder; otherwise the copy is looked up by path
                // when it's next needed (the phone answered OK, so it's there; listing the
                // folder here made a whole-folder copy list its growing destination per file).
                // Copies under another name don't come here, so the name is the source's.
                // Checked even when a pause arrives now: the copy is made, and without the check it
                // would count as not done and be copied again ("already exists").
                self.paths.forget(destination.path)
                let parentHandle = parent.handle
                try await Task {
                    let isTheCopy = try await self.worker.run(.interactive) { session -> Bool in
                        guard let info = try Self.infoIfExists(session, result) else { return false }
                        return Self.info(info, isNamed: destination.name, in: parentHandle)
                    }
                    if isTheCopy {
                        self.paths.remember([(destination.path, Node(storage: parent.storage, handle: result, isDirectory: false))])
                    }
                }.value
                return
            }
            if source.name != destination.name {
                // The item has left its folder: give it its name even if the job was paused or
                // cancelled meanwhile, or it'd stay under a hidden temporary name.
                let name = destination.name
                try await Task { try await self.worker.run(.interactive) { try $0.rename(result, to: name) } }.value
            }
            self.paths.forget(source.path)
            self.paths.forget(destination.path)
            self.paths.remember([(destination.path, Node(storage: parent.storage, handle: result, isDirectory: node.isDirectory))])
        }
    }

    // MARK: File operations

    public func makeDirectory(_ ref: RemoteRef) async throws {
        var names: [String: Set<String>] = [:]
        guard try await make(ref, names: &names) else { throw DeviceFSError.alreadyExists(ref.name) }
    }

    /// One listing for each parent that was there already; the folders made here are known empty.
    public func makeDirectories(_ refs: [RemoteRef]) async throws {
        var names: [String: Set<String>] = [:]
        for ref in refs { _ = try await make(ref, names: &names) }
    }

    /// Makes the folder `ref` unless its parent has something by that name (false). `names`: what
    /// each parent has, by path, listed when first needed.
    private func make(_ ref: RemoteRef, names: inout [String: Set<String>]) async throws -> Bool {
        guard let parentPath = ref.parentPath, Self.fitsPTPString(ref.name), FileNames.isAllowed(ref.name) else { throw DeviceFSError.invalidName(ref.name) }
        let parent = try await resolve(RemoteRef(path: parentPath))
        let name = ref.name
        if names[parentPath] == nil {
            names[parentPath] = Set(try await listNames(parent, path: parentPath, token: nil).map(\.name))
        }
        guard names[parentPath]?.contains(name) != true else { return false }
        let handle = try await worker.run(.interactive) { session in
            let handle = try session.createFolder(named: name, storage: parent.storage, parent: parent.handle)
            try Self.verify(handle, isNamed: name, in: session)
            return handle
        }
        paths.remember([(ref.path, Node(storage: parent.storage, handle: handle, isDirectory: true))])
        names[parentPath, default: []].insert(name)
        names[ref.path] = []
        return true
    }

    public func rename(_ ref: RemoteRef, to newName: String) async throws -> RemoteRef {
        guard FileNames.isAllowed(newName), Self.fitsPTPString(newName),
              let parentPath = ref.parentPath else { throw DeviceFSError.invalidName(newName) }
        let node = try await resolve(ref)
        let target = RemoteRef(path: parentPath).appending(newName)
        // What's in the folder from its last listing (browsing it filled the path cache), so a
        // batch of renames doesn't list the folder each time; listed once if it wasn't. The
        // phone refuses a name that's taken exactly (QUIRKS M20) but not one in another case,
        // which it would replace (S7): that's what this catches. The item itself may change case.
        let parent = try await resolve(RemoteRef(path: parentPath))
        if paths.count(in: parentPath) == nil { _ = try await listNames(parent, path: parentPath, token: nil) }
        // Confirmed on the phone: the cache may hold something deleted since.
        if let there = paths.node(at: target.path), there.handle != node.handle,
           try await existingFile(target, in: parent) != nil {
            throw DeviceFSError.alreadyExists(newName)
        }
        let handle = node.handle
        if newName != ref.name, FolderNames.same(newName, ref.name) {
            // Only the case (or composition) changes: the phone reports a direct rename done but
            // the file keeps its name. Through a hidden name it takes (QUIRKS S7).
            let step = WorkNames.moving(newName), oldName = ref.name
            try await Task { try await self.worker.run(.interactive) { session in
                try session.rename(handle, to: step)
                do {
                    try session.rename(handle, to: newName)
                } catch {
                    try? session.rename(handle, to: oldName)
                    throw error
                }
            } }.value
            paths.forget(ref.path)
            paths.remember([(target.path, node)])
            return target
        }
        do {
            try await worker.run(.interactive) { try $0.rename(handle, to: newName) }
        } catch MtpError.response(let op, PTPResponse.generalError) {
            // Taken since the folder was listed (M20).
            if await isThere(target, in: parent) { throw DeviceFSError.alreadyExists(newName) }
            throw MtpError.response(op: op, code: PTPResponse.generalError)
        }
        paths.forget(ref.path)
        paths.remember([(target.path, node)])
        return target
    }

    public func delete(_ refs: [RemoteRef]) async throws {
        for ref in refs {
            let node = try await resolve(ref)
            guard node.handle != Self.rootHandle else { throw DeviceFSError.invalidName(ref.path) }
            let handle = node.handle
            try await worker.run(.interactive) { try $0.delete(handle) }
            paths.forget(ref.path)
        }
    }
}

extension MtpDeviceInfo {
    /// Samsung's `samsung.com/devicestatus: N` from the vendor extension (undocumented;
    /// measured: 0 in File transfer mode, 4 when USB is set to charging only).
    public var samsungDeviceStatus: Int? {
        guard let range = vendorExtension.range(of: "samsung.com/devicestatus:") else { return nil }
        let digits = vendorExtension[range.upperBound...].drop { $0 == " " }.prefix { $0.isNumber }
        return Int(digits)
    }
}

/// SendObjectInfo was refused (nothing was created).
private struct ObjectInfoRefused: Error {
    let underlying: Error
}
