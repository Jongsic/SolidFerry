import AdbKit
import DeviceCore
import MtpKit
import Foundation
import Observation
import os
import UsbKit

/// Where a device's connection stands. One value, so the parts can't disagree.
enum ConnectionPhase {
    case idle
    /// `stage` is only reported over MTP (ADB connects in a moment).
    case connecting(TransportKind, stage: ConnectStage?, started: Date)
    case connected(any DeviceFileSystem, TransportKind)
    /// The last attempt failed; `ConnectRetry` says when the next one may start. `started` is
    /// when that attempt began, for the waiting screens.
    case failed(TransportKind, any Error, started: Date)
}

private let sessionLog = Logger(subsystem: WorkNames.subsystem, category: "devices")

/// Waits in connecting that have to agree with each other.
enum SessionTiming {
    /// When to decide again once adb has had time to report a newly plugged-in phone: just
    /// after `TransportPreference.adbGrace`.
    static let afterAdbGrace: Duration = .seconds(TransportPreference.adbGrace) + .milliseconds(100)
    /// Losing a connection is acted on after this long: adb briefly drops a device while
    /// another one enumerates, and flipping to MTP and back would disturb every window.
    static let lossDebounce: Duration = .seconds(2)
}

/// Where connecting stands, for the waiting screens (the views don't see backend types).
enum ConnectStage: Equatable {
    case claiming
    case openingSession
    case waitingForStorage
    /// The phone is finishing a request macOS's photo service made before we took it over.
    case phoneBusy

    init(_ stage: MtpFileSystem.OpenStage) {
        self = switch stage {
        case .claiming: .claiming
        case .openingSession: .openingSession
        case .waitingForStorage: .waitingForStorage
        case .phoneBusy: .phoneBusy
        }
    }
}

@MainActor @Observable
final class DeviceSession {
    let serial: String
    var id: String { serial }
    /// Kept across disconnects so windows can still label the device.
    private(set) var lastKnownName: String?
    private(set) var phase = ConnectionPhase.idle
    private(set) var retry = ConnectRetry()
    /// Goes up with every new connection, so a job can tell "the connection that dropped"
    /// from "a new one" (object identities can be reused after the old one is freed).
    private(set) var connectionGeneration = 0
    private(set) var shortcuts: [Shortcut] = []
    /// Favorite folder paths for this device, stored only on this Mac.
    private(set) var favorites: FavoritePaths {
        didSet {
            if favorites.paths != oldValue.paths {
                UserDefaults.standard.set(favorites.paths, forKey: SettingsKey.favorites(serial))
            }
        }
    }
    /// adb address while also connected over Wi-Fi (in use, or standing by behind USB).
    var wifiAddress: String?
    /// Where the phone advertises wireless debugging on the network, if it does.
    var wifiAdvertised: String?
    /// The Wi-Fi address to show. A connection adb made through mDNS is named after the
    /// service ("adb-SERIAL-xyz._adb-tls-connect._tcp"), not an address: then the address
    /// the phone advertises, if known.
    var wifiShownAddress: String? {
        guard let wifiAddress else { return nil }
        return wirelessSerial(fromInstance: wifiAddress) == nil ? wifiAddress : wifiAdvertised
    }
    /// adb on this phone has accepted this Mac (so Wi-Fi connects without asking again).
    private(set) var adbAllowed = false
    private(set) var wifiSetup = WifiSetup.idle
    private var wifiTask: Task<Void, Never>?
    /// The user dropped Wi-Fi for this phone; don't reconnect it on our own until asked.
    private(set) var wifiDeclined = false

    enum WifiSetup: Equatable {
        case idle
        case turningOn
        /// The phone asks whether to allow wireless debugging on this network.
        case waitingForApproval
        case connecting
        case failed(WifiFailure)
    }

    enum WifiFailure: Equatable {
        case notAllowed
        case notFound
        /// Wireless debugging is on but this Mac can't reach the phone.
        case unreachable
    }

    var preference: TransportPreference {
        didSet {
            UserDefaults.standard.set(preference.rawValue, forKey: SettingsKey.transport(serial))
            resetRetry()
            reevaluate(immediately: true)
        }
    }

