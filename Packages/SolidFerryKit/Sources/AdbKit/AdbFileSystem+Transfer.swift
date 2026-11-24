import Darwin
import DeviceCore
import Foundation
import os

// Moving files over the sync protocol.

extension AdbFileSystem {
    public func download(_ entry: RemoteEntry, to destination: URL, replacing: Bool?,
                         progress: @escaping @Sendable (Int) -> Void) async throws {
        let client = client, serial = serial
        try await cancellableBlocking { canceller in
            let socket = try client.openService(serial: serial, "sync:")
            canceller.attach(socket)
            let sync = SyncConnection(socket: socket)
            try Self.receiveAtomically(sync, entry: entry, to: destination, replacing: replacing, progress: progress)
            sync.quit()
        }
    }

    public func read(_ entry: RemoteEntry, into fd: Int32, progress: @escaping @Sendable (Int) -> Void) async throws {
        let client = client, serial = serial
        try await cancellableBlocking { canceller in
            let socket = try client.openService(serial: serial, "sync:")
            canceller.attach(socket)
            let sync = SyncConnection(socket: socket)
            try sync.receive(entry.ref.path, to: fd, progress: progress)
            sync.quit()
        }
    }

    /// The sync protocol only reads whole files (QUIRKS A19), so a range is read with `dd`
    /// (`capabilities.readsRanges`: checked at connect). Fewer bytes than asked is the error.
    public func read(_ entry: RemoteEntry, range: Range<UInt64>, chunk: @escaping @Sendable (Data) -> Void) async throws {
        guard !range.isEmpty else { return }
        let client = client, serial = serial
        let command = "dd if=\(Self.shellQuote(entry.ref.path)) \(Self.rangeFlags) skip=\(range.lowerBound) "
            + "count=\(range.count) bs=262144 2>/dev/null"
        let received = try await cancellableBlocking(endsAtClose: true) { canceller -> UInt64 in
            let socket = try client.openService(serial: serial, "exec:" + command)
            canceller.attach(socket)
            var received: UInt64 = 0
            try socket.readUntilClosed { bytes in
                received += UInt64(bytes.count)
                chunk(Data(bytes))
            }
            return received
        }
        guard received == UInt64(range.count) else {
            throw AdbError.commandFailed("read \(received) of \(range.count) bytes at \(range.lowerBound)")
        }
    }

    /// Many files over one sync connection with pipelined requests (see `receiveMany`);
    /// each is written atomically like `download`.
    public func downloadMany(_ items: [DownloadItem],
                             progress: @escaping @Sendable (Int) -> Void,
                             completed: @escaping @Sendable (Int, Error?) -> Void) async throws {
        let client = client, serial = serial
        try await cancellableBlocking { canceller in
            var start: Int? = 0
            while let offset = start {
                let socket = try client.openService(serial: serial, "sync:")
                canceller.attach(socket)
                let sync = SyncConnection(socket: socket)
                let batch = Array(items[offset...])
                var current: PartialDownload?
                defer { current?.abandon() }
                start = try sync.receiveMany(batch.map(\.entry.ref.path), open: { i in
                    do {
                        let partial = try PartialDownload.open(for: batch[i].destination, replacing: batch[i].replacing)
                        current = partial
                        return partial.fd
                    } catch {
                        // This file can't be written here; the others still can.
                        completed(offset + i, error)
                        return -1
                    }
                }, finish: { i, failure in
                    guard let partial = current else { return }
                    current = nil
                    if let failure {
                        partial.abandon()
                        completed(offset + i, failure)
                        return
                    }
                    do {
                        try partial.finish(modified: batch[i].entry.modified)
                        completed(offset + i, nil)
                    } catch {
                        completed(offset + i, error)
                    }
                }, progress: progress).map { offset + $0 }
                if start == nil { sync.quit() }
            }
        }
    }

    /// Writes to a hidden partial file next to the destination, then renames it into place
    /// so a cancelled transfer never leaves a truncated file.
    private static func receiveAtomically(_ sync: SyncConnection, entry: RemoteEntry, to destination: URL, replacing: Bool?,
                                          progress: (Int) -> Void) throws {
        let partial = try PartialDownload.open(for: destination, replacing: replacing)
        do {
            try sync.receive(entry.ref.path, to: partial.fd, progress: progress)
        } catch {
            partial.abandon()
            throw error
        }
        try partial.finish(modified: entry.modified)
    }

    /// Sends to a hidden partial file next to the destination and renames it into place, so
    /// a file already there stays intact until the new one is complete (a failed or
    /// cancelled upload never costs the user the original). Going straight to the destination
    /// (see `UploadWriting`) saves the rename, which is a shell command of its own; copying
    /// into the file there takes the rename's place and keeps that file.
    public func upload(_ source: URL, to destination: RemoteRef, modified: Date?, replacing: Bool?,
                       writing: UploadWriting, progress: @escaping @Sendable (Int) -> Void) async throws {
        try await send(.file(source), to: destination, modified: modified, replacing: replacing, writing: writing, progress: progress)
    }

