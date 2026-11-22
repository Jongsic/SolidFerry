import DeviceCore
import Foundation

/// What to do when the destination already has a file with the same name.
/// Same policy for every transport; `ifHashDiffers` needs `FSCapabilities.deviceHashing`.
public enum ExistingFilePolicy: String, Codable, CaseIterable, Sendable {
    case skip
    case ifSizeOrDateDiffers
    case ifHashDiffers
    case keepBoth
    case overwrite
    case ask
}

/// For the "…differs" policies: how to bring in the different file.
public enum DifferentFileAction: String, Codable, CaseIterable, Sendable {
    case overwrite
    case keepBoth
}

/// When a copied folder's name is already taken at the destination.
public enum ExistingFolderPolicy: String, Codable, CaseIterable, Sendable {
    /// Copy into the existing folder; files follow the file policy. Nothing is deleted.
    case merge
    /// Copy into a new "name (1)" folder.
    case keepBoth
}

public struct TransferPolicy: Codable, Hashable, Sendable {
    public var existing: ExistingFilePolicy
    public var whenDifferent: DifferentFileAction
    /// Treat equal size as "same file" even if dates differ (other tools often reset mtime
    /// to the copy time).
    public var sizeOnlyMatch: Bool
    public var existingFolder: ExistingFolderPolicy
    /// A file already there with the same size (and, compared by contents, the same contents)
    /// but another date only gets the incoming file's date; nothing is copied. Downloads to this
    /// Mac only (`normalized`), with the skip and "…differs" policies.
    public var datesOnlyWhenSameSize: Bool

    /// Defaults never touch what's already at the destination.
    public init(existing: ExistingFilePolicy = .skip,
                whenDifferent: DifferentFileAction = .keepBoth,
                sizeOnlyMatch: Bool = false,
                existingFolder: ExistingFolderPolicy = .merge,
                datesOnlyWhenSameSize: Bool = false) {
        self.existing = existing
        self.whenDifferent = whenDifferent
        self.sizeOnlyMatch = sizeOnlyMatch
        self.existingFolder = existingFolder
        self.datesOnlyWhenSameSize = datesOnlyWhenSameSize
    }

    /// Without content hashes (MTP, device to device) "compare contents" falls back to
    /// comparing size and date; otherwise every same-size file would count as different and be
    /// replaced. The remembered last policy can carry it into such a transfer. Dates are set
    /// only on this Mac (`toMac`): phones differ too much in whether they keep them.
    public func normalized(hashAvailable: Bool, toMac: Bool = false) -> TransferPolicy {
        var policy = self
        if existing == .ifHashDiffers, !hashAvailable { policy.existing = .ifSizeOrDateDiffers }
        if !toMac { policy.datesOnlyWhenSameSize = false }
        return policy
    }

    /// Whether "dates only" applies under this file policy.
    public var setsDates: Bool {
        datesOnlyWhenSameSize && [.skip, .ifSizeOrDateDiffers, .ifHashDiffers].contains(existing)
    }

    /// Tolerates settings saved by older versions (missing keys take defaults).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = TransferPolicy()
        existing = try c.decodeIfPresent(ExistingFilePolicy.self, forKey: .existing) ?? defaults.existing
        whenDifferent = try c.decodeIfPresent(DifferentFileAction.self, forKey: .whenDifferent) ?? defaults.whenDifferent
        sizeOnlyMatch = try c.decodeIfPresent(Bool.self, forKey: .sizeOnlyMatch) ?? defaults.sizeOnlyMatch
        existingFolder = try c.decodeIfPresent(ExistingFolderPolicy.self, forKey: .existingFolder) ?? defaults.existingFolder
        datesOnlyWhenSameSize = try c.decodeIfPresent(Bool.self, forKey: .datesOnlyWhenSameSize) ?? defaults.datesOnlyWhenSameSize
    }
}

/// What's at the destination path.
public enum ExistingItem: Sendable, Hashable {
    case none
    case directory
    case file(sizeMatches: Bool, dateMatches: Bool)

    /// Dates this close count as the same (FAT/exFAT keep them to 2 s).
    public static let dateTolerance: TimeInterval = 2

    /// Compares a remote file with whatever is at `url`. Dates within `dateTolerance` count
    /// as equal. `remoteSizeWraps`: the device's size is only the low 32 bits.
    public static func at(_ url: URL, remoteSize: UInt64?, remoteModified: Date?, remoteSizeWraps: Bool = false) -> ExistingItem {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]) else {
            return .none
        }
        if values.isDirectory == true { return .directory }
        let sizeMatches = values.fileSize.map { sameSize(UInt64($0), remoteSize, wraps: remoteSizeWraps) } ?? false
        let dateMatches: Bool = {
            guard let local = values.contentModificationDate, let remote = remoteModified else { return false }
            return abs(local.timeIntervalSince(remote)) <= dateTolerance
        }()
        return .file(sizeMatches: sizeMatches, dateMatches: dateMatches)
    }
}