    private(set) var adb: DeviceDescriptor?
    private(set) var usb: UsbAndroidDevice?
    private let client: AdbClient
    private var switchTask: Task<Void, Never>?
    /// The MTP connection being opened, cancelled when MTP is no longer the target (opening can
    /// wait up to 90 s for a busy phone, which would hold up a switch to ADB).
    private var mtpConnectTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var usbFirstSeen: Date?

    init(serial: String, client: AdbClient) {
        self.serial = serial
        self.client = client
        favorites = FavoritePaths(UserDefaults.standard.stringArray(forKey: SettingsKey.favorites(serial)) ?? [])
        preference = UserDefaults.standard.string(forKey: SettingsKey.transport(serial)).flatMap(TransportPreference.init) ?? .auto
    }

    // MARK: Connection, as the views read it

    var fileSystem: (any DeviceFileSystem)? {
        if case .connected(let fs, _) = phase { fs } else { nil }
    }

    var activeTransport: TransportKind? {
        if case .connected(_, let transport) = phase { transport } else { nil }
    }

    /// An attempt to connect is under way (not waiting to try again).
    var isConnecting: Bool {
        if case .connecting = phase { true } else { false }
    }

    /// While connecting over MTP: the current step and when connecting began.
    var connectStage: ConnectStage? {
        if case .connecting(.mtp, let stage, _) = phase { stage } else { nil }
    }

    var connectStarted: Date? {
        switch phase {
        case .connecting(_, _, let started), .failed(_, _, let started): started
        default: nil
        }
    }

    /// Set while waiting to retry a failed connection (the device is still plugged in).
    var retryAt: Date? { retry.retryAt }

    /// Why connecting over ADB failed (still shown while it's tried again).
    var error: String? {
        switch phase {
        case .failed(.adb, let error, _): UserMessage.describe(error)
        case .connecting(.adb, _, _): retry.lastError.map(UserMessage.describe)
        default: nil
        }
    }

    /// What the last MTP attempt failed with.
    var mtpFailure: MtpConnectError? {
        guard case .failed(.mtp, let error, _) = phase else { return nil }
        return error as? MtpConnectError ?? .other(error.localizedDescription)
    }

    /// What adb calls this phone: the serial over USB, an address over Wi-Fi.
    var adbSerial: String { adb?.serial ?? serial }

    var availableTransports: Set<TransportKind> {
        var set = Set<TransportKind>()
        if adb != nil { set.insert(.adb) }
        if usb?.hasMTP == true { set.insert(.mtp) }
        return set
    }

    /// The connection this device should use now.
    var targetTransport: TransportKind? {
        preference.target(TransportOptions(adbStatus: adb?.status, usbHasMTP: usb?.hasMTP == true,
                                           usbHasADB: usb?.hasADB == true,
                                           usbSeenFor: usbFirstSeen.map { Date().timeIntervalSince($0) }))
    }

    /// nil while the device is disconnected.
    var descriptor: DeviceDescriptor? {
        guard adb != nil || usb != nil else { return lingering }
        // ADB was chosen but the phone only offers File transfer: say so instead of
        // "connecting" forever. (Offering ADB over USB, it's on and adb hasn't listed it yet.)
        if preference == .adb || usb?.hasMTP != true, adb == nil, usb?.hasADB == true, AdbSetup.shared.missing {
            return DeviceDescriptor(transport: .adb, serial: serial, name: displayName, link: .usb,
                                    status: .adbMissing, availableTransports: availableTransports)
        }
        if preference == .adb, adb == nil {
            return DeviceDescriptor(transport: .adb, serial: serial, name: displayName, link: .usb,
                                    status: usb?.hasADB == true ? .connecting : .usbDebuggingOff,
                                    availableTransports: availableTransports)
        }
        // MTP was chosen but the phone doesn't offer it: its USB is in charging mode.
        if preference == .mtp, usb?.hasMTP != true {
            return DeviceDescriptor(transport: .mtp, serial: serial, name: displayName, link: adb?.link ?? .usb,
                                    status: .needsFileTransfer, availableTransports: availableTransports)
        }
        let transport = targetTransport ?? activeTransport ?? (adb != nil ? .adb : .mtp)
        let status: DeviceStatus = switch transport {
        case .adb:
            // adb lists it, but connecting failed (and is tried again): not ready for files.
            if case .failed(.adb, _, _) = phase, adb?.status == .ready { .notResponding } else { adb?.status ?? .offline }
        case .mtp: mtpStatus
        }
        return DeviceDescriptor(transport: transport, serial: serial, name: displayName,
                                link: adb?.link ?? .usb, status: status, availableTransports: availableTransports)
    }

