import AppKit
import DeviceCore
import OSLog
import SwiftUI

/// Right-hand side of a window: path bar, file list, status bar; actions and view options
/// live in the window toolbar as icon + text buttons.
struct BrowserView: View {
    @Bindable var browser: BrowserModel
    let deviceID: String?
    let session: DeviceSession?
    let deviceName: String
    /// Expands this device in the sidebar (used when the star points at an existing shortcut).
    var revealInSidebar: () -> Void = {}
    @AppStorage(SettingsKey.sizeDisplay) private var sizeDisplay = SizeDisplay.auto
    @AppStorage(SettingsKey.toolbarStyle) private var toolbarStyle = ToolbarStyle.titleBar
    @AppStorage(SettingsKey.showPreviewPanel) private var showPreview = false
    @Environment(\.openWindow) private var openWindow
    @State private var pendingDelete: [RemoteEntry]?
    @State private var batchRenameRequest: BatchRenameRequest?

    private func requestBatchRename(_ entries: [RemoteEntry]) {
        guard isConnected, entries.count > 1 else { return }
        let renaming = Set(entries.map(\.name))
        batchRenameRequest = BatchRenameRequest(entries: entries,
                                                others: browser.allNames.subtracting(renaming))
    }
    @Environment(TransferQueue.self) private var queue

    private func requestUpload(_ urls: [URL], into folder: RemoteRef?) {
        guard let fs = browser.fileSystem, let deviceID, let target = folder ?? browser.location, !urls.isEmpty else { return }
        showDialog(.upload(UploadRequest(deviceID: deviceID, deviceName: deviceName, sources: urls,
                                         destination: target, fileSystem: fs)))
    }

    private func requestDeviceCopy(_ items: [DraggedEntry], into folder: RemoteRef?, move: Bool) -> Bool {
        guard let fs = browser.fileSystem, let deviceID, let target = folder ?? browser.location,
              let first = items.first else { return false }
        guard let sourceFS = queue.fileSystem(of: first.deviceID) else {
            browser.operationError = String(localized: "\(first.deviceName) isn’t connected. Connect it to copy these items.")
            return false
        }
        showDialog(.deviceCopy(DeviceCopyRequest(items: items, sourceFileSystem: sourceFS, destinationDeviceID: deviceID,
                                                 destinationDeviceName: deviceName, destination: target,
                                                 destinationFileSystem: fs, move: move)))
        return true
    }

