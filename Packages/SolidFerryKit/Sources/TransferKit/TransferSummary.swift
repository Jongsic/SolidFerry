import Foundation

/// Counts for the transfer dialogs. In hash mode "same/different" can't be known before
/// hashing, so same-size files are reported as "to compare" instead.
public struct TransferSummary: Sendable {
    public var new = 0
    public var same = 0
    public var different = 0
    public var sameSize = 0
    public var differentSize = 0
    public var copyCount = 0
    public var copyBytes: UInt64 = 0
    public var hashCount = 0
    public var askCount = 0
    public var skipCount = 0

    /// Files whose name is already taken at the destination.
    public var existingCount: Int { same + different }

    /// `choices`: per-file decisions from the table, parallel to `sizes` (nil = the policy's).
    public init(sizes: [UInt64?], existing: [ExistingItem], policy: TransferPolicy, choices: [ConflictChoice?] = []) {
        for (index, (size, item)) in zip(sizes, existing).enumerated() {
            let choice = index < choices.count ? choices[index] : nil
            switch item {
            case .none: new += 1
            case .directory: different += 1; differentSize += 1
            case .file(let sizeMatches, _):
                if item.isSame(sizeOnlyMatch: policy.sizeOnlyMatch) { same += 1 } else { different += 1 }
                if sizeMatches { sameSize += 1 } else { differentSize += 1 }
            }
            switch FileDecision.decide(item, policy, choice: choice) {
            case .transfer, .overwrite, .keepBoth:
                copyCount += 1
                copyBytes += size ?? 0
            case .needsHash: hashCount += 1
            case .ask: askCount += 1
            case .skipIdentical, .skipExisting, .typeConflict: skipCount += 1
            }
        }
    }

    public init(rows: [FileRow], policy: TransferPolicy, choices: [String: ConflictChoice]) {
        self.init(sizes: rows.map(\.incomingSize), existing: rows.map(\.existing), policy: policy,
                  choices: rows.map { choices[$0.relativePath] })
    }
}

/// One planned file as the dialog's list shows it.
public struct FileRow: Identifiable, Sendable {
    public enum Kind: Int, CaseIterable {
        case different, same, folderInTheWay, new
    }

    /// Path below the destination, the key for per-file choices.
    public let relativePath: String
    public let existing: ExistingItem
    public let incomingSize: UInt64?
    public let incomingDate: Date?
    public let existingSize: UInt64?
    public let existingDate: Date?

    public var id: String { relativePath }

    public init(relativePath: String, existing: ExistingItem, incomingSize: UInt64?, incomingDate: Date?,
                existingSize: UInt64?, existingDate: Date?) {
        self.relativePath = relativePath
        self.existing = existing
        self.incomingSize = incomingSize
        self.incomingDate = incomingDate
        self.existingSize = existingSize
        self.existingDate = existingDate
    }

    /// The per-file choices for files still in the way (the folder policy can change that).
    public static func choices(_ choices: [String: ConflictChoice], stillInTheWayIn rows: [FileRow]?) -> [String: ConflictChoice] {
        let inTheWay = Set((rows ?? []).lazy.filter { if case .file = $0.existing { true } else { false } }.map(\.relativePath))
        return choices.filter { inTheWay.contains($0.key) }
    }

    public func kind(sizeOnlyMatch: Bool) -> Kind {
        switch existing {
        case .none: .new
        case .directory: .folderInTheWay
        case .file: existing.isSame(sizeOnlyMatch: sizeOnlyMatch) ? .same : .different
        }
    }
}

/// Which files the list shows; the colored counts above it switch between them.
public enum FileFilter: Hashable, Sendable {
    case all, new, same, different
}

extension FileRow {
    /// The rows for the filter: files in the way first (different, then same, then folders
    /// in the way), then new ones. Each group keeps the plan's order.
    public static func visible(_ rows: [FileRow], filter: FileFilter, sizeOnlyMatch: Bool) -> [FileRow] {
        let wanted: Set<Kind> = switch filter {
        case .all: Set(Kind.allCases)
        case .new: [.new]
        case .same: [.same]
        case .different: [.different, .folderInTheWay]
        }
        var groups: [[FileRow]] = Array(repeating: [], count: Kind.allCases.count)
        for row in rows {
            let kind = row.kind(sizeOnlyMatch: sizeOnlyMatch)
            if wanted.contains(kind) { groups[kind.rawValue].append(row) }
        }
        return groups.flatMap { $0 }
    }
}

extension TransferPolicy {
    /// Whether the list counts same-size files as the same: in hash mode it can't know yet, and
    /// the counts above it say "same size, to compare".
    public var matchesBySizeInList: Bool { sizeOnlyMatch || existing == .ifHashDiffers }
}
