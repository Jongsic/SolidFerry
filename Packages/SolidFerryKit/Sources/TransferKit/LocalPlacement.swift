import DeviceCore
import Foundation

/// Where one file of a download goes on this Mac, and what's done with it.
public struct LocalPlacement: Sendable {
    public let file: PlannedFile
    /// The file's place; for "keep both", a free name next to it.
    public let target: URL
    public let existing: ExistingItem
    public let decision: FileDecision
}

extension TransferPlan {
    /// Decides each file against what's on this Mac. Every file's own place is reserved before
    /// any "keep both" name is picked, so a picked "a (1).jpg" is never where another file of
    /// the same download goes (that one would replace it). `stop` is asked for every file.
    public func placedLocally(into destination: URL, policy: TransferPolicy, choices: [String: ConflictChoice] = [:],
                              sizesWrap: Bool, stop: () -> Bool = { false }) throws -> [LocalPlacement] {
        var reserved = FolderNames(files.map { destination.appendingPathComponent($0.relativePath).path })
        return try files.map { file in
            if stop() { throw CancellationError() }
            let target = destination.appendingPathComponent(file.relativePath)
            let existing = ExistingItem.at(target, remoteSize: file.entry.size, remoteModified: file.entry.modified,
                                           remoteSizeWraps: sizesWrap)
            let decision = FileDecision.decide(existing, policy, choice: choices[file.relativePath])
            return LocalPlacement(file: file, target: decision == .keepBoth ? uniqueDestination(for: target, reserved: &reserved) : target,
                                  existing: existing, decision: decision)
        }
    }
}
