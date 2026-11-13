import DeviceCore
import Foundation

/// Renaming many items at once: a few rules applied in order (find/replace, case, prefix and
/// suffix, numbering), previewed before anything changes.
public struct BatchRenameRules: Codable, Hashable, Sendable {
    public enum CaseChange: String, Codable, CaseIterable, Sendable {
        case unchanged, lower, upper, title
    }

    public enum NumberPosition: String, Codable, CaseIterable, Sendable {
        /// "001 name"
        case before
        /// "name 001"
        case after
        /// "001" (the name is replaced by the number)
        case replace
    }

    public var find = ""
    public var replace = ""
    public var useRegex = false
    public var matchCase = false
    public var caseChange = CaseChange.unchanged
    public var prefix = ""
    public var suffix = ""
    public var numbering = false
    public var numberPosition = NumberPosition.after
    public var start = 1
    public var step = 1
    public var digits = 3
    public var separator = " "
    /// Also apply to the extension (otherwise ".jpg" etc. is left alone).
    public var includeExtension = false

    public init() {}

    /// The new name for `name`, the `index`-th item in the list.
    public func apply(to name: String, index: Int, isDirectory: Bool) throws -> String {
        let (base, ext) = Self.split(name, isDirectory: isDirectory || includeExtension)
        var result = base

        if !find.isEmpty {
            if useRegex {
                let regex = try NSRegularExpression(pattern: find, options: matchCase ? [] : [.caseInsensitive])
                result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result),
                                                        withTemplate: replace)
            } else {
                result = result.replacingOccurrences(of: find, with: replace, options: matchCase ? [] : [.caseInsensitive])
            }
        }

        switch caseChange {
        case .unchanged: break
        case .lower: result = result.lowercased()
        case .upper: result = result.uppercased()
        case .title: result = result.capitalized
        }

        result = prefix + result + suffix

        if numbering {
            let value = start + index * step
            let number = String(format: "%0\(max(1, min(digits, 10)))d", value)
            switch numberPosition {
            case .before: result = number + separator + result
            case .after: result = result + separator + number
            case .replace: result = number
            }
        }
        return ext.isEmpty ? result : result + "." + ext
    }

    /// "photo.JPG" → ("photo", "JPG"); dotfiles and folders have no extension.
    static func split(_ name: String, isDirectory: Bool) -> (String, String) {
        guard !isDirectory, let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, "") }
        return (String(name[..<dot]), String(name[name.index(after: dot)...]))
    }
}

public struct BatchRenameRow: Hashable, Sendable {
    public enum Problem: Hashable, Sendable {
        /// Empty, ".", "..", or contains "/".
        case invalid
        /// Another item in the list would get the same name.
        case duplicate
        /// Taken by an item in the folder that isn't being renamed.
        case taken
        /// The find pattern isn't a valid regular expression.
        case badPattern
    }

    public let oldName: String
    public let newName: String
    public let problem: Problem?

    public var changes: Bool { problem == nil && oldName != newName }
}

public enum BatchRename {
    /// Previews every item; `others` are the folder's names that aren't being renamed.
    public static func preview(_ items: [(name: String, isDirectory: Bool)], rules: BatchRenameRules,
                               others: Set<String>) -> [BatchRenameRow] {
        var names: [String?] = []
        for (index, item) in items.enumerated() {
            names.append(try? rules.apply(to: item.name, index: index, isDirectory: item.isDirectory))
        }
        // Device file systems are case-sensitive, but compare loosely: the Mac copy of the
        // folder and MTP clients often aren't.
        var counts: [String: Int] = [:]
        for name in names.compactMap({ $0 }) { counts[FolderNames.key(name), default: 0] += 1 }
        let others = FolderNames(others)
        return items.indices.map { i in
            let old = items[i].name
            guard let new = names[i] else { return BatchRenameRow(oldName: old, newName: old, problem: .badPattern) }
            let problem: BatchRenameRow.Problem? =
                !FileNames.isAllowed(new) ? .invalid
                : counts[FolderNames.key(new), default: 0] > 1 ? .duplicate
                : others.contains(new) ? .taken
                : nil
            return BatchRenameRow(oldName: old, newName: new, problem: problem)
        }
    }

    /// The renames to perform, in an order that never collides: names that another item in
    /// the list still holds go through a temporary name first.
    public static func steps(_ rows: [BatchRenameRow]) -> [(from: String, to: String)] {
        let changing = rows.filter(\.changes)
        let held = Set(changing.map { $0.oldName.lowercased() })
        var direct: [(String, String)] = []
        var viaTemp: [(String, String)] = []
        for row in changing {
            if held.contains(row.newName.lowercased()) { viaTemp.append((row.oldName, row.newName)) } else { direct.append((row.oldName, row.newName)) }
        }
        guard !viaTemp.isEmpty else { return direct }
        let token = UUID().uuidString.prefix(8)
        let temps = viaTemp.enumerated().map { ($1.0, WorkNames.step("rename", "\(token)-\($0)")) }
        // Move every blocked item aside first, then the direct ones, then into place.
        return temps.map { ($0.0, $0.1) } + direct + zip(temps, viaTemp).map { ($0.1, $1.1) }
    }
}
