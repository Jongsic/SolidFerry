import CryptoKit
import Foundation

/// MD5 of a local file, streamed. MD5 only to match `md5sum` on the device; not for security.
/// Stops with `CancellationError` when the task is cancelled (checked every megabyte), so
/// pausing doesn't wait for a large video to be read to the end.
public func localMD5(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = Insecure.MD5()
    while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
        if Task.isCancelled { throw CancellationError() }
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

/// MD5s of files on this Mac (nil where there's no file or it can't be read), a few at a
/// time: each is a blocking read, which shouldn't hold every thread of the shared pool (other
/// devices' work waits on those) or make a spinning disk seek between many files.
public func localMD5s(_ urls: [URL?], atOnce: Int = 3) async throws -> [Int: String] {
    try await withThrowingTaskGroup(of: (Int, String?).self) { group in
        var result: [Int: String] = [:]
        var next = 0
        func start() {
            let index = next, url = urls[next]
            next += 1
            group.addTask {
                guard let url else { return (index, nil) }
                do {
                    return (index, try localMD5(of: url))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    return (index, nil)
                }
            }
        }
        while next < min(atOnce, urls.count) { start() }
        while let (index, hash) = try await group.next() {
            result[index] = hash
            if next < urls.count { start() }
        }
        return result
    }
}
