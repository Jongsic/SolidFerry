import DeviceCore
import SwiftUI

/// One browser window: device sidebar on the left, browser on the right.
struct BrowserWindow: View {
    let hub: DeviceHub
    @Binding var target: BrowserTarget?
    @State private var model: WindowModel
    @Environment(TransferQueue.self) private var queue
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.controlActiveState) private var activeState

    init(hub: DeviceHub, target: Binding<BrowserTarget?>) {
        self.hub = hub
        _target = target
        // No value means the tab bar's "+": start where the active window is.
        let start = target.wrappedValue ?? WindowTabs.lastActiveTarget.map {
            BrowserTarget(deviceID: $0.deviceID, path: $0.path)
        }
        _model = State(initialValue: WindowModel(hub: hub, target: start))
    }

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            if model.device?.status == .ready || model.browser.location != nil {
                BrowserView(browser: model.browser, deviceID: model.deviceID, session: model.session,
                            deviceName: model.device?.name ?? model.session?.lastKnownName ?? String(localized: "Device"),
                            revealInSidebar: { model.reveal(model.deviceID) })
            } else {
                EmptyStateView(model: model)
            }
        }
        .task {
            hub.start()
            #if DEBUG
            DevelopmentSnapshots.startIfRequested(openWindow: openWindow, openSettings: openSettings)
            #endif
        }
        .onChange(of: hub.devices, initial: true) { model.ensureDevice() }
        .onChange(of: model.session.flatMap { $0.fileSystem.map(ObjectIdentifier.init) }) { model.syncFileSystem() }
        // Keep the restorable window value in sync so a relaunch reopens the same place.
        .onChange(of: model.place) { target = BrowserTarget(deviceID: model.deviceID, path: model.target.path, nonce: target?.nonce ?? UUID()) }
        // The window's own value: `model.target` is new on every read and would count as a
        // change every time the view draws.
        .focusedSceneValue(\.browserTarget, target)
        .background(WindowReader { WindowTabs.adopt($0) })
        .onChange(of: activeState, initial: true) { if activeState == .key { WindowTabs.lastActiveTarget = model.target } }
        .onChange(of: model.place) {
            if activeState == .key { WindowTabs.lastActiveTarget = model.target }
        }
        .onChange(of: queue.windowRequest) { openWindow(id: WindowID.transfers) }
    }
}

/// Devices as a tree, Finder-style: each device row expands to its shortcuts and
/// favorites, so with several phones it's always clear which folder belongs to which.
private struct Sidebar: View {
    @Bindable var model: WindowModel

    var body: some View {
        List(selection: $model.sidebarSelection) {
            Section {
                ForEach(model.hub.devices) { device in
                    DeviceTree(model: model, device: device)
                }
            } header: {
                HStack {
                    Text("Devices").appFont(.subheadline, weight: .semibold)
                    Spacer()
                    AddWirelessButton()
                }
            }
        }
        .textArea(.sidebar)
    }
}

/// "+ Wi-Fi" beside the sidebar's Devices heading: adding a device over the network (a cable
/// adds one by itself).
private struct AddWirelessButton: View {
    @Environment(\.openWindow) private var openWindow
    @State private var hovering = false

    var body: some View {
        Button { openWindow(id: WindowID.wireless) } label: {
            HStack(spacing: 2) {
                Image(systemName: "plus")
                Text("Wi-Fi")
            }
            .appFont(.subheadline, weight: .semibold)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(hovering ? 0.12 : 0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { hovering = $0 }
        .help("New Wireless Connection…")
        .accessibilityLabel("New Wireless Connection…")
    }
}

private struct DeviceTree: View {
    @Bindable var model: WindowModel
    let device: DeviceDescriptor

    var body: some View {
        let session = model.hub.session(device.id)
        let shortcuts = session?.fileSystem != nil ? session?.shortcuts ?? [] : []
        let favorites = session?.fileSystem != nil ? session?.visibleFavorites ?? [] : []
        if shortcuts.isEmpty && favorites.isEmpty {
            deviceLabel.tag(SidebarItem.device(device.id))
        } else {
            DisclosureGroup(isExpanded: model.expansion(for: device.id)) {
                ForEach(shortcuts, id: \.path) { shortcut in
                    // Sidebar rows don't take the list's font; each row sets its own.
                    Label(shortcut.name, systemImage: shortcut.icon)
                        .appFont(.body)
                        .tag(SidebarItem.shortcut(device.id, shortcut.path))
                }
                if !favorites.isEmpty {
                    // The device's own places above, the folders added to the sidebar below.
                    Text("Favorites")
                        .appFont(.caption, weight: .semibold)
                        .foregroundStyle(.secondary)
                        .padding(.top, shortcuts.isEmpty ? 0 : 6)
                        .selectionDisabled()
                }
                ForEach(favorites, id: \.self) { path in
                    FavoriteRow(path: path, missing: session?.missingFavorites.contains(path) == true)
                        .tag(SidebarItem.favorite(device.id, path))
                        .contextMenu {
                            Button("Remove from Sidebar") { session?.removeFavorite(path) }
                        }
                }
            } label: {
                deviceLabel.tag(SidebarItem.device(device.id))
            }
        }
    }

    private var deviceLabel: some View {
        HStack(spacing: 6) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name)
                        .appFont(.body, weight: device.id == model.deviceID ? .semibold : .regular)
                    DeviceConnectionLine(device: device, session: model.hub.session(device.id))
                }
            } icon: {
                Image(systemName: device.link == .wifi ? "iphone.radiowaves.left.and.right" : "smartphone")
            }
            .help(device.link == .wifi ? String(localized: "Connected over Wi-Fi") : String(localized: "Connected with a USB cable"))
            Spacer(minLength: 0)
            if let session = model.hub.session(device.id) {
                DeviceSettingsButton(device: device, session: session)
            }
        }
    }
}

