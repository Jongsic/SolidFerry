import Foundation

/// Which connection a device should use. Stored per device serial.
public enum TransportPreference: String, CaseIterable, Sendable {
    /// ADB when it's ready (fastest), otherwise MTP.
    case auto
    case adb
    case mtp
}

/// What's known about a phone when choosing its connection.
public struct TransportOptions: Sendable {
    /// What adb says about the phone; nil when adb doesn't list it.
    public var adbStatus: DeviceStatus?
    public var usbHasMTP: Bool
    public var usbHasADB: Bool
    /// How long USB has shown the phone; nil when it isn't on USB.
    public var usbSeenFor: TimeInterval?

    public init(adbStatus: DeviceStatus?, usbHasMTP: Bool, usbHasADB: Bool, usbSeenFor: TimeInterval?) {
        self.adbStatus = adbStatus
        self.usbHasMTP = usbHasMTP
        self.usbHasADB = usbHasADB
        self.usbSeenFor = usbSeenFor
    }
}

extension TransportPreference {
    /// adb reports a USB phone a moment after the USB scan sees it. Until then Auto waits,
    /// rather than open MTP only to switch to ADB right after.
    public static let adbGrace: TimeInterval = 3

    /// The connection to use now; nil to use none (yet).
    public func target(_ options: TransportOptions) -> TransportKind? {
        switch self {
        case .adb: return options.adbStatus != nil ? .adb : nil
        case .mtp: return options.usbHasMTP ? .mtp : nil
        case .auto:
            if options.adbStatus == .ready { return .adb }
            if options.adbStatus == nil, options.usbHasADB, let seen = options.usbSeenFor, seen < Self.adbGrace {
                return nil
            }
            if options.usbHasMTP { return .mtp }
            return options.adbStatus != nil ? .adb : nil
        }
    }
}
