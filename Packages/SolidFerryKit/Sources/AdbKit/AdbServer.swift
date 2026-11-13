import DeviceCore
import Foundation

/// Finds the adb binary and makes sure its server is running. The binary is only used for
/// that (and pairing later); everything else goes over the socket.
public enum AdbServer {
    /// GUI apps don't inherit the shell PATH, so check the usual install locations too.
    public static func locateBinary() -> URL? {
        let env = ProcessInfo.processInfo.environment
        var candidates: [String] = []
        for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let sdk = env[key] { candidates.append(sdk + "/platform-tools/adb") }
        }
        candidates.append(NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb")
        candidates += ["/opt/homebrew/bin/adb", "/usr/local/bin/adb", appInstalled.path]
        if let path = env["PATH"] {
            candidates += path.split(separator: ":").map { $0 + "/adb" }
        }
        return candidates
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// Where the app puts platform-tools it downloads for someone who has none (its own
    /// Application Support folder). Used only when there's no adb elsewhere.
    public static var appInstalled: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(WorkNames.subsystem, isDirectory: true)
            .appendingPathComponent("platform-tools/adb")
    }

    public static func ensureRunning(client: AdbClient = AdbClient()) async throws {
        if (try? await client.serverVersion()) != nil { return }
        guard let adb = locateBinary() else { throw AdbError.adbNotFound }
        try await blocking {
            let process = Process()
            process.executableURL = adb
            process.arguments = ["-P", String(client.port), "start-server"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
        }
        _ = try await client.serverVersion()
    }
}
