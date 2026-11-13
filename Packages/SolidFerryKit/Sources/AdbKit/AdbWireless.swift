import Foundation
import Network
import os

/// A wireless-debugging endpoint a phone advertises on the local network.
public struct AdbMdnsService: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        /// "Pair device with pairing code / QR code" is open on the phone.
        case pairing
        /// Wireless debugging is on; paired Macs can connect.
        case connect
        case other
    }

    public let instance: String
    public let kind: Kind
    /// "192.168.0.12:37123"
    public let address: String

    public var id: String { "\(instance)|\(address)" }

    /// The phone's serial when the instance name carries it ("adb-R5XX00ABCDE-AbCdEf").
    public var deviceSerial: String? { wirelessSerial(fromInstance: instance) }

    /// Parses `host:mdns:services`: "instance\ttype\taddress" per line.
    static func parse(_ text: String) -> [AdbMdnsService] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 3 else { return nil }
            let kind: Kind = fields[1].hasPrefix("_adb-tls-pairing") ? .pairing
                : fields[1].hasPrefix("_adb-tls-connect") ? .connect : .other
            return AdbMdnsService(instance: fields[0], kind: kind, address: fields[2])
        }
    }
}

/// "adb-R5XX00ABCDE-AbCdEf" or "adb-R5XX00ABCDE-AbCdEf._adb-tls-connect._tcp" → "R5XX00ABCDE".
public func wirelessSerial(fromInstance name: String) -> String? {
    let instance = name.split(separator: ".").first.map(String.init) ?? name
    guard instance.hasPrefix("adb-") else { return nil }
    let rest = instance.dropFirst(4)
    guard let dash = rest.lastIndex(of: "-"), dash != rest.startIndex else { return nil }
    return String(rest[..<dash])
}

/// "Successfully paired to 192.168.0.12:37123 [guid=adb-R5XX00ABCDE-AbCdEf]" → "R5XX00ABCDE".
func pairedSerial(fromReply reply: String) -> String? {
    guard let start = reply.range(of: "[guid=")?.upperBound,
          let end = reply[start...].firstIndex(of: "]") else { return nil }
    return wirelessSerial(fromInstance: String(reply[start..<end]))
}

extension AdbClient {
    public func mdnsServices() async throws -> [AdbMdnsService] {
        AdbMdnsService.parse(try await blocking { try hostQuery("host:mdns:services") })
    }

    /// Pairs with a phone showing a pairing code (or our QR code's password). Returns the
    /// phone's serial when adb's reply names it ("Successfully paired to … [guid=adb-SERIAL-…]").
    @discardableResult
    public func pair(address: String, code: String) async throws -> String? {
        let message: String = try await blocking {
            let socket = try connect()
            try socket.sendHostRequest("host:pair:\(code):\(address)")
            // OKAY for the request, then the sentence that's the only real verdict; a failure
            // puts FAIL before it, a success nothing (QUIRKS A14).
            try socket.readStatus() // request accepted
            let next = try socket.readString(4)
            if next == "FAIL" { throw AdbError.failed(try socket.readHexLengthString()) }
            if next == "OKAY" { return try socket.readHexLengthString() }
            guard let length = Int(next, radix: 16) else {
                throw AdbError.protocolViolation("unexpected reply \(next.debugDescription)")
            }
            return try socket.readString(length)
        }
        guard message.hasPrefix("Successfully") else { throw AdbError.failed(message) }
        return pairedSerial(fromReply: message)
    }

    /// Connects to a paired phone's wireless-debugging address.
    public func connect(address: String) async throws {
        let message = try await blocking { try hostQuery("host:connect:\(address)") }
        // The server answers OKAY either way; only these replies mean connected (adb's
        // `adb connect` reports the same text). Anything else is a failure reason. QUIRKS A14.
        guard message.hasPrefix("connected to") || message.hasPrefix("already connected to") else {
            throw AdbError.failed(message)
        }
    }

    public func disconnect(address: String) async throws {
        _ = try await blocking { try hostQuery("host:disconnect:\(address)") }
    }

    /// Asks the phone (over USB) whether wireless debugging is on and where adbd listens,
    /// without relying on mDNS, which macOS's adb doesn't always see (QUIRKS A15).
    public func wirelessEndpoint(serial: String) async throws -> WirelessEndpoint {
        let output = try await exec(serial: serial,
            "settings get global adb_wifi_enabled; ip -4 addr show wlan0 2>/dev/null; cat /proc/net/tcp6 /proc/net/tcp 2>/dev/null")
        return WirelessEndpoint.parse(String(decoding: output, as: UTF8.self))
    }

    /// The phone's hardware serial, the same one it reports over USB.
    public func hardwareSerial(of serial: String) async throws -> String? {
        let output = try await exec(serial: serial, "getprop ro.serialno")
        let value = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

/// Whether a TCP connection to "host:port" opens within `timeout`. adb's own connect waits out
/// the system's 75 s timeout when nothing answers (a network that keeps devices apart), so this
/// is asked first. QUIRKS A17.
public func tcpReachable(_ address: String, timeout: TimeInterval) async -> Bool {
    guard let colon = address.lastIndex(of: ":"),
          let port = NWEndpoint.Port(String(address[address.index(after: colon)...])) else { return false }
    let connection = NWConnection(host: NWEndpoint.Host(String(address[..<colon])), port: port, using: .tcp)
    return await withCheckedContinuation { continuation in
        let finished = OSAllocatedUnfairLock(initialState: false)
        let finish: @Sendable (Bool) -> Void = { reachable in
            guard finished.withLock({ done in defer { done = true }; return !done }) else { return }
            connection.cancel()
            continuation.resume(returning: reachable)
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: finish(true)
            case .failed, .waiting, .cancelled: finish(false)
            default: break
            }
        }
        connection.start(queue: .global())
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(false) }
    }
}

/// The text Android's "Pair device with QR code" scanner expects; the phone then
/// advertises a pairing service named `name`, and pairs with `password`.
public func wirelessPairingQRText(name: String, password: String) -> String {
    "WIFI:T:ADB;S:\(name);P:\(password);;"
}

public struct WirelessEndpoint: Sendable, Equatable {
    /// Wireless debugging is switched on.
    public var enabled = false
    /// "192.168.0.12:41234" once both the Wi-Fi address and adbd's port are known.
    public var address: String?

    /// Parses `settings get`, `ip addr` and /proc/net/tcp output: adbd runs as the shell
    /// user (uid 2000) and listens on all interfaces.
    static func parse(_ text: String) -> WirelessEndpoint {
        var result = WirelessEndpoint()
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        result.enabled = lines.first == "1"
        var ip: String?
        var ports: [Int] = []
        for line in lines {
            if line.hasPrefix("inet "), let addr = line.split(separator: " ").dropFirst().first?.split(separator: "/").first {
                ip = ip ?? String(addr)
            }
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count > 7, fields[3] == "0A", fields[7] == "2000" else { continue }
            let local = fields[1].split(separator: ":")
            guard local.count == 2, local[0].allSatisfy({ $0 == "0" }), let port = Int(local[1], radix: 16) else { continue }
            ports.append(port)
        }
        // Prefer the wireless-debugging port over a legacy `adb tcpip 5555`.
        if let ip, let port = ports.first(where: { $0 != 5555 }) ?? ports.first {
            result.address = "\(ip):\(port)"
        }
        return result
    }
}
