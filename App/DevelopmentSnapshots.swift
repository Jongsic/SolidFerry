#if DEBUG
import AppKit
import DeviceCore
import OSLog
import SwiftUI

/// Development builds only: saves the app's own windows as PNG files, so the UI can be checked
/// without granting screen recording to anything (an app may draw its own windows).
///
///     <app> -dev.snapshot /path/to/dir [-dev.snapshotDelay 4] [-dev.snapshotCount 1] [-dev.snapshotEvery 3]
///             [-dev.showWindow settings|transfers|wireless]
///
/// Only the app's own windows are drawn; whatever the file list shows ends up in the images, so
/// point it at test folders rather than personal files.
@MainActor
enum DevelopmentSnapshots {
    private static var started = false

    static func startIfRequested(openWindow: OpenWindowAction, openSettings: OpenSettingsAction) {
        guard !started else { return }
        started = true
        let defaults = UserDefaults.standard
        switch defaults.string(forKey: "dev.showWindow") {
        case "settings": openSettings()
        case "transfers": openWindow(id: WindowID.transfers)
        case "wireless": openWindow(id: WindowID.wireless)
        default: break
        }
        // -dev.openTabs SERIAL:/path;…: more browser windows, as tabs of the first one.
        if let tabs = defaults.string(forKey: "dev.openTabs") {
            Task {
                for spec in tabs.split(separator: ";") {
                    try? await Task.sleep(for: .seconds(0.8))
                    guard let colon = spec.firstIndex(of: ":") else { continue }
                    WindowTabs.pendingParent = NSApp.keyWindow
                    openWindow(id: WindowID.browser, value: BrowserTarget(deviceID: String(spec[..<colon]),
                                                                          path: String(spec[spec.index(after: colon)...])))
                }
            }
        }
        // -dev.press ACTION@SECONDS[@viewer];…: keys and menu choices, as a person would make them.
        if let presses = defaults.string(forKey: "dev.press") {
            for spec in presses.split(separator: ";") {
                let parts = spec.split(separator: "@").map(String.init)
                guard parts.count >= 2, let at = Double(parts[1]) else { continue }
                let inViewer = parts.count > 2 && parts[2] == "viewer"
                Task {
                    try? await Task.sleep(for: .seconds(at))
                    perform(parts[0], inViewer: inViewer)
                }
            }
        }
        guard let directory = defaults.string(forKey: "dev.snapshot") else { return }
        let folder = URL(fileURLWithPath: directory)
        // Launch arguments arrive as strings: double(forKey:) reads them, `as? Double` doesn't.
        func seconds(_ key: String, or fallback: Double) -> Double {
            defaults.object(forKey: key) == nil ? fallback : defaults.double(forKey: key)
        }
        let delay = seconds("dev.snapshotDelay", or: 4), every = seconds("dev.snapshotEvery", or: 3)
        let count = max(defaults.integer(forKey: "dev.snapshotCount"), 1)
        Task {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for round in 1...count {
                try? await Task.sleep(for: .seconds(round == 1 ? delay : every))
                capture(into: folder, round: round)
            }
        }
    }

    private typealias Key = (code: UInt16, characters: String, modifiers: NSEvent.ModifierFlags)

    private static let pressKeys: [String: Key] = [
        "space": (49, " ", []), "return": (36, "\r", []), "down": (125, "\u{F701}", []), "up": (126, "\u{F700}", []),
        "escape": (53, "\u{1B}", []), "backspace": (51, "\u{7F}", []), "shift-backspace": (51, "\u{7F}", .shift),
    ]

    private static var log: Logger { Logger(subsystem: WorkNames.subsystem, category: "development") }

    /// The frontmost file list window: the one that has the keys while a viewer opened with
    /// Space stands in front of it.
    private static var listWindow: NSWindow? {
        NSApp.orderedWindows.first { $0.isVisible && $0.contentView?.firstSubview(of: FileNSTableView.self) != nil }
    }

    /// One -dev.press action: a key (space, return, down, up, escape, backspace, shift-backspace), "find" (⌘F),
    /// "type:TEXT" (typed into whatever has the keys), or "menu:NAME:ITEM" (right-click the row
    /// named NAME and choose ITEM). `inViewer`: the key goes to the frontmost viewer window,
    /// through the event queue as typing does (so the app's key monitors see it).
    private static func perform(_ action: String, inViewer: Bool) {
        if action == "find" {
            log.notice("find in \(listWindow?.title ?? "-", privacy: .public)")
            NameFilterField.focus(in: listWindow)
        } else if action.hasPrefix("type:") {
            guard let window = listWindow else { return }
            log.notice("type \(action.dropFirst(5), privacy: .public) into \(String(describing: window.firstResponder.map { type(of: $0) }), privacy: .public)")
            for character in action.dropFirst(5) { send((0, String(character), []), to: window) }
        } else if action.hasPrefix("menu:") {
            let parts = action.split(separator: ":", maxSplits: 2).map(String.init)
            guard parts.count == 3 else { return }
            chooseFromRowMenu(row: parts[1], item: parts[2])
        } else if let key = pressKeys[action] {
            if inViewer {
                guard let viewer = NSApp.orderedWindows.first(where: { $0.isVisible && $0.contentView?.firstSubview(of: FileNSTableView.self) == nil })
                else { return }
                // As after a click on it: the viewer has the keys.
                viewer.makeKeyAndOrderFront(nil)
                log.notice("press \(key.code, privacy: .public) in viewer \(viewer.title, privacy: .public), key window \(NSApp.keyWindow?.title ?? "none", privacy: .public)")
                for event in keyEvents(key, window: viewer) { NSApp.postEvent(event, atStart: false) }
            } else {
                press(key)
            }
        }
    }

