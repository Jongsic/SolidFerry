import AppKit
import ImageIO

/// Turning a device file's bytes into something to show: pictures, text, picture details.
enum FileDecoding {
    /// The photo the right way up (as its orientation tag says), at full size.
    static func image(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            // Kinds ImageIO doesn't decode (SVG) may still be drawn by AppKit.
            return NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height, 1),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// UTF-8 or UTF-16 (with its mark), else the encoding macOS finds most likely (EUC-KR
    /// and Shift JIS files are still common). Nil for what isn't text.
    static func text(from data: Data) -> String? {
        if data.isEmpty { return "" }
        if let text = String(data: data, encoding: .utf8) {
            return text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        // Binary, not text.
        if data.prefix(8192).contains(0) { return nil }
        let korean = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosKorean.rawValue)))
        var converted: NSString?
        let found = NSString.stringEncoding(for: data, encodingOptions: [
            .suggestedEncodingsKey: [korean.rawValue, String.Encoding.shiftJIS.rawValue, String.Encoding.windowsCP1252.rawValue],
            .allowLossyKey: false,
        ], convertedString: &converted, usedLossyConversion: nil)
        return found == 0 ? nil : converted as String?
    }
}

/// One line of what a file says about itself ("Camera: …").
struct PreviewDetail: Hashable, Sendable {
    let label: String
    let value: String
}

/// Everything a file says about itself, as stored: tags by group ("Exif", "GPS", …), and the
/// same as ImageIO reads it, keys and values untouched.
struct FileMetadata: Sendable {
    struct Group: Hashable, Sendable {
        let name: String
        let entries: [PreviewDetail]
    }

    var groups: [Group]
    var raw: String
}

extension FileDecoding {
    /// From the start of a picture file (or all of it): the small picture stored inside it
    /// (made from the whole picture when `complete`), and what it says about itself. Nil when
    /// ImageIO can't read it.
    /// A picture's size as shown (turned by its orientation), from the start of the file: a
    /// header says it before any pixels.
    static func pictureSize(from data: Data, complete: Bool) -> CGSize? {
        let source = CGImageSourceCreateIncremental(nil)
        CGImageSourceUpdateData(source, data as CFData, complete)
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        return pictureSize(properties)
    }

