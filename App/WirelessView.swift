import AdbKit
import CoreImage.CIFilterBuiltins
import DeviceCore
import os
import SwiftUI

/// Connect a phone over Wi-Fi: scan a QR code (or type the pairing code) once, then it
/// connects by itself whenever wireless debugging is on and both are on the same network.
struct WirelessView: View {
    @State private var model: WirelessModel

    init(hub: DeviceHub) {
        _model = State(initialValue: WirelessModel(hub: hub))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if AdbSetup.shared.missing {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Connecting over Wi-Fi needs adb on this Mac.").appFont(.headline)
                    AdbInstall()
                }
            }
            Text("The device and this Mac need to be on the same Wi-Fi network. Pair a device once; after that it connects whenever wireless debugging is on.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("With a QR code").appFont(.headline)
                            Text("On the device, open Settings › Developer options › Wireless debugging, tap “Pair device with QR code” and scan this code.")
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        QRCodeImage(text: model.qrText)
                            .scaledFrame(width: 148, height: 148)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("With a pairing code").appFont(.headline)
                        if model.pairingServices.isEmpty {
                            Text("Tap “Pair device with pairing code” on the device; it appears here.")
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            ForEach(model.pairingServices) { service in
                                PairingRow(service: service, model: model)
                            }
                        }
                    }
                }
                .padding(8)
            } label: {
                Text("Pair a new device").appFont(.headline)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    if model.connectServices.isEmpty {
                        Text("Devices with wireless debugging on appear here.").foregroundStyle(.secondary)
                    } else {
                        ForEach(model.connectServices) { service in
                            HStack {
                                Image(systemName: "wifi")
                                // Name (when this Mac knows the device), then serial and address.
                                Text(model.name(of: service) ?? String(localized: "Android device")).fontWeight(.semibold)
                                Text("Serial \(service.deviceSerial ?? service.instance) · \(service.address)")
                                    .foregroundStyle(.secondary).monospacedDigit()
                                Spacer()
                                if model.isConnected(service) {
                                    Text("Connected").foregroundStyle(.secondary)
                                } else {
                                    Button("Connect") { Task { await model.connect(service.address) } }
                                        .disabled(model.isBusy)
                                }
                            }
                        }
                    }
                    HStack {
                        TextField("IP address and port", text: $model.manualAddress)
                            .textFieldStyle(.roundedBorder)
                            .scaledFrame(width: 220)
                            .onSubmit { Task { await model.connect(model.manualAddress) } }
                        Button("Connect") { Task { await model.connect(model.manualAddress) } }
                            .disabled(model.manualAddress.isEmpty || model.isBusy)
                    }
                }
                .padding(8)
            } label: {
                Text("Devices on this network with wireless debugging on").appFont(.headline)
            }

            Divider()
            // What any of the ways above did, and the window's button, always here.
            HStack(alignment: .center, spacing: 12) {
                StatusLine(status: model.status)
                Spacer(minLength: 0)
                FinishButton(connected: model.isConnected)
            }
        }
        .padding(20)
        .scaledFrame(width: 560)
        .textArea(.panels)
        .scaledButtons()
        .task { await model.watch() }
    }
}

/// "Close" until a device connected, then "Done" as the default button.
private struct FinishButton: View {
    let connected: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if connected {
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        } else {
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
        }
    }
}

private struct PairingRow: View {
    let service: AdbMdnsService
    let model: WirelessModel
    @State private var code = ""

    var body: some View {
        HStack {
            Image(systemName: "number")
            Text(service.address).monospacedDigit()
            Spacer()
            TextField("6-digit code", text: $code)
                .textFieldStyle(.roundedBorder)
                .scaledFrame(width: 110)
                .onSubmit(pair)
            Button("Pair", action: pair)
                .disabled(code.count < 6 || model.isBusy)
        }
    }

    private func pair() {
        guard code.count >= 6 else { return }
        Task { await model.pair(service, code: code) }
    }
}

private struct StatusLine: View {
    let status: WirelessModel.Status

