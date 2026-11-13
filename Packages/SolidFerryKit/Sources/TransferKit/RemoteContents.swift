import DeviceCore
import Foundation

/// A device file read into memory, for looking at it without putting it on this Mac's disk.
public enum RemoteContents {
    /// More than `limit` bytes came (the file is bigger than allowed, or grew).
    public struct TooLarge: Error {
        public let limit: Int
    }

    /// Reads all of `entry` from `fs`. Needs `capabilities.streamsFiles`. Stops with
    /// `TooLarge` past `limit` bytes; cancelling stops the reading too.
    public static func data(of entry: RemoteEntry, from fs: any DeviceFileSystem, limit: Int,
                            progress: @escaping @Sendable (Int) -> Void) async throws -> Data {
        guard fs.capabilities.streamsFiles else { throw DeviceFSError.unsupported }
        let pipe = try LocalPipe()
        let reading = Task {
            defer { pipe.closeWriteEnd() }
            try await fs.read(entry, into: pipe.writeEnd, progress: progress)
        }
        let expected = entry.size.map { Int(clamping: $0) } ?? 0
        let collected: Result<Data, Error> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    continuation.resume(returning: Result { try collect(pipe.readEnd, expected: min(expected, limit), limit: limit) })
                }
            }
        } onCancel: {
            reading.cancel()
            pipe.endReading()
        }
        // Stops the source if it's still sending (too large, or cancelled).
        pipe.closeReadEnd()
        let sourceResult = await reading.result
        if Task.isCancelled { throw CancellationError() }
        let data = try collected.get()
        try sourceResult.get()
        return data
    }

    private static func collect(_ fd: Int32, expected: Int, limit: Int) throws -> Data {
        var data = Data()
        data.reserveCapacity(expected)
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0 {
                if errno == EINTR { continue }
                throw DeviceFSError.localRead(errnoDescription())
            }
            if n == 0 { return data }
            if data.count + n > limit { throw TooLarge(limit: limit) }
            data.append(contentsOf: buffer[0..<n])
        }
    }
}
