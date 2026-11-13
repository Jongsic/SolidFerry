import AdbKit
import DeviceCore
import MtpKit
import Foundation
import Observation
import os
import UsbKit

/// App-wide owner of devices and their connections. Every window looks devices up here, so
/// one device has exactly one session no matter how many windows show it. A device is one
/// physical phone (keyed by serial) whether it shows up over ADB, MTP or both.
@MainActor @Observable
final class DeviceHub {
    /// What adb reports, before merging with USB.
    private(set) var adbDevices: [DeviceDescriptor] = []
    private(set) var usbDevices: [UsbAndroidDevice] = []
    private(set) var serverMessage: String?
    private(set) var sessions: [String: DeviceSession] = [:]
    /// Serials in the order they first appeared, so the sidebar doesn't reshuffle.
    private var order: [String] = []
    /// Wireless adb serials ("192.168.0.12:41234", "adb-SERIAL-xyz._adb-tls-connect._tcp")
    /// → the phone's hardware serial, so a phone is one device over USB and Wi-Fi.
    private var hardwareSerials: [String: String] = [:]
    private var resolving: Set<String> = []

    private let client = AdbClient()
    private var started = false
    private var usbWatcher: UsbWatcher?
    /// `log stream --predicate 'subsystem == "<bundle ID>"'` shows device events.
    private let log = Logger(subsystem: WorkNames.subsystem, category: "devices")

