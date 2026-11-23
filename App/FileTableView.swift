import AppKit
import DeviceCore
import SwiftUI
import UniformTypeIdentifiers

enum SizeDisplay: String {
    case auto
    case bytes
}

/// Where a folder is in the sidebar.
enum SidebarPlace {
    case none, favorite
    /// One of the device's own places (Internal Storage, Camera, …): always there.
    case shortcut
}

/// What the file list asks of the window it's in.
@MainActor
protocol FileListHost {
    func open(_ entry: RemoteEntry)
    /// Space: shows the file in the viewer while the list keeps the keyboard, or hides it.
    func quickLook(_ entry: RemoteEntry?)
    func openInNewWindow(_ entry: RemoteEntry)
    /// ⌫ / ⇧⌫ in the list: the previous or next folder in the window's history.
    func goThroughHistory(forward: Bool)
    /// Whether the folder is in the sidebar: one of the device's places, a favorite, or neither.
    func sidebarPlace(of path: String) -> SidebarPlace
    /// Adds the folder to the sidebar's favorites, or removes it.
    func toggleInSidebar(_ path: String)
    /// Receives a file and opens it in `app` (nil: the default one for its kind).
    func openFile(_ entry: RemoteEntry, with app: URL?)
    func download(_ entries: [RemoteEntry])
    func rename(_ entry: RemoteEntry, to name: String)
    /// Several items selected: rename them together.
    func renameTogether(_ entries: [RemoteEntry])
    func confirmDelete(_ entries: [RemoteEntry])
    func newFolder()
    /// Finder files dropped or pasted on the list (nil folder = the current one).
    func upload(_ urls: [URL], into folder: RemoteRef?)
    /// Rows scrolled into view (ids), so their missing details can be fetched first.
    func visibleRowsChanged(_ ids: [String])
    /// Rows from one of our windows dropped or pasted here (nil folder = the current one).
    /// Returns false when it can't be done (e.g. the items' phone isn't connected any more).
    func copyFromDevice(_ items: [DraggedEntry], into folder: RemoteRef?, move: Bool) -> Bool
    /// Rows dragged to Finder: the folder they landed in and the promises' completions.
    func downloadDropped(_ entries: [RemoteEntry], to folder: URL, completions: [(Error?) -> Void])
}

