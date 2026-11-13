import AppKit
import AVFoundation
import Carbon.HIToolbox
import CryptoKit
import DeviceCore
import ImageIO
import PDFKit
import SwiftUI
import TransferKit
import UniformTypeIdentifiers

/// What the viewer shows a file as, from the type its name says.
enum ViewerKind {
    case image, pdf, text
    /// Video or audio, played while it's read.
    case media

    init?(name: String) {
        guard let type = FileOpening.type(of: name) else { return nil }
        if type.conforms(to: .pdf) {
            self = .pdf
        } else if Self.plays(type) {
            self = .media
        } else if type.conforms(to: .image) {
            self = .image
        } else if type.conforms(to: .text), !type.conforms(to: .rtf), !type.conforms(to: .rtfd) {
            // Plain text, source code, JSON, XML, HTML (shown as written).
            self = .text
        } else {
            return nil
        }
    }

    /// Largest file the viewer shows, in bytes (Settings ▸ Viewer).
    var limit: UInt64 {
        let key: String
        switch self {
        case .media: return .max // only the parts played are read
        case .image: key = SettingsKey.viewerImageLimitMB
        case .pdf: key = SettingsKey.viewerPDFLimitMB
        case .text: key = SettingsKey.viewerTextLimitMB
        }
        return UInt64(max(UserDefaults.standard.integer(forKey: key), 1)) * 1_000_000
    }
}

/// Opening a device file in an app on this Mac: it's received to a temporary folder that's
/// emptied when the app quits (and at launch, after a crash). Changes made there stay there.
/// Each device file has one place there, so opening it again replaces the copy (or reuses it,
/// when the file hasn't changed) rather than adding another.
@MainActor
enum FileOpening {
    static let folder = FileManager.default.temporaryDirectory.appendingPathComponent("\(WorkNames.tag)-open")

    nonisolated static func type(of name: String) -> UTType? {
        let ext = (name as NSString).pathExtension
        return ext.isEmpty ? nil : UTType(filenameExtension: ext)
    }

    /// The app macOS opens this kind of file with.
    static func defaultApp(for name: String) -> URL? {
        NSWorkspace.shared.urlForApplication(toOpen: type(of: name) ?? .data)
    }

    /// Apps that say they open this kind of file, the default first.
    static func apps(for name: String) -> [URL] {
        let all = NSWorkspace.shared.urlsForApplications(toOpen: type(of: name) ?? .data)
        let first = defaultApp(for: name)
        var seen = Set<String>()
        return ([first].compactMap { $0 } + all).filter { seen.insert($0.path).inserted }
    }

    static func appName(_ app: URL) -> String {
        FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
    }

    /// The place for this device file, keeping its name (the app shows it): the same every time.
    static func place(for entry: RemoteEntry, deviceID: String) throws -> URL {
        let digest = SHA256.hash(data: Data("\(deviceID)\n\(entry.ref.path)".utf8))
        let dir = folder.appendingPathComponent(digest.prefix(8).map { String(format: "%02x", $0) }.joined())
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(entry.name)
    }