private struct FavoriteRow: View {
    let path: String
    let missing: Bool

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(RemoteRef(path: path).name).appFont(.body)
                if missing {
                    Text("Folder not found").appFont(.caption).foregroundStyle(.orange)
                }
            }
        } icon: {
            Image(systemName: missing ? "exclamationmark.triangle" : "star")
        }
        .foregroundStyle(missing ? .secondary : .primary)
        .help(path)
    }
}

private struct EmptyStateView: View {
    let model: WindowModel

    var body: some View {
        let hub = model.hub
        if let message = hub.serverMessage {
            MessageView(Text("Can’t Reach adb"), systemImage: "bolt.horizontal.circle", description: Text(message))
        } else if let device = model.device, let session = model.session, session.isConnecting {
            ConnectingCard(deviceName: device.name, stage: session.connectStage, since: session.connectStarted)
                .scaledButtons()
        } else if let device = model.device ?? (model.deviceID == nil ? hub.devices.first : nil), device.status != .ready,
                  let session = hub.session(device.id) {
            // A window without a device picks the first ready one; until one is, it shows how
            // the first one is getting there.
            ConnectionSteps(device: device, session: session)
        } else if model.deviceID != nil, model.device == nil {
            // Its device was unplugged.
            let name = model.session?.lastKnownName ?? String(localized: "Device")
            MessageView(title: Text("\(name) disconnected"), systemImage: "cable.connector.slash",
                        description: Text("Connect it again, or choose another device in the sidebar.")) {
                ConnectOptions()
            }
        } else if hub.devices.isEmpty {
            NoDevicesView()
        } else {
            ProgressView()
        }
    }
}

/// No device at all: plug one in, or add one over Wi-Fi.
private struct NoDevicesView: View {
    var body: some View {
        MessageView(title: Text("No Devices"), systemImage: "smartphone",
                    description: Text("Connect a device in one of these ways.")) {
            ConnectOptions()
        }
    }
}

/// A plugged-in device that isn't ready: its connection steps, and getting ADB where that's
/// what it waits on. In place of the files, or over the last folder shown.
struct ConnectionSteps: View {
    let device: DeviceDescriptor
    let session: DeviceSession

    var body: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 14) {
                Label(device.name, systemImage: "smartphone").appFont(.headline)
                ConnectionChecklist(device: device, session: session)
            }
            .scaledButtons()
            .frame(maxWidth: 380, alignment: .leading)
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            // Waiting on ADB: USB debugging is on (or ADB was chosen) but there's no adb here,
            // or ADB was chosen and USB debugging is off.
            if session.adb == nil, (AdbSetup.shared.missing && session.usb?.hasADB == true) || session.preference == .adb {
                AdbSetupCard(session: session)
                    .scaledButtons()
            }
        }
    }
}

extension DeviceStatus {
    var label: String {
        switch self {
        case .ready: String(localized: "Connected")
        case .unauthorized: String(localized: "Waiting for approval")
        case .offline: String(localized: "Offline")
        case .connecting: String(localized: "Connecting…")
        case .noPermission, .unknown, .notResponding: String(localized: "Unavailable")
        case .needsFileTransfer: String(localized: "Charging only")
        case .noStorage: String(localized: "Waiting for access")
        case .busy: String(localized: "In use by another app")
        case .usbDebuggingOff: String(localized: "USB debugging is off")
        case .adbMissing: String(localized: "Needs adb")
        }
    }
}
