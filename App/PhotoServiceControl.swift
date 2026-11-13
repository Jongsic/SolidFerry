import Darwin
import Foundation

/// Optional: stop macOS's photo service (ptpcamerad) from taking Android phones.
///
/// macOS treats an Android phone's MTP interface as a camera; when one is plugged in, Photos
/// (including its widget) asks ptpcamerad to read the phone's library. ptpcamerad grabs the
/// phone before we can, and even after we take it over the phone keeps working on
/// that scan (first listing took 17 s instead of 0.3 s). Disabling the service for this user
/// (`launchctl disable gui/<uid>/com.apple.ptpcamerad`) prevents it; enabling reverts it.
/// Side effect: Photos and Image Capture can't import from cameras/phones while it's off.
enum PhotoServiceControl {
    static let label = "com.apple.ptpcamerad"
    private static var target: String { "gui/\(getuid())/\(label)" }

    enum Failure: Error, LocalizedError {
        case launchctl(String)
        var errorDescription: String? {
            switch self {
            case .launchctl(let output): String(localized: "macOS didn’t allow the change (\(output)).")
            }
        }
    }

    /// Whether the service is disabled for this user.
    static func isBlocked() async -> Bool {
        let output = (try? await run(["print-disabled", "gui/\(getuid())"])) ?? ""
        guard let line = output.split(separator: "\n").first(where: { $0.contains("\"\(label)\"") }) else { return false }
        return line.contains("disabled") || line.contains("true")
    }

    /// Whether the service is loaded in this login session. `disable` alone only stops it
    /// from loading at the next login; while loaded it's still started on demand (measured).
    static func isLoaded() async -> Bool {
        (try? await run(["print", target])) != nil
    }

    static func setBlocked(_ blocked: Bool) async throws {
        if blocked {
            try await run(["disable", target])
            // Also try to unload it now. With SIP on, macOS refuses for its own services
            // (the plist is SIP-restricted), and the setting takes effect at the next login.
            if (try? await run(["bootout", target])) == nil {
                _ = try? await run(["kill", "SIGKILL", target])
            }
        } else {
            try await run(["enable", target])
            _ = try? await run(["bootstrap", "gui/\(getuid())", "/System/Library/LaunchAgents/\(label).plist"])
        }
    }

    @discardableResult
    private static func run(_ arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                process.arguments = arguments
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    if process.terminationStatus == 0 {
                        continuation.resume(returning: output)
                    } else {
                        continuation.resume(throwing: Failure.launchctl(output.isEmpty ? "exit \(process.terminationStatus)" : output))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