    /// Right-clicks the row named `row` in the frontmost list and chooses `item` from its menu,
    /// logging the menu's items.
    private static func chooseFromRowMenu(row name: String, item title: String) {
        guard let table = listWindow?.contentView?.firstSubview(of: FileNSTableView.self), let menu = table.menu else { return }
        let row = (0..<table.numberOfRows).first { row in
            (0..<table.numberOfColumns).contains { column in
                (table.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView)?.textField?.stringValue == name
            }
        }
        guard let row else {
            log.notice("menu: no row \(name, privacy: .public)")
            return
        }
        table.developmentClickedRow = row
        defer { table.developmentClickedRow = nil }
        menu.delegate?.menuNeedsUpdate?(menu)
        log.notice("menu on \(name, privacy: .public): \(menu.items.map { $0.isSeparatorItem ? "—" : $0.title }.joined(separator: " | "), privacy: .public)")
        guard let choice = menu.items.first(where: { $0.title == title }), let action = choice.action else {
            log.notice("menu: no item \(title, privacy: .public)")
            return
        }
        NSApp.sendAction(action, to: choice.target, from: choice)
    }

    private static func keyEvents(_ key: Key, window: NSWindow) -> [NSEvent] {
        [NSEvent.EventType.keyDown, .keyUp].compactMap { type in
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: key.modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                             windowNumber: window.windowNumber, context: nil, characters: key.characters,
                             charactersIgnoringModifiers: key.characters, isARepeat: false, keyCode: key.code)
        }
    }

    private static func send(_ key: Key, to window: NSWindow) {
        for event in keyEvents(key, window: window) { window.sendEvent(event) }
    }

    /// Sends a key down and up to the key window (or the frontmost list when the app isn't
    /// active), through the same path as typing.
    private static func press(_ key: Key) {
        guard let window = NSApp.keyWindow ?? listWindow else { return }
        // Nothing clicked yet: the file list takes the keys, as after a click on a row.
        if window.firstResponder === window, let list = window.contentView?.firstSubview(of: FileNSTableView.self) {
            window.makeFirstResponder(list)
        }
        log.notice("press \(key.code, privacy: .public) in \(window.title, privacy: .public), responder \(String(describing: window.firstResponder.map { type(of: $0) }), privacy: .public)")
        send(key, to: window)
    }

    /// The window as the window server shows it (sidebar materials included). Our own
    /// windows need no screen recording permission.
    private static func windowImage(_ window: NSWindow) -> Data? {
        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                                  [.boundsIgnoreFraming, .bestResolution]),
              image.width > 1 else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// Fallback: the views drawn into a bitmap (materials such as the sidebar come out blank).
    private static func viewImage(_ window: NSWindow) -> Data? {
        // The frame view also holds the title bar and toolbar.
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    /// Draws every visible window (title bar and toolbar included) into "<round>-<n>-<title>.png",
    /// and a window with a sheet open once more with the sheet in place ("…-with-sheet.png").
    static func capture(into folder: URL, round: Int) {
        for (index, window) in NSApp.windows.enumerated() where window.isVisible {
            guard let png = windowImage(window) ?? viewImage(window) else { continue }
            let title = window.title.isEmpty ? String(describing: type(of: window)) : window.title
            let safe = title.replacingOccurrences(of: "/", with: "-").prefix(40)
            try? png.write(to: folder.appendingPathComponent("\(round)-\(index)-\(safe).png"))
            if let sheet = window.attachedSheet, let combined = image(of: window, with: sheet, base: png) {
                try? combined.write(to: folder.appendingPathComponent("\(round)-\(index)-\(safe)-with-sheet.png"))
            }
        }
    }

    /// The window's image with its sheet's image drawn where the sheet is on screen.
    private static func image(of window: NSWindow, with sheet: NSWindow, base: Data) -> Data? {
        guard let sheetPNG = windowImage(sheet), let back = NSBitmapImageRep(data: base),
              let front = NSBitmapImageRep(data: sheetPNG) else { return nil }
        let scale = Double(back.pixelsWide) / window.frame.width
        guard let context = CGContext(data: nil, width: back.pixelsWide, height: back.pixelsHigh, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let backImage = back.cgImage, let frontImage = front.cgImage else { return nil }
        context.draw(backImage, in: CGRect(x: 0, y: 0, width: back.pixelsWide, height: back.pixelsHigh))
        // Both frames are in screen points, origin bottom left, like the context.
        let origin = CGPoint(x: (sheet.frame.minX - window.frame.minX) * scale, y: (sheet.frame.minY - window.frame.minY) * scale)
        context.setShadow(offset: CGSize(width: 0, height: -6 * scale), blur: 30 * scale,
                          color: NSColor.black.withAlphaComponent(0.3).cgColor)
        context.draw(frontImage, in: CGRect(origin: origin, size: CGSize(width: front.pixelsWide, height: front.pixelsHigh)))
        return context.makeImage().map { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) } ?? nil
    }
}
private extension NSView {
    func firstSubview<T: NSView>(of type: T.Type) -> T? {
        for view in subviews {
            if let match = view as? T ?? view.firstSubview(of: type) { return match }
        }
        return nil
    }
}
#endif