    var body: some View {
        Group {
            switch status {
            case .waiting:
                Label("Waiting for a device…", systemImage: "antenna.radiowaves.left.and.right").foregroundStyle(.secondary)
            case .working(let text):
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(text)
                }
            case .done(let text):
                Label(text, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .connected(let name):
                Label(name.map { String(localized: "\($0) is connected over Wi-Fi. It’s in the sidebar.") }
                      ?? String(localized: "Connected. The device is in the sidebar."),
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed(let text):
                Label(text, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct QRCodeImage: View {
    let text: String

    var body: some View {
        if let image = Self.render(text) {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .padding(8)
                .background(.white, in: RoundedRectangle(cornerRadius: 8))
        } else {
            RoundedRectangle(cornerRadius: 8).fill(.quaternary)
        }
    }

    private static func render(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}

@MainActor @Observable
final class WirelessModel {
    enum Status: Equatable {
        case waiting
        case working(String)
        case done(String)
        case failed(String)
        /// Connected over Wi-Fi: the device's name, when known.
        case connected(String?)
    }

    private let hub: DeviceHub

    init(hub: DeviceHub) {
        self.hub = hub
    }

    /// Our QR code's pairing service name and password (new each time the window opens).
    let qrName = "\(WorkNames.tag)-" + WirelessModel.randomString(6)
    let qrPassword = WirelessModel.randomString(10)
    var qrText: String { wirelessPairingQRText(name: qrName, password: qrPassword) }

    private(set) var services: [AdbMdnsService] = []
    private(set) var status = Status.waiting
    private(set) var isBusy = false
    var isConnected: Bool {
        if case .connected = status { true } else { false }
    }
    var manualAddress = ""
    /// After pairing, until the device is on Wi-Fi: its serial (when adb named it), the
    /// devices on Wi-Fi before, when it paired, and whether we asked adb to connect it.
    private var pairing: (serial: String?, before: Set<String>, at: ContinuousClock.Instant, connectAsked: Bool)?
    /// Addresses our QR code was tried at, each once; none after it paired. adb keeps listing
    /// the pairing service for seconds after the phone closed it, and pairing there again
    /// fails (QUIRKS A18).
    private var qrTried = Set<String>()
    private var qrPaired = false
    private let client = AdbClient()

    var pairingServices: [AdbMdnsService] {
        services.filter { $0.kind == .pairing && $0.instance != qrName }
    }

    /// What the network shows now (mDNS), paired with this Mac or not.
    var connectServices: [AdbMdnsService] {
        services.filter { $0.kind == .connect }
    }

    /// The device's name when this Mac knows it.
    func name(of service: AdbMdnsService) -> String? {
        service.deviceSerial.flatMap { hub.device($0)?.name }
    }

    func isConnected(_ service: AdbMdnsService) -> Bool {
        service.deviceSerial.map(hub.wifiSerials.contains) ?? false
    }

    /// Looks for phones every 1.5 s while the window is open.
    func watch() async {
        while !Task.isCancelled {
            services = (try? await client.mdnsServices()) ?? []
            if !isBusy, !qrPaired, let qr = services.first(where: {
                $0.kind == .pairing && $0.instance == qrName && !qrTried.contains($0.address)
            }) {
                qrTried.insert(qr.address)
                await pair(qr, code: qrPassword)
            }
            await followPairing()
            try? await Task.sleep(for: .milliseconds(1500))
        }
    }

    func pair(_ service: AdbMdnsService, code: String) async {
        isBusy = true
        defer { isBusy = false }
        status = .working(String(localized: "Pairing…"))
        let isQR = service.instance == qrName
        log.notice("pairing \(isQR ? "by QR" : "by code", privacy: .public) at \(service.address, privacy: .public)")
        do {
            let serial = try await client.pair(address: service.address, code: code)
            log.notice("paired at \(service.address, privacy: .public): \(serial ?? "no serial", privacy: .public)")
            if isQR { qrPaired = true }
            status = .done(String(localized: "Paired. Connecting…"))
            pairing = (serial ?? service.deviceSerial, hub.wifiSerials, .now, false)
        } catch {
            log.error("pairing at \(service.address, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            status = .failed(String(localized: "Pairing didn’t work. Check the code, or open the pairing screen on the device again."))
        }
    }

    /// After pairing: done once the device is on Wi-Fi. adb connects it by itself, usually
    /// within a moment; only if it hasn't after a few seconds is it asked to, at the address
    /// the device advertises then (right after pairing that can still be the old port).
    private func followPairing() async {
        guard let paired = pairing else { return }
        let now = hub.wifiSerials
        if let device = paired.serial ?? now.subtracting(paired.before).first, now.contains(device) {
            pairing = nil
            status = .connected(hub.device(device)?.name)
        } else if !isBusy, !paired.connectAsked, ContinuousClock.now - paired.at > .seconds(5), let serial = paired.serial,
                  let service = connectServices.first(where: { $0.deviceSerial == serial }) {
            pairing?.connectAsked = true
            await connect(service.address)
        }
    }

    func connect(_ address: String) async {
        let address = address.trimmingCharacters(in: .whitespaces)
        guard !address.isEmpty else { return }
        isBusy = true
        defer { isBusy = false }
        status = .working(String(localized: "Connecting to \(address)…"))
        // adb waits up to 75 s on an address it can't reach (QUIRKS A17).
        guard await tcpReachable(address.contains(":") ? address : "\(address):5555", timeout: 3) else { // adb's default port
            status = .failed(String(localized: "This Mac can’t reach \(address). Check that the device is on the same Wi-Fi network and that wireless debugging is on."))
            return
        }
        do {
            try await client.connect(address: address)
            if pairing == nil { status = .connected(nil) }
        } catch AdbError.failed(let reply) where reply.hasPrefix("failed to authenticate") {
            // The device doesn't accept this Mac's key: never paired, or unpaired on the device.
            status = .failed(String(localized: "This device hasn’t allowed this Mac. Pair it above first."))
        } catch {
            status = .failed(String(localized: "Couldn’t connect. Pair the device first, and check it’s on the same Wi-Fi network."))
        }
    }

    private let log = Logger(subsystem: WorkNames.subsystem, category: "devices")

    private static func randomString(_ count: Int) -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        return String((0..<count).map { _ in alphabet.randomElement()! })
    }
}
