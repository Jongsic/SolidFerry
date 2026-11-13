import Foundation
import UsbKit

/// Names people recognize for processes that can hold a phone's MTP connection.
enum OwnerNames {
    static func friendly(_ process: String) -> String {
        switch process {
        case UsbInterfaceOwner.photoService: String(localized: "macOS photo service")
        case "icdd": String(localized: "Image Capture")
        case "Android File Transfer", "Android File Transfer Agent": "Android File Transfer"
        case "OpenMTP", "openmtp": "OpenMTP"
        case "Smart Switch", "SmartSwitch", "Smart Switch Agent": "Samsung Smart Switch"
        default: process
        }
    }

    /// One readable name per app, however many connections it holds.
    static func list(_ owners: [String]) -> String {
        var seen = Set<String>()
        // "A, B and C", in the user's language.
        return owners.map(friendly).filter { seen.insert($0).inserted }.formatted(.list(type: .and))
    }
}
