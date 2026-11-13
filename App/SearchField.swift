import AppKit
import SwiftUI

/// The file list's search field (⌘F), with a toggle at its right end that makes the search a
/// regular expression. A toolbar item of our own: SwiftUI's `.searchable` field always comes
/// last in the toolbar, so nothing could follow it.
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isRegex: Bool

    func makeNSView(context: Context) -> RegexSearchField {
        let field = RegexSearchField()
        field.placeholderString = String(localized: "Search")
        field.sendsSearchStringImmediately = true
        field.target = context.coordinator
        field.action = #selector(Coordinator.searched(_:))
        field.regexButton.target = context.coordinator
        field.regexButton.action = #selector(Coordinator.toggledRegex(_:))
        field.regexButton.toolTip = String(localized: "Search with a regular expression")
        return field
    }

    func updateNSView(_ field: RegexSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        field.isRegex = isRegex
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: SearchField
        init(_ parent: SearchField) { self.parent = parent }

        /// Every change, the clear button and Escape included.
        @objc func searched(_ field: NSSearchField) { parent.text = field.stringValue }
        @objc func toggledRegex(_ button: NSButton) { parent.isRegex = button.state == .on }
    }
}

/// A search field with room at its right end for the regular expression toggle.
final class RegexSearchField: NSSearchField {
    override class var cellClass: AnyClass? {
        get { RegexSearchFieldCell.self }
        set {}
    }

    let regexButton = NSButton()

    var isRegex = false {
        didSet { styleRegexButton() }
    }

    /// A round button: gray when off, the accent color when on.
    private static let buttonSize: CGFloat = 20

    override init(frame: NSRect) {
        super.init(frame: frame)
        regexButton.setButtonType(.pushOnPushOff)
        regexButton.isBordered = false
        regexButton.wantsLayer = true
        regexButton.layer?.cornerRadius = Self.buttonSize / 2
        regexButton.setAccessibilityLabel(String(localized: "Search with a regular expression"))
        regexButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(regexButton)
        NSLayoutConstraint.activate([
            regexButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            regexButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            regexButton.widthAnchor.constraint(equalToConstant: Self.buttonSize),
            regexButton.heightAnchor.constraint(equalToConstant: Self.buttonSize),
        ])
        styleRegexButton()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        styleRegexButton()
    }

    private func styleRegexButton() {
        regexButton.state = isRegex ? .on : .off
        regexButton.attributedTitle = NSAttributedString(string: ".*", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold),
            .foregroundColor: isRegex ? NSColor.white : NSColor.secondaryLabelColor,
        ])
        // Layer colors don't follow light and dark by themselves: resolved here, again on change.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            regexButton.layer?.backgroundColor = (isRegex ? NSColor.controlAccentColor : NSColor.quaternaryLabelColor).cgColor
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }
}

/// Text and the clear button stop short of the toggle.
final class RegexSearchFieldCell: NSSearchFieldCell {
    static let toggleWidth: CGFloat = 30

    override func searchTextRect(forBounds rect: NSRect) -> NSRect {
        var text = super.searchTextRect(forBounds: rect)
        text.size.width -= Self.toggleWidth
        return text
    }

    override func cancelButtonRect(forBounds rect: NSRect) -> NSRect {
        super.cancelButtonRect(forBounds: rect).offsetBy(dx: -Self.toggleWidth, dy: 0)
    }
}

/// ⌘F: the cursor goes into the key window's search field. A window without one (a text
/// viewer) opens its find bar instead.
@MainActor
enum NameFilterField {
    static func focusInKeyWindow() { focus(in: NSApp.keyWindow) }

    static func focus(in window: NSWindow?) {
        if let window, let field = window.toolbar?.items.lazy.compactMap({ $0.view.flatMap(searchField(in:)) }).first {
            window.makeFirstResponder(field)
            return
        }
        let find = NSMenuItem()
        find.tag = NSTextFinder.Action.showFindInterface.rawValue
        if !NSApp.sendAction(#selector(NSResponder.performTextFinderAction(_:)), to: nil, from: find) { NSSound.beep() }
    }

    private static func searchField(in view: NSView) -> RegexSearchField? {
        if let field = view as? RegexSearchField { return field }
        return view.subviews.lazy.compactMap(searchField(in:)).first
    }
}