/// Finder-grade file list: NSTableView with cell reuse, multi-selection, type-select,
/// header-click sorting, keyboard open and a context menu.
struct FileTableView: NSViewRepresentable {
    let entries: [RemoteEntry]
    /// Changes when the folder changes; the list scrolls back to the top then.
    let locationKey: String?
    /// False while the device is disconnected: rows stay visible but can't be used.
    let enabled: Bool
    @Binding var selection: Set<String>
    /// Set to an entry ID to start inline renaming it; cleared once editing begins.
    @Binding var renamingID: String?
    @Binding var sort: BrowserSort
    let sizeDisplay: SizeDisplay
    /// Point size of the rows' text (Settings ▸ Text size).
    var textSize: Double = 13
    /// Point size of the column titles.
    var headerTextSize: Double = 11
    let host: any FileListHost
    /// Who the rows belong to, so other windows can copy them device-to-device.
    var dragOrigin: DragOrigin?
    /// The folder shown, for drops that don't land on a folder row.
    var currentFolder: RemoteRef?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let table = FileNSTableView()
        table.style = .fullWidth
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.allowsTypeSelect = true
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.rowHeight = 22
        table.intercellSpacing = NSSize(width: 6, height: 0)

        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: column.identifier)
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = column.minWidth
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.sortKey.rawValue, ascending: column.defaultAscending)
            if column.alignment == .right {
                tableColumn.headerCell.alignment = .right
            }
            table.addTableColumn(tableColumn)
        }
        table.autosaveName = "FileTable"
        table.autosaveTableColumns = true

        let coordinator = context.coordinator
        table.dataSource = coordinator
        table.delegate = coordinator
        table.target = coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        table.registerForDraggedTypes([.fileURL, DraggedEntry.pasteboardType])
        table.onOpenSelection = { [weak coordinator] in coordinator?.openSelection() }
        table.onQuickLook = { [weak coordinator] in coordinator?.quickLookSelection() }
        table.onRenameSelection = { [weak coordinator] in coordinator?.renameSelection() }
        table.onDeleteSelection = { [weak coordinator] in coordinator?.deleteSelection() }
        table.onHistory = { [weak coordinator] forward in
            guard let coordinator, coordinator.parent.enabled else { return }
            coordinator.parent.host.goThroughHistory(forward: forward)
        }
        table.onCopySelection = { [weak coordinator] in coordinator?.copySelection() ?? false }
        table.onPaste = { [weak coordinator] move in coordinator?.paste(move: move) ?? false }
        let menu = NSMenu()
        menu.delegate = coordinator
        table.menu = menu
        coordinator.table = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(coordinator, selector: #selector(Coordinator.scrolled(_:)),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        DispatchQueue.main.async { table.window?.makeFirstResponder(table) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(self)
    }

    // MARK: Columns

    enum Column: CaseIterable {
        case name, size, modified, kind

        var identifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier("col.\(self)") }
        var title: String {
            switch self {
            case .name: String(localized: "Name")
            case .size: String(localized: "Size")
            case .modified: String(localized: "Date Modified")
            case .kind: String(localized: "Kind")
            }
        }
        var width: CGFloat {
            switch self {
            case .name: 360
            case .size: 100
            case .modified: 130
            case .kind: 120
            }
        }
        var minWidth: CGFloat {
            switch self {
            case .name: 160
            case .size: 60
            case .modified: 110
            case .kind: 60
            }
        }
        var sortKey: SortKey {
            switch self {
            case .name: .name
            case .size: .size
            case .modified: .modified
            case .kind: .kind
            }
        }
        /// Newest/biggest first feels natural for these.
        var defaultAscending: Bool { self == .name || self == .kind }
        var alignment: NSTextAlignment { self == .size ? .right : .left }

        init?(_ identifier: NSUserInterfaceItemIdentifier?) {
            guard let match = Self.allCases.first(where: { $0.identifier == identifier }) else { return nil }
            self = match
        }
    }

    // MARK: Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate,
                             NSFilePromiseProviderDelegate, NSTextFieldDelegate {
        var parent: FileTableView
        weak var table: NSTableView?
        private(set) var entries: [RemoteEntry] = []
        private var sizeDisplay: SizeDisplay
        private var textSize: Double = 13
        private var headerTextSize: Double = 0
        private var locationKey: String?
        private var applyingState = false
        /// The window's selection as of the last time the list and the window agreed: a
        /// window selection that differs from it was changed by the window, and is shown.
        private var syncedSelection = Set<String>()
        /// Rows dragged to Finder whose promises are still arriving (FileTableView+Drop).
        var pendingDrop: PendingDrop?

        init(_ parent: FileTableView) {
            self.parent = parent
            self.sizeDisplay = parent.sizeDisplay
        }

        func update(_ parent: FileTableView) {
            self.parent = parent
            guard let table else { return }
            applyingState = true
            defer { applyingState = false }

            let descriptor = NSSortDescriptor(key: parent.sort.key.rawValue, ascending: parent.sort.ascending)
            if table.sortDescriptors.first != descriptor {
                table.sortDescriptors = [descriptor]
            }

            // The selection the list shows: the window's when the window changed it; otherwise
            // the list's own, which can be ahead of the window's while a click is still under
            // way (⌘-click). Rows not in the list keep the window's.
            var selection: Set<String>?
            if parent.selection != syncedSelection {
                selection = parent.selection
            }

            if table.isEnabled != parent.enabled {
                table.isEnabled = parent.enabled
                table.alphaValue = parent.enabled ? 1 : 0.35
                if !parent.enabled { table.deselectAll(nil) }
                selection = parent.selection
            }

            if parent.textSize != textSize {
                textSize = parent.textSize
                table.rowHeight = Self.rowHeight(for: textSize)
                table.reloadData()
            }
            if parent.headerTextSize != headerTextSize {
                headerTextSize = parent.headerTextSize
                let font = NSFont.systemFont(ofSize: headerTextSize)
                // The header cell draws its title at its own size unless the title carries the font.
                for column in table.tableColumns {
                    let paragraph = NSMutableParagraphStyle()
                    paragraph.alignment = column.headerCell.alignment
                    paragraph.lineBreakMode = .byTruncatingTail
                    column.headerCell.attributedStringValue = NSAttributedString(
                        string: column.title, attributes: [.font: font, .paragraphStyle: paragraph])
                }
                if let header = table.headerView {
                    header.frame.size.height = max(28, (headerTextSize * 2.2).rounded())
                    // The clip view lays the rows out under the header's new height.
                    table.enclosingScrollView?.tile()
                    header.needsDisplay = true
                }
            }

            let sizeDisplayChanged = parent.sizeDisplay != sizeDisplay
            if parent.entries != entries || sizeDisplayChanged {
                let old = entries
                entries = parent.entries
                sizeDisplay = parent.sizeDisplay
                if old.map(\.id) == entries.map(\.id), table.numberOfRows == entries.count {
                    // Same rows, new details (sizes/dates arriving): refresh only the rows that
                    // changed, in place, so the selection, scroll position and an in-progress
                    // rename aren't disturbed.
                    let rows = sizeDisplayChanged
                        ? IndexSet(integersIn: 0..<entries.count)
                        : IndexSet(entries.indices.filter { entries[$0] != old[$0] })
                    let columns = IndexSet(table.tableColumns.indices.filter {
                        table.tableColumns[$0].identifier != Column.name.identifier
                    })
                    if !rows.isEmpty { table.reloadData(forRowIndexes: rows, columnIndexes: columns) }
                } else {
                    if selection == nil {
                        let shown = Set(table.selectedRowIndexes.compactMap { $0 < old.count ? old[$0].id : nil })
                        selection = shown.union(parent.selection.subtracting(old.map(\.id)))
                    }
                    table.reloadData()
                    lastVisible = nil
                }
                DispatchQueue.main.async { [weak self] in self?.reportVisibleRows() }
            }

            if parent.locationKey != locationKey {
                locationKey = parent.locationKey
                table.scrollRowToVisible(0)
            }

            if let selection {
                syncedSelection = parent.selection
                let wanted = IndexSet(entries.indices.filter { selection.contains(entries[$0].id) })
                if wanted != table.selectedRowIndexes {
                    table.selectRowIndexes(wanted, byExtendingSelection: false)
                    if let first = wanted.first { table.scrollRowToVisible(first) }
                }
            }

            if let id = parent.renamingID, let row = entries.firstIndex(where: { $0.id == id }) {
                DispatchQueue.main.async { [weak self] in
                    self?.parent.renamingID = nil
                    self?.beginRename(row: row)
                }
            }
        }

        // Visible rows

        private var lastVisible: Range<Int>?

        @objc func scrolled(_ notification: Notification) {
            reportVisibleRows()
        }

        func reportVisibleRows() {
            guard let table, !entries.isEmpty else { return }
            let range = table.rows(in: table.visibleRect)
            let rows = range.location..<min(range.location + range.length, entries.count)
            guard rows != lastVisible, !rows.isEmpty else { return }
            lastVisible = rows
            parent.host.visibleRowsChanged(rows.map { entries[$0].id })
        }

        // Data source

        func numberOfRows(in tableView: NSTableView) -> Int {
            entries.count
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !applyingState, let descriptor = tableView.sortDescriptors.first,
                  let key = descriptor.key.flatMap(SortKey.init(rawValue:)) else { return }
            parent.sort = BrowserSort(key: key, ascending: descriptor.ascending)
        }

        // Delegate

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let column = Column(tableColumn?.identifier), row < entries.count else { return nil }
            let entry = entries[row]
            let cell = tableView.makeView(withIdentifier: Self.cellIdentifier(column, textSize), owner: nil) as? NSTableCellView
                ?? Self.makeCell(column, textSize: textSize)
            let text = cell.textField!
            text.isEditable = false // a reused cell may have been mid-rename
            text.textColor = entry.isHidden ? .secondaryLabelColor : (column == .name ? .labelColor : .secondaryLabelColor)
            switch column {
            case .name:
                text.stringValue = entry.name
                cell.imageView?.image = FileIcons.icon(for: entry)
            case .size:
                text.stringValue = entry.size.map { Self.format(size: $0, sizeDisplay) } ?? (entry.isPartial ? "…" : "—")
            case .modified:
                text.stringValue = entry.modified?.formatted(.listTimestamp) ?? (entry.isPartial ? "…" : "—")
            case .kind:
                text.stringValue = FileIcons.kind(for: entry)
            }
            return cell
        }

        func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
            Column(tableColumn?.identifier) == .name ? entries[row].name : nil
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !applyingState, let table else { return }
            let ids = Set(table.selectedRowIndexes.compactMap { $0 < entries.count ? entries[$0].id : nil })
            syncedSelection = ids
            if ids != parent.selection { parent.selection = ids }
        }

        // Actions

        @objc func doubleClicked(_ sender: NSTableView) {
            guard parent.enabled else { return }
            let row = sender.clickedRow
            guard row >= 0, row < entries.count else { return }
            parent.host.open(entries[row])
        }

        func openSelection() {
            guard let table else { return }
            let selected = table.selectedRowIndexes.map { entries[$0] }
            if selected.count == 1 { parent.host.open(selected[0]) }
        }

        /// The first selected file, or nil (the viewer then just closes, if it's open).
        func quickLookSelection() {
            guard let table, parent.enabled else { return }
            parent.host.quickLook(table.selectedRowIndexes.lazy.map { self.entries[$0] }.first { $0.kind == .file })
        }

        func renameSelection() {
            guard let table, parent.enabled, !table.selectedRowIndexes.isEmpty else { return }
            if table.selectedRowIndexes.count > 1 {
                parent.host.renameTogether(table.selectedRowIndexes.map { entries[$0] })
            } else if let row = table.selectedRowIndexes.first {
                beginRename(row: row)
            }
        }

        func deleteSelection() {
            guard let table, parent.enabled, !table.selectedRowIndexes.isEmpty else { return }
            parent.host.confirmDelete(table.selectedRowIndexes.map { entries[$0] })
        }

        /// Puts the selected items on the clipboard (with their paths as text).
        func copySelection() -> Bool {
            guard let table, parent.enabled, let origin = parent.dragOrigin else { return false }
            let targets = table.selectedRowIndexes.map { entries[$0] }.filter { $0.kind == .file || $0.kind == .directory }
            return copy(targets, origin: origin)
        }

        func copy(_ targets: [RemoteEntry], origin: DragOrigin) -> Bool {
            guard !targets.isEmpty else { return false }
            let items = targets.compactMap { entry -> NSPasteboardItem? in
                guard let data = try? JSONEncoder().encode(DraggedEntry(deviceID: origin.deviceID, deviceName: origin.deviceName, entry: entry))
                else { return nil }
                let item = NSPasteboardItem()
                item.setData(data, forType: DraggedEntry.pasteboardType)
                item.setString(entry.ref.path, forType: .string)
                return item
            }
            NSPasteboard.general.clearContents()
            return NSPasteboard.general.writeObjects(items)
        }

        func paste(move: Bool) -> Bool {
            guard parent.enabled, let current = parent.currentFolder, let origin = parent.dragOrigin else { return false }
            let pasteboard = NSPasteboard.general
            let items = DraggedEntry.read(from: pasteboard)
            if !items.isEmpty {
                let sameDevice = items.allSatisfy { $0.deviceID == origin.deviceID }
                // Moving onto itself does nothing; copying into the same folder can keep both.
                if move && sameDevice && !canDrop(items, into: current, origin: origin) { return false }
                if items.contains(where: { $0.deviceID == origin.deviceID && (current.path == $0.path || current.path.hasPrefix($0.path + "/")) }) {
                    return false
                }
                return parent.host.copyFromDevice(items, into: nil, move: move && sameDevice)
            }
            let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: Self.fileURLOptions) as? [URL] ?? []
            guard !urls.isEmpty else { return false }
            parent.host.upload(urls, into: nil)
            return true
        }

        var canPaste: Bool {
            let pasteboard = NSPasteboard.general
            return pasteboard.canReadItem(withDataConformingToTypes: [DraggedEntry.pasteboardType.rawValue])
                || pasteboard.canReadObject(forClasses: [NSURL.self], options: Self.fileURLOptions)
        }

        // Inline rename, Finder-style: the name cell becomes editable, the base name is
        // selected, Return commits, Esc cancels.

        private var editing: (entry: RemoteEntry, field: NSTextField)?
        private var editCancelled = false

        func beginRename(row: Int) {
            guard let table, parent.enabled, row < entries.count else { return }
            let column = table.column(withIdentifier: Column.name.identifier)
            guard column >= 0 else { return }
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
            guard let cell = table.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView,
                  let field = cell.textField else { return }
            let entry = entries[row]
            field.isEditable = true
            field.isSelectable = true
            field.delegate = self
            editing = (entry, field)
            editCancelled = false
            table.window?.makeFirstResponder(field)
            if let editor = field.currentEditor() {
                let name = entry.name as NSString
                let ext = entry.isDirectory ? "" : name.pathExtension
                let length = ext.isEmpty ? name.length : name.length - (ext as NSString).length - 1
                editor.selectedRange = NSRange(location: 0, length: max(0, length))
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                editCancelled = true
                table?.window?.makeFirstResponder(table)
                return true
            }
            return false
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let (entry, field) = editing else { return }
            editing = nil
            field.isEditable = false
            field.isSelectable = false
            let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if editCancelled || newName.isEmpty || newName == entry.name {
                field.stringValue = entry.name
            } else {
                parent.host.rename(entry, to: newName)
            }
            if table?.window?.firstResponder !== table { table?.window?.makeFirstResponder(table) }
        }

        // Cells

        static func rowHeight(for textSize: Double) -> CGFloat {
            (textSize * 1.7).rounded()
        }

        /// Cells are made per text size, so changing it doesn't reuse cells of the old size.
        private static func cellIdentifier(_ column: Column, _ textSize: Double) -> NSUserInterfaceItemIdentifier {
            NSUserInterfaceItemIdentifier("\(column.identifier.rawValue).\(Int(textSize))")
        }

        private static func makeCell(_ column: Column, textSize: Double) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = cellIdentifier(column, textSize)
            let text = NSTextField(labelWithString: "")
            text.translatesAutoresizingMaskIntoConstraints = false
            text.lineBreakMode = column == .name ? .byTruncatingMiddle : .byTruncatingTail
            text.alignment = column.alignment
            text.font = column == .size || column == .modified
                ? .monospacedDigitSystemFont(ofSize: textSize, weight: .regular)
                : .systemFont(ofSize: textSize)
            let iconSize = (textSize * 1.25).rounded()
            cell.addSubview(text)
            cell.textField = text

            if column == .name {
                let image = NSImageView()
                image.translatesAutoresizingMaskIntoConstraints = false
                image.imageScaling = .scaleProportionallyUpOrDown
                cell.addSubview(image)
                cell.imageView = image
                NSLayoutConstraint.activate([
                    image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    image.widthAnchor.constraint(equalToConstant: iconSize),
                    image.heightAnchor.constraint(equalToConstant: iconSize),
                    text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
                ])
            } else {
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2).isActive = true
            }
            NSLayoutConstraint.activate([
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        private static let byteFormatter: NumberFormatter = {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.usesGroupingSeparator = true
            return formatter
        }()

        static func format(size: UInt64, _ display: SizeDisplay) -> String {
            switch display {
            case .auto: ByteFormat.string(size)
            case .bytes: byteFormatter.string(from: NSNumber(value: size)) ?? String(size)
            }
        }
    }
}
