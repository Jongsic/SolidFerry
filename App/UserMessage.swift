import AdbKit
import DeviceCore
import MtpKit
import Foundation
import os
import TransferKit

private let errorLog = Logger(subsystem: WorkNames.subsystem, category: "errors")

/// Turns backend errors into localized, user-facing sentences. Packages only carry typed
/// errors, so every visible message is translated here.
enum UserMessage {
    /// An MTP connection failed in a way we don't recognize (the details go to the log).
    static let connectFailure = String(localized: "The device didn’t answer as expected. Unplug it and connect it again.")

    static func describe(_ error: Error) -> String {
        // Reaching here, it wasn't the task that stopped: a connection that closed under the
        // work (an MTP session ends its queued requests this way).
        if error is CancellationError {
            return String(localized: "The connection to the device was lost. Reconnect it.")
        }
        if let fsError = error as? DeviceFSError {
            switch fsError {
            case .unsupported: return String(localized: "This connection doesn’t support that yet.")
            case .alreadyExists(let name): return String(localized: "“\(name)” already exists.")
            case .invalidName(let name):
                return String(localized: "“\(name)” can’t be used as a name on the device. Names can’t contain \" : * ? < > | \\ or /.")
            case .notFound(let path): return String(localized: "\(path) doesn’t exist.")
            case .notADirectory(let path): return String(localized: "\(path) is not a folder.")
            case .localWrite(let reason): return String(localized: "Couldn’t write the file on this Mac (\(reason)).")
            case .localRead(let reason): return String(localized: "Couldn’t read the file on this Mac (\(reason)).")
            }
        }
        if let zip = error as? ZipWriter.Failure {
            return switch zip {
            case .tooLarge(let name): String(localized: "“\(name)” changed while it was being zipped. Try again.")
            case .unreadable(let path): String(localized: "Couldn’t read \(path) on this Mac to zip it.")
            }
        }
        if let mtp = error as? MtpError {
            switch mtp {
            case .response(_, let code) where code == PTPResponse.invalidObjectHandle:
                return String(localized: "The file changed on the device. Reload and try again.")
            case .response(_, let code) where code == PTPResponse.storeFull:
                return String(localized: "The device’s storage is full.")
            case .response(_, let code) where code == PTPResponse.accessDenied || code == PTPResponse.objectWriteProtected:
                return String(localized: "The device doesn’t allow changing that.")
            default:
                // Codes mean nothing to people; keep them for the log.
                errorLog.error("unrecognized MTP error: \(mtp.description, privacy: .public)")
                return String(localized: "The device couldn’t do that. Try again, or reconnect the device.")
            }
        }
        guard let adb = error as? AdbError else { return other(error) }
        switch adb {
        case .serverUnavailable, .connectionClosed:
            return String(localized: "Can’t reach the adb server.")
        case .adbNotFound:
            return String(localized: "adb wasn’t found. Install Android platform-tools.")
        case .io(let reason):
            errorLog.error("adb io: \(reason, privacy: .public)")
            return String(localized: "The connection was interrupted. Try again, or reconnect the device.")
        case .protocolViolation:
            return String(localized: "The device sent an unexpected response.")
        case .failed(let message):
            errorLog.error("adb: \(message, privacy: .public)")
            if message.contains("offline") || message.contains("not found") {
                return String(localized: "The connection to the device was lost. Reconnect it.")
            }
            return String(localized: "The device couldn’t do that. Try again, or reconnect the device.")
        case .commandFailed(let output):
            // The shell's own words mean little to people; the ones that say what to do are told.
            errorLog.error("adb command: \(output, privacy: .public)")
            if output.contains("No space left") { return String(localized: "The device’s storage is full.") }
            if output.contains("Read-only") || output.contains("Permission denied") {
                return String(localized: "The device doesn’t allow changing that.")
            }
            return String(localized: "The device couldn’t do that. Try again, or reconnect the device.")
        case .notADirectory(let path):
            return String(localized: "\(path) is not a folder.")
        case .pathTooLong(let path):
            return String(localized: "The path is too long: \(path)")
        case .remoteError(let path, let errno):
            switch errno {
            case 2: return String(localized: "\(path) doesn’t exist.")
            case 13: return String(localized: "No permission to open \(path).")
            default:
                errorLog.error("adb remote error \(errno, privacy: .public) for \(path, privacy: .public)")
                return String(localized: "Couldn’t open \(path).")
            }
        }
    }

    /// Errors of other kinds: the system's own sentences where it has them (files on this Mac,
    /// the network); a type of ours that isn't described above goes to the log instead of
    /// showing its name.
    private static func other(_ error: Error) -> String {
        let domain = (error as NSError).domain
        if [NSCocoaErrorDomain, NSPOSIXErrorDomain, NSURLErrorDomain, NSOSStatusErrorDomain].contains(domain) {
            return error.localizedDescription
        }
        errorLog.error("undescribed error: \(String(describing: error), privacy: .public)")
        return String(localized: "Something went wrong. Try again, or reconnect the device.")
    }
}
