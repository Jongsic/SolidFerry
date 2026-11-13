import Foundation

public enum AdbDeviceState: Sendable, Hashable {
    case device
    case unauthorized
    case authorizing
    case offline
    case connecting
    case noPermissions
    case other(String)

    init(_ raw: String) {
        switch raw {
        case "device": self = .device
        case "unauthorized": self = .unauthorized
        case "authorizing": self = .authorizing
        case "offline": self = .offline
        case "connecting": self = .connecting
        case "no": self = .noPermissions // "no permissions (...)"
        default: self = .other(raw)
        }
    }
}

public struct AdbDeviceInfo: Sendable, Hashable, Identifiable {
    public let serial: String
    public let state: AdbDeviceState
    /// `product`, `model`, `device`, `transport_id`, `usb`, ... from `devices -l`.
    public let properties: [String: String]

    public var id: String { serial }
    public var model: String? { properties["model"] }
    public var isWireless: Bool {
        serial.contains("._adb-tls-connect.") || serial.contains(":")
    }

    /// Parses `host:devices-l` / `host:track-devices-l` output.
    static func parseList(_ text: String) -> [AdbDeviceInfo] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let tokens = line.split(whereSeparator: \.isWhitespace)
            guard tokens.count >= 2 else { return nil }
            var properties: [String: String] = [:]
            for token in tokens.dropFirst(2) {
                guard let colon = token.firstIndex(of: ":") else { continue }
                properties[String(token[..<colon])] = String(token[token.index(after: colon)...])
            }
            return AdbDeviceInfo(serial: String(tokens[0]), state: AdbDeviceState(String(tokens[1])), properties: properties)
        }
    }
}

/// Talks to the adb server over its local socket (default port 5037).
public struct AdbClient: Sendable {
    public let port: UInt16

    public init(port: UInt16 = 5037) {
        self.port = port
    }

    func connect() throws -> AdbSocket {
        try AdbSocket(port: port)
    }

    func hostQuery(_ request: String) throws -> String {
        let socket = try connect()
        try socket.sendHostRequest(request)
        try socket.readStatus()
        return try socket.readHexLengthString()
    }

    /// Opens `service` on the device (`sync:`, `exec:...`). The returned socket is attached to it.
    func openService(serial: String, _ service: String) throws -> AdbSocket {
        let socket = try connect()
        try socket.sendHostRequest("host:transport:\(serial)")
        try socket.readStatus()
        try socket.sendHostRequest(service)
        try socket.readStatus()
        return socket
    }

    public func serverVersion() async throws -> Int {
        let text = try await blocking { try hostQuery("host:version") }
        guard let version = Int(text, radix: 16) else { throw AdbError.protocolViolation("bad version \(text)") }
        return version
    }

    public func devices() async throws -> [AdbDeviceInfo] {
        AdbDeviceInfo.parseList(try await blocking { try hostQuery("host:devices-l") })
    }

    public func features(serial: String) async throws -> Set<String> {
        let text = try await blocking { try hostQuery("host-serial:\(serial):features") }
        return Set(text.split(separator: ",").map(String.init))
    }

    /// Runs a command on the device without a pty and returns its stdout. Cancelling throws
    /// `CancellationError`: the socket is shut down to stop the read, which otherwise looks
    /// like the command's normal end and would pass for its whole output.
    public func exec(serial: String, _ command: String) async throws -> Data {
        try await cancellableBlocking(endsAtClose: true) { canceller in
            let socket = try openService(serial: serial, "exec:\(command)")
            canceller.attach(socket)
            return Data(try socket.readToEnd())
        }
    }

    /// Emits the full device list now and on every change. Ends with an error when the
    /// server goes away.
    public func trackDevices() -> AsyncThrowingStream<[AdbDeviceInfo], Error> {
        let port = port
        return AsyncThrowingStream { continuation in
            let canceller = SocketCanceller()
            continuation.onTermination = { _ in canceller.cancel() }
            DispatchQueue.global(qos: .utility).async {
                do {
                    let socket = try AdbSocket(port: port, bufferSize: 64 * 1024)
                    canceller.attach(socket)
                    try socket.sendHostRequest("host:track-devices-l")
                    try socket.readStatus()
                    while true {
                        continuation.yield(AdbDeviceInfo.parseList(try socket.readHexLengthString()))
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
