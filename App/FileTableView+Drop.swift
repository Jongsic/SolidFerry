import AppKit
import DeviceCore
import UniformTypeIdentifiers

extension FileTableView.Coordinator {
    // Drop from Finder: onto a folder row uploads into it, anywhere else into this folder.

    static let fileURLOptions: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]

    /// The folder row a drop lands on, if it lands on one.
    private func folder(at row: Int, _ operation: NSTableView.DropOperation) -> RemoteRef? {
        guard operation == .on, entries.indices.contains(row), entries[row].isDirectory else { return nil }
        return entries[row].ref
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        let items = DraggedEntry.read(from: info.draggingPasteboard)
        if !items.isEmpty { return validateDeviceDrop(items, info: info, tableView: tableView, row: row, dropOperation: dropOperation) }
        guard parent.enabled,
              info.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: Self.fileURLOptions) else { return [] }
        if folder(at: row, dropOperation) != nil { return .copy }
        tableView.setDropRow(-1, dropOperation: .on)
        return .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        let items = DraggedEntry.read(from: info.draggingPasteboard)
        if !items.isEmpty {
            let folder = folder(at: row, dropOperation)
            guard (folder ?? parent.currentFolder) != nil else { return false }
            // Bring this window forward: the copy dialog opens on it.
            NSApp.activate()
            tableView.window?.makeKeyAndOrderFront(nil)
            return parent.host.copyFromDevice(items, into: folder, move: dropOperationIsMove(items, info: info))
        }
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: Self.fileURLOptions) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        let folder = folder(at: row, dropOperation)
        parent.host.upload(urls, into: folder)
        return true
    }

    // Drop from another of our windows (or this one, into a subfolder). Same device moves
    // like Finder does on one disk, ⌥ copies; another device always copies.

    private func validateDeviceDrop(_ items: [DraggedEntry], info: NSDraggingInfo, tableView: NSTableView,
                                    row: Int, dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard parent.enabled, let origin = parent.dragOrigin else { return [] }
        if let folder = folder(at: row, dropOperation), canDrop(items, into: folder, origin: origin) {
            return dropOperationIsMove(items, info: info) ? .move : .copy
        }
        guard let current = parent.currentFolder, canDrop(items, into: current, origin: origin) else { return [] }
        tableView.setDropRow(-1, dropOperation: .on)
        return dropOperationIsMove(items, info: info) ? .move : .copy
    }

    /// Not into the folder they're already in, nor into themselves.
    func canDrop(_ items: [DraggedEntry], into folder: RemoteRef, origin: DragOrigin) -> Bool {
        guard items.allSatisfy({ $0.deviceID == origin.deviceID }) else { return true }
        return !items.contains { item in
            let parentPath = RemoteRef(path: item.path).parentPath
            return parentPath == folder.path || folder.path == item.path || folder.path.hasPrefix(item.path + "/")
        }
    }

    private func dropOperationIsMove(_ items: [DraggedEntry], info: NSDraggingInfo) -> Bool {
        guard let origin = parent.dragOrigin, items.allSatisfy({ $0.deviceID == origin.deviceID }) else { return false }
        return info.draggingSourceOperationMask.contains(.move) && !NSEvent.modifierFlags.contains(.option)
    }

    // Drag to Finder: one file promise per row. Finder asks for each promise separately;
    // they're gathered back into one job per drag.

    struct PendingDrop {
        /// Tells this drag's timer apart from a later drag's.
        let id = UUID()
        var expected: Int
        var entries: [RemoteEntry] = []
        var folder: URL?
        var completions: [(Error?) -> Void] = []
    }

    nonisolated private static let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard parent.enabled, row < entries.count else { return nil }
        let entry = entries[row]
        guard entry.kind == .file || entry.kind == .directory else { return nil }
        let type = entry.isDirectory ? UTType.folder : (UTType(filenameExtension: entry.fileExtension) ?? .data)
        let provider = RemoteFilePromiseProvider(fileType: type.identifier, delegate: self)
        provider.userInfo = entry
        if let origin = parent.dragOrigin {
            provider.payload = try? JSONEncoder().encode(DraggedEntry(deviceID: origin.deviceID, deviceName: origin.deviceName, entry: entry))
        }
        return provider
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                   willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        let count = rowIndexes.filter { $0 < entries.count && (entries[$0].kind == .file || entries[$0].kind == .directory) }.count
        pendingDrop = PendingDrop(expected: count)
    }

    nonisolated func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        (provider.userInfo as? RemoteEntry)?.name ?? "file"
    }

    nonisolated func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue {
        Self.promiseQueue
    }

    nonisolated func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL,
                                         completionHandler: @escaping (Error?) -> Void) {
        guard let entry = provider.userInfo as? RemoteEntry else {
            completionHandler(CocoaError(.fileWriteUnknown))
            return
        }
        nonisolated(unsafe) let completion = completionHandler
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.promiseArrived(entry, url: url, completion: completion) }
        }
    }

    private func promiseArrived(_ entry: RemoteEntry, url: URL, completion: @escaping (Error?) -> Void) {
        var drop = pendingDrop ?? PendingDrop(expected: 1)
        drop.entries.append(entry)
        drop.folder = drop.folder ?? url.deletingLastPathComponent()
        drop.completions.append(completion)
        pendingDrop = drop
        if drop.entries.count >= drop.expected {
            flushDrop()
        } else if drop.entries.count == 1 {
            // Don't wait forever if Finder declines some of the promises. Finder asks for
            // all of them right after the drop, so a second is plenty.
            let id = drop.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.flushDrop(id) }
        }
    }

    /// Hands the gathered promises to the window; `id` limits it to that drag.
    private func flushDrop(_ id: UUID? = nil) {
        guard let drop = pendingDrop, id == nil || drop.id == id, let folder = drop.folder, !drop.entries.isEmpty else { return }
        pendingDrop = nil
        // The copy dialog opens on the window the drag came from; bring that one forward,
        // not whichever window happened to be key.
        NSApp.activate()
        table?.window?.makeKeyAndOrderFront(nil)
        parent.host.downloadDropped(drop.entries, to: folder, completions: drop.completions)
    }
}
