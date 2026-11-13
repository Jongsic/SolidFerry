import Foundation

enum ByteFormat {
    static func string(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

extension URL {
    var abbreviatingWithTildeInPath: String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}

extension FormatStyle where Self == Date.VerbatimFormatStyle {
    /// Fixed-width, year-first timestamp for list columns: 2026/01/22 13:44
    static var listTimestamp: Date.VerbatimFormatStyle {
        Date.VerbatimFormatStyle(
            format: "\(year: .padded(4))/\(month: .twoDigits)/\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
            timeZone: .current,
            calendar: Calendar(identifier: .gregorian)
        )
    }
}