    /// The copy at `url` is the device file as it is now (same size and date).
    static func isCurrent(_ url: URL, for entry: RemoteEntry) -> Bool {
        guard let size = entry.size, let modified = entry.modified,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.size] as? NSNumber)?.uint64Value == size,
              let date = attributes[.modificationDate] as? Date else { return false }
        return abs(date.timeIntervalSince(modified)) < 2
    }

    static func removeAll() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Asks for an app in /Applications (Open With ▸ Other…).
    static func chooseApp() -> URL? {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = String(localized: "Open")
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// One viewer window's file and what's shown of it.
@MainActor @Observable
final class FileViewerModel {
    enum Content {
        case loading
        case image(CGImage)
        case pdf(PDFDocument)
        case media(AVPlayer)
        /// `indented`: the same JSON laid out (nil when it isn't JSON).
        case text(String, indented: String?)
        /// Not shown here; only opening it in an app.
        case notShown(NotShown)
        case failed(String)
    }

    enum NotShown {
        case kind
        case tooLarge(limit: UInt64)
        case unreadableImage
        case unreadablePDF
        case unplayable
        case notText
    }

    private(set) var entry: RemoteEntry
    let deviceName: String
    private let device: ViewerDevice
    /// The device's connection now (another one once it's back after dropping).
    private var fs: any DeviceFileSystem { device.connection() ?? device.opened }
    /// Playing stopped where the device's connection dropped; carries on once it's back.
    private(set) var waitingForDevice = false
    /// A picture's size on screen.
    let zoom = ImageZoom()
    private(set) var content = Content.loading
    private(set) var received = 0
    /// Receiving the file to open it in an app: bytes so far.
    private(set) var opening: Int?
    private(set) var openFailure: String?
    private var data: Data?
    private var loader: DeviceMediaLoader?
    private var task: Task<Void, Never>?
    private var openTask: Task<Void, Never>?
    /// Closes the window (when it was opened only to hand the file to an app).
    var close: () -> Void = {}
    /// Gives the window the shape of a picture (`false`) or video (`true`) of this size, and
    /// shows it if it's waiting for that.
    var fitWindow: (CGSize, _ isVideo: Bool) -> Void = { _, _ in }
    /// The window has its shape; later news of the size (the decoded picture) leaves it be.
    @ObservationIgnored private var fitted = false

    init(entry: RemoteEntry, deviceName: String, device: ViewerDevice) {
        self.entry = entry
        self.deviceName = deviceName
        self.device = device
    }

    var defaultApp: URL? { FileOpening.defaultApp(for: entry.name) }

    func load() {
        task?.cancel()
        content = .loading
        received = 0
        task = Task { await read() }
    }

    private func read() async {
        guard let kind = ViewerKind(name: entry.name),
              kind == .media ? fs.capabilities.readsRanges : fs.capabilities.streamsFiles else {
            content = .notShown(.kind)
            return
        }
        do {
            if entry.size == nil || entry.isPartial { entry = try await fs.entry(at: entry.ref) }
            if let size = entry.size, size > kind.limit {
                content = .notShown(.tooLarge(limit: kind.limit))
                return
            }
            if kind == .media {
                try await play()
                return
            }
            // The picture's size is in its first bytes: the window takes its shape before the
            // rest arrives.
            if kind == .image, fs.capabilities.readsRanges, let size = entry.size, size > Self.headerBytes,
               let head = try? await FilePreviewLoader.read(entry, bytes: Self.headerBytes, from: fs),
               let shape = FileDecoding.pictureSize(from: head, complete: false) {
                fit(shape, isVideo: false)
            }
            let data = try await RemoteContents.data(of: entry, from: fs, limit: Int(kind.limit)) { [weak self] n in
                Task { @MainActor in self?.received += n }
            }
            self.data = data
            switch kind {
            case .image:
                // Decoding a big photo takes a moment; not on the main thread.
                let image = await Task.detached { FileDecoding.image(from: data) }.value
                try Task.checkCancellation()
                content = image.map(Content.image) ?? .notShown(.unreadableImage)
                if let image { fit(CGSize(width: image.width, height: image.height), isVideo: false) }
            case .pdf:
                if let document = PDFDocument(data: data), !document.isLocked {
                    content = .pdf(document)
                } else {
                    content = .notShown(.unreadablePDF)
                }
            case .text:
                let isJSON = FileOpening.type(of: entry.name)?.conforms(to: .json) == true
                let read = await Task.detached { () -> (String, String?)? in
                    guard let text = FileDecoding.text(from: data) else { return nil }
                    return (text, isJSON ? JSONLayout.indented(text) : nil)
                }.value
                content = read.map { .text($0.0, indented: $0.1) } ?? .notShown(.notText)
            case .media:
                break // played above, without reading it all
            }
        } catch is CancellationError where Task.isCancelled {
        } catch is RemoteContents.TooLarge {
            content = .notShown(.tooLarge(limit: kind.limit))
        } catch {
            content = .failed(UserMessage.describe(error))
        }
    }

    /// Enough of a picture's start for its size: JPEG puts it after the Exif (usually well
    /// inside 64 KB), PNG and HEIC near the very start.
    private static let headerBytes: UInt64 = 64 * 1024

    private func fit(_ size: CGSize, isVideo: Bool) {
        guard !fitted else { return }
        fitted = true
        fitWindow(size, isVideo)
    }

    /// Receives the file (or uses what's already here) and opens it in `app` (nil: the
    /// default one).
    func open(with app: URL?, thenClose: Bool = false) {
        guard opening == nil else { return }
        openFailure = nil
        opening = 0
        let reading = ViewerKind(name: entry.name) == .media ? nil : task
        openTask = Task {
            defer { opening = nil }
            // A read into memory under way is waited for and used, not read a second time.
            if data == nil, let reading { await reading.value }
            do {
                try Task.checkCancellation()
                let url = try FileOpening.place(for: entry, deviceID: device.id)
                // Both write beside the old copy and then take its place, so an app that still
                // has it open keeps what it had; both keep the device file's date.
                if FileOpening.isCurrent(url, for: entry) {
                } else if let data {
                    try data.write(to: url, options: .atomic)
                    if let modified = entry.modified {
                        try? FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
                    }
                } else {
                    try await fs.download(entry, to: url) { [weak self] n in
                        Task { @MainActor in self?.opening? += n }
                    }
                }
                guard let app = app ?? defaultApp else {
                    openFailure = String(localized: "No app on this Mac opens this kind of file. Choose one with Open With.")
                    return
                }
                _ = try await NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                if thenClose { close() }
            } catch is CancellationError where Task.isCancelled {
            } catch {
                openFailure = UserMessage.describe(error)
            }
        }
    }

    private func play() async throws {
        guard let size = entry.size, let type = FileOpening.type(of: entry.name) else {
            content = .notShown(.unplayable)
            return
        }
        let loader = DeviceMediaLoader(entry: entry, size: size, fs: fs, contentType: type.identifier) { [weak self] lost, error in
            await self?.connection(replacing: lost, after: error)
        }
        self.loader = loader
        let asset = loader.makeAsset()
        guard try await asset.load(.isPlayable) else {
            content = .notShown(.unplayable)
            return
        }
        try Task.checkCancellation()
        if let track = try await asset.loadTracks(withMediaType: .video).first {
            let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
            let shown = natural.applying(transform)
            try Task.checkCancellation()
            fit(CGSize(width: abs(shown.width), height: abs(shown.height)), isVideo: true)
        }
        try Task.checkCancellation()
        let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        content = .media(player)
        player.play()
        #if DEBUG
        DevelopmentLaunchArguments.seek(player)
        #endif
    }

    /// After a read failed on `lost`: the device's next connection, waited for while the window
    /// is open, or nil when the connection is fine and the read failed for another reason.
    private func connection(replacing lost: any DeviceFileSystem, after error: Error) async -> (any DeviceFileSystem)? {
        let gone = lost.isConnectionLoss(error)
        if gone { device.broke(lost) }
        // Unplugged, a read can fail (cut short) before the device's removal is noticed.
        let noticeBy = ContinuousClock.now + .seconds(3)
        defer { waitingForDevice = false }
        while !Task.isCancelled {
            let current = device.connection()
            if let current, current !== lost { return current }
            if current === lost, !gone {
                if ContinuousClock.now > noticeBy { return nil }
            } else {
                waitingForDevice = true
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
        return nil
    }

    func stop() {
        task?.cancel()
        task = nil
        openTask?.cancel()
        openTask = nil
        if case .media(let player) = content {
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
        loader?.stop()
        loader = nil
    }
}

/// The device a viewer reads from: the connection it opened with, and the device's connection
/// now, which changes when it drops and comes back (over Wi-Fi, or plugged in again).
struct ViewerDevice {
    let id: String
    let opened: any DeviceFileSystem
    let connection: @MainActor () -> (any DeviceFileSystem)?
    /// Tells the device a connection stopped answering.
    let broke: @MainActor (any DeviceFileSystem) -> Void
}

/// The viewer windows, one per file (opening the same file again brings its window forward).
@MainActor
final class FileViewers: NSObject, NSWindowDelegate {
    static let shared = FileViewers()
    private var windows: [ObjectIdentifier: (key: String, model: FileViewerModel)] = [:]
    /// Windows waiting for their file's size before they show: nothing else holds them yet.
    private var unshown: [ObjectIdentifier: NSWindow] = [:]
    /// The window Space opened from a file list (Quick Look): it comes up without taking the
    /// keyboard, and the next Space closes it.
    private weak var quickLookWindow: NSWindow?

    override init() {
        super.init()
        // Space in a viewer window closes it, as in Quick Look; a video or song keeps Space
        // for play and pause.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard Int(event.keyCode) == kVK_Space, event.modifierFlags.isDisjoint(with: [.command, .option, .control, .shift])
            else { return event }
            let number = event.windowNumber
            // Key events arrive on the main thread.
            return MainActor.assumeIsolated { self?.closeOnSpace(windowNumber: number) == true } ? nil : event
        }
    }

    /// Closes that viewer window, unless it plays a video or song or a space is being typed
    /// (the find bar).
    private func closeOnSpace(windowNumber: Int) -> Bool {
        guard let window = NSApp.window(withWindowNumber: windowNumber), let viewer = windows[ObjectIdentifier(window)],
              ViewerKind(name: viewer.model.entry.name) != .media,
              (window.firstResponder as? NSTextView)?.isEditable != true else { return false }
        window.close()
        return true
    }

    /// Closes the window Space opened, if it's still there. True if there was one.
    func closeQuickLook() -> Bool {
        guard let window = quickLookWindow, windows[ObjectIdentifier(window)] != nil else { return false }
        window.close()
        return true
    }

    /// Shows `entry` in its window; with `app`, only receives it and opens it there (`.some(nil)`:
    /// the default app), closing the window once it's open. Meanwhile the window shows how far
    /// it got. `quickLook`: the window comes up behind the keyboard (see `quickLookWindow`).
    func show(_ entry: RemoteEntry, deviceID: String, deviceName: String, device: ViewerDevice,
              openingWith app: URL?? = nil, quickLook: Bool = false) {
        let key = "\(deviceID)\n\(entry.ref.path)"
        if let (window, model) = windows.first(where: { $0.value.key == key }).flatMap({ id, value in
            NSApp.windows.first { ObjectIdentifier($0) == id }.map { ($0, value.model) }
        }) {
            if quickLook {
                quickLookWindow = window
                window.orderFront(nil)
            } else {
                window.makeKeyAndOrderFront(nil)
            }
            if let app { model.open(with: app) }
            return
        }
        let model = FileViewerModel(entry: entry, deviceName: deviceName, device: device)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        let hosting = NSHostingController(rootView: FileViewerView(model: model).textArea(.panels))
        // The view's title, subtitle and toolbar become the window's.
        hosting.sceneBridgingOptions = [.title, .toolbars]
        window.contentViewController = hosting
        window.toolbarStyle = .unified
        window.title = entry.name
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.delegate = self
        window.setContentSize(NSSize(width: 900, height: 640))
        if let key = NSApp.keyWindow {
            window.setFrameTopLeftPoint(key.cascadeTopLeft(from: NSPoint(x: key.frame.minX, y: key.frame.maxY)))
        } else {
            window.center()
        }
        windows[ObjectIdentifier(window)] = (key, model)
        if quickLook { quickLookWindow = window }
        model.close = { [weak window] in window?.close() }
        model.fitWindow = { [weak self, weak window] size, isVideo in
            guard let window else { return }
            self?.fit(window, around: size, isVideo: isVideo)
            self?.present(window)
        }
        if let app {
            // Read the way the viewer reads (one read, used for the app), but a video or song
            // isn't played.
            if ViewerKind(name: entry.name) != .media { model.load() }
            model.open(with: app, thenClose: true)
        } else {
            model.load()
        }
        // A picture or video waits a moment for its size, so its window opens in its shape
        // rather than changing after it appears.
        let kind = ViewerKind(name: entry.name)
        if app == nil, kind == .image || kind == .media {
            unshown[ObjectIdentifier(window)] = window
            Task { [weak self, weak window] in
                try? await Task.sleep(for: .milliseconds(700))
                if let window { self?.present(window) }
            }
        } else {
            present(window)
        }
        #if DEBUG
        DevelopmentViewer.zoomSteps(model.zoom)
        DevelopmentViewer.closeEarly(window) { [weak self] in
            self?.show(entry, deviceID: deviceID, deviceName: deviceName, device: device, openingWith: app)
        }
        #endif
    }

    /// The window in the media's shape, at most half the screen across and 70% of its height
    /// (title bar included), and never narrower than `minimumWidth`: a picture up to its own
    /// size (it isn't enlarged), a video at least 800 wide where that fits. Stays where it
    /// was, on the screen.
    private func fit(_ window: NSWindow, around media: CGSize, isVideo: Bool) {
        guard media.width > 0, media.height > 0, let screen = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        // Title bar and toolbar (the toolbar may not be in place yet before the window shows).
        let titleBar = max(window.frame.height - window.contentLayoutRect.height, 52)
        let room = CGSize(width: screen.width / 2, height: screen.height * 0.7 - titleBar)
        let fitting = min(room.width / media.width, room.height / media.height)
        let scale = isVideo ? min(fitting, max(1, 800 / media.width)) : min(fitting, 1)
        let size = NSSize(width: max((media.width * scale).rounded(), FileViewerView.minimumWidth),
                          height: max((media.height * scale).rounded(), 240))
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.size.height = size.height + titleBar
        frame.origin = NSPoint(x: window.frame.midX - frame.width / 2, y: window.frame.midY - frame.height / 2)
        frame.origin.x = min(max(frame.minX, screen.minX), screen.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, screen.minY), screen.maxY - frame.height)
        window.setFrame(frame, display: true, animate: window.isVisible)
    }

    private func present(_ window: NSWindow) {
        unshown[ObjectIdentifier(window)] = nil
        // Closed before it came up (Space pressed again): it stays closed.
        guard !window.isVisible, windows[ObjectIdentifier(window)] != nil else { return }
        if window === quickLookWindow { window.orderFront(nil) } else { window.makeKeyAndOrderFront(nil) }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        unshown[ObjectIdentifier(window)] = nil
        windows.removeValue(forKey: ObjectIdentifier(window))?.model.stop()
    }
}

private extension NSWindow {
    func cascadeTopLeft(from point: NSPoint) -> NSPoint {
        NSPoint(x: point.x + 24, y: point.y - 24)
    }
}

struct FileViewerView: View {
    /// Wide enough for every toolbar button, so none is folded into the » menu.
    static let minimumWidth: CGFloat = 800
    let model: FileViewerModel
    @AppStorage(SettingsKey.viewerIndentJSON) private var indentJSON = true

    /// The device, then the file's size (and a picture's pixels).
    private var subtitle: String {
        var parts = [model.deviceName]
        if let size = model.entry.size { parts.append(ByteFormat.string(size)) }
        if case .image(let image) = model.content { parts.append("\(image.width) × \(image.height)") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                if let failure = model.openFailure {
                    Text(failure)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .padding(12)
                }
            }
        .frame(minWidth: Self.minimumWidth, minHeight: 240)
        // As in Preview: the title bar says what the file is, its toolbar what can be done.
        .navigationTitle(model.entry.name)
        .navigationSubtitle(subtitle)
        .toolbar { ViewerToolbar(model: model) }
        .background {
            // Esc closes, as Quick Look does.
            Button { model.close() } label: { EmptyView() }.keyboardShortcut(.cancelAction).hidden()
            if case .image = model.content { ImageZoomKeys(zoom: model.zoom) }
        }
    }

    @ViewBuilder private var content: some View {
        switch model.content {
        case .loading:
            VStack(spacing: 8) {
                if let size = model.entry.size, size > 0 {
                    // Read for the viewer, or received for an app.
                    let done = UInt64(max(model.received, model.opening ?? 0))
                    ProgressView(value: Double(min(done, size)), total: Double(size))
                        .frame(maxWidth: 240)
                } else {
                    ProgressView()
                }
            }
        case .image(let image):
            ZoomableImageView(image: image, zoom: model.zoom, mode: model.zoom.mode)
        case .pdf(let document):
            ViewerPDFView(document: document)
        case .media(let player):
            ViewerPlayerView(player: player)
                .overlay(alignment: .top) {
                    if model.waitingForDevice {
                        Text("Waiting for \(model.deviceName) to reconnect")
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(.regularMaterial, in: Capsule())
                            .padding(12)
                    }
                }
        case .text(let text, let indented):
            ViewerTextView(text: indentJSON ? indented ?? text : text)
        case .notShown(let reason):
            NotShownView(model: model, reason: reason)
        case .failed(let message):
            VStack(spacing: 12) {
                Text(message).multilineTextAlignment(.center)
                Button("Try Again") { model.load() }
            }
            .padding()
        }
    }
}

/// The viewer's toolbar: zoom for pictures, indenting for JSON, and opening the file in an app.
/// What doesn't fit a narrow window goes into the toolbar's » menu.
private struct ViewerToolbar: ToolbarContent {
    let model: FileViewerModel
    @AppStorage(SettingsKey.viewerIndentJSON) private var indentJSON = true

    var body: some ToolbarContent {
        if case .image = model.content {
            ImageZoomToolbar(zoom: model.zoom)
        }
        if case .text(_, let indented) = model.content, indented != nil {
            ToolbarItem {
                Toggle(isOn: $indentJSON) { Label("Indent", systemImage: "increase.indent") }
                    .help("Lay out JSON one value per line")
            }
        }
        if let opening = model.opening {
            ToolbarItem {
                if let size = model.entry.size, size > 0 {
                    // Waiting on the viewer's own read until that's done.
                    ProgressView(value: Double(min(UInt64(max(opening, model.received)), size)), total: Double(size)).frame(width: 100)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        }
        ToolbarItem { OpenMenu(model: model) }
    }
}

/// "Open in Preview", with Open With ▸ (apps for this kind, Other…) beside it.
private struct OpenMenu: View {
    let model: FileViewerModel

    var body: some View {
        let apps = FileOpening.apps(for: model.entry.name)
        Menu {
            ForEach(apps, id: \.self) { app in
                Button(FileOpening.appName(app)) { model.open(with: app) }
            }
            if !apps.isEmpty { Divider() }
            Button("Other…") {
                if let app = FileOpening.chooseApp() { model.open(with: app) }
            }
        } label: {
            if let first = model.defaultApp {
                Label("Open in \(FileOpening.appName(first))", systemImage: "arrow.up.forward.app")
            } else {
                Label("Open With", systemImage: "arrow.up.forward.app")
            }
        } primaryAction: {
            if let first = model.defaultApp {
                model.open(with: first)
            } else if let app = FileOpening.chooseApp() {
                model.open(with: app)
            }
        }
        .labelStyle(.titleAndIcon)
        .menuIndicator(.visible)
        .fixedSize()
        .disabled(model.opening != nil)
        .help("Open in an app on this Mac; the arrow chooses which")
    }
}

private struct NotShownView: View {
    let model: FileViewerModel
    let reason: FileViewerModel.NotShown

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(for: FileOpening.type(of: model.entry.name) ?? .data))
                .resizable()
                .frame(width: 96, height: 96)
            Text(model.entry.name).appFont(.title3, weight: .medium).multilineTextAlignment(.center)
            Text(explanation).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding()
    }

    private var explanation: String {
        switch reason {
        case .kind: String(localized: "This kind of file can’t be shown here. Open it in an app.")
        case .tooLarge(let limit):
            String(localized: "Larger than files shown here (\(ByteFormat.string(limit)), Settings ▸ Viewer). Open it in an app.")
        case .unreadableImage: String(localized: "This picture can’t be shown here. Open it in an app.")
        case .unreadablePDF: String(localized: "This PDF can’t be shown here. Open it in an app.")
        case .unplayable: String(localized: "This file can’t be played here. Open it in an app.")
        case .notText: String(localized: "This file doesn’t read as text. Open it in an app.")
        }
    }
}

/// Read-only, selectable text; AppKit's view stays quick with megabytes of it.
private struct ViewerTextView: NSViewRepresentable {
    let text: String
    @Environment(\.textScale) private var scale

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let view = scroll.documentView as! NSTextView
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.textContainerInset = NSSize(width: 8, height: 8)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let view = scroll.documentView as! NSTextView
        if view.string != text {
            view.string = text
            view.scrollToBeginningOfDocument(nil)
        }
        let font = NSFont.monospacedSystemFont(ofSize: scale.size(.body), weight: .regular)
        if view.font != font { view.font = font }
    }
}

/// Pages one under another, fitted to the window's width.
private struct ViewerPDFView: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = document
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
    }
}