    private func chooseFilesToUpload() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Upload")
        if panel.runModal() == .OK { requestUpload(panel.urls, into: nil) }
    }

    /// While disconnected the window keeps showing where it was, but nothing can be
    /// selected, opened or navigated until the device is back.
    private var isConnected: Bool { browser.fileSystem != nil }

    private func requestDownload(_ entries: [RemoteEntry], droppedAt folder: URL? = nil,
                                 completions: [(Error?) -> Void] = []) {
        guard let fs = browser.fileSystem, let deviceID, !entries.isEmpty else {
            completions.forEach { $0(CocoaError(.userCancelled)) }
            return
        }
        showDialog(.download(DownloadRequest(deviceID: deviceID, deviceName: deviceName, entries: entries,
                                             fileSystem: fs, droppedAt: folder, completions: completions)))
    }

    private func showDialog(_ request: TransferDialogRequest) {
        openWindow(id: WindowID.transferDialog, value: TransferDialogs.register(request))
    }

    /// The file list with its state overlays (connecting, waiting, errors, empty).
    @ViewBuilder private var fileList: some View {
        FileTableView(
            entries: browser.visibleEntries,
            locationKey: browser.location?.path,
            enabled: isConnected,
            selection: $browser.selection,
            renamingID: $browser.renamingID,
            sort: $browser.sort,
            sizeDisplay: sizeDisplay,
            textSize: TextSettings.shared.scale(for: .fileList).size(.body),
            headerTextSize: TextSettings.shared.scale(for: .fileList).size(.subheadline),
            host: self,
            dragOrigin: deviceID.map { DragOrigin(deviceID: $0, deviceName: deviceName) },
            currentFolder: browser.location
        )
        .overlay {
            if !isConnected {
                if let session, session.isConnecting {
                    ConnectingCard(deviceName: deviceName, stage: session.connectStage, since: session.connectStarted)
                        .scaledButtons()
                } else if let session, session.adb != nil || session.usb != nil,
                          let device = session.descriptor, device.status != .ready {
                    // Still plugged in, but waiting on something (USB debugging, a permission…).
                    ConnectionSteps(device: device, session: session)
                        .shadow(radius: 8, y: 2)
                } else {
                    DisconnectedCard(deviceName: deviceName, path: browser.location?.path)
                }
            } else if browser.connectionLost {
                WaitingCard(title: String(localized: "Checking the connection to \(deviceName)…"), detail: nil, since: nil)
                    .scaledButtons()
            } else if browser.isLoading && browser.visibleEntries.isEmpty && browser.error == nil {
                ListingWaitCard(folderName: browser.location?.name ?? "", since: browser.loadStarted,
                                fileSystem: browser.fileSystem)
                    .scaledButtons()
            } else if let error = browser.error {
                MessageView(title: Text("Can’t Load This Folder"), systemImage: "exclamationmark.triangle",
                            description: Text(error)) {
                    if let path = browser.location?.path, session?.isFavorite(path) == true {
                        Button("Remove from Favorites") { session?.removeFavorite(path) }
                    }
                }
            } else if !browser.isLoading && browser.visibleEntries.isEmpty {
                if browser.unfilteredCount > 0 {
                    MessageView(title: Text("No Matches"), systemImage: "magnifyingglass",
                                description: browser.nameFilterIsInvalid ? Text("The search pattern isn’t valid.")
                                    : browser.nameFilterIsRegex ? Text("No names in this folder match “\(browser.nameFilter)”.")
                                    : Text("No names in this folder contain “\(browser.nameFilter)”.")) {
                        Button("Show All") { browser.nameFilter = "" }
                    }
                } else {
                    MessageView(Text("Empty Folder"), systemImage: "folder")
                }
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if toolbarStyle == .separateRow {
                HStack(spacing: 2) {
                    actionButtons
                    Spacer()
                }
                .buttonStyle(.accessoryBar)
                .toggleStyle(.button)
                .menuStyle(.button)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                Divider()
            }
            PathBar(browser: browser, deviceName: deviceName, session: session,
                    enabled: isConnected, revealInSidebar: revealInSidebar)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .textArea(.pathBar)
            Divider()
            // Over MTP, unless MTP was chosen for this phone.
            if let session, session.activeTransport == .mtp, session.adb?.status != .ready, session.preference != .mtp {
                AdbSuggestionBar(session: session)
                    .scaledButtons()
            }
            HStack(spacing: 0) {
                fileList
                if showPreview {
                    Divider()
                    PreviewPanel(selected: browser.selectedEntries, deviceID: deviceID,
                                 fs: isConnected ? browser.fileSystem : nil, open: open)
                        .scaledFrame(width: 300)
                        .textArea(.panels)
                }
            }
            Group {
                TransferBar()
                    .textArea(.statusBar)
                Divider()
                // Part of the file list as far as people are concerned ("12 items").
                StatusBar(browser: browser, sizeDisplay: sizeDisplay)
                    .textArea(.fileList)
            }
        }
        #if DEBUG
        // Development: -dev.showDialog download|upload:/local/path opens that dialog once
        // the folder is listed, for checking it in snapshots.
        .onChange(of: browser.visibleEntries.isEmpty || browser.isLoading, initial: true) { _, notReady in
            guard !notReady, !DevelopmentDialog.shown, let spec = UserDefaults.standard.string(forKey: "dev.showDialog") else { return }
            // A launch argument can't be removed from the defaults; remember it's done instead.
            DevelopmentDialog.shown = true
            if spec == "download" {
                requestDownload(browser.visibleEntries)
            } else if spec.hasPrefix("upload:") {
                requestUpload([URL(fileURLWithPath: String(spec.dropFirst(7)))], into: nil)
            } else if spec.hasPrefix("select:") {
                let names = Set(spec.dropFirst(7).split(separator: ";").map(String.init))
                browser.selection = Set(browser.visibleEntries.filter { names.contains($0.name) }.map(\.id))
            } else if spec.hasPrefix("filter:") {
                // Types each text into the name filter in turn, 1.5 s apart, logging how long each took.
                Task {
                    for text in spec.dropFirst(7).split(separator: ";", omittingEmptySubsequences: false) {
                        try? await Task.sleep(for: .seconds(1.5))
                        let started = ContinuousClock.now
                        browser.nameFilter = String(text)
                        let took = ContinuousClock.now - started
                        Logger(subsystem: WorkNames.subsystem, category: "development")
                            .notice("filter \"\(text, privacy: .public)\": \(browser.visibleEntries.count, privacy: .public) of \(browser.unfilteredCount, privacy: .public) in \(took, privacy: .public)")
                    }
                }
            } else if spec.hasPrefix("selectEach:") {
                let names = spec.dropFirst(11).split(separator: ";").map(String.init)
                let every = UserDefaults.standard.object(forKey: "dev.selectEvery") == nil
                    ? 2 : UserDefaults.standard.double(forKey: "dev.selectEvery")
                Task {
                    for name in names {
                        guard let entry = browser.visibleEntries.first(where: { $0.name == name }) else { continue }
                        browser.selection = [entry.id]
                        try? await Task.sleep(for: .seconds(every))
                    }
                }
            } else if spec.hasPrefix("view:") {
                for name in spec.dropFirst(5).split(separator: ";") {
                    guard let entry = browser.visibleEntries.first(where: { $0.name == name }) else { continue }
                    if UserDefaults.standard.string(forKey: "dev.openWith") == "default" {
                        openFile(entry, with: nil)
                    } else {
                        open(entry)
                    }
                }
            }
        }
        #endif
        .sheet(item: $batchRenameRequest) { BatchRenameSheet(request: $0, browser: browser) }
        .alert(deleteTitle, isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
               presenting: pendingDelete) { targets in
            Button("Delete", role: .destructive) { Task { await browser.delete(targets) } }
            Button("Cancel", role: .cancel) {}
        } message: { targets in
            if targets.contains(where: \.isDirectory) {
                Text("They’re deleted from the device right away, including everything inside folders. This can’t be undone.")
            } else {
                Text("They’re deleted from the device right away. This can’t be undone.")
            }
        }
        .alert("Couldn’t Complete the Operation", isPresented: Binding(get: { browser.operationError != nil },
                                                                     set: { if !$0 { browser.operationError = nil } })) {
            Button("OK") {}
        } message: {
            Text(browser.operationError ?? "")
        }
        .navigationTitle(browser.location?.name ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? ""))
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { browser.goBack() } label: { Label("Back", systemImage: "chevron.left") }
                    .disabled(!browser.canGoBack)
                    .keyboardShortcut("[", modifiers: .command)
                    .help("Back")
                    .labelStyle(.iconOnly)
                Button { browser.goForward() } label: { Label("Forward", systemImage: "chevron.right") }
                    .disabled(!browser.canGoForward)
                    .keyboardShortcut("]", modifiers: .command)
                    .help("Forward")
                    .labelStyle(.iconOnly)
                Button { browser.goUp() } label: { Label("Enclosing Folder", systemImage: "arrow.up") }
                    .disabled(!isConnected || !browser.canGoUp)
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    .help("Enclosing Folder")
                    .labelStyle(.iconOnly)
            }
            if toolbarStyle == .titleBar {
                ToolbarItemGroup(placement: .primaryAction) {
                    actionButtons
                }
            }
            ToolbarItem(placement: .primaryAction) {
                SearchField(text: $browser.nameFilter, isRegex: $browser.nameFilterIsRegex)
                    .frame(minWidth: 140, idealWidth: 200, maxWidth: 240)
            }
        }
    }
}

