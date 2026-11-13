import DeviceCore
import Testing

// Which connection a phone gets, for each setting and what the phone offers.

private func options(adb: DeviceStatus? = nil, mtp: Bool = false, adbInterface: Bool = false,
                     seenFor: Double? = 10) -> TransportOptions {
    TransportOptions(adbStatus: adb, usbHasMTP: mtp, usbHasADB: adbInterface, usbSeenFor: seenFor)
}

@Test func autoPrefersReadyAdb() {
    #expect(TransportPreference.auto.target(options(adb: .ready, mtp: true, adbInterface: true)) == .adb)
    // Over Wi-Fi only (not on USB).
    #expect(TransportPreference.auto.target(options(adb: .ready, seenFor: nil)) == .adb)
}

@Test func autoUsesMtpWhileAdbIsntReady() {
    // Waiting for "Allow USB debugging": browse over MTP meanwhile.
    #expect(TransportPreference.auto.target(options(adb: .unauthorized, mtp: true, adbInterface: true)) == .mtp)
    // USB debugging off.
    #expect(TransportPreference.auto.target(options(mtp: true)) == .mtp)
}

@Test func autoWaitsBrieflyForAdbAfterPlugIn() {
    // USB shows an ADB interface but adb hasn't listed the phone yet.
    let justPlugged = options(mtp: true, adbInterface: true, seenFor: TransportPreference.adbGrace - 1)
    #expect(TransportPreference.auto.target(justPlugged) == nil)
    let afterGrace = options(mtp: true, adbInterface: true, seenFor: TransportPreference.adbGrace + 0.1)
    #expect(TransportPreference.auto.target(afterGrace) == .mtp)
}

@Test func autoFallsBackToAdbInAnyState() {
    // Charging only with debugging waiting for approval: show the ADB steps.
    #expect(TransportPreference.auto.target(options(adb: .unauthorized, adbInterface: true)) == .adb)
    #expect(TransportPreference.auto.target(options()) == nil)
}

@Test func chosenTransportIsKept() {
    #expect(TransportPreference.adb.target(options(adb: .unauthorized, mtp: true)) == .adb)
    #expect(TransportPreference.adb.target(options(mtp: true)) == nil)
    #expect(TransportPreference.mtp.target(options(adb: .ready, mtp: true)) == .mtp)
    #expect(TransportPreference.mtp.target(options(adb: .ready)) == nil)
}