    private var displayName: String {
        if let name = adb?.name { return name }
        if let mtp = fileSystem as? MtpFileSystem, !mtp.deviceInfo.model.isEmpty { return mtp.deviceInfo.model }
        if let name = lastKnownName { return name }
        return usb?.productName.replacingOccurrences(of: "_", with: " ") ?? serial
    }

    private var mtpStatus: DeviceStatus {
        if case .connected(_, .mtp) = phase { return .ready }
        guard let failure = mtpFailure else { return .connecting }
        return switch failure {
        case .chargingOnly: .needsFileTransfer
        case .noStorage: .noStorage
        case .busy(let owners): .busy(owners)
        case .unresponsive: .notResponding
        case .notFound: .offline
        case .other(let message): .unknown(message)
        }
    }

    private var usbLink = UsbLinkHistory()
    private var usbStableTask: Task<Void, Never>?

    /// The USB link dropped and came back by itself more than once lately.
    var usbUnstable: Bool { usbLink.isUnstable }

    private func noteUsbChange(from old: UsbAndroidDevice?, to new: UsbAndroidDevice?) {
        guard usbLink.changed(from: old, to: new, at: Date()) else { return }
        sessionLog.notice("\(self.serial, privacy: .public): USB link dropped and came back (registry \(new?.registryID ?? 0, privacy: .public)); \(self.usbLink.recentDrops, privacy: .public) in 2 min")
        usbStableTask?.cancel()
        usbStableTask = Task {
            try? await Task.sleep(for: .seconds(UsbLinkHistory.dropWindow))
            guard !Task.isCancelled else { return }
            usbLink.calmed()
        }
    }

    /// The device as last seen, shown as connecting for a moment after it went from both adb
    /// and USB: changing its USB mode or a re-enumeration takes it away for a second or two,
    /// and it shouldn't vanish from the sidebar and come back meanwhile.
    private var lingering: DeviceDescriptor?
    private var lingerTask: Task<Void, Never>?

    func update(adb: DeviceDescriptor?, usb: UsbAndroidDevice?) {
        let shown = descriptor
        defer { linger(after: shown) }
        noteUsbChange(from: self.usb, to: usb)
        // Something changed on the phone's side: earlier failures say nothing about now.
        if self.usb?.registryID != usb?.registryID || self.usb?.hasMTP != usb?.hasMTP
            || self.adb?.status != adb?.status || self.adb?.serial != adb?.serial {
            resetRetry()
        }
        self.adb = adb
        if adb?.status == .ready { adbAllowed = true }
        if usb == nil { usbFirstSeen = nil } else if self.usb == nil {
            usbFirstSeen = Date()
            // Re-decide once the adb grace period is over.
            Task {
                try? await Task.sleep(for: SessionTiming.afterAdbGrace)
                reevaluate(immediately: false)
            }
        }
        self.usb = usb
        if let name = adb?.name { lastKnownName = name }
        reevaluate(immediately: false)
    }

    private func linger(after shown: DeviceDescriptor?) {
        if adb != nil || usb != nil {
            lingerTask?.cancel()
            lingerTask = nil
            lingering = nil
            return
        }
        guard lingering == nil, let shown else { return }
        lingering = DeviceDescriptor(transport: shown.transport, serial: shown.serial, name: shown.name, link: shown.link,
                                     status: .connecting, availableTransports: [])
        lingerTask = Task {
            try? await Task.sleep(for: .seconds(UsbLinkHistory.bounceWindow))
            guard !Task.isCancelled else { return }
            lingering = nil
        }
    }