extension BrowserView {
    /// File actions and view options. Defined once; shown in the title bar or in a row of
    /// their own depending on the "Toolbar Buttons" setting.
    @ViewBuilder private var actionButtons: some View {
        Button { Task { await browser.createFolder() } } label: {
            Label("New Folder", systemImage: "folder.badge.plus")
        }
        .disabled(!isConnected)
        .keyboardShortcut("n", modifiers: [.command, .shift])
        .help("New Folder")
        .labelStyle(.titleAndIcon)

        if !browser.selectedEntries.isEmpty {
            Button {
                let selected = browser.selectedEntries
                if selected.count == 1 { browser.renamingID = selected.first?.id } else { requestBatchRename(selected) }
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .disabled(!isConnected)
            .help("Rename (F2)")
            .labelStyle(.titleAndIcon)
        }

        if !browser.selectedEntries.isEmpty {
            Button { pendingDelete = browser.selectedEntries } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(!isConnected)
            .help("Delete (⌘⌫)")
            .labelStyle(.titleAndIcon)
        }

        Button { chooseFilesToUpload() } label: {
            Label("Upload", systemImage: "arrow.up.to.line")
        }
        .disabled(!isConnected)
        .keyboardShortcut("u", modifiers: [.command, .shift])
        .help("Upload files from this Mac")
        .labelStyle(.titleAndIcon)

        Button { requestDownload(browser.selectedEntries) } label: {
            Label("Download", systemImage: "arrow.down.to.line")
        }
        .disabled(!isConnected || browser.selectedEntries.isEmpty)
        .keyboardShortcut("d", modifiers: [.command, .shift])
        .help("Download to Mac")
        .labelStyle(.titleAndIcon)

        Button { browser.reload() } label: {
            Label("Reload", systemImage: "arrow.clockwise")
        }
        .disabled(!isConnected)
        .keyboardShortcut("r", modifiers: .command)
        .help("Reload")
        .labelStyle(.titleAndIcon)

        Toggle(isOn: $showPreview) {
            Label("Preview", systemImage: "sidebar.right")
        }
        .help("Show the selected file’s preview and details")
        .labelStyle(.titleAndIcon)

        Menu {
            Picker("Size", selection: $sizeDisplay) {
                Text("Auto (2.6 MB)").tag(SizeDisplay.auto)
                Text("Bytes (2,725,997)").tag(SizeDisplay.bytes)
            }
            .pickerStyle(.inline)
        } label: {
            sizeDisplay == .auto ? Text("Size: Auto") : Text("Size: Bytes")
        }
        .help("How file sizes are shown")

        Toggle(isOn: $browser.showHidden) {
            Label("Hidden Files", systemImage: browser.showHidden ? "eye" : "eye.slash")
        }
        .help("Show hidden files")
        .labelStyle(.titleAndIcon)
    }

    private var deleteTitle: String {
        guard let targets = pendingDelete else { return "" }
        return targets.count == 1
            ? String(localized: "Delete “\(targets[0].name)”?")
            : String(localized: "Delete \(targets.count) items?")
    }
}

/// Shown over the (dimmed, inactive) list while the device is away.
private struct DisconnectedCard: View {
    let deviceName: String
    let path: String?
    @Environment(\.textScale) private var scale

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "cable.connector.slash")
                .font(.system(size: 34 * max(1, scale.factor)))
                .foregroundStyle(.orange)
            Text("\(deviceName) disconnected").appFont(.title3, weight: .semibold)
            Text("This folder reopens when the device reconnects.")
                .foregroundStyle(.secondary)
            if let path {
                Text(path).appFont(.callout, design: .monospaced).foregroundStyle(.secondary)
            }
            ConnectOptions()
                .padding(.top, 10)
        }
        .multilineTextAlignment(.center)
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(radius: 8, y: 2)
    }
}

