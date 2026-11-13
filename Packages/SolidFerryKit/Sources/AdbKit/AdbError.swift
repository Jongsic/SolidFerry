import Foundation

/// Errors carry the facts; the app turns them into localized sentences. `errorDescription`
/// is English for the CLI and logs.
public enum AdbError: Error, LocalizedError, Equatable, Sendable {
    /// Nothing is listening on the adb server port.
    case serverUnavailable(String)
    /// No adb binary to start the server with.
    case adbNotFound
    case io(String)
    case connectionClosed
    case protocolViolation(String)
    /// The server or device answered FAIL.
    case failed(String)
    /// A stat on the device failed with this (wire) errno.
    case remoteError(path: String, errno: UInt32)
    case notADirectory(String)
    /// A shell command on the device exited non-zero; carries its output.
    case commandFailed(String)
    case pathTooLong(String)

    public var errorDescription: String? {
        switch self {
        case .serverUnavailable(let reason): "cannot reach the adb server (\(reason))"
        case .adbNotFound: "adb not found; install Android platform-tools"
        case .io(let reason): "I/O error: \(reason)"
        case .connectionClosed: "connection closed"
        case .protocolViolation(let reason): "protocol error: \(reason)"
        case .failed(let message): message
        case .notADirectory(let path): "\(path): not a directory"
        case .commandFailed(let output): "command failed: \(output)"
        case .pathTooLong(let path): "\(path): path too long"
        case .remoteError(let path, let errno):
            switch errno {
            case 2: "\(path): no such file or directory"
            case 13: "\(path): permission denied"
            default: "\(path): error \(errno)"
            }
        }
    }
}
