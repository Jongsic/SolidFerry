import DeviceCore
import Foundation
import Observation
import SwiftUI

/// What a browser window shows. Stored by SwiftUI for window restoration. The nonce keeps
/// every window distinct: SwiftUI focuses an existing window when asked to open an equal value.
struct BrowserTarget: Codable, Hashable {
    var deviceID: String?
    var path: String?
    var nonce = UUID()
}

/// Sidebar rows are qualified by device, so the same path on two phones stays distinct.
enum SidebarItem: Hashable {
    case device(String)
    case shortcut(String, String)
    case favorite(String, String)
}

@MainActor @Observable
final class WindowModel {
    let hub: DeviceHub
    let browser = BrowserModel()
    private(set) var deviceID: String?
    /// Devices the user collapsed in this window's sidebar (all start expanded).
    private var collapsedDevices = Set<String>()

    func reveal(_ deviceID: String?) {
        if let deviceID { collapsedDevices.remove(deviceID) }
    }

    func expansion(for deviceID: String) -> Binding<Bool> {
        Binding(
            get: { !self.collapsedDevices.contains(deviceID) },
            set: { expanded in
                if expanded { self.collapsedDevices.remove(deviceID) } else { self.collapsedDevices.insert(deviceID) }
            }
        )
    }

    init(hub: DeviceHub, target: BrowserTarget?) {
        self.hub = hub
        var target = target
        #if DEBUG
        if target == nil { target = DevelopmentLaunchArguments.initialTarget }
        #endif
        // Device IDs are serials; a restored window can carry "adb:SERIAL" for the same device.
        deviceID = target?.deviceID.map { $0.hasPrefix("adb:") ? String($0.dropFirst(4)) : $0 }
        browser.deviceID = deviceID
        if let path = target?.path { browser.setPendingLocation(path) }
        browser.onSwitchDevice = { [weak self] id, path in self?.selectDevice(id, path: path, recordHistory: false) }
        browser.onLoadFailure = { [weak self] path in self?.session?.markFavoriteMissing(path) }
        browser.onConnectionLost = { [weak self] fs in self?.session?.connectionBroke(fs) }
        browser.onRenamed = { [weak self] device, old, new in self?.hub.session(device)?.favoritesFollowRename(from: old, to: new) }
        browser.onDeleted = { [weak self] device, paths in self?.hub.session(device)?.favoritesFollowDelete(paths) }
    }

    var session: DeviceSession? { hub.session(deviceID) }
    var device: DeviceDescriptor? { hub.device(deviceID) }

    var target: BrowserTarget {
        BrowserTarget(deviceID: deviceID, path: browser.location?.path)
    }

    /// Where the window is: device and path together (the same path on another device is
    /// another place). Unlike `target`, two reads of the same place are equal.
    var place: HistoryEntry {
        HistoryEntry(deviceID: deviceID ?? "", path: browser.location?.path ?? "")
    }

    /// Pick a device only for a window that has none. A window whose device goes away keeps
    /// waiting for it; it never jumps to another phone on its own.
    func ensureDevice() {
        if deviceID == nil, let id = hub.firstReadyDeviceID { selectDevice(id) }
        syncFileSystem()
    }

    /// Switches to `id` (at `path`, or the device root). On the current device it just navigates.
    /// History navigation passes `recordHistory: false` since it manages the stacks itself.
    func selectDevice(_ id: String, path: String? = nil, recordHistory: Bool = true) {
        guard id != deviceID else {
            if let path {
                browser.navigate(to: RemoteRef(path: path))
            } else if let root = browser.fileSystem?.roots.first {
                browser.navigate(to: root.ref) // clicking the current device goes back to its root
            }
            return
        }
        if recordHistory { browser.recordDeviceSwitch() }
        deviceID = id
        browser.deviceID = id
        browser.detach(resetLocation: true)
        if let path { browser.setPendingLocation(path) }
        syncFileSystem()
    }

    /// Attach or detach the browser to match the session's current connection.
    func syncFileSystem() {
        if let fs = session?.fileSystem {
            browser.attach(fs)
        } else if browser.fileSystem != nil {
            browser.detach(resetLocation: false)
        }
    }

    /// Always a row the sidebar shows: a selection pointing at a row that isn't there (the
    /// device gone for a moment while its USB re-enumerates, or its shortcuts hidden while it
    /// reconnects) would leave the old row drawn on top of the list.
    var sidebarSelection: SidebarItem? {
        get {
            guard let deviceID, hub.devices.contains(where: { $0.id == deviceID }) else { return nil }
            // Shortcut and favorite rows are listed only while connected (DeviceTree).
            if let path = browser.location?.path, session?.fileSystem != nil {
                if session?.isShortcut(path) == true { return .shortcut(deviceID, path) }
                if session?.isFavorite(path) == true { return .favorite(deviceID, path) }
            }
            return .device(deviceID)
        }
        set {
            switch newValue {
            case .device(let id): selectDevice(id)
            case .shortcut(let id, let path), .favorite(let id, let path): selectDevice(id, path: path)
            case nil: break // clicking empty space must not drop the connection
            }
        }
    }
}

struct BrowserTargetFocusKey: FocusedValueKey {
    typealias Value = BrowserTarget
}

extension FocusedValues {
    var browserTarget: BrowserTarget? {
        get { self[BrowserTargetFocusKey.self] }
        set { self[BrowserTargetFocusKey.self] = newValue }
    }
}
