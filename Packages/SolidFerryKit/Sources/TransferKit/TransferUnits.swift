import DeviceCore
import Foundation

/// How a job's files go out: small downloads in batches over one connection, since per-file
/// overhead dominates them (within a batch, requests go out ahead; QUIRKS A8); everything else
/// one by one.
public enum TransferUnits {
    /// Files below this size are batched, up to `batchCount` files or `batchBytes` a batch.
    public static let smallFile: UInt64 = 1 << 20
    public static let batchCount = 64
    public static let batchBytes: UInt64 = 8 << 20

    /// `batchable`: the file may share a connection with others (a download, where the
    /// backend runs connections side by side). Units keep the files' order.
    public static func plan(_ files: [(index: Int, size: UInt64?, batchable: Bool)]) -> [[Int]] {
        var units: [[Int]] = []
        var batch: [Int] = []
        var bytes: UInt64 = 0
        for file in files {
            guard file.batchable, (file.size ?? 0) < smallFile else {
                units.append([file.index])
                continue
            }
            batch.append(file.index)
            bytes += file.size ?? 0
            if batch.count >= batchCount || bytes >= batchBytes {
                units.append(batch)
                batch = []
                bytes = 0
            }
        }
        if !batch.isEmpty { units.append(batch) }
        return units
    }
}

extension ExistingItem {
    /// Whether `there`, found where a file planned as new was to go, is that very file, sent
    /// before the job stopped (so it was never marked done). Only when files go under a
    /// temporary name first, so one under its own name is complete: written straight, it may
    /// be a cut-off copy the phone reports at full size. Same size, and the same date where the
    /// phone keeps dates.
    public static func isAlreadySent(_ there: RemoteEntry?, size: UInt64?, modified: Date?,
                                     sentUnderTemporaryName: Bool, phoneKeepsDates: Bool) -> Bool {
        guard sentUnderTemporaryName, let there, let size else { return false }
        return ExistingItem.remote(there, localSize: size, localModified: modified).isSame(sizeOnlyMatch: !phoneKeepsDates)
    }
}