/// Equal sizes; with `wraps`, only the low 32 bits are compared (see `exactLargeSizes`).
func sameSize(_ a: UInt64?, _ b: UInt64?, wraps: Bool) -> Bool {
    guard let a, let b else { return false }
    return wraps ? UInt32(truncatingIfNeeded: a) == UInt32(truncatingIfNeeded: b) : a == b
}

/// What to do with one file that's in the way, chosen per file in the copy dialog.
public enum ConflictChoice: String, Sendable, Hashable, Codable, CaseIterable {
    case skip
    case overwrite
    case keepBoth
}

public enum FileDecision: String, Sendable, Hashable, Codable {
    case transfer
    case overwrite
    case keepBoth
    case skipIdentical
    case skipExisting
    /// Same size: compare content hashes before deciding.
    case needsHash
    /// Policy is "ask": the user decides.
    case ask
    /// A folder occupies the file's name.
    case typeConflict
    /// The file there is the same but for its date: only the date is set
    /// (`TransferPolicy.datesOnlyWhenSameSize`).
    case setDate

    public var transfers: Bool {
        self == .transfer || self == .overwrite || self == .keepBoth
    }

    /// With `choice`, the user's decision for this one file (made in the dialog) wins over the
    /// policy, for files that are in the way; it means nothing for new files or folders.
    public static func decide(_ existing: ExistingItem, _ policy: TransferPolicy, choice: ConflictChoice?) -> FileDecision {
        guard let choice, case .file = existing else { return decide(existing, policy) }
        return switch choice {
        case .skip: .skipExisting
        case .overwrite: .overwrite
        case .keepBoth: .keepBoth
        }
    }

    public static func decide(_ existing: ExistingItem, _ policy: TransferPolicy) -> FileDecision {
        switch existing {
        case .none:
            return .transfer
        case .directory:
            return .typeConflict
        case .file(let sizeMatches, let dateMatches):
            let different: FileDecision = policy.whenDifferent == .overwrite ? .overwrite : .keepBoth
            if policy.setsDates, policy.existing != .ifHashDiffers, sizeMatches, !dateMatches { return .setDate }
            switch policy.existing {
            case .skip: return .skipExisting
            case .ifSizeOrDateDiffers:
                return existing.isSame(sizeOnlyMatch: policy.sizeOnlyMatch) ? .skipIdentical : different
            case .ifHashDiffers:
                return sizeMatches ? .needsHash : different
            case .keepBoth: return .keepBoth
            case .overwrite: return .overwrite
            case .ask: return .ask
            }
        }
    }

    /// Resolves `needsHash` once both hashes are known (`dateMatches`: the two files' dates).
    public static func afterHash(equal: Bool, dateMatches: Bool = true, _ policy: TransferPolicy) -> FileDecision {
        if equal { return policy.setsDates && !dateMatches ? .setDate : .skipIdentical }
        return policy.whenDifferent == .overwrite ? .overwrite : .keepBoth
    }
}

/// "name (1).ext", "name (2).ext", … not present on disk nor already reserved in this job.
/// A folder's name has no extension: "Photos.2023" becomes "Photos.2023 (1)", not
/// "Photos (1).2023". `reserved` holds whole paths and ignores case, as the Mac's disk does.
public func uniqueDestination(for url: URL, reserved: inout FolderNames, isDirectory: Bool = false) -> URL {
    let directory = url.deletingLastPathComponent()
    let ext = isDirectory ? "" : url.pathExtension
    let base = isDirectory ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
    var n = 1
    while true {
        let name = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
        let candidate = directory.appendingPathComponent(name)
        if !reserved.contains(candidate.path), !FileManager.default.fileExists(atPath: candidate.path) {
            reserved.insert(candidate.path)
            return candidate
        }
        n += 1
    }
}

extension ExistingItem {
    /// The file already there counts as the same file: same size and date, or same size alone
    /// when dates can't be trusted (`sizeOnlyMatch`). One rule for deciding, counting and showing.
    public func isSame(sizeOnlyMatch: Bool) -> Bool {
        guard case .file(let sizeMatches, let dateMatches) = self else { return false }
        return sizeMatches && (dateMatches || sizeOnlyMatch)
    }
}