    func start() {
        guard !started else { return }
        started = true
        Task { await watchDevices() }
        Task { await watchUsb() }
        Task { await watchWireless() }
        // React the instant a phone is plugged in, so an MTP-only phone is claimed before
        // macOS's photo service grabs it (polling every 2 s lost that race).
        usbWatcher = UsbWatcher { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.refreshUsb() { self.syncSessions() }
            }
        }
    }

    /// Connected devices (over any transport).
    var devices: [DeviceDescriptor] {
        DeviceDescriptor.distinguishingNames(order.compactMap { sessions[$0]?.descriptor })
    }

    func device(_ id: String?) -> DeviceDescriptor? {
        guard let descriptor = session(id)?.descriptor else { return nil }
        return devices.first { $0.serial == descriptor.serial } ?? descriptor
    }

    func session(_ id: String?) -> DeviceSession? {
        // Device IDs are serials; a restored window can carry "adb:SERIAL" for the same device.
        guard let id else { return nil }
        return sessions[id] ?? sessions[String(id.drop { $0 != ":" }.dropFirst())]
    }

    var firstReadyDeviceID: String? {
        devices.first { $0.status == .ready }?.id
    }

    private func watchDevices() async {
        for await event in AdbDeviceMonitor(client: client).events() {
            switch event {
            case .devices(let list):
                log.notice("adb devices: \(list.map { "\($0.serial)=\(String(describing: $0.status))" }.joined(separator: ", "), privacy: .public)")
                serverMessage = nil
                AdbSetup.shared.missing = false
                adbDevices = list
                resolveWirelessSerials()
            case .serverUnavailable(let error):
                log.error("adb server unavailable: \(String(describing: error), privacy: .public)")
                AdbSetup.shared.missing = error == .adbNotFound
                serverMessage = AdbSetup.shared.missing ? nil : UserMessage.describe(error)
                adbDevices = []
            }
            refreshUsb()
            syncSessions()
        }
    }

    /// Phones advertising wireless debugging. A phone this Mac already reaches over adb is
    /// also connected over Wi-Fi, so unplugging the cable doesn't interrupt anything. Other
    /// phones on the network are left alone (connecting would ask their owner for approval).
    private func watchWireless() async {
        var attempted: [String: Date] = [:]
        while !Task.isCancelled {
            let services = (try? await client.mdnsServices()) ?? []
            for (serial, session) in sessions {
                let service = services.first { $0.kind == .connect && $0.deviceSerial == serial }
                if session.wifiAdvertised != service?.address { session.wifiAdvertised = service?.address }
                guard session.wifiAddress == nil, session.adbAllowed, !session.wifiDeclined, !session.isSettingUpWifi,
                      UserDefaults.standard.bool(forKey: SettingsKey.autoWifi),
                      Date().timeIntervalSince(attempted[serial] ?? .distantPast) > 30 else { continue }
                // At most every 30 s per phone, whether or not it turns out to be on: asking a
                // phone with wireless debugging off is a shell command each time.
                attempted[serial] = Date()
                // Plugged in: ask the phone directly (mDNS doesn't always see it).
                var address = service?.address
                if let usbAdb = session.adb, usbAdb.link == .usb, usbAdb.status == .ready {
                    let endpoint = try? await client.wirelessEndpoint(serial: usbAdb.serial)
                    if endpoint?.enabled == true { address = endpoint?.address ?? address } else { address = nil }
                }
                guard let address else { continue }
                log.notice("\(serial, privacy: .public): connecting over Wi-Fi at \(address, privacy: .public)")
                try? await client.connect(address: address)
            }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    /// The IORegistry snapshot is cheap; poll it so MTP devices and owners show up.
    private func watchUsb() async {
        while !Task.isCancelled {
            if refreshUsb() { syncSessions() }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    @discardableResult
    private func refreshUsb() -> Bool {
        let snapshot = UsbProbe.androidDevices()
        guard snapshot != usbDevices else { return false }
        log.notice("usb: \(snapshot.map { "\($0.serial ?? "?") mtp=\($0.hasMTP) adb=\($0.hasADB)" }.joined(separator: ", "), privacy: .public)")
        usbDevices = snapshot
        return true
    }

    /// Devices adb has ready over Wi-Fi, by serial.
    var wifiSerials: Set<String> {
        Set(adbDevices.filter { $0.link == .wifi && $0.status == .ready }.compactMap(key(for:)))
    }

    /// The device a wireless adb entry belongs to; nil until it's known.
    private func key(for adb: DeviceDescriptor) -> String? {
        adb.link == .wifi ? hardwareSerials[adb.serial] : adb.serial
    }

    private func resolveWirelessSerials() {
        for device in adbDevices where device.link == .wifi && hardwareSerials[device.serial] == nil {
            if let serial = wirelessSerial(fromInstance: device.serial) {
                hardwareSerials[device.serial] = serial
                continue
            }
            guard device.status == .ready, !resolving.contains(device.serial) else { continue }
            resolving.insert(device.serial)
            let transport = device.serial
            Task {
                let serial = try? await client.hardwareSerial(of: transport)
                resolving.remove(transport)
                guard let serial else {
                    // Often just too early after connecting. Leave it unresolved (it isn't
                    // shown meanwhile) and ask again, rather than showing a second device.
                    try? await Task.sleep(for: .seconds(3))
                    resolveWirelessSerials()
                    return
                }
                hardwareSerials[transport] = serial
                syncSessions()
            }
        }
    }

    /// The adb entry a device should use: USB when it's plugged in, Wi-Fi otherwise.
    private func adbEntry(for serial: String) -> DeviceDescriptor? {
        let entries = adbDevices.filter { key(for: $0) == serial }
        return entries.first { $0.link == .usb } ?? entries.first { $0.status == .ready } ?? entries.first
    }

    /// Sessions outlive disconnects so windows reattach to the same object on reconnect.
    private func syncSessions() {
        var present = Set<String>()
        for device in adbDevices { if let key = key(for: device) { present.insert(key) } }
        // Offering only ADB, it's listed by adb; without adb, so that getting it can be offered.
        for usb in usbDevices where usb.hasMTP || (usb.hasADB && AdbSetup.shared.missing) {
            if let serial = usb.serial { present.insert(serial) }
        }

        for serial in present {
            let session = sessions[serial] ?? {
                let created = DeviceSession(serial: serial, client: client)
                sessions[serial] = created
                return created
            }()
            if !order.contains(serial) { order.append(serial) }
            let wifi = adbDevices.first { $0.link == .wifi && $0.status == .ready && key(for: $0) == serial }?.serial
            if session.wifiAddress != wifi { session.wifiAddress = wifi }
            session.update(adb: adbEntry(for: serial),
                           usb: usbDevices.first { $0.serial == serial })
        }
        for (serial, session) in sessions where !present.contains(serial) {
            session.update(adb: nil, usb: nil)
        }
        order.removeAll { !present.contains($0) && sessions[$0]?.descriptor == nil }
    }
}
