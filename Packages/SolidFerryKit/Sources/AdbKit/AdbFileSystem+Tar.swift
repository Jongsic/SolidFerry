import Darwin
import DeviceCore
import Foundation
import os

// Bundled downloads: many small files as one tar stream (QUIRKS A13).

extension AdbFileSystem {
    /// Streams the files as one tar archive from the phone and writes each one as its data
    /// arrives. Files the stream didn't include (unreadable, or no tar on the phone) are
    /// fetched the usual way.
    public func downloadBundled(_ items: [DownloadItem],
                                progress: @escaping @Sendable (Int) -> Void,
                                completed: @escaping @Sendable (Int, Error?) -> Void) async throws {
        guard await tarAvailable.check(self) else {
            return try await downloadMany(items, progress: progress, completed: completed)
        }
        let done = OSAllocatedUnfairLock<Set<Int>>(initialState: [])
        let quoted = items.map { Self.shellQuote(Self.tarName($0.entry.ref.path)) }
        // One adb request carries the whole command; keep it well under its 64 KB limit.
        for range in Self.argumentBatches(quoted, limit: 48_000) {
            let batch = Array(items[range])
            let offset = range.lowerBound
            let command = "tar -cf - -C / -- " + quoted[range].joined(separator: " ") + " 2>/dev/null"
            do {
                try await streamTar(command: command, batch: batch, progress: progress) { i, error in
                    done.withLock { _ = $0.insert(offset + i) }
                    completed(offset + i, error)
                }
            } catch let error as AdbError where !Task.isCancelled && (error == .connectionClosed || {
                if case .protocolViolation = error { true } else { false } }()) {
                // The stream ended early or isn't what we expected (tar stopped, or a header
                // didn't check out): the files it didn't deliver are fetched the usual way below.
            }
        }
        let delivered = done.withLock { $0 }
        let missing = items.indices.filter { !delivered.contains($0) }
        guard !missing.isEmpty else { return }
        try await downloadMany(missing.map { items[$0] }, progress: progress) { k, error in
            completed(missing[k], error)
        }
    }

    /// "/sdcard/DCIM/a.jpg" → "sdcard/DCIM/a.jpg", as tar names it with `-C /`.
    static func tarName(_ path: String) -> String {
        String(path.drop { $0 == "/" })
    }

    private func streamTar(command: String, batch: [DownloadItem],
                           progress: @escaping @Sendable (Int) -> Void,
                           completed: @escaping @Sendable (Int, Error?) -> Void) async throws {
        let client = client, serial = serial
        var indexByName: [String: Int] = [:]
        for (i, item) in batch.enumerated() { indexByName[Self.tarName(item.entry.ref.path)] = i }
        let names = indexByName
        try await cancellableBlocking { canceller in
            let socket = try client.openService(serial: serial, "exec:" + command)
            canceller.attach(socket)
            var current: (index: Int, partial: PartialDownload)?
            defer { current?.partial.abandon() }
            try TarReader(socket: socket).read(open: { entry in
                let name = entry.name.hasPrefix("./") ? String(entry.name.dropFirst(2)) : entry.name
                guard let i = names[name] else { return nil }
                do {
                    let partial = try PartialDownload.open(for: batch[i].destination, replacing: batch[i].replacing)
                    current = (i, partial)
                    return partial.fd
                } catch {
                    // This file can't be written here; the others still can.
                    completed(i, error)
                    return nil
                }
            }, finish: { entry in
                guard let (i, partial) = current else { return }
                current = nil
                let modified = batch[i].entry.modified ?? Date(timeIntervalSince1970: TimeInterval(entry.mtime))
                do {
                    try partial.finish(modified: modified)
                    completed(i, nil)
                } catch {
                    completed(i, error)
                }
            }, progress: progress)
        }
    }
}

/// Whether the phone has a usable tar, asked once per connection.
final class TarProbe: Sendable {
    private let result = OSAllocatedUnfairLock<Bool?>(initialState: nil)

    /// Only a definite answer is remembered; a failed or cancelled check is asked again.
    func check(_ fs: AdbFileSystem) async -> Bool {
        if let cached = result.withLock({ $0 }) { return cached }
        guard let data = try? await fs.client.exec(serial: fs.serial, "tar --version 2>&1") else { return false }
        let output = String(decoding: data, as: UTF8.self)
        let available = output.contains("toybox") || output.contains("GNU tar") || output.contains("busybox")
        result.withLock { $0 = available }
        return available
    }
}