    /// Brings the connection in line with `targetTransport`. Losing the current connection
    /// is debounced (`SessionTiming.lossDebounce`).
    private func reevaluate(immediately: Bool) {
        let target = targetTransport
        // An MTP device that left USB is gone for sure (unlike adb's brief re-listings).
        if activeTransport == .mtp, usb == nil, fileSystem != nil {
            switchTask?.cancel()
            switchTask = nil
            disconnect()
            return
        }
        // Over adb it must also be the same link: unplugging USB moves to Wi-Fi and back.
        let currentUsable = activeTransport == target && fileSystem != nil
            && (target != .adb || (adb?.status == .ready && (fileSystem as? AdbFileSystem)?.serial == adbSerial))
        if currentUsable {
            switchTask?.cancel()
            switchTask = nil
            return
        }
        if fileSystem != nil && !immediately {
            guard switchTask == nil else { return }
            switchTask = Task {
                try? await Task.sleep(for: SessionTiming.lossDebounce)
                guard !Task.isCancelled else { return }
                switchTask = nil
                reevaluate(immediately: true)
            }
            return
        }
        switchTask?.cancel()
        switchTask = nil
        if case .connecting(.mtp, _, _) = phase, target != .mtp { mtpConnectTask?.cancel() }
        if fileSystem != nil { disconnect() }
        connect(to: target)
    }

    /// Drops the connection (or the last failure). An attempt in progress finishes by itself.
    /// A connection that stopped answering while the device is still plugged in (a listing or a
    /// transfer timed out, QUIRKS M8): shown as not responding, with what fixes it, rather than
    /// waited on forever. Unplugged, the device's removal handles it.
    func connectionBroke(_ fs: any DeviceFileSystem) {
        guard case .connected(let current, .mtp) = phase, current === fs, usb?.hasMTP == true else { return }
        sessionLog.notice("\(self.serial, privacy: .public): MTP stopped answering while connected")
        disconnect()
        let failure = MtpConnectError.unresponsive
        phase = .failed(.mtp, failure, started: Date())
        scheduleRetry(after: failure, waitForChange: true)
    }

    private func disconnect() {
        switch phase {
        case .connected(let fs, _):
            fs.close()
            phase = .idle
            shortcuts = []
        case .failed:
            phase = .idle
        case .idle, .connecting:
            break
        }
    }

    // MARK: Retrying

    /// Forget earlier failures: the phone was replugged or changed mode, or the user asked.
    private func resetRetry() {
        retry = ConnectRetry()
        retryTask?.cancel()
        retryTask = nil
    }