    public func upload(from fd: Int32, size: UInt64, to destination: RemoteRef, modified: Date?, replacing: Bool?,
                       writing: UploadWriting, progress: @escaping @Sendable (Int) -> Void) async throws {
        try await send(.stream(fd, size: size), to: destination, modified: modified, replacing: replacing,
                       writing: writing, progress: progress)
    }

    /// What an upload sends: a file on this Mac (to its end), or exactly `size` bytes from a
    /// stream (`LocalPipe`).
    private enum Contents: Sendable {
        case file(URL)
        case stream(Int32, size: UInt64)
    }

    private func send(_ contents: Contents, to destination: RemoteRef, modified: Date?, replacing: Bool?,
                      writing: UploadWriting, progress: @escaping @Sendable (Int) -> Void) async throws {
        let client = client, serial = serial, statV2 = statV2
        let mtime = UInt32(clamping: Int((modified ?? Date()).timeIntervalSince1970))
        guard FileNames.isAllowed(destination.name) else { throw DeviceFSError.invalidName(destination.name) }
        // Unique per upload: after an interrupted upload, adbd removes that upload's unfinished
        // file a moment later, which would take a new upload's file of the same name with it
        // (QUIRKS A12). Independent of the name, so it's never longer than the name allows.
        let partial = RemoteRef(path: destination.parentPath ?? "/").appending(WorkNames.step("part"))
        let sending = OSAllocatedUnfairLock(initialState: false)
        let straight = OSAllocatedUnfairLock(initialState: false)
        do {
            try await cancellableBlocking { canceller in
                let fd: Int32, expected: UInt64?
                switch contents {
                case .file(let source):
                    fd = Darwin.open(source.path, O_RDONLY)
                    guard fd >= 0 else { throw DeviceFSError.localRead("\(source.path): \(errnoDescription())") }
                    expected = nil
                case .stream(let stream, let size):
                    (fd, expected) = (stream, size)
                }
                defer { if case .file = contents { Darwin.close(fd) } }
                let socket = try client.openService(serial: serial, "sync:")
                canceller.attach(socket)
                let sync = SyncConnection(socket: socket)
                var direct = false
                if replacing == true {
                    direct = writing.isStraight(replacing: true)
                } else if writing.isStraight(replacing: false) || writing.isStraight(replacing: true) {
                    // adbd deletes a file it's about to receive over, so going straight needs
                    // to know whether one is there (a stat on this connection, about a millisecond).
                    let there = Self.exists(destination.path, sync: sync, v2: statV2)
                    if there == true, replacing == false { throw DeviceFSError.alreadyExists(destination.name) }
                    // Couldn't tell: the temporary name, which doesn't need to know.
                    direct = there.map { writing.isStraight(replacing: $0) } ?? false
                }
                let decided = direct
                straight.withLock { $0 = decided }
                sending.withLock { $0 = true }
                try sync.send(from: fd, to: direct ? destination.path : partial.path, mtime: mtime, expected: expected,
                              progress: progress)
                sync.quit()
            }
            if !straight.withLock({ $0 }) {
                let from = Self.shellQuote(partial.path), to = Self.shellQuote(destination.path)
                if replacing == false {
                    // Planned as a new file: one that turned up since isn't overwritten.
                    try await runIfFree(destination, "mv -f -- \(from) \(to)")
                } else {
                    // Its date is set again once it's in place: renamed over a file, it takes the
                    // time it's first read (QUIRKS A23); copied into one, the time of copying.
                    let date = modified.map { " && touch -m -d \($0.formatted(.iso8601)) -- \(to)" } ?? ""
                    if writing.replacedFile == .intoExisting {
                        // Copied into the file there, which stays the same file (QUIRKS A22). A
                        // link, or nothing there, is replaced as usual.
                        try await run("if [ -f \(to) ] && [ ! -L \(to) ]; then cat -- \(from) > \(to) && rm -f -- \(from); "
                            + "else mv -f -- \(from) \(to); fi\(date)")
                    } else {
                        try await run("mv -f -- \(from) \(to)\(date)")
                    }
                }
            }
        } catch {
            if sending.withLock({ $0 }) {
                // Outside this (possibly cancelled) task, or the cleanup itself would be cancelled.
                if straight.withLock({ $0 }) {
                    // adbd deletes the unfinished file itself, a moment later; wait for that so
                    // sending the same name again right away isn't deleted with it (QUIRKS A12).
                    let path = destination.path
                    _ = await Task { await self.waitUntilGone(path) }.value
                } else {
                    let partialPath = partial.path
                    _ = await Task { try? await self.run("rm -f -- " + Self.shellQuote(partialPath)) }.value
                }
            }
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    /// Whether something is at `path`; nil when the check itself failed.
    private static func exists(_ path: String, sync: SyncConnection, v2: Bool) -> Bool? {
        do {
            _ = try sync.stat(path, v2: v2)
            return true
        } catch AdbError.remoteError(_, 2) {
            return false
        } catch {
            return nil
        }
    }

    /// Waits up to a few seconds for adbd to remove a file whose upload failed.
    private func waitUntilGone(_ path: String) async {
        for _ in 0..<15 {
            guard (try? await entry(at: RemoteRef(path: path))) != nil else { return }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }
}
