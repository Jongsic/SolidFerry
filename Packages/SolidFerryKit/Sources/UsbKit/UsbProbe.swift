import Foundation
import IOKit

/// A process holding an open user client on a USB interface (from `IOUserClientCreator`).
public struct UsbInterfaceOwner: Sendable, Hashable {
    public let pid: Int32
    public let name: String

    /// macOS's photo service, which grabs an Android phone's MTP interface for Photos (QUIRKS H2).
    public static let photoService = "ptpcamerad"
    public var isPhotoService: Bool { name == Self.photoService }

    /// Parses "pid 79756, ptpcamerad".
    init?(creator: String) {
        let parts = creator.split(separator: ",", maxSplits: 1)
        guard parts.count == 2, parts[0].hasPrefix("pid "), let pid = Int32(parts[0].dropFirst(4)) else { return nil }
        self.pid = pid
        self.name = parts[1].trimmingCharacters(in: .whitespaces)
    }
}

/// What a USB interface is to us.
enum UsbInterfaceRole: Equatable {
    case adb
    case mtp
    case other

    init(class cls: Int?, subclass sub: Int?, protocol proto: Int?, name: String) {
        if cls == 255 && sub == 66 && proto == 1 {
            self = .adb
        } else if name.hasPrefix("MTP") {
            // Android names its MTP interface "MTP" (the gadget's interface string), whether
            // it's declared as the still-image class (6/1/1) or vendor-specific. The class
            // alone isn't enough: cameras use 6/1/1 too, and treating one as a phone would
            // take it away from macOS's photo service. QUIRKS H6.
            self = .mtp
        } else {
            self = .other
        }
    }
}

/// An Android-looking USB device and the interfaces we care about. Read-only snapshot of
/// the IORegistry; nothing is opened or claimed.
public struct UsbAndroidDevice: Sendable, Hashable, Identifiable {
    public let registryID: UInt64
    public let vendorID: Int
    public let productID: Int
    public let productName: String
    /// Matches the adb serial for USB-connected adb devices.
    public let serial: String?
    public let hasMTP: Bool
    public let hasADB: Bool
    /// Processes (other than us) that opened the MTP interface.
    public let mtpOwners: [UsbInterfaceOwner]
    /// IORegistry entry ID of the MTP interface, to open it.
    public let mtpInterfaceID: UInt64?

    public var id: UInt64 { registryID }
}

public enum UsbProbe {
    public static func androidDevices() -> [UsbAndroidDevice] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var result: [UsbAndroidDevice] = []
        while true {
            let device = IOIteratorNext(iterator)
            guard device != 0 else { break }
            defer { IOObjectRelease(device) }
            if let info = inspect(device) { result.append(info) }
        }
        return result
    }

    private static func inspect(_ device: io_registry_entry_t) -> UsbAndroidDevice? {
        var hasMTP = false
        var hasADB = false
        var mtpOwners: [UsbInterfaceOwner] = []
        var mtpInterfaceID: UInt64?
        let ownPID = ProcessInfo.processInfo.processIdentifier

        forEachChild(of: device) { interface in
            guard IOObjectConformsTo(interface, "IOUSBHostInterface") != 0 else { return }
            let role = UsbInterfaceRole(class: intProperty(interface, "bInterfaceClass"),
                                        subclass: intProperty(interface, "bInterfaceSubClass"),
                                        protocol: intProperty(interface, "bInterfaceProtocol"),
                                        name: registryName(interface))
            switch role {
            case .adb:
                hasADB = true
            case .mtp:
                hasMTP = true
                var id: UInt64 = 0
                IORegistryEntryGetRegistryEntryID(interface, &id)
                mtpInterfaceID = id
                forEachChild(of: interface) { client in
                    guard let creator = stringProperty(client, "IOUserClientCreator"),
                          let owner = UsbInterfaceOwner(creator: creator), owner.pid != ownPID else { return }
                    // An app can hold several user clients; list each process once.
                    if !mtpOwners.contains(where: { $0.pid == owner.pid }) { mtpOwners.append(owner) }
                }
            case .other:
                break
            }
        }
        guard hasMTP || hasADB else { return nil }

        var registryID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(device, &registryID)
        return UsbAndroidDevice(
            registryID: registryID,
            vendorID: intProperty(device, "idVendor") ?? 0,
            productID: intProperty(device, "idProduct") ?? 0,
            productName: stringProperty(device, "USB Product Name") ?? registryName(device),
            serial: stringProperty(device, "kUSBSerialNumberString"),
            hasMTP: hasMTP,
            hasADB: hasADB,
            mtpOwners: mtpOwners,
            mtpInterfaceID: mtpInterfaceID
        )
    }

    private static func forEachChild(of entry: io_registry_entry_t, _ body: (io_registry_entry_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, kIOServicePlane, &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while true {
            let child = IOIteratorNext(iterator)
            guard child != 0 else { break }
            body(child)
            IOObjectRelease(child)
        }
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func intProperty(_ entry: io_registry_entry_t, _ key: String) -> Int? {
        (property(entry, key) as? NSNumber)?.intValue
    }

    private static func stringProperty(_ entry: io_registry_entry_t, _ key: String) -> String? {
        property(entry, key) as? String
    }

    private static func registryName(_ entry: io_registry_entry_t) -> String {
        var buffer = [CChar](repeating: 0, count: 128)
        return buffer.withUnsafeMutableBufferPointer { p in
            IORegistryEntryGetName(entry, p.baseAddress!) == KERN_SUCCESS ? String(cString: p.baseAddress!) : ""
        }
    }
}
