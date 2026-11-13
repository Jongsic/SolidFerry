import AppKit
import DeviceCore
import UniformTypeIdentifiers

/// Finder icons and kind names per extension, cached.
@MainActor
enum FileIcons {
    private static var icons: [String: NSImage] = [:]
    private static var kinds: [String: String] = [:]

    static func icon(for entry: RemoteEntry) -> NSImage {
        let key = cacheKey(entry)
        if let cached = icons[key] { return cached }
        let image = NSWorkspace.shared.icon(for: type(of: entry))
        image.size = NSSize(width: 16, height: 16)
        icons[key] = image
        return image
    }

    static func kind(for entry: RemoteEntry) -> String {
        switch entry.kind {
        case .directory: return String(localized: "Folder")
        case .symlink: return String(localized: "Link")
        case .other: return "—"
        case .file: break
        }
        let key = cacheKey(entry)
        if let cached = kinds[key] { return cached }
        let description = UTType(filenameExtension: entry.fileExtension)?.localizedDescription
            ?? (entry.fileExtension.isEmpty ? String(localized: "Document") : String(localized: "\(entry.fileExtension.uppercased()) File"))
        kinds[key] = description
        return description
    }

    private static func cacheKey(_ entry: RemoteEntry) -> String {
        switch entry.kind {
        case .directory: "/dir"
        case .symlink: "/link"
        case .other: "/other"
        case .file: entry.fileExtension
        }
    }

    private static func type(of entry: RemoteEntry) -> UTType {
        switch entry.kind {
        case .directory, .symlink: .folder
        case .other: .item
        case .file: UTType(filenameExtension: entry.fileExtension) ?? .data
        }
    }
}
