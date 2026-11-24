import AppKit
import SwiftUI

/// A download, upload or device-copy dialog to show.
enum TransferDialogRequest {
    case download(DownloadRequest)
    case upload(UploadRequest)
    case deviceCopy(DeviceCopyRequest)

    var id: UUID {
        switch self {
        case .download(let request): request.id
        case .upload(let request): request.id
        case .deviceCopy(let request): request.id
        }
    }
}

/// The transfer dialogs, each in a window of its own: it can be moved and resized (a wider
/// list), and the browser stays usable meanwhile. A window opens with its request's id; the
/// request itself (a connection, Finder's promises) waits here until the window closes.
@MainActor
enum TransferDialogs {
    private static var requests: [UUID: TransferDialogRequest] = [:]

    /// Keeps `request` for its window and returns the id to open the window with.
    static func register(_ request: TransferDialogRequest) -> UUID {
        requests[request.id] = request
        return request.id
    }

    static func request(_ id: UUID) -> TransferDialogRequest? { requests[id] }

    static func remove(_ id: UUID) { requests[id] = nil }
}

struct TransferDialogWindow: View {
    let id: UUID?

    /// A dialog opened by a drag and drop with Finder comes up while Finder is the active app;
    /// asking to be active isn't always granted, so the window is also put in front of Finder's.
    private static func bringForward(_ window: NSWindow) {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    var body: some View {
        Group {
            if let id, let request = TransferDialogs.request(id) {
                Group {
                    switch request {
                    case .download(let request): DownloadSheet(request: request)
                    case .upload(let request): UploadSheet(request: request)
                    case .deviceCopy(let request): DeviceCopySheet(request: request)
                    }
                }
                .onDisappear { TransferDialogs.remove(id) }
                .background(WindowReader { window in Task { @MainActor in Self.bringForward(window) } })
            } else {
                // Nothing to show (its request is gone, as for a window macOS brings back
                // at launch): close.
                Color.clear.frame(width: 1, height: 1)
                    .background(WindowReader { window in Task { @MainActor in window.close() } })
            }
        }
    }
}
