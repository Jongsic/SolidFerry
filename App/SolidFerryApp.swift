import AppKit
import SwiftUI

@main
struct SolidFerryApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var hub: DeviceHub
    @State private var queue: TransferQueue

    init() {
        SettingsKey.registerDefaults()
        let hub = DeviceHub()
        _hub = State(initialValue: hub)
        let queue = TransferQueue(hub: hub)
        _queue = State(initialValue: queue)
        AppDelegate.queue = queue
        #if DEBUG
        DevelopmentLaunchArguments.apply(to: queue, hub: hub)
        #endif
    }

    var body: some Scene {
        WindowGroup(id: WindowID.browser, for: BrowserTarget.self) { $target in
            BrowserWindow(hub: hub, target: $target)
                .environment(queue)
                .textArea(.panels)
        }
        .defaultSize(width: 980, height: 640)
        .commands {
            NewWindowCommands()
            CommandGroup(after: .pasteboard) {
                Button("Move Items Here") {
                    NSApp.sendAction(#selector(FileNSTableView.pasteAndMove(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("v", modifiers: [.command, .option])
                Divider()
                Button("Search") { NameFilterField.focusInKeyWindow() }
                    .keyboardShortcut("f", modifiers: .command)
            }
            ToolbarStyleCommands()
        }

        Settings {
            SettingsView()
        }

        Window("New Wireless Connection", id: WindowID.wireless) {
            WirelessView(hub: hub)
        }
        .windowResizability(.contentSize)

        Window("Transfers", id: WindowID.transfers) {
            TransfersView()
                .environment(queue)
                .textArea(.panels)
        }
        .defaultSize(width: 640, height: 420)
        .keyboardShortcut("t", modifiers: [.command, .option])
    }
}

/// Asks before a quit cuts off transfers under way.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static weak var queue: TransferQueue?

    @MainActor func applicationDidFinishLaunching(_ notification: Notification) {
        // Files opened in other apps last time, if it didn't quit normally.
        FileOpening.removeAll()
    }

    @MainActor func applicationWillTerminate(_ notification: Notification) {
        FileOpening.removeAll()
    }

    @MainActor func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let queue = Self.queue, !queue.activeJobs.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = String(localized: "Stop the transfers and quit?")
        alert.informativeText = String(localized: "They can be resumed the next time you open the app. Files that were partly copied start over.")
        alert.addButton(withTitle: String(localized: "Quit"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }
}

/// ⌘N / ⌘T open a new window / tab at the focused window's device and folder.
private struct NewWindowCommands: Commands {
    @FocusedValue(\.browserTarget) private var focusedTarget
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Window") {
                openWindow(id: WindowID.browser, value: BrowserTarget(deviceID: focusedTarget?.deviceID, path: focusedTarget?.path))
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("New Tab") {
                WindowTabs.pendingParent = NSApp.keyWindow
                openWindow(id: WindowID.browser, value: BrowserTarget(deviceID: focusedTarget?.deviceID, path: focusedTarget?.path))
            }
            .keyboardShortcut("t", modifiers: .command)

            Divider()

            Button("New Wireless Connection…") { openWindow(id: WindowID.wireless) }
        }
    }
}

enum ToolbarStyle: String {
    /// macOS default: buttons share the title bar.
    case titleBar
    /// Explorer-like: buttons get their own row under the title bar.
    case separateRow
}

/// View ▸ Toolbar Buttons: where the action buttons go.
private struct ToolbarStyleCommands: Commands {
    @AppStorage(SettingsKey.toolbarStyle) private var style = ToolbarStyle.titleBar

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Picker("Toolbar Buttons", selection: $style) {
                Text("In the Title Bar").tag(ToolbarStyle.titleBar)
                Text("In a Separate Row").tag(ToolbarStyle.separateRow)
            }
        }
    }
}

/// The app's windows, for `WindowGroup`/`Window` and `openWindow`.
enum WindowID {
    static let browser = "browser"
    static let transfers = "transfers"
    static let wireless = "wireless"
}