    /// After a failed attempt: try again later, or not until something changes. Retrying a
    /// phone whose MTP server stopped answering only queues more work on it (QUIRKS M8: only a
    /// USB mode reset helps), and charging-only can't change without a USB re-enumeration.
    private func scheduleRetry(after error: any Error, waitForChange: Bool) {
        retryTask?.cancel()
        retryTask = nil
        guard let delay = retry.failed(error, waitForChange: waitForChange) else { return }
        retryTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            retry.open()
            reevaluate(immediately: true)
        }
    }

    private func connect(to target: TransportKind?) {
        // One connection at a time: never open a second one over a live connection.
        guard let target, !isConnecting, fileSystem == nil, retry.allowsAttempt() else { return }
        switch target {
        case .adb:
            guard adb?.status == .ready else { return }
            let started = Date()
            phase = .connecting(.adb, stage: nil, started: started)
            Task {
                do {
                    let fs = try await AdbFileSystem.connect(client: client, serial: adbSerial)
                    guard targetTransport == .adb else {
                        phase = .idle
                        reevaluate(immediately: true) // the target changed meanwhile
                        return
                    }
                    resetRetry()
                    await adopt(fs, as: .adb)
                } catch {
                    phase = .failed(.adb, error, started: started)
                    scheduleRetry(after: error, waitForChange: false)
                }
            }
        case .mtp:
            let started = Date()
            phase = .connecting(.mtp, stage: .claiming, started: started)
            mtpConnectTask = Task {
                defer {
                    mtpConnectTask = nil
                    // Not connected and not waiting on a retry: decide again. That includes MTP
                    // being wanted again by now, after this attempt was given up on (a new
                    // attempt was refused while this one was still finishing).
                    let idle = if case .idle = phase { true } else { false }
                    if fileSystem == nil, idle || targetTransport != .mtp { reevaluate(immediately: true) }
                }
                do {
                    let fs = try await MtpFileSystem.open(serial: serial) { stage in
                        Task { @MainActor in
                            if case .connecting(.mtp, _, let started) = self.phase {
                                self.phase = .connecting(.mtp, stage: ConnectStage(stage), started: started)
                            }
                        }
                    }
                    guard targetTransport == .mtp else {
                        fs.close()
                        phase = .idle
                        return
                    }
                    resetRetry()
                    await adopt(fs, as: .mtp)
                } catch let failure as MtpConnectError {
                    sessionLog.notice("\(self.serial, privacy: .public) MTP failed: \(failure.description, privacy: .public)")
                    phase = .failed(.mtp, failure, started: started)
                    switch failure {
                    case .unresponsive, .chargingOnly: scheduleRetry(after: failure, waitForChange: true)
                    default: scheduleRetry(after: failure, waitForChange: false) // locked, busy: fixed on the phone or by quitting an app
                    }
                } catch is CancellationError {
                    // Given up on: MTP isn't wanted any more. Not a failure.
                    phase = .idle
                } catch {
                    sessionLog.notice("\(self.serial, privacy: .public) MTP failed: \(String(describing: error), privacy: .public)")
                    phase = .failed(.mtp, error, started: started)
                    scheduleRetry(after: error, waitForChange: false)
                }
            }
        }
    }

    private func adopt(_ fs: any DeviceFileSystem, as transport: TransportKind) async {
        sessionLog.notice("\(self.serial, privacy: .public) connected via \(transport.rawValue, privacy: .public)\((fs as? MtpFileSystem)?.tookOverFromPtpcamerad == true ? " (taken over from ptpcamerad)" : "", privacy: .public) \(self.connectStarted.map { String(format: "%.0fms after connect start", Date().timeIntervalSince($0) * 1000) } ?? "", privacy: .public)")
        phase = .connected(fs, transport)
        connectionGeneration += 1
        if let mtp = fs as? MtpFileSystem, !mtp.deviceInfo.model.isEmpty, adb == nil {
            lastKnownName = mtp.deviceInfo.model
        }
        // Looked up after connecting; don't apply results from a connection that's gone.
        let found = await Shortcut.existing(in: fs)
        guard fileSystem === fs else { return }
        shortcuts = found
        await checkFavorites(fs)
    }

    func isFavorite(_ path: String?) -> Bool {
        path.map(favorites.contains) ?? false
    }

    func isShortcut(_ path: String) -> Bool {
        shortcuts.contains { $0.path == path }
    }

    /// Favorites to list: the ones that aren't already shortcuts.
    var visibleFavorites: [String] {
        favorites.paths.filter { !isShortcut($0) }
    }

    var missingFavorites: Set<String> { favorites.missing }

    func toggleFavorite(_ path: String) {
        if isFavorite(path) { removeFavorite(path) } else { addFavorite(path) }
    }

    func addFavorite(_ path: String) {
        guard !isShortcut(path) else { return }
        favorites.add(path)
    }

    func removeFavorite(_ path: String) { favorites.remove(path) }
    func favoritesFollowRename(from old: String, to new: String) { favorites.followRename(from: old, to: new) }
    func favoritesFollowDelete(_ paths: [String]) { favorites.followDelete(paths) }
    /// Called when a favorite fails to open, so the sidebar can flag it.
    func markFavoriteMissing(_ path: String) { favorites.markMissing(path) }

    private func checkFavorites(_ fs: any DeviceFileSystem) async {
        var missing = Set<String>()
        for path in favorites.paths {
            let entry = try? await fs.entry(at: RemoteRef(path: path))
            if entry?.isDirectory != true { missing.insert(path) }
        }
        guard fileSystem === fs else { return }
        favorites.setMissing(missing)
    }

    // MARK: Phone-side USB mode (needs ADB)

    /// Puts the phone's USB into "File transfer" (MTP). Only offered when the user asked
    /// for MTP and ADB is there to do it.
    func switchPhoneToFileTransfer() async {
        _ = try? await client.exec(serial: adbSerial, "svc usb setFunctions mtp")
        resetRetry()
        try? await Task.sleep(for: .seconds(3)) // the phone re-enumerates; storage appears shortly after
        reevaluate(immediately: true)
    }

    /// Restarts the phone's MTP server by turning USB data off and back to File transfer —
    /// the only fix found for a stalled Samsung MTP server (QUIRKS M8).
    func restartPhoneMtp() async {
        disconnect()
        _ = try? await client.exec(serial: adbSerial, "svc usb setFunctions")
        try? await Task.sleep(for: .seconds(2))
        _ = try? await client.exec(serial: adbSerial, "svc usb setFunctions mtp")
        resetRetry()
        try? await Task.sleep(for: .seconds(2))
        // The re-enumeration usually reconnected meanwhile; this only covers the case it didn't.
        reevaluate(immediately: true)
    }

    // MARK: Wi-Fi

    /// Turns on the phone's wireless debugging (over the USB connection) and connects over
    /// Wi-Fi too. The phone may ask to allow it on this network; that's shown while waiting.
    func connectOverWifi() {
        guard wifiTask == nil, adb?.status == .ready else { return }
        wifiDeclined = false
        wifiTask = Task {
            defer { wifiTask = nil }
            let transport = adbSerial
            wifiSetup = .turningOn
            _ = try? await client.exec(serial: transport, "settings put global adb_wifi_enabled 1")
            var sawPrompt = false
            var firstAttempt: Date?
            var failure = WifiFailure.notFound
            let deadline = Date().addingTimeInterval(90)
            while Date() < deadline, !Task.isCancelled, adb?.status == .ready {
                if wifiAddress != nil {
                    wifiSetup = .idle
                    return
                }
                let endpoint = try? await client.wirelessEndpoint(serial: transport)
                if endpoint?.enabled == false {
                    // Android turns it back off while asking "Allow wireless debugging on this network?".
                    sawPrompt = true
                    wifiSetup = .waitingForApproval
                } else if let address = endpoint?.address ?? wifiAdvertised {
                    wifiSetup = .connecting
                    firstAttempt = firstAttempt ?? Date()
                    await dropStaleWifiEntries(keeping: address)
                    do {
                        guard await tcpReachable(address, timeout: 3) else { throw WifiUnreachable() }
                        try await client.connect(address: address)
                    } catch {
                        // On, but this Mac can't reach it: usually another Wi-Fi network,
                        // or a router that keeps devices apart.
                        if let firstAttempt, Date().timeIntervalSince(firstAttempt) > 15 {
                            failure = .unreachable
                            break
                        }
                    }
                } else if endpoint?.enabled == true {
                    wifiSetup = .turningOn
                }
                try? await Task.sleep(for: .seconds(1))
            }
            if wifiAddress != nil {
                wifiSetup = .idle
            } else if Task.isCancelled || adb?.status != .ready {
                wifiSetup = .idle
            } else {
                if sawPrompt && wifiSetup == .waitingForApproval { failure = .notAllowed }
                if firstAttempt != nil && failure == .notFound { failure = .unreachable }
                wifiSetup = .failed(failure)
            }
            sessionLog.notice("\(self.serial, privacy: .public): Wi-Fi setup ended: \(String(describing: self.wifiSetup), privacy: .public), address \(self.wifiAddress ?? "none", privacy: .public)")
        }
    }

    /// Forgets old Wi-Fi addresses of this phone (the port changes each time wireless
    /// debugging is turned on), so adb doesn't keep an offline entry around.
    private func dropStaleWifiEntries(keeping address: String) async {
        guard let host = address.split(separator: ":").first else { return }
        let devices = (try? await client.devices()) ?? []
        for device in devices where device.serial.hasPrefix(host + ":") && device.serial != address && device.state != .device {
            try? await client.disconnect(address: device.serial)
        }
    }

    var isSettingUpWifi: Bool { wifiTask != nil }

    /// Drops the Wi-Fi connection (the phone keeps wireless debugging on).
    func disconnectWifi() async {
        guard let address = wifiAddress else { return }
        wifiDeclined = true
        try? await client.disconnect(address: address)
    }

    /// The connection uses its fastest way of listing folders (shown as "Fast mode").
    var isFastMode: Bool {
        fileSystem?.capabilities.fastListing ?? false
    }
}

/// Wireless debugging's port doesn't answer from this Mac.
private struct WifiUnreachable: Error {}
