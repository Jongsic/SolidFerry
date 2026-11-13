import DeviceCore
import Foundation
import os

/// Copying a file between two devices. Phones can't reach each other, so it goes through
/// this Mac: straight across when both connections can stream (read from one while writing to
/// the other, nothing on disk), otherwise through a temporary file deleted right away.
public enum DeviceToDevice {
    /// Reading from the source device failed (so a lost connection there is the source's).
    public struct SourceFailed: Error {
        public let underlying: Error
    }

    /// Copies `entry` from `source` to the full path `destination` on `target`, keeping its
    /// date when the target allows. `replacing` and `writing` as for `upload`. `progress`
    /// adds up to the file's size. `throughMac` takes the temporary file even when both
    /// could stream (for comparing the two).
    public static func copy(_ entry: RemoteEntry, from source: any DeviceFileSystem,
                            to destination: RemoteRef, on target: any DeviceFileSystem,
                            replacing: Bool? = nil, writing: UploadWriting = .safe, throughMac: Bool = false,
                            progress: @escaping @Sendable (Int) -> Void) async throws {
        // A streamed upload must know the exact size up front; sizes that wrap at 4 GB
        // (QUIRKS A2) can't say it.
        if !throughMac, source.capabilities.streamsFiles, target.capabilities.streamsFiles, source.capabilities.exactLargeSizes {
            var entry = entry
            if entry.size == nil || entry.isPartial {
                do { entry = try await source.entry(at: entry.ref) } catch { throw SourceFailed(underlying: error) }
            }
            if let size = entry.size {
                try await stream(entry, size: size, from: source, to: destination, on: target, replacing: replacing,
                                 writing: writing, progress: progress)
                return
            }
        }
        try await throughFile(entry, from: source, to: destination, on: target, replacing: replacing,
                              writing: writing, progress: progress)
    }

    private enum Side {
        case source, target
    }

    /// Reads from `source` into a `LocalPipe` while `target` uploads from it. Whichever side
    /// stops first closes its end, which stops the other: the target sees the stream end too
    /// soon (and puts nothing in place), the source can't write any more. The side that
    /// stopped first is the one whose error is reported.
    ///
    /// The source isn't cancelled itself: it stops when the target does. An upload that can't
    /// be interrupted halfway (MTP sends a file in one transaction) then still gets the real
    /// bytes to the end, as it would from a file, instead of zeros for the rest.
    private static func stream(_ entry: RemoteEntry, size: UInt64, from source: any DeviceFileSystem,
                               to destination: RemoteRef, on target: any DeviceFileSystem,
                               replacing: Bool?, writing: UploadWriting,
                               progress: @escaping @Sendable (Int) -> Void) async throws {
        let pipe = try LocalPipe()
        let first = OSAllocatedUnfairLock<Side?>(initialState: nil)
        let reading = Task {
            defer { pipe.closeWriteEnd() }
            do {
                try await source.read(entry, into: pipe.writeEnd) { _ in }
            } catch {
                first.withLock { $0 = $0 ?? .source }
                throw error
            }
        }
        var targetError: Error?
        do {
            try await target.upload(from: pipe.readEnd, size: size, to: destination, modified: entry.modified,
                                    replacing: replacing, writing: writing, progress: progress)
        } catch {
            first.withLock { $0 = $0 ?? .target }
            targetError = error
        }
        pipe.closeReadEnd()
        let sourceResult = await reading.result
        if case .failure(let error) = sourceResult, first.withLock({ $0 }) == .source {
            // Also when the target finished anyway: it got the right number of bytes, but the
            // source didn't vouch for them.
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw SourceFailed(underlying: error)
        }
        if let targetError { throw targetError }
    }

    /// Downloads to a temporary file on this Mac, then uploads it.
    private static func throughFile(_ entry: RemoteEntry, from source: any DeviceFileSystem,
                                    to destination: RemoteRef, on target: any DeviceFileSystem,
                                    replacing: Bool?, writing: UploadWriting,
                                    progress: @escaping @Sendable (Int) -> Void) async throws {
        let temp = WorkNames.scratch()
        defer { try? FileManager.default.removeItem(at: temp) }
        // Every byte comes in from the source and goes out to the target, so each counts half
        // (progress would otherwise stand still while it comes in).
        let remainder = OSAllocatedUnfairLock(initialState: 0)
        let half: @Sendable (Int) -> Void = { bytes in
            progress(remainder.withLock { odd in
                let total = odd + bytes
                odd = total % 2
                return total / 2
            })
        }
        do {
            try await source.download(entry, to: temp, progress: half)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SourceFailed(underlying: error)
        }
        try await target.upload(temp, to: destination, modified: entry.modified, replacing: replacing,
                                writing: writing, progress: half)
    }
}