    private static func pictureSize(_ properties: [CFString: Any]) -> CGSize? {
        guard let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        // Orientations 5–8 turn the picture on its side.
        let turned = (properties[kCGImagePropertyOrientation] as? Int ?? 1) >= 5
        return turned ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    /// `size`: the picture's own size, turned as it's shown.
    static func picturePreview(from data: Data, complete: Bool, maxPixels: Int)
        -> (picture: CGImage?, size: CGSize?, details: [PreviewDetail], metadata: FileMetadata)? {
        let source = CGImageSourceCreateIncremental(nil)
        CGImageSourceUpdateData(source, data as CFData, complete)
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              properties[kCGImagePropertyPixelWidth] != nil else { return nil }
        // Only part of the file: only the small picture stored in it.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: complete,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        var picture = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        let size = pictureSize(properties)
        // From part of a file, ImageIO also draws what it has of the picture itself (the top of
        // a PNG), fitted to `maxPixels`. A stored small picture comes at its own, smaller size.
        if !complete, let found = picture,
           let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
           max(found.width, found.height) >= min(maxPixels, max(width, height)) {
            picture = nil
        }
        return (picture, size, pictureDetails(properties), metadata(properties as [String: Any], general: String(localized: "Picture")))
    }

    private static func pictureDetails(_ properties: [CFString: Any]) -> [PreviewDetail] {
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
        var details: [PreviewDetail] = []
        func add(_ label: String, _ value: String?) {
            if let value, !value.isEmpty { details.append(PreviewDetail(label: label, value: value)) }
        }
        if var width = properties[kCGImagePropertyPixelWidth] as? Int, var height = properties[kCGImagePropertyPixelHeight] as? Int {
            // Orientations 5–8 turn the picture on its side.
            if let orientation = properties[kCGImagePropertyOrientation] as? Int, orientation >= 5 { swap(&width, &height) }
            add(String(localized: "Dimensions"), "\(width) × \(height)")
        }
        if let taken = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let parser = DateFormatter()
            parser.locale = Locale(identifier: "en_US_POSIX")
            parser.dateFormat = "yyyy:MM:dd HH:mm:ss"
            add(String(localized: "Taken"), parser.date(from: taken).map { $0.formatted(date: .abbreviated, time: .shortened) } ?? taken)
        }
        let make = (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let model = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        add(String(localized: "Camera"), model.lowercased().hasPrefix(make.lowercased()) ? model : [make, model].filter { !$0.isEmpty }.joined(separator: " "))
        add(String(localized: "Lens"), exif[kCGImagePropertyExifLensModel] as? String)
        var exposure: [String] = []
        if let time = exif[kCGImagePropertyExifExposureTime] as? Double, time > 0 {
            exposure.append(time >= 1 ? "\(time.formatted()) s" : "1/\(Int((1 / time).rounded())) s")
        }
        if let f = exif[kCGImagePropertyExifFNumber] as? Double { exposure.append("ƒ/\(f.formatted(.number.precision(.fractionLength(0...1))))") }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first { exposure.append("ISO \(iso)") }
        if let focal = exif[kCGImagePropertyExifFocalLength] as? Double { exposure.append("\(focal.formatted(.number.precision(.fractionLength(0...1)))) mm") }
        add(String(localized: "Exposure"), exposure.joined(separator: " · "))
        if let latitude = gps[kCGImagePropertyGPSLatitude] as? Double, let longitude = gps[kCGImagePropertyGPSLongitude] as? Double {
            let ns = gps[kCGImagePropertyGPSLatitudeRef] as? String ?? "N", ew = gps[kCGImagePropertyGPSLongitudeRef] as? String ?? "E"
            add(String(localized: "Location"), String(format: "%.5f° %@, %.5f° %@", latitude, ns, longitude, ew))
        }
        return details
    }

    /// Tags by group: the dictionary's plain values first (under `general`), then each nested
    /// dictionary ("{Exif}" → "Exif"), with names spaced ("ExposureTime" → "Exposure Time").
    static func metadata(_ properties: [String: Any], general: String) -> FileMetadata {
        var groups: [FileMetadata.Group] = []
        let plain = properties.filter { !($0.value is [String: Any]) }
        if !plain.isEmpty { groups.append(.init(name: general, entries: entries(plain))) }
        for (key, value) in properties.sorted(by: { $0.key < $1.key }) {
            guard let nested = value as? [String: Any], !nested.isEmpty else { continue }
            groups.append(.init(name: key.trimmingCharacters(in: CharacterSet(charactersIn: "{}")), entries: entries(nested)))
        }
        return FileMetadata(groups: groups, raw: rawText(properties, indent: ""))
    }

    private static func entries(_ dictionary: [String: Any]) -> [PreviewDetail] {
        dictionary.sorted { $0.key < $1.key }.map { PreviewDetail(label: spaced($0.key), value: readable($0.value)) }
    }

    /// "ExposureTime" → "Exposure Time", "ISOSpeedRatings" → "ISO Speed Ratings".
    private static func spaced(_ key: String) -> String {
        let name = key.trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
        var out = ""
        let characters = Array(name)
        for (i, c) in characters.enumerated() {
            if i > 0, c.isUppercase {
                let previous = characters[i - 1]
                let nextIsLower = i + 1 < characters.count && characters[i + 1].isLowercase
                if previous.isLowercase || previous.isNumber || (previous.isUppercase && nextIsLower) { out.append(" ") }
            }
            out.append(c)
        }
        return out
    }

    private static func readable(_ value: Any) -> String {
        switch value {
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
            return number.boolValue ? "true" : "false"
        case let number as NSNumber:
            let double = number.doubleValue
            return double == double.rounded() && abs(double) < 1e15 ? String(Int64(double)) : double.formatted(.number.precision(.fractionLength(0...6)))
        case let data as Data:
            return String(localized: "\(data.count) bytes")
        case let date as Date:
            return date.formatted(date: .abbreviated, time: .standard)
        case let array as [Any]:
            return array.map(readable).joined(separator: ", ")
        case let dictionary as [String: Any]:
            return dictionary.sorted { $0.key < $1.key }.map { "\($0.key): \(readable($0.value))" }.joined(separator: "; ")
        default:
            return "\(value)"
        }
    }

    /// The dictionary as stored: keys as they are, values unformatted, nesting indented.
    private static func rawText(_ dictionary: [String: Any], indent: String) -> String {
        dictionary.sorted { $0.key < $1.key }.map { key, value in
            if let nested = value as? [String: Any] {
                return "\(indent)\(key)\n" + rawText(nested, indent: indent + "    ")
            }
            let text: String = switch value {
            case let data as Data: "<\(data.count) bytes>"
            case let array as [Any]: "(" + array.map { "\($0)" }.joined(separator: ", ") + ")"
            default: "\(value)"
            }
            return "\(indent)\(key) = \(text)"
        }.joined(separator: "\n")
    }

    /// The start of a text file cut off anywhere: decoded without the last few bytes when the cut
    /// splits a character.
    static func textStart(from data: Data, complete: Bool) -> String? {
        if complete { return text(from: data) }
        for cut in 0...3 where data.count > cut {
            let start = data.dropLast(cut)
            if String(data: start, encoding: .utf8) != nil { return text(from: start) }
        }
        return text(from: data) ?? text(from: data.dropLast(1))
    }
}
