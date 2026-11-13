import DeviceCore
import Foundation

public enum AdbMonitorEvent: Sendable {
    case devices([DeviceDescriptor])
    case serverUnavailable(AdbError)
}

/// Watches adb devices, (re)starting the server and reconnecting as needed.
public struct AdbDeviceMonitor: Sendable {
    public let client: AdbClient

    public init(client: AdbClient = AdbClient()) {
        self.client = client
    }

    public func events() -> AsyncStream<AdbMonitorEvent> {
        let client = client
        return AsyncStream { continuation in
            let task = Task {
                while !Task.isCancelled {
                    do {
                        try await AdbServer.ensureRunning(client: client)
                        for try await list in client.trackDevices() {
                            continuation.yield(.devices(list.map(\.descriptor)))
                        }
                    } catch {
                        if Task.isCancelled { break }
                        continuation.yield(.serverUnavailable(error as? AdbError ?? .io(error.localizedDescription)))
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension AdbDeviceInfo {
    var descriptor: DeviceDescriptor {
        let status: DeviceStatus = switch state {
        case .device: .ready
        case .unauthorized: .unauthorized
        case .authorizing, .connecting: .connecting
        case .offline: .offline
        case .noPermissions: .noPermission
        case .other(let raw): .unknown(raw)
        }
        let name = model?.replacingOccurrences(of: "_", with: " ") ?? serial
        return DeviceDescriptor(transport: .adb, serial: serial, name: name,
                                link: isWireless ? .wifi : .usb, status: status)
    }
}
