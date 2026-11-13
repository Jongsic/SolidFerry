import Foundation
import Testing
@testable import UsbKit

@Test func ownersFromTheRegistry() {
    let owner = UsbInterfaceOwner(creator: "pid 79756, ptpcamerad")
    #expect(owner?.pid == 79756)
    #expect(owner?.name == "ptpcamerad")
    #expect(owner?.isPhotoService == true)
    // Names can contain commas; only the first one separates.
    #expect(UsbInterfaceOwner(creator: "pid 12, Android File Transfer, Agent")?.name == "Android File Transfer, Agent")
    #expect(UsbInterfaceOwner(creator: "pid 12, OpenMTP")?.isPhotoService == false)
}

@Test func ownersThatDontParse() {
    #expect(UsbInterfaceOwner(creator: "") == nil)
    #expect(UsbInterfaceOwner(creator: "ptpcamerad") == nil)
    #expect(UsbInterfaceOwner(creator: "pid x, ptpcamerad") == nil)
    #expect(UsbInterfaceOwner(creator: "79756, ptpcamerad") == nil)
}

@Test func interfaceRoles() {
    #expect(UsbInterfaceRole(class: 255, subclass: 66, protocol: 1, name: "ADB Interface") == .adb)
    // Phones name the MTP interface, declared as still image or vendor-specific.
    #expect(UsbInterfaceRole(class: 6, subclass: 1, protocol: 1, name: "MTP") == .mtp)
    #expect(UsbInterfaceRole(class: 255, subclass: 255, protocol: 0, name: "MTP") == .mtp)
    // A camera is still image too, but not named MTP: left to macOS (QUIRKS H6).
    #expect(UsbInterfaceRole(class: 6, subclass: 1, protocol: 1, name: "PTP") == .other)
    #expect(UsbInterfaceRole(class: 6, subclass: 1, protocol: 1, name: "") == .other)
    // Fastboot and other vendor interfaces.
    #expect(UsbInterfaceRole(class: 255, subclass: 66, protocol: 3, name: "fastboot") == .other)
    #expect(UsbInterfaceRole(class: nil, subclass: nil, protocol: nil, name: "") == .other)
}

// MARK: Link drops (QUIRKS G8)

private func phone(_ registry: UInt64, mtp: Bool = true, adb: Bool = true, product: Int = 0x6860) -> UsbAndroidDevice {
    UsbAndroidDevice(registryID: registry, vendorID: 0x04E8, productID: product, productName: "Phone", serial: "S",
                     hasMTP: mtp, hasADB: adb, mtpOwners: [], mtpInterfaceID: nil)
}

private let t0 = Date(timeIntervalSince1970: 1_000_000)

/// Plugs in at t0 and lets the phone settle.
private func settled() -> UsbLinkHistory {
    var history = UsbLinkHistory()
    _ = history.changed(from: nil, to: phone(1), at: t0)
    return history
}

@Test func plugInAndSettlingAreNotDrops() {
    var history = UsbLinkHistory()
    let dropped1 = history.changed(from: nil, to: phone(1), at: t0)
    #expect(!dropped1)
    // Re-enumerating within the first seconds after plugging in.
    let dropped2 = history.changed(from: phone(1), to: nil, at: t0.addingTimeInterval(5))
    #expect(!dropped2)
    let dropped3 = history.changed(from: nil, to: phone(2), at: t0.addingTimeInterval(6))
    #expect(!dropped3)
}

@Test func modeChangesAreNotDrops() {
    var history = settled()
    let dropped4 = history.changed(from: phone(1), to: phone(2, mtp: false), at: t0.addingTimeInterval(60))
    #expect(!dropped4)
    let dropped5 = history.changed(from: phone(2, mtp: false), to: phone(3, product: 0x685C), at: t0.addingTimeInterval(70))
    #expect(!dropped5)
    #expect(history.recentDrops == 0)
}

@Test func threeDropsInTwoMinutesWarnUntilItCalms() {
    var history = settled()
    // Gone and back within a few seconds, same mode: the link dropped.
    let gone = history.changed(from: phone(1), to: nil, at: t0.addingTimeInterval(60))
    #expect(!gone)
    let back = history.changed(from: nil, to: phone(2), at: t0.addingTimeInterval(62))
    #expect(back)
    let replaced = history.changed(from: phone(2), to: phone(3), at: t0.addingTimeInterval(90)) // in one step
    #expect(replaced)
    #expect(!history.isUnstable) // twice can be switching USB modes on a Galaxy
    let third = history.changed(from: phone(3), to: phone(4), at: t0.addingTimeInterval(100))
    #expect(third)
    #expect(history.isUnstable && history.recentDrops == 3)
    history.calmed()
    #expect(!history.isUnstable && history.recentDrops == 0)
}

@Test func dropsFarApartDontAddUp() {
    var history = settled()
    let dropped9 = history.changed(from: phone(1), to: phone(2), at: t0.addingTimeInterval(60))
    #expect(dropped9)
    let dropped10 = history.changed(from: phone(2), to: phone(3), at: t0.addingTimeInterval(60 + UsbLinkHistory.dropWindow + 1))
    #expect(dropped10)
    #expect(!history.isUnstable && history.recentDrops == 1)
}

@Test func unpluggingForAWhileIsAReplugNotADrop() {
    var history = settled()
    let dropped11 = history.changed(from: phone(1), to: nil, at: t0.addingTimeInterval(60))
    #expect(!dropped11)
    let dropped12 = history.changed(from: nil, to: phone(2), at: t0.addingTimeInterval(70))
    #expect(!dropped12)
    // Settling again after the replug.
    let dropped13 = history.changed(from: phone(2), to: phone(3), at: t0.addingTimeInterval(75))
    #expect(!dropped13)
}
