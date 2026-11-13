import DeviceCore
import Foundation

/// Whether a phone keeps the dates of files sent to it, per phone and kind of connection (a
/// Galaxy keeps them over ADB but not over MTP). Measured once by `probe`, or learned from an
/// upload that saw them dropped, and remembered on this Mac.
enum UploadDates {
    enum Known: String {
        case kept
        case ignored
    }

    private static func key(_ deviceID: String, _ fs: any DeviceFileSystem) -> String {
        SettingsKey.uploadDates(deviceID, connection: fs.transport.rawValue)
    }

    static func known(_ deviceID: String, fs: any DeviceFileSystem) -> Known? {
        if !fs.capabilities.keepsUploadDates { return .ignored }
        return UserDefaults.standard.string(forKey: key(deviceID, fs)).flatMap(Known.init)
    }

    static func remember(_ known: Known, _ deviceID: String, fs: any DeviceFileSystem) {
        UserDefaults.standard.set(known.rawValue, forKey: key(deviceID, fs))
    }

    /// Measures it in `folder` (the upload's destination) unless it's already known.
    static func probe(_ deviceID: String, fs: any DeviceFileSystem, in folder: RemoteRef) async -> Known? {
        if let known = known(deviceID, fs: fs) { return known }
        guard let kept = try? await fs.probeKeepsUploadDates(in: folder) else { return nil }
        let result: Known = kept ? .kept : .ignored
        remember(result, deviceID, fs: fs)
        return result
    }
}
