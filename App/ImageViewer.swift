import AppKit
import SwiftUI

/// How a picture in the viewer is sized: fitted to the window (never past its own size), or
/// at a scale. Shared by the picture and the bar's zoom buttons.
@MainActor @Observable
final class ImageZoom {
    enum Mode: Equatable {
        case fit
        case scale(CGFloat)
    }

    var mode = Mode.fit
    /// The scale on screen now, fitted or not (1 = one pixel per point).
    fileprivate(set) var shown: CGFloat = 1

    static let minimum: CGFloat = 0.05, maximum: CGFloat = 16
    private static let steps: [CGFloat] = [0.05, 0.1, 0.25, 0.5, 0.75, 1, 1.5, 2, 3, 4, 6, 8, 12, 16]

    func zoomIn() { mode = .scale(Self.steps.first { $0 > shown * 1.01 } ?? Self.maximum) }
    func zoomOut() { mode = .scale(Self.steps.last { $0 < shown * 0.99 } ?? Self.minimum) }
    var canZoomIn: Bool { shown < Self.maximum * 0.99 }
    var canZoomOut: Bool { shown > Self.minimum * 1.01 }
}

/// The picture: fitted or at a scale; pinch or ⌃/⌘-scroll to zoom, drag or scroll to move around
/// a picture larger than the window, double-click to switch between fitted and actual size.
struct ZoomableImageView: NSViewRepresentable {
    let image: CGImage
    let zoom: ImageZoom
    /// Read here so a change reaches `updateNSView`.
    let mode: ImageZoom.Mode

    func makeNSView(context: Context) -> ImageScrollView { ImageScrollView(image: image, zoom: zoom) }

    func updateNSView(_ view: ImageScrollView, context: Context) { view.apply(mode) }
}

final class ImageScrollView: NSScrollView {
    private let zoom: ImageZoom
    private let imageSize: NSSize
    private var mode = ImageZoom.Mode.fit

    init(image: CGImage, zoom: ImageZoom) {
        self.zoom = zoom
        imageSize = NSSize(width: image.width, height: image.height)
        super.init(frame: .zero)
        contentView = CenteringClipView()
        let picture = PanningImageView(frame: NSRect(origin: .zero, size: imageSize))
        picture.image = image
        picture.wantsLayer = true
        picture.layer?.contents = image
        picture.layer?.contentsGravity = .resize
        picture.layer?.minificationFilter = .trilinear
        picture.onDoubleClick = { [weak self] point in self?.toggleActualSize(at: point) }
        documentView = picture
        drawsBackground = false
        borderType = .noBorder
        hasHorizontalScroller = true
        hasVerticalScroller = true
        autohidesScrollers = true
        allowsMagnification = true
        minMagnification = ImageZoom.minimum
        maxMagnification = ImageZoom.maximum
        NotificationCenter.default.addObserver(self, selector: #selector(didMagnify), name: NSScrollView.didEndLiveMagnifyNotification, object: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Fitted: the whole picture in the window, never larger than its own size.
    private var fitScale: CGFloat {
        let space = contentSize
        guard imageSize.width > 0, imageSize.height > 0, space.width > 0, space.height > 0 else { return 1 }
        return min(1, space.width / imageSize.width, space.height / imageSize.height)
    }

    func apply(_ newMode: ImageZoom.Mode) {
        guard newMode != mode else { return }
        mode = newMode
        switch newMode {
        case .fit:
            magnification = fitScale
        case .scale(let scale):
            let visible = contentView.documentVisibleRect
            setMagnification(scale, centeredAt: NSPoint(x: visible.midX, y: visible.midY))
        }
        report()
    }

    override func tile() {
        super.tile()
        // Fitted pictures follow the window's size.
        if mode == .fit, abs(magnification - fitScale) > 0.0001 {
            magnification = fitScale
            report()
        }
    }

    private func toggleActualSize(at point: NSPoint) {
        if mode == .fit, fitScale < 1 {
            mode = .scale(1)
            setMagnification(1, centeredAt: point)
        } else {
            mode = .fit
            magnification = fitScale
        }
        report()
        zoom.mode = mode
    }

    /// ⌃ or ⌘ with the scroll wheel zooms around the pointer, as in other picture viewers.
    /// (⌥ is often macOS's own screen zoom.)
    override func scrollWheel(with event: NSEvent) {
        guard !event.modifierFlags.intersection([.control, .command]).isEmpty, let picture = documentView else {
            return super.scrollWheel(with: event)
        }
        // Away from you zooms in, whichever way scrolling is set to go.
        var delta = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
        delta *= event.hasPreciseScrollingDeltas ? 0.01 : 0.1
        guard delta != 0 else { return }
        let scale = min(max(magnification * exp(delta), ImageZoom.minimum), ImageZoom.maximum)
        setMagnification(scale, centeredAt: picture.convert(event.locationInWindow, from: nil))
        mode = .scale(magnification)
        zoom.mode = mode
        report()
    }

    @objc private func didMagnify() {
        mode = .scale(magnification)
        zoom.mode = mode
        report()
    }

    /// Tells the bar the scale on screen, outside SwiftUI's update.
    private func report() {
        let shown = magnification
        DispatchQueue.main.async { [zoom] in
            if abs(zoom.shown - shown) > 0.0001 { zoom.shown = shown }
        }
        window?.invalidateCursorRects(for: documentView!)
    }
}

/// Keeps a picture smaller than the window in the middle of it.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let picture = documentView?.frame else { return rect }
        if rect.width > picture.width { rect.origin.x = (picture.width - rect.width) / 2 }
        if rect.height > picture.height { rect.origin.y = (picture.height - rect.height) / 2 }
        return rect
    }
}

