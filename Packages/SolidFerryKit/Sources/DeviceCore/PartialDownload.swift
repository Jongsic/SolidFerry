import Darwin
import Foundation

/// A download written under a hidden name next to its destination (`partialDownloadURL`) and
/// put in place only when complete, stamped with the phone's date: a stopped transfer never
/// leaves a truncated file under the real name. A file at the destination is replaced only
/// when the download was planned to (or, not knowing, when it was there as the download started);
/// one that turned up since stays (another download of the same name finished first).
public struct PartialDownload: Sendable {
    public let destination: URL
    public let url: URL
    /// Where to write the contents.
    public let fd: Int32
    /// The file at the destination is replaced.
    let replaces: Bool

    /// Creates (or empties) the partial file. Another download writing the same one at the
    /// same time (same name, same folder) is refused as `alreadyExists`.
    public static func open(for destination: URL, replacing: Bool?) throws -> PartialDownload {
        try DiskWait.during { try opening(destination, replacing: replacing) }
    }

    private static func opening(_ destination: URL, replacing: Bool?) throws -> PartialDownload {
        let url = partialDownloadURL(for: destination)
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT, 0o644)
        guard fd >= 0 else { throw DeviceFSError.localWrite("\(url.path): \(errnoDescription())") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw DeviceFSError.alreadyExists(destination.lastPathComponent)
        }
        guard ftruncate(fd, 0) == 0 else {
            let reason = errnoDescription()
            close(fd)
            throw DeviceFSError.localWrite("\(url.path): \(reason)")
        }
        return PartialDownload(destination: destination, url: url, fd: fd,
                               replaces: replacing ?? FileManager.default.fileExists(atPath: destination.path))
    }

    /// Writes all of `bytes`.
    public func write(_ bytes: UnsafeRawBufferPointer) throws {
        try DiskWait.during { try writeAll(bytes) }
    }

    private func writeAll(_ bytes: UnsafeRawBufferPointer) throws {
        var written = 0
        while written < bytes.count {
            let n = Darwin.write(fd, bytes.baseAddress! + written, bytes.count - written)
            if n < 0 {
                if errno == EINTR { continue }
                throw DeviceFSError.localWrite("\(url.path): \(errnoDescription())")
            }
            written += n
        }
    }

    /// Stamps `modified` (best effort: the file is right without it), closes and renames into
    /// place. Closes the file on every path; removes it if it can't be put in place.
    public func finish(modified: Date?) throws {
        try DiskWait.during { try finishing(modified: modified) }
    }

    private func finishing(modified: Date?) throws {
        if let modified {
            let seconds = Int(modified.timeIntervalSince1970)
            var times = [timeval(tv_sec: seconds, tv_usec: 0), timeval(tv_sec: seconds, tv_usec: 0)]
            futimes(fd, &times)
        }
        var placed = renamex_np(url.path, destination.path, replaces ? 0 : UInt32(RENAME_EXCL)) == 0
        var failure = errno
        if !placed, failure == ENOTSUP { // a volume without it (some network and FAT disks)
            if FileManager.default.fileExists(atPath: destination.path) {
                failure = EEXIST
            } else {
                placed = Darwin.rename(url.path, destination.path) == 0
                failure = errno
            }
        }
        // Removed while still locked, so another download of the name can't open it in between.
        if !placed { unlink(url.path) }
        close(fd)
        guard placed else {
            if failure == EEXIST { throw DeviceFSError.alreadyExists(destination.lastPathComponent) }
            throw DeviceFSError.localWrite("\(destination.path): \(String(cString: strerror(failure)))")
        }
    }

    /// Closes and removes the partial file (the transfer failed or stopped).
    public func abandon() {
        unlink(url.path)
        close(fd)
    }
}

/// The C library's message for the current `errno`.
public func errnoDescription() -> String {
    String(cString: strerror(errno))
}