/// Explorer-style address bar: the device name (→ "/") then each path component, all
/// buttons that navigate there.
/// Clicking the last component or the empty area (or ⌘L) switches to an editable field;
/// Enter navigates, Esc or losing focus reverts.
private struct PathBar: View {
    let browser: BrowserModel
    let deviceName: String
    let session: DeviceSession?
    let enabled: Bool
    let revealInSidebar: () -> Void
    @State private var editing = false
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing {
                TextField("Path", text: $text)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit {
                        browser.navigate(to: RemoteRef(path: Self.normalize(text)))
                        editing = false
                    }
                    .onExitCommand { editing = false }
                    .onChange(of: focused) { if !focused { editing = false } }
                    .task { focused = true }
                    .padding(.horizontal, 6)
            } else {
                breadcrumbs
            }
        }
        .frame(height: 26)
        // Disconnected: keep showing where we were, but don't let it be changed.
        .allowsHitTesting(enabled)
        .opacity(enabled ? 1 : 0.55)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(editing ? Color.accentColor : Color(nsColor: .separatorColor)))
        .background {
            Button(action: beginEditing) { EmptyView() }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(!enabled)
                .opacity(0)
                .allowsHitTesting(false)
        }
    }

    private var breadcrumbs: some View {
        let parts = [(name: deviceName, path: "/")] + Self.components(of: browser.location?.path ?? "/")
        return HStack(spacing: 1) {
            ForEach(parts.indices, id: \.self) { i in
                if i > 0 {
                    Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary)
                }
                let isLast = i == parts.count - 1
                Crumb(title: parts[i].name) {
                    if isLast { beginEditing() } else { browser.navigate(to: RemoteRef(path: parts[i].path)) }
                }
                .layoutPriority(isLast ? 1 : 0)
            }
            Color.clear
                .frame(minWidth: 20, maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { beginEditing() }
            if let session, let path = browser.location?.path {
                FavoriteStar(session: session, path: path, revealInSidebar: revealInSidebar)
                    .padding(.trailing, 4)
            }
        }
        .padding(.horizontal, 3)
    }

    private func beginEditing() {
        text = browser.location?.path ?? "/"
        editing = true
    }

    static func components(of path: String) -> [(name: String, path: String)] {
        var result: [(String, String)] = []
        var current = ""
        for part in path.split(separator: "/") {
            current += "/" + part
            result.append((String(part), current))
        }
        return result
    }

    static func normalize(_ input: String) -> String {
        let parts = input.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/")
        return "/" + parts.joined(separator: "/")
    }
}

