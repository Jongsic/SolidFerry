import AppKit

/// Open popovers follow their content's size without animating (QUIRKS H7). Opening and
/// closing still animate: animation is turned off once a popover is shown and back on as it
/// closes. Applies to every popover, SwiftUI's included (they're NSPopovers).
@MainActor
final class PopoverResizing: NSObject {
    private static var installed: PopoverResizing?

    static func install() {
        guard installed == nil else { return }
        let observer = PopoverResizing()
        let center = NotificationCenter.default
        center.addObserver(observer, selector: #selector(didShow), name: NSPopover.didShowNotification, object: nil)
        center.addObserver(observer, selector: #selector(willClose), name: NSPopover.willCloseNotification, object: nil)
        installed = observer
    }

    @objc private func didShow(_ notification: Notification) {
        (notification.object as? NSPopover)?.animates = false
    }

    @objc private func willClose(_ notification: Notification) {
        (notification.object as? NSPopover)?.animates = true
    }
}
