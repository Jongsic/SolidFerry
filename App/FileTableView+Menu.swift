import AppKit
import DeviceCore

extension FileTableView.Coordinator {
    // Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let table, parent.enabled else { return }
        guard table.clickedRow >= 0, table.clickedRow < entries.count else {
            // Empty area.
            menu.addItem(item(String(localized: "New Folder"), #selector(menuNewFolder(_:)), ()))
            if canPaste {
                menu.addItem(.separator())
                menu.addItem(item(String(localized: "Paste"), #selector(menuPaste(_:)), ()))
            }
            return
        }
        // Right-clicking outside the selection acts on the clicked row only (Finder behavior).
        let rows = table.selectedRowIndexes.contains(table.clickedRow)
            ? table.selectedRowIndexes : IndexSet(integer: table.clickedRow)
        let targets = rows.map { entries[$0] }

        let downloadTitle = targets.count == 1 ? String(localized: "Download…") : String(localized: "Download \(targets.count) Items…")
        menu.addItem(item(downloadTitle, #selector(menuDownload(_:)), targets))
        menu.addItem(.separator())

        if targets.count == 1, let entry = targets.first, entry.kind == .directory || entry.kind == .symlink {
            menu.addItem(item(String(localized: "Open"), #selector(menuOpen(_:)), entry))
            menu.addItem(item(String(localized: "Open in New Window"), #selector(menuOpenInNewWindow(_:)), entry))
            switch parent.host.sidebarPlace(of: entry.ref.path) {
            case .none: menu.addItem(item(String(localized: "Add to Sidebar"), #selector(menuToggleInSidebar(_:)), entry))
            case .favorite: menu.addItem(item(String(localized: "Remove from Sidebar"), #selector(menuToggleInSidebar(_:)), entry))
            case .shortcut: break
            }
            menu.addItem(.separator())
        }
        if targets.count == 1, let entry = targets.first, entry.kind == .file {
            menu.addItem(item(String(localized: "Open"), #selector(menuOpen(_:)), entry))
            menu.addItem(openWithItem(entry))
            menu.addItem(.separator())
        }
        if targets.count == 1, let entry = targets.first {
            menu.addItem(item(String(localized: "Rename"), #selector(menuRename(_:)), entry))
        } else {
            menu.addItem(item(String(localized: "Rename \(targets.count) Items…"), #selector(menuBatchRename(_:)), targets))
        }
        let deleteTitle = targets.count == 1 ? String(localized: "Delete…") : String(localized: "Delete \(targets.count) Items…")
        menu.addItem(item(deleteTitle, #selector(menuDelete(_:)), targets))
        menu.addItem(.separator())
        if parent.dragOrigin != nil {
            menu.addItem(item(targets.count == 1 ? String(localized: "Copy") : String(localized: "Copy \(targets.count) Items"), #selector(menuCopy(_:)), targets))
        }
        menu.addItem(item(targets.count == 1 ? String(localized: "Copy Path") : String(localized: "Copy \(targets.count) Paths"), #selector(menuCopyPaths(_:)), targets))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "New Folder"), #selector(menuNewFolder(_:)), ()))
    }

    private func item(_ title: String, _ action: Selector, _ payload: Any) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = payload
        return item
    }

    @objc private func menuOpen(_ sender: NSMenuItem) {
        if let entry = sender.representedObject as? RemoteEntry { parent.host.open(entry) }
    }

    /// Open With ▸ the apps for this kind of file, Other….
    private func openWithItem(_ entry: RemoteEntry) -> NSMenuItem {
        let submenu = NSMenu()
        let apps = FileOpening.apps(for: entry.name)
        for (i, app) in apps.enumerated() {
            let title = i == 0 && app == FileOpening.defaultApp(for: entry.name)
                ? String(localized: "\(FileOpening.appName(app)) (default)") : FileOpening.appName(app)
            let row = item(title, #selector(menuOpenWith(_:)), (entry, app))
            let icon = NSWorkspace.shared.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            row.image = icon
            submenu.addItem(row)
            if i == 0, apps.count > 1 { submenu.addItem(.separator()) }
        }
        if !apps.isEmpty { submenu.addItem(.separator()) }
        submenu.addItem(item(String(localized: "Other…"), #selector(menuOpenWithOther(_:)), entry))
        let parentItem = NSMenuItem(title: String(localized: "Open With"), action: nil, keyEquivalent: "")
        parentItem.submenu = submenu
        return parentItem
    }

    @objc private func menuOpenWith(_ sender: NSMenuItem) {
        if let (entry, app) = sender.representedObject as? (RemoteEntry, URL) { parent.host.openFile(entry, with: app) }
    }

    @objc private func menuOpenWithOther(_ sender: NSMenuItem) {
        if let entry = sender.representedObject as? RemoteEntry, let app = FileOpening.chooseApp() {
            parent.host.openFile(entry, with: app)
        }
    }

    @objc private func menuOpenInNewWindow(_ sender: NSMenuItem) {
        if let entry = sender.representedObject as? RemoteEntry { parent.host.openInNewWindow(entry) }
    }

    @objc private func menuToggleInSidebar(_ sender: NSMenuItem) {
        if let entry = sender.representedObject as? RemoteEntry { parent.host.toggleInSidebar(entry.ref.path) }
    }

    @objc private func menuRename(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? RemoteEntry,
              let row = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        beginRename(row: row)
    }

    @objc private func menuDelete(_ sender: NSMenuItem) {
        if let targets = sender.representedObject as? [RemoteEntry] { parent.host.confirmDelete(targets) }
    }

    @objc private func menuNewFolder(_ sender: NSMenuItem) {
        parent.host.newFolder()
    }

    @objc private func menuDownload(_ sender: NSMenuItem) {
        if let targets = sender.representedObject as? [RemoteEntry] { parent.host.download(targets) }
    }

    @objc private func menuBatchRename(_ sender: NSMenuItem) {
        guard let targets = sender.representedObject as? [RemoteEntry] else { return }
        parent.host.renameTogether(targets)
    }

    @objc private func menuCopy(_ sender: NSMenuItem) {
        guard let targets = sender.representedObject as? [RemoteEntry], let origin = parent.dragOrigin else { return }
        _ = copy(targets, origin: origin)
    }

    @objc private func menuPaste(_ sender: NSMenuItem) {
        if !paste(move: false) { NSSound.beep() }
    }

    @objc private func menuCopyPaths(_ sender: NSMenuItem) {
        guard let targets = sender.representedObject as? [RemoteEntry] else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(targets.map(\.ref.path).joined(separator: "\n"), forType: .string)
    }
}
