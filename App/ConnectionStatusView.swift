import DeviceCore
import SwiftUI

/// How a device in the sidebar is connected, always shown under its name:
/// "● ⫯ ADB (Auto) · Fast mode", or what's wrong. Always one line: the sidebar list doesn't
/// lay its rows out again when one gets taller, so an extra line drew over the row below.
struct DeviceConnectionLine: View {
    let device: DeviceDescriptor
    let session: DeviceSession?

    var body: some View {
        HStack(spacing: 4) {
            StatusDot(color: device.status == .ready ? .green : .orange)
            // The icon says USB or Wi-Fi, which leaves room for the rest.
            Image(systemName: device.link.symbol)
                .help(device.link.title)
                .accessibilityLabel(device.link.title)
            if device.status == .ready {
                Text(verbatim: "\(transportLabel) · \(speedLabel)")
            } else {
                Text(device.status.label).foregroundStyle(.orange)
            }
            if session?.usbUnstable == true {
                // The connection panel says it in full.
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("USB keeps dropping: the connection dropped and came back several times. Try another cable or USB port, or connect directly instead of through a hub.")
                    .accessibilityLabel(Text("USB keeps dropping"))
            }
        }
        .appFont(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    /// "ADB (Auto)", or "MTP (Fixed)" when the connection was chosen in the panel.
    private var transportLabel: String {
        let title = device.transport.title
        return session?.preference ?? .auto == .auto
            ? String(localized: "\(title) (Auto)") : String(localized: "\(title) (Fixed)")
    }

    private var speedLabel: String {
        session?.isFastMode == true ? String(localized: "Fast mode") : String(localized: "Standard mode")
    }
}

/// The gear next to a device in the sidebar: opens its connection panel.
struct DeviceSettingsButton: View {
    let device: DeviceDescriptor
    let session: DeviceSession
    @State private var showsDetails = false

    var body: some View {
        Button { showsDetails.toggle() } label: {
            Label("Connection settings", systemImage: "gearshape")
                .labelStyle(.iconOnly)
                .foregroundStyle(device.status == .ready ? Color.secondary : Color.orange)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help("Connection settings")
        .popover(isPresented: $showsDetails, arrowEdge: .trailing) {
            ConnectionDetails(device: device, session: session)
        }
        #if DEBUG
        // Development: -dev.connectionPanel SERIAL opens this panel, for checking it in snapshots.
        .task {
            guard UserDefaults.standard.string(forKey: "dev.connectionPanel") == device.serial else { return }
            try? await Task.sleep(for: .seconds(1))
            showsDetails = true
        }
        #endif
    }
}

private struct ConnectionDetails: View {
    let device: DeviceDescriptor
    @Bindable var session: DeviceSession
    @State private var working = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: device.link.symbol)
                    .appFont(.title2)
                    .foregroundStyle(device.status == .ready ? .green : .orange)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name).appFont(.headline)
                    Text(device.serial).appFont(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                Text(device.link.title)
                    .appFont(.callout, weight: .semibold)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }

            Text("Cable and Wi-Fi").appFont(.subheadline, weight: .semibold)
            usbRow
            wifiRow

            Divider()

            HStack {
                Text("Connection")
                SegmentedChoice(selection: $session.preference, options: [
                    (.auto, String(localized: "Auto")), (.adb, "ADB"), (.mtp, "MTP"),
                ])
            }
            Text("Auto uses ADB when USB debugging is allowed, otherwise MTP.")
                .appFont(.caption).foregroundStyle(.secondary)

            Divider()

            if device.status != .ready {
                ConnectionChecklist(device: device, session: session)
                Divider()
            }

            adbRow
            mtpRow

            let adaptations = self.adaptations
            if !adaptations.isEmpty {
                Divider()
                Text("Adjusted for this device").appFont(.subheadline, weight: .semibold)
                ForEach(adaptations, id: \.self) { line in
                    Label(line, systemImage: "wrench.adjustable")
                        .appFont(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .appFont(.callout)
        .padding(16)
        .scaledFrame(width: 380, alignment: .leading)
        // Opened from a sidebar row, whose one-line limit would otherwise cut every message here.
        .lineLimit(nil)
        .textArea(.panels)
        .scaledButtons()
        .disabled(working)
    }

    /// What the app does differently for this phone over the current connection, from what
    /// the connection reports and what was measured on it (QUIRKS A2, G6, M18).
    private var adaptations: [String] {
        guard let fs = session.fileSystem else { return [] }
        var lines: [String] = []
        if UploadDates.known(device.id, fs: fs) == .ignored {
            lines.append(String(localized: "Files sent to it get the date they arrived, so files are compared by size."))
        }
        if !fs.capabilities.exactLargeSizes {
            lines.append(String(localized: "Sizes over 4 GB aren’t shown exactly; comparisons still tell them apart."))
        }
        if !fs.capabilities.deviceHashing {
            lines.append(String(localized: "Contents can’t be compared on this connection; size and date are used."))
        }
        return lines
    }

    @ViewBuilder private var usbRow: some View {
        let plugged = session.mtpDiagnosis.cabled || (session.adb?.link == .usb)
        row(color: plugged ? .green : .gray, title: String(localized: "USB cable"),
            badge: plugged && device.link == .usb ? String(localized: "In use") : nil) {
            if plugged {
                Text("Connected").foregroundStyle(.secondary)
                if session.usbUnstable {
                    Text("The USB connection dropped and came back several times. Try another cable or USB port, or connect directly instead of through a hub.")
                        .foregroundStyle(.orange)
                }
            } else {
                Text("Not plugged in").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var wifiRow: some View {
        let inUse = device.link == .wifi
        if session.wifiAddress != nil {
            row(color: .green, title: "Wi-Fi", badge: inUse ? String(localized: "In use") : String(localized: "Ready")) {
                if let shown = session.wifiShownAddress {
                    Text(verbatim: shown).foregroundStyle(.secondary).monospacedDigit()
                }
                if inUse {
                    Text("Slower than the cable. Plug it in for big transfers; it switches by itself.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Unplug the cable and the connection carries on over Wi-Fi.").foregroundStyle(.secondary)
                }
                Button("Disconnect Wi-Fi") { run { await session.disconnectWifi() } }
                    .controlSize(.small)
            }
        } else {
            switch session.wifiSetup {
            case .turningOn:
                row(color: .orange, title: "Wi-Fi", badge: nil) { progress(String(localized: "Turning on wireless debugging on the device…")) }
            case .waitingForApproval:
                row(color: .orange, title: "Wi-Fi", badge: nil) {
                    Text("Tap “Allow” on the device.").fontWeight(.semibold)
                    Text("The device asks whether to allow wireless debugging on this network.").foregroundStyle(.secondary)
                }
            case .connecting:
                row(color: .orange, title: "Wi-Fi", badge: nil) { progress(String(localized: "Connecting over Wi-Fi…")) }
            case .failed(let failure):
                row(color: .red, title: "Wi-Fi", badge: nil) {
                    switch failure {
                    case .notAllowed: Text("Wireless debugging wasn’t allowed on the device.")
                    case .notFound: Text("The device wasn’t found on Wi-Fi. Check that it’s on the same Wi-Fi network as this Mac.")
                    case .unreachable:
                        Text("Wireless debugging is on, but this Mac can’t reach the device.")
                    }
                    Button("Try Again") { session.connectOverWifi() }
                        .controlSize(.small)
                }
            case .idle:
                row(color: .gray, title: "Wi-Fi", badge: nil) {
                    if session.adb?.status == .ready {
                        Text("Keep working after you unplug the cable. The cable is used while it’s plugged in.")
                            .foregroundStyle(.secondary)
                        Button("Connect over Wi-Fi") { session.connectOverWifi() }
                            .controlSize(.small)
                    } else {
                        Text("Connecting over Wi-Fi needs USB debugging.").foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text(text)
        }
    }

    @ViewBuilder private var adbRow: some View {
        if device.availableTransports.contains(.adb) {
            let active = session.activeTransport == .adb
            row(color: active ? .green : .gray, title: "ADB · \(device.link.title)", badge: active ? String(localized: "In use") : nil) {
                if active {
                    Text(session.isFastMode ? String(localized: "Fast mode") : String(localized: "Standard mode"))
                } else if session.adb?.status == .unauthorized {
                    Text("Tap “Allow USB debugging” on the device.")
                } else if session.adb?.status == .offline {
                    Text("Unplug and reconnect the device.").foregroundStyle(.secondary)
                } else {
                    Text("Available").foregroundStyle(.secondary)
                }
            }
        } else {
            row(color: .gray, title: "ADB", badge: nil) {
                Text(AdbSuggestion.benefit(for: session)).foregroundStyle(.secondary)
                AdbGuide(session: session)
            }
        }
    }

    @ViewBuilder private var mtpRow: some View {
        let active = session.activeTransport == .mtp
        if !device.availableTransports.contains(.mtp) {
            if session.preference == .mtp {
                row(color: .orange, title: "MTP", badge: nil) {
                    Text("The device’s USB is set to charging only.")
                    if device.availableTransports.contains(.adb) {
                        Button("Switch Device to File Transfer") { run { await session.switchPhoneToFileTransfer() } }
                    } else {
                        Text("Choose “File transfer” in the device’s USB notification.").foregroundStyle(.secondary)
                    }
                }
            } else {
                row(color: .gray, title: "MTP", badge: nil) {
                    Text("Not detected").foregroundStyle(.secondary)
                }
            }
        } else if active {
            row(color: .green, title: "MTP · USB", badge: String(localized: "In use")) {
                Text("Fast mode")
            }
        } else if session.targetTransport == .mtp {
            mtpProblemRow
        } else if case let owners = session.mtpDiagnosis.holderNames, !owners.isEmpty {
            row(color: .gray, title: "MTP", badge: nil) {
                Text("In use by \(OwnerNames.list(owners)).")
                Text("MTP isn’t used while in ADB mode. Switching to MTP mode will release it.").foregroundStyle(.secondary)
            }
        } else {
            row(color: .gray, title: "MTP", badge: nil) {
                Text("Available").foregroundStyle(.secondary)
            }
        }
    }

    /// MTP was chosen (or is the only option) but isn't connected yet: say why, and when ADB
    /// is attached offer to fix the phone's USB mode for the user.
    @ViewBuilder private var mtpProblemRow: some View {
        let canFix = device.availableTransports.contains(.adb)
        let mtp = session.mtpDiagnosis
        row(color: .orange, title: "MTP", badge: nil) {
            // What the last attempt ran into comes first (with its fix, such as restarting the
            // phone's MTP); another app holding the phone is the answer when nothing else is.
            if mtp.problem == nil, !mtp.blockers.isEmpty {
                Text("\(OwnerNames.list(mtp.blockers.map(\.name))) is using the device’s file access. Quit that app to connect.")
            } else {
                problem(mtp, canFix: canFix)
            }
        }
    }

    @ViewBuilder private func problem(_ mtp: MtpDiagnosis, canFix: Bool) -> some View {
            switch mtp.problem {
            case .chargingOnly:
                Text("The device’s USB is set to charging only.")
                if canFix {
                    Button("Switch Device to File Transfer") { run { await session.switchPhoneToFileTransfer() } }
                } else {
                    Text("Choose “File transfer” in the device’s USB notification.").foregroundStyle(.secondary)
                }
            case .noStorage:
                Text("Waiting for the device to allow access.")
                Text("Unlock the device and choose “File transfer” in its USB notification.").foregroundStyle(.secondary)
                if canFix {
                    Button("Switch Device to File Transfer") { run { await session.switchPhoneToFileTransfer() } }
                }
            case .unresponsive:
                Text("The device stopped responding.")
                if canFix {
                    Button("Restart the Device’s File Transfer") { run { await session.restartPhoneMtp() } }
                } else {
                    Text("Unplug and reconnect the device.").foregroundStyle(.secondary)
                }
            case .unknown:
                Text(UserMessage.connectFailure).foregroundStyle(.secondary)
            case nil:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Connecting…")
                }
            }
    }

    private func run(_ action: @escaping @MainActor () async -> Void) {
        working = true
        Task {
            await action()
            working = false
        }
    }

    private func row(color: Color, title: String, badge: String?, @ViewBuilder detail: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            StatusDot(color: color)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(title).fontWeight(.medium)
                    if let badge {
                        Text(badge)
                            .appFont(.caption2, weight: .semibold)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(color.opacity(0.18), in: Capsule())
                    }
                }
                detail().appFont(.caption).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct StatusDot: View {
    let color: Color

    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
    }
}

extension TransportKind {
    var title: String {
        switch self {
        case .adb: "ADB"
        case .mtp: "MTP"
        }
    }
}

extension LinkKind {
    var title: String {
        switch self {
        case .usb: "USB"
        case .wifi: "Wi-Fi"
        }
    }

    var symbol: String {
        switch self {
        case .usb: "cable.connector"
        case .wifi: "wifi"
        }
    }
}