/// Like a browser's bookmark star: favorite the current folder. A folder that's already a
/// shortcut shows as saved; clicking it just reveals the shortcut instead of duplicating it.
private struct FavoriteStar: View {
    let session: DeviceSession
    let path: String
    let revealInSidebar: () -> Void

    var body: some View {
        let isShortcut = session.isShortcut(path)
        let isFavorite = session.isFavorite(path)
        Button {
            if isShortcut { revealInSidebar() } else { session.toggleFavorite(path) }
        } label: {
            Image(systemName: isShortcut || isFavorite ? "star.fill" : "star")
                .foregroundStyle(isFavorite ? Color.yellow : Color.secondary)
        }
        .buttonStyle(.borderless)
        .labelStyle(.iconOnly)
        .help(isShortcut ? Text("Already in Shortcuts") : isFavorite ? Text("Remove from Favorites") : Text("Add to Favorites"))
        .accessibilityLabel(isShortcut ? Text("Already in Shortcuts") : isFavorite ? Text("Remove from Favorites") : Text("Add to Favorites"))
    }
}

private struct Crumb: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        // A plain button rather than a tap gesture, so it's reachable with VoiceOver and the
        // keyboard like Finder's path bar.
        Button(action: action) {
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(hovering ? Color.primary.opacity(0.08) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct StatusBar: View {
    let browser: BrowserModel
    let sizeDisplay: SizeDisplay

    var body: some View {
        HStack(spacing: 6) {
            if browser.isLoading && !browser.detailsPending {
                ProgressView().controlSize(.small)
                Text("Loading… \(browser.loadedCount)")
            } else {
                if browser.visibleEntries.count == browser.unfilteredCount {
                    Text("\(browser.visibleEntries.count) items")
                } else {
                    Text("\(browser.visibleEntries.count) of \(browser.unfilteredCount) items")
                }
                if browser.detailsPending {
                    ProgressView().controlSize(.mini)
                    Text("· loading sizes and dates")
                    if browser.sortIsDeferred { Text("(sorted when done)") }
                }
            }
            let selected = browser.selectedEntries
            if !selected.isEmpty {
                let bytes = selected.reduce(UInt64(0)) { $0 + ($1.size ?? 0) }
                Text("· \(selected.count) selected (\(FileTableView.Coordinator.format(size: bytes, sizeDisplay)))")
            }
            Spacer()
        }
        .appFont(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }
}

#if DEBUG
/// -dev.showDialog opens its dialog once per launch.
@MainActor enum DevelopmentDialog {
    static var shown = false
}
#endif

extension BrowserView: FileListHost {
    func open(_ entry: RemoteEntry) {
        if entry.kind == .file {
            showFile(entry)
        } else {
            browser.activate(entry)
        }
    }

    func openFile(_ entry: RemoteEntry, with app: URL?) { showFile(entry, openingWith: .some(app)) }

    func goThroughHistory(forward: Bool) {
        guard forward ? browser.canGoForward : browser.canGoBack else {
            NSSound.beep()
            return
        }
        if forward { browser.goForward() } else { browser.goBack() }
    }

    func quickLook(_ entry: RemoteEntry?) {
        if FileViewers.shared.closeQuickLook() { return }
        guard let entry, ViewerKind(name: entry.name) != nil else {
            NSSound.beep()
            return
        }
        showFile(entry, quickLook: true)
    }

    private func showFile(_ entry: RemoteEntry, openingWith app: URL?? = nil, quickLook: Bool = false) {
        guard let fs = browser.fileSystem, let deviceID else { return }
        let queue = queue, session = session
        let device = ViewerDevice(id: deviceID, opened: fs, connection: { queue.fileSystem(of: deviceID) },
                                  broke: { [weak session] in session?.connectionBroke($0) })
        FileViewers.shared.show(entry, deviceID: deviceID, deviceName: deviceName, device: device, openingWith: app,
                                quickLook: quickLook)
    }

    func sidebarPlace(of path: String) -> SidebarPlace {
        guard let session else { return .shortcut }
        return session.isShortcut(path) ? .shortcut : session.isFavorite(path) ? .favorite : .none
    }

    func toggleInSidebar(_ path: String) { session?.toggleFavorite(path) }

    func openInNewWindow(_ entry: RemoteEntry) {
        openWindow(id: WindowID.browser, value: BrowserTarget(deviceID: deviceID, path: entry.ref.path))
    }

    func download(_ entries: [RemoteEntry]) { requestDownload(entries) }
    func rename(_ entry: RemoteEntry, to name: String) { Task { await browser.rename(entry, to: name) } }
    func renameTogether(_ entries: [RemoteEntry]) { requestBatchRename(entries) }
    func confirmDelete(_ entries: [RemoteEntry]) { pendingDelete = entries }
    func newFolder() { Task { await browser.createFolder() } }
    func upload(_ urls: [URL], into folder: RemoteRef?) { requestUpload(urls, into: folder) }
    func visibleRowsChanged(_ ids: [String]) { browser.visibleRowsChanged(ids) }

    func copyFromDevice(_ items: [DraggedEntry], into folder: RemoteRef?, move: Bool) -> Bool {
        requestDeviceCopy(items, into: folder, move: move)
    }

    func downloadDropped(_ entries: [RemoteEntry], to folder: URL, completions: [(Error?) -> Void]) {
        // Same dialog as the Download button; Finder waits on the promises meanwhile.
        requestDownload(entries, droppedAt: folder, completions: completions)
    }
}
