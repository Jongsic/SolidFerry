import AppKit
import SwiftUI

/// Bridges SwiftUI browser windows to AppKit window tabbing, which macOS gives every
/// `WindowGroup` window for free.
@MainActor
enum WindowTabs {
    /// The window the next browser window should join as a tab (⌘T).
    static weak var pendingParent: NSWindow?

    /// Where the most recently active browser window was. Tabs opened with the tab bar's
    /// "+" arrive without a value and start here, like ⌘T.
    static var lastActiveTarget: BrowserTarget?

    /// Adds `window` as a tab of the pending parent, if one was requested.
    static func adopt(_ window: NSWindow) {
        guard let parent = pendingParent, parent !== window else { return }
        pendingParent = nil
        guard parent.tabbingIdentifier == window.tabbingIdentifier else { return }
        parent.addTabbedWindow(window, ordered: .above)
        window.makeKeyAndOrderFront(nil)
    }
}

/// Reports the NSWindow hosting a SwiftUI view.
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ReaderView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class ReaderView: NSView {
        var onWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }
}
