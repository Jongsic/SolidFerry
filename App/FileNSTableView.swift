import AppKit
import Carbon.HIToolbox

/// Return / Enter / ⌘↓ open the selection (Explorer), F2 renames (Explorer), ⌘⌫ deletes
/// (Finder), ⌫ / ⇧⌫ go back / forward (web browsers), Space shows or hides the selected file
/// in the viewer (Finder's Quick Look).
/// Handled here rather than as menu shortcuts so they never fire while a name is being edited.
final class FileNSTableView: NSTableView {
    var onOpenSelection: (() -> Void)?
    var onQuickLook: (() -> Void)?
    /// When a name was last typed to jump to a row: a space soon after is part of that name.
    private var lastTypeSelect = Date.distantPast
    var onRenameSelection: (() -> Void)?
    var onDeleteSelection: (() -> Void)?
    /// ⌫: back (false), ⇧⌫: forward (true).
    var onHistory: ((_ forward: Bool) -> Void)?
    var onCopySelection: (() -> Bool)?
    /// Pastes into the shown folder; true = move (⌥⌘V). False if there's nothing to paste.
    var onPaste: ((Bool) -> Bool)?

    // Edit menu: ⌘C copies the selected items (paste them into another folder or device
    // window), ⌘V pastes them or Finder files here, ⌥⌘V moves them here.

    @objc func copy(_ sender: Any?) {
        if onCopySelection?() != true { NSSound.beep() }
    }

    @objc func paste(_ sender: Any?) {
        if onPaste?(false) != true { NSSound.beep() }
    }

    @objc func pasteAndMove(_ sender: Any?) {
        if onPaste?(true) != true { NSSound.beep() }
    }

    #if DEBUG
    /// Development (-dev.press menu:…): the row a right-click would have been on.
    var developmentClickedRow: Int?
    override var clickedRow: Int { developmentClickedRow ?? super.clickedRow }
    #endif

    override func keyDown(with event: NSEvent) {
        let command = event.modifierFlags.contains(.command)
        switch Int(event.keyCode) {
        case kVK_Return, kVK_ANSI_KeypadEnter: onOpenSelection?()
        case kVK_DownArrow where command: onOpenSelection?()
        case kVK_F2: onRenameSelection?()
        case kVK_Delete where command: onDeleteSelection?()
        case kVK_Delete where event.modifierFlags.isDisjoint(with: [.command, .option, .control]):
            onHistory?(event.modifierFlags.contains(.shift))
        case kVK_Space where event.modifierFlags.isDisjoint(with: [.command, .option, .control, .shift])
            && Date().timeIntervalSince(lastTypeSelect) > 1:
            onQuickLook?()
        default:
            if event.characters?.contains(where: { $0.isLetter || $0.isNumber || $0 == " " }) == true { lastTypeSelect = Date() }
            super.keyDown(with: event)
        }
    }
}