/// Dragging moves a picture larger than the window. Copy (⌘C, or the right-click menu) puts
/// the picture on the clipboard.
private final class PanningImageView: NSView {
    var onDoubleClick: (NSPoint) -> Void = { _ in }
    var image: CGImage?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // So Edit ▸ Copy reaches it without a click first.
        window?.makeFirstResponder(self)
    }

    @objc func copy(_ sender: Any?) {
        guard let image else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))])
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "Copy"), action: #selector(copy(_:)), keyEquivalent: "c").target = self
        return menu
    }
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?

    private var movable: Bool {
        guard let clip = enclosingScrollView?.contentView else { return false }
        return clip.bounds.width < frame.width - 0.5 || clip.bounds.height < frame.height - 0.5
    }

    override func resetCursorRects() {
        if movable { addCursorRect(visibleRect, cursor: .openHand) }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick(convert(event.locationInWindow, from: nil))
            return
        }
        guard movable, let clip = enclosingScrollView?.contentView else { return }
        dragStart = (event.locationInWindow, clip.bounds.origin)
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let scrollView = enclosingScrollView else { return }
        let clip = scrollView.contentView
        let scale = scrollView.magnification
        let origin = NSPoint(x: start.origin.x - (event.locationInWindow.x - start.mouse.x) / scale,
                             y: start.origin.y - (event.locationInWindow.y - start.mouse.y) / scale)
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
        scrollView.reflectScrolledClipView(clip)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStart != nil else { return }
        dragStart = nil
        NSCursor.pop()
    }
}

/// The toolbar's zoom controls, as in Preview: out and in, the scale, fit to the window, actual
/// size. The keys work whether or not the buttons fit in the toolbar.
struct ImageZoomToolbar: ToolbarContent {
    let zoom: ImageZoom

    var body: some ToolbarContent {
        ToolbarItem {
            ControlGroup {
                Button { zoom.zoomOut() } label: { Label("Zoom Out", systemImage: "minus.magnifyingglass") }
                    .disabled(!zoom.canZoomOut)
                    .help("Zoom Out (⌘−)")
                Button { zoom.zoomIn() } label: { Label("Zoom In", systemImage: "plus.magnifyingglass") }
                    .disabled(!zoom.canZoomIn)
                    .help("Zoom In (⌘+)")
            } label: {
                Label("Zoom", systemImage: "magnifyingglass")
            }
        }
        ToolbarItem {
            Text(zoom.shown, format: .percent.precision(.fractionLength(0)))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 44)
        }
        ToolbarItem {
            Button { zoom.mode = .fit } label: { Label("Fit to Window", systemImage: "arrow.down.right.and.arrow.up.left") }
                .disabled(zoom.mode == .fit)
                .help("Fit to Window (⌘9)")
        }
        ToolbarItem {
            Button { zoom.mode = .scale(1) } label: { Label("Actual Size", systemImage: "1.magnifyingglass") }
                .disabled(zoom.mode == .scale(1))
                .help("Actual Size (⌘0)")
        }
    }
}

/// The zoom keys (⌘− ⌘+ ⌘9 ⌘0), kept out of sight.
struct ImageZoomKeys: View {
    let zoom: ImageZoom

    var body: some View {
        Group {
            Button("Zoom Out") { zoom.zoomOut() }.keyboardShortcut("-", modifiers: .command)
            Button("Zoom In") { zoom.zoomIn() }.keyboardShortcut("+", modifiers: .command)
            // ⌘= as well, as in Preview: "+" needs Shift on most keyboards.
            Button("Zoom In") { zoom.zoomIn() }.keyboardShortcut("=", modifiers: .command)
            Button("Fit to Window") { zoom.mode = .fit }.keyboardShortcut("9", modifiers: .command)
            Button("Actual Size") { zoom.mode = .scale(1) }.keyboardShortcut("0", modifiers: .command)
        }
        .hidden()
    }
}
