import Darwin
import os

/// How long this app has been waiting on a disk of this Mac: writes to files (and creating,
/// stamping and renaming them) go through `during`, and `longest` tells how long the oldest
/// one still going has taken. A slow or busy disk (an external drive flushing its cache) makes
/// a download stand still while its device has the data ready; the transfers window says so
/// instead of showing no speed.
public enum DiskWait {
    private static let ongoing = OSAllocatedUnfairLock(initialState: (next: 0, started: [Int: ContinuousClock.Instant]()))

    /// Runs `body`, counted as waiting on the disk while it runs.
    public static func during<T>(_ body: () throws -> T) rethrows -> T {
        let token = ongoing.withLock { state in
            defer { state.next += 1 }
            state.started[state.next] = .now
            return state.next
        }
        defer { _ = ongoing.withLock { $0.started.removeValue(forKey: token) } }
        return try body()
    }

    /// How long the oldest disk operation still going has been waiting; nil when none is.
    public static var longest: Duration? {
        ongoing.withLock { state in state.started.values.min().map { .now - $0 } }
    }
}

/// Whether `fd` is a file on a disk (not a pipe or a socket).
func isDiskFile(_ fd: Int32) -> Bool {
    var info = stat()
    return fstat(fd, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
}
