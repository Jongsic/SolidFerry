import AppKit
import DeviceCore

/// The device a window's rows come from.
struct DragOrigin {
    let deviceID: String
    let deviceName: String
}

/// Device entries on a pasteboard (drags between windows, ⌘C/⌘V), next to the file promise
/// that lets the same drag land in Finder.
struct DraggedEntry: Codable, Hashable {
    let deviceID: String
    let deviceName: String
    /// The entry as listed, MTP handle and all.
    let entry: RemoteEntry

    var path: String { entry.ref.path }
    var name: String { entry.name }

    static let pasteboardType = NSPasteboard.PasteboardType("\(WorkNames.subsystem).remote-entry")

    static func read(from pasteboard: NSPasteboard) -> [DraggedEntry] {
        (pasteboard.pasteboardItems ?? []).compactMap { item in
            item.data(forType: pasteboardType).flatMap { try? JSONDecoder().decode(DraggedEntry.self, from: $0) }
        }
    }
}

/// A file promise (for Finder) that also carries the device entry (for other windows).
final class RemoteFilePromiseProvider: NSFilePromiseProvider {
    var payload: Data?

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [DraggedEntry.pasteboardType]
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        type == DraggedEntry.pasteboardType ? payload : super.pasteboardPropertyList(forType: type)
    }
}
