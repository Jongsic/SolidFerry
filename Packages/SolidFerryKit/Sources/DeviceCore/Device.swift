import Foundation

public enum TransportKind: String, Sendable, Hashable {
    case adb
    case mtp
}

public enum LinkKind: Sendable, Hashable {
    case usb
    case wifi
}

public enum DeviceStatus: Sendable, Hashable {
    case ready
    /// Waiting for the user to accept a prompt on the phone (USB debugging authorization).
    case unauthorized
    case offline
    case connecting
    /// The OS denied access to the USB device.
    case noPermission
    /// MTP: the phone's USB is set to charging only.
    case needsFileTransfer
    /// MTP: connected but no storage exposed (locked, or File transfer not chosen).
    case noStorage
    /// MTP: another app holds the interface.
    case busy([String])
    /// MTP: the phone's MTP server stopped responding.
    case notResponding
    /// ADB was chosen for this phone but USB debugging is off (it's only in File transfer).
    case usbDebuggingOff
    /// Reachable only over ADB (or ADB was chosen), and this Mac has no adb.
    case adbMissing
    /// A state we don't know how to use (raw adb state string).
    case unknown(String)
}

/// One physical device. `transport` is the connection in use; a phone reachable over both
/// ADB and MTP is still one device (same id), so favorites, history and jobs follow it.
public struct DeviceDescriptor: Sendable, Hashable, Identifiable {
    public let transport: TransportKind
    public let serial: String
    public var name: String
    public let link: LinkKind
    public let status: DeviceStatus
    public let availableTransports: Set<TransportKind>

    public init(transport: TransportKind, serial: String, name: String, link: LinkKind, status: DeviceStatus,
                availableTransports: Set<TransportKind> = []) {
        self.transport = transport
        self.serial = serial
        self.name = name
        self.link = link
        self.status = status
        self.availableTransports = availableTransports.isEmpty ? [transport] : availableTransports
    }

    public var id: String { serial }

    /// Devices with the same name (two of one model) get the end of their serial number
    /// added, as few characters as tell them apart: "Lenovo TB J606F (AAAA)".
    public static func distinguishingNames(_ devices: [DeviceDescriptor]) -> [DeviceDescriptor] {
        let groups = Dictionary(grouping: devices.indices, by: { devices[$0].name })
        var result = devices
        for indices in groups.values where indices.count > 1 {
            let serials = indices.map { devices[$0].serial.filter { $0.isLetter || $0.isNumber } }
            let longest = serials.map(\.count).max() ?? 0
            var length = min(4, longest)
            while length < longest, Set(serials.map { $0.suffix(length) }).count < serials.count { length += 1 }
            for (index, serial) in zip(indices, serials) {
                result[index].name += " (\(serial.suffix(length)))"
            }
        }
        return result
    }
}
