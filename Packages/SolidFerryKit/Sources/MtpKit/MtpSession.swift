import Darwin
import DeviceCore
import Foundation
import IOKit
import IOUSBHost
import UsbKit

public enum MtpError: Error, CustomStringConvertible, LocalizedError {
    public var errorDescription: String? { description }

    case deviceNotFound
    /// Another process holds the MTP interface.
    case interfaceBusy([UsbInterfaceOwner])
    case usb(String)
    case protocolViolation(String)
    case response(op: UInt16, code: UInt16)
    case cancelled

    public var description: String {
        switch self {
        case .deviceNotFound: "MTP interface not found"
        case .interfaceBusy(let owners): "MTP interface in use by \(owners.map { "\($0.name)(\($0.pid))" }.joined(separator: ", "))"
        case .usb(let message): "USB: \(message)"
        case .protocolViolation(let message): "protocol: \(message)"
        case .response(let op, let code): String(format: "op 0x%04X failed: 0x%04X", op, code)
        case .cancelled: "cancelled"
        }
    }
}

public struct MtpDeviceInfo: Sendable {
    public var manufacturer = ""
    public var model = ""
    public var version = ""
    public var serial = ""
    public var vendorExtension = ""
    public var operations: Set<UInt16> = []
}

public struct MtpObjectInfo: Sendable {
    public var handle: UInt32
    public var storageID: UInt32
    public var format: UInt16
    public var size: UInt64
    public var parent: UInt32
    public var name: String
    public var modified: Date?
    public var isFolder: Bool { format == ptpFormatAssociation }
}

/// One MTP session over the device's MTP USB interface. Blocking; one transaction at a
/// time (MTP allows nothing else); MtpWorker runs everything on one thread.
public final class MtpSession {
    private let interface: IOUSBHostInterface
    private let bulkIn: IOUSBHostPipe
    private let bulkOut: IOUSBHostPipe
    /// The phone's event pipe, kept read so its events never wait on us (QUIRKS M17).
    private let events: EventDrain?
    private let maxPacket: Int
    private var transaction: UInt32 = 0
    private let readBuffer: NSMutableData
    private let interfaceNumber: UInt16
    private let lock = NSLock()
    private var cancelRequested = false
    private var abandoned = false

    /// Opens the MTP interface of the USB device with this serial. If macOS's ptpcamerad
    /// holds it, it's killed and the interface taken before its relaunch does (QUIRKS H2).
    public init(serial: String) throws {
        guard let device = UsbProbe.androidDevices().first(where: { $0.serial == serial }),
              let interfaceID = device.mtpInterfaceID else { throw MtpError.deviceNotFound }

        var opened: IOUSBHostInterface?
        var evicted = false
        let deadline = Date().addingTimeInterval(3)
        var lastError = ""
        repeat {
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(interfaceID))
            guard service != 0 else { throw MtpError.deviceNotFound }
            do {
                opened = try IOUSBHostInterface(__ioService: service, options: [.deviceSeize], queue: nil, interestHandler: nil)
            } catch {
                IOObjectRelease(service) // looked up again on the next try
                lastError = "\(error)"
                let owners = UsbProbe.androidDevices().first { $0.serial == serial }?.mtpOwners ?? []
                guard !owners.isEmpty, owners.allSatisfy(\.isPhotoService) else {
                    throw owners.isEmpty ? MtpError.usb(lastError) : MtpError.interfaceBusy(owners)
                }
                // ptpcamerad ignores SIGTERM. After SIGKILL launchd relaunches it and it
                // grabs the phone again within ~0.75 s (measured), so retry fast and take the
                // interface in that gap; once we hold it, the new instance can't. QUIRKS H2.
                owners.forEach { kill($0.pid, SIGKILL) }
                evicted = true
                usleep(20_000)
            }
        } while opened == nil && Date() < deadline
        guard let interface = opened else { throw MtpError.usb("open failed: \(lastError)") }
        self.interface = interface

        // Find bulk IN / bulk OUT endpoints.
        var inAddress: Int?
        var outAddress: Int?
        var eventAddress: Int?
        var packet = 512
        let config = interface.configurationDescriptor
        let ifaceDesc = interface.interfaceDescriptor
        var current = UnsafeRawPointer(ifaceDesc).assumingMemoryBound(to: IOUSBDescriptorHeader.self)
        while let endpoint = IOUSBGetNextEndpointDescriptor(config, ifaceDesc, current) {
            let address = Int(IOUSBGetEndpointAddress(endpoint))
            if IOUSBGetEndpointType(endpoint) == UInt8(kIOUSBEndpointTypeBulk.rawValue) {
                if address & 0x80 != 0 { inAddress = address } else { outAddress = address }
                packet = Int(endpoint.pointee.wMaxPacketSize)
            } else if IOUSBGetEndpointType(endpoint) == UInt8(kIOUSBEndpointTypeInterrupt.rawValue), address & 0x80 != 0 {
                eventAddress = address
            }
            current = UnsafeRawPointer(endpoint).assumingMemoryBound(to: IOUSBDescriptorHeader.self)
        }
        guard let inAddress, let outAddress else { throw MtpError.usb("bulk endpoints not found") }
        bulkIn = try interface.copyPipe(withAddress: inAddress)
        bulkOut = try interface.copyPipe(withAddress: outAddress)
        events = eventAddress.flatMap { try? interface.copyPipe(withAddress: $0) }.map(EventDrain.init)
        maxPacket = packet
        interfaceNumber = UInt16(interface.interfaceDescriptor.pointee.bInterfaceNumber)
        readBuffer = NSMutableData(length: 2 << 20)!
        // ptpcamerad killed mid-transfer leaves the phone pushing the rest of its reply, and
        // the phone won't read our commands until that's taken. Drain until the line is quiet.
        // Never a class Device Reset: on Samsung it hangs in 2 of 3 attempts (QUIRKS M7).
        drainStaleData(quietFor: evicted ? 0.5 : 0.1, upTo: evicted ? 15 : 1)
        wasEvicted = evicted
        events?.read()
    }

    deinit {
        try? events?.pipe.__abort(with: .asynchronous)
        interface.destroy()
    }

    /// Keeps a read pending on the event pipe and discards what arrives. Android's MTP server
    /// sends an event after every change (object added, removed…) and, on some phones, waits
    /// up to a second for the host to take it before answering the next command (QUIRKS M17).
    /// We don't use the events: listings are always fetched fresh. Only the pipe's completions
    /// touch it after the first read, one read at a time.
    private final class EventDrain: @unchecked Sendable {
        let pipe: IOUSBHostPipe
        private let buffer = NSMutableData(length: 64)!

        init(pipe: IOUSBHostPipe) { self.pipe = pipe }

        func read() {
            do {
                try pipe.enqueueIORequest(with: buffer, completionTimeout: 0) { [weak self] status, _ in
                    // Aborted (session closing) or the phone went away: stop.
                    guard status == kIOReturnSuccess else { return }
                    self?.read()
                }
            } catch {
                mtpLog.notice("event pipe not readable: \(error)")
            }
        }
    }

    /// Whether ptpcamerad had to be cleared to open this session.
    public private(set) var wasEvicted = false

    /// A previous client that quit mid-transaction can leave its reply in the pipe; the next
    /// session would read it as its own. Discard whatever is waiting before starting (QUIRKS M7:
    /// a Device Reset would be the textbook fix, but it stalls Samsung phones).
    private func drainStaleData(quietFor quiet: TimeInterval = 0.1, upTo limit: TimeInterval = 1) {
        let deadline = Date().addingTimeInterval(limit)
        while Date() < deadline, !lock.withLock({ abandoned }) {
            var received = 0
            do {
                try bulkIn.__sendIORequest(with: readBuffer, bytesTransferred: &received, completionTimeout: quiet)
            } catch {
                return // quiet for `quiet` seconds
            }
        }
    }

    /// OpenSession, retried while the phone is still busy finishing someone else's request
    /// (after ptpcamerad is killed the phone keeps working on its last command, e.g. listing
    /// every photo, and ignores ours until done). Keeps the interface the whole time: letting
    /// go hands the phone back to ptpcamerad, which starts over.
    public func openSessionRecovering(patience: TimeInterval, onBusy: () -> Void) throws {
        let deadline = Date().addingTimeInterval(patience)
        var reported = false
        while true {
            do {
                try openSession()
                return
            } catch {
                if lock.withLock({ abandoned }) { throw CancellationError() }
                guard IOReturnCode.of(error) == IOReturnCode.timeout, Date() < deadline else { throw error }
                if !reported {
                    reported = true
                    onBusy()
                }
                try? bulkOut.clearStall()
                drainStaleData(quietFor: 1, upTo: max(1, deadline.timeIntervalSinceNow))
            }
        }
    }

    // MARK: Transactions

    /// Sends a command, reads the optional data phase and the response.
    /// Returns (data payload, response params). With `dataSink`, the data phase is streamed
    /// to it instead of collected (for file contents).
    @discardableResult
    public func transact(_ op: UInt16, _ params: [UInt32] = [], timeout: TimeInterval = MtpTuning.commandTimeout,
                         dataSink: ((UnsafeRawBufferPointer) throws -> Void)? = nil) throws -> ([UInt8], [UInt32]) {
        do {
            return try transactOnce(op, params, timeout: timeout, dataSink: dataSink)
        } catch MtpError.response(let failedOp, PTPResponse.sessionNotOpen) where failedOp != PTPOp.openSession.rawValue {
            // The phone dropped our session (seen on a Galaxy right after taking it over from
            // macOS's photo service, QUIRKS G4). Open it again and retry once; nothing was transferred.
            mtpLog.notice("session was closed by the phone; reopening")
            try openSession()
            return try transactOnce(op, params, timeout: timeout, dataSink: dataSink)
        }
    }

    private func transactOnce(_ op: UInt16, _ params: [UInt32], timeout: TimeInterval,
                              dataSink: ((UnsafeRawBufferPointer) throws -> Void)?) throws -> ([UInt8], [UInt32]) {
        let tx = op == PTPOp.openSession.rawValue ? 0 : nextTransaction()
        try write(ptpCommand(op, transaction: tx, params: params))

        // If writing what arrives fails (the Mac's disk is full), the phone still sends the rest
        // of the data and its response: read them out first, or the next command would read
        // file bytes as its answer. The failure is thrown after.
        var sinkFailure: Error?
        let guardedSink = dataSink.map { sink in
            { (bytes: UnsafeRawBufferPointer) throws in
                guard sinkFailure == nil else { return }
                do { try sink(bytes) } catch { sinkFailure = error }
            }
        }
        var payload: [UInt8] = []
        while true {
            let container = try readContainer(timeout: timeout, expecting: tx, dataSink: guardedSink)
            // Events can arrive on this pipe; containers of an earlier transaction are strays.
            if container.type == PTPContainerType.event.rawValue || container.transaction != tx { continue }
            switch container.type {
            case PTPContainerType.data.rawValue:
                payload = container.body
            case PTPContainerType.response.rawValue:
                let params = try checked(container, op: op)
                if let sinkFailure { throw sinkFailure }
                return (payload, params)
            default:
                throw MtpError.protocolViolation("unexpected container type \(container.type)")
            }
        }
    }

    /// Reads up to this transaction's response (after a data-out phase, none comes in).
    private func readResponse(op: UInt16, transaction tx: UInt32, timeout: TimeInterval) throws -> [UInt32] {
        while true {
            let container = try readContainer(timeout: timeout, expecting: tx, dataSink: nil)
            if container.type == PTPContainerType.event.rawValue || container.transaction != tx { continue }
            guard container.type == PTPContainerType.response.rawValue else {
                throw MtpError.protocolViolation("expected response, got \(container.type)")
            }
            return try checked(container, op: op)
        }
    }

    /// A response's parameters, or its failure.
    private func checked(_ response: PTPContainer, op: UInt16) throws -> [UInt32] {
        guard response.code == PTPResponse.ok
            || (op == PTPOp.openSession.rawValue && response.code == PTPResponse.sessionAlreadyOpen) else {
            throw MtpError.response(op: op, code: response.code)
        }
        return response.params
    }

    private func nextTransaction() -> UInt32 {
        lock.withLock {
            transaction += 1
            cancelRequested = false
            return transaction
        }
    }

    // MARK: Cancel (PTP USB still-image class "Cancel Request")

    /// Gives up on this session from another thread: what's waiting on the phone returns at
    /// once with an error, recovery stops retrying, and no further request is sent. For a connection attempt that's no
    /// longer wanted (the session is closed after); no PTP cancel request is sent (QUIRKS M8).
    public func abandon() {
        lock.withLock { abandoned = true }
        try? bulkIn.__abort(with: .asynchronous)
        try? bulkOut.__abort(with: .asynchronous)
    }

    /// Cancels the transaction in flight from another thread (PTP "Cancel Request"); the
    /// blocked call throws `MtpError.cancelled`. Experiments only (`sferry mtp-cancel-test`): on
    /// Samsung it can leave the MTP server unresponsive (QUIRKS M8), so the app never cancels a
    /// transaction midway and splits transfers into chunks instead.
    public func cancelCurrentTransaction() {
        let tx = lock.withLock {
            cancelRequested = true
            return transaction
        }
        var payload: [UInt8] = [0x01, 0x40] // CancellationCode 0x4001
        withUnsafeBytes(of: tx.littleEndian) { payload.append(contentsOf: $0) }
        let data = NSMutableData(bytes: payload, length: payload.count)
        let request = IOUSBDeviceRequest(bmRequestType: 0x21, bRequest: 0x64, wValue: 0, wIndex: interfaceNumber, wLength: 6)
        var sent = 0
        try? interface.__send(request, data: data, bytesTransferred: &sent, completionTimeout: 2)
        try? bulkIn.__abort(with: .asynchronous)
    }

    private var isCancelRequested: Bool { lock.withLock { cancelRequested } }

    /// After a cancel: wait for the device to report OK, clear stalls, discard leftovers.
    private func recoverFromCancel() {
        let deadline = Date().addingTimeInterval(3)
        let request = IOUSBDeviceRequest(bmRequestType: 0xA1, bRequest: 0x67, wValue: 0, wIndex: interfaceNumber, wLength: 20)
        while Date() < deadline {
            let status = NSMutableData(length: 20)!
            var received = 0
            if (try? interface.__send(request, data: status, bytesTransferred: &received, completionTimeout: 1)) != nil, received >= 4 {
                let code = status.bytes.load(fromByteOffset: 2, as: UInt16.self).littleEndian
                if code == PTPResponse.ok { break }
            }
            usleep(20_000)
        }
        // Drop anything the device had already queued for the cancelled transaction. Only
        // clear a stall if the pipe actually stalled: clearing a healthy endpoint resets its
        // data toggle, and some device controllers don't follow, breaking the next transfer.
        while true {
            readBuffer.length = readBuffer.length
            var received = 0
            do {
                try bulkIn.__sendIORequest(with: readBuffer, bytesTransferred: &received, completionTimeout: 0.2)
            } catch {
                if Self.isStall(error) {
                    try? bulkIn.clearStall()
                    continue
                }
                break
            }
        }
        lock.withLock { cancelRequested = false }
    }

    private func write(_ bytes: [UInt8]) throws {
        // Given up on: no new request goes out (abandon() only stops the ones in flight).
        if lock.withLock({ abandoned }) { throw CancellationError() }
        let data = NSMutableData(bytes: bytes, length: bytes.count)
        var sent = 0
        do {
            try bulkOut.__sendIORequest(with: data, bytesTransferred: &sent, completionTimeout: MtpTuning.writeTimeout)
        } catch {
            // Retry once, but only if nothing went out: resending a partly sent command would
            // hand the phone a corrupt one. A halted endpoint (left over from an interrupted
            // transaction, QUIRKS M8) refuses IO until cleared; clear only that one, since
            // clearing a healthy endpoint resets its data toggle and some controllers don't follow.
            mtpLog.notice("command write failed (\(String(describing: error), privacy: .public)), \(sent, privacy: .public) bytes out")
            guard sent == 0 else { throw error }
            if Self.isStall(error) { try? bulkOut.clearStall() }
            try bulkOut.__sendIORequest(with: data, bytesTransferred: &sent, completionTimeout: MtpTuning.writeTimeout)
        }
    }

    static func isStall(_ error: Error) -> Bool {
        IOReturnCode.of(error) == IOReturnCode.pipeStalled
    }

    /// Reads one container (header + body), spanning as many bulk transfers as needed. A
    /// data container's body goes to `dataSink` when given (and isn't returned).
    private func readContainer(timeout: TimeInterval, expecting expectedTx: UInt32,
                               dataSink: ((UnsafeRawBufferPointer) throws -> Void)?) throws -> PTPContainer {
        var bytes: [UInt8] = []
        var header: (type: UInt16, code: UInt16, length: Int, tx: UInt32)?
        var consumed = 0 // bytes of this container seen so far
        while true {
            readBuffer.length = readBuffer.length
            var received = 0
            do {
                try bulkIn.__sendIORequest(with: readBuffer, bytesTransferred: &received, completionTimeout: timeout)
            } catch {
                if isCancelRequested {
                    recoverFromCancel()
                    throw MtpError.cancelled
                }
                throw error
            }
            if isCancelRequested {
                recoverFromCancel()
                throw MtpError.cancelled
            }
            if received == 0 { continue } // zero-length packet ending a previous transfer
            var chunk = UnsafeRawBufferPointer(start: readBuffer.bytes, count: received)
            if header == nil {
                guard received >= 12 else { throw MtpError.protocolViolation("short header") }
                let length = Int(chunk.load(fromByteOffset: 0, as: UInt32.self).littleEndian)
                // A container can't be shorter than its own header; don't trust the phone on it.
                guard length >= 12 else { throw MtpError.protocolViolation("container length \(length)") }
                let type = chunk.load(fromByteOffset: 4, as: UInt16.self).littleEndian
                let code = chunk.load(fromByteOffset: 6, as: UInt16.self).littleEndian
                let tx = chunk.load(fromByteOffset: 8, as: UInt32.self).littleEndian
                header = (type, code, length, tx)
                consumed = 12
                chunk = UnsafeRawBufferPointer(rebasing: chunk[12...])
            }
            let (type, code, length, tx) = header!
            let body = UnsafeRawBufferPointer(rebasing: chunk[..<min(chunk.count, length - consumed)])
            if type == PTPContainerType.data.rawValue, let dataSink {
                // A stray data phase from another transaction is skipped, not written out.
                if tx == expectedTx { try dataSink(body) }
            } else {
                bytes.append(contentsOf: body)
            }
            consumed += body.count
            if chunk.count > body.count {
                // The phone ran the next container into this transfer (no zero-length packet
                // after a full one). Not seen so far; the bytes are lost, so say so.
                mtpLog.error("dropped \(chunk.count - body.count, privacy: .public) bytes after a container")
            }
            if consumed >= length { return PTPContainer(type: type, code: code, transaction: tx, body: bytes) }
        }
    }

    /// Streams `length` bytes of an object from `offset` to `sink`, in chunks small enough to
    /// interleave other requests between them.
    ///
    /// Samsung's stack hangs when the reply that ends a file has a last USB packet that's
    /// exactly full (libmtp `SAMSUNG_OFFSET_BUG`, QUIRKS M10); that tail is split so it never lines up.
    public func readObject(_ handle: UInt32, size: UInt64, from start: UInt64 = 0, chunk: UInt64 = MtpTuning.readChunk,
                           sink: (UnsafeRawBufferPointer) throws -> Void) throws {
        var offset = start
        while offset < size {
            offset += try readChunk(handle, size: size, offset: offset, maxLength: chunk, sink: sink)
        }
    }

    /// One GetPartialObject64 request; returns the bytes delivered. Callers loop, which lets
    /// a scheduler slip other requests in between chunks.
    public func readChunk(_ handle: UInt32, size: UInt64, offset: UInt64, maxLength: UInt64,
                          sink: (UnsafeRawBufferPointer) throws -> Void) throws -> UInt64 {
        let length = MtpPackets.readLength(size: size, offset: offset, maxLength: maxLength, maxPacket: maxPacket)
        var received: UInt64 = 0
        let (_, response) = try withoutActuallyEscaping(sink) { sink in
            try transact(
                PTPOp.getPartialObject64.rawValue,
                [handle, UInt32(truncatingIfNeeded: offset), UInt32(truncatingIfNeeded: offset >> 32), UInt32(length)],
                timeout: MtpTuning.transferTimeout,
                dataSink: { bytes in
                    received += UInt64(bytes.count)
                    try sink(bytes)
                }
            )
        }
        // What arrived decides the next offset; a phone reporting a different count would
        // otherwise shift the rest of the file.
        if let reported = response.first, UInt64(reported) != received {
            throw MtpError.protocolViolation("partial read at \(offset): \(received) bytes, phone reported \(reported)")
        }
        guard received > 0 else { throw MtpError.protocolViolation("empty partial read at \(offset)") }
        return received
    }

    /// Sends a command followed by a data-out phase, then reads the response.
    @discardableResult
    public func transact(_ op: UInt16, _ params: [UInt32], dataOut: [UInt8], timeout: TimeInterval = MtpTuning.commandTimeout) throws -> [UInt32] {
        let tx = nextTransaction()
        try write(ptpCommand(op, transaction: tx, params: params))
        let container = ptpHeader(.data, code: op, transaction: tx, bodyLength: UInt64(dataOut.count)) + dataOut
        try write(container)
        if container.count % maxPacket == 0 { try write([]) } // terminate with a zero-length packet
        return try readResponse(op: op, transaction: tx, timeout: timeout)
    }

    // MARK: Operations

    public func openSession() throws {
        try transact(PTPOp.openSession.rawValue, [1])
    }

    public func closeSession() {
        _ = try? transact(PTPOp.closeSession.rawValue)
    }

    public func deviceInfo() throws -> MtpDeviceInfo {
        try MtpDeviceInfo(dataset: transact(PTPOp.getDeviceInfo.rawValue).0)
    }

    public struct StorageInfo: Sendable {
        public var id: UInt32
        public var description: String
        public var volumeIdentifier: String
        public var capacity: UInt64
        public var free: UInt64
    }

    public func storageInfo(_ id: UInt32) throws -> StorageInfo {
        try StorageInfo(dataset: transact(PTPOp.getStorageInfo.rawValue, [id]).0, id: id)
    }

    /// Announces a file; returns its new handle. Follow with `sendObject`.
    public func sendObjectInfo(name: String, size: UInt64, storage: UInt32, parent: UInt32, modified: Date?) throws -> UInt32 {
        let data = try objectInfoDataset(name: name, folder: false, size: size, storage: storage, parent: parent,
                                         date: modified.map(Self.ptpDate) ?? "")
        let response = try transact(PTPOp.sendObjectInfo.rawValue, [storage, parent], dataOut: data)
        guard response.count >= 3 else { throw MtpError.protocolViolation("SendObjectInfo response") }
        return response[2]
    }

    /// Streams a file as the SendObject data phase (one transaction for the whole file).
    public func sendObject(from fd: Int32, size: UInt64, progress: (Int) -> Void) throws {
        let tx = nextTransaction()
        try write(ptpCommand(PTPOp.sendObject.rawValue, transaction: tx, params: []))
        let header = ptpHeader(.data, code: PTPOp.sendObject.rawValue, transaction: tx, bodyLength: size)
        let length = 12 + size
        // A bulk transfer shorter than a multiple of the packet size ends the data phase on
        // the phone's side (it stored 1 MB of a 30 MB file and stopped listening). So every
        // transfer but the last is a whole number of packets: the first carries the 12-byte
        // header plus `chunk - 12` bytes, the rest exactly `chunk`. QUIRKS M9.
        let chunk = MtpTuning.sendChunk // a multiple of 512 and 1024
        let buffer = NSMutableData(length: chunk)!
        buffer.replaceBytes(in: NSRange(location: 0, length: 12), withBytes: header)
        var offset = 12
        var sent: UInt64 = 0
        var finished = false
        // Reading the Mac's file failed: the rest goes as zeros so the data phase still ends
        // where the header said (a phone left waiting for bytes takes the next commands as file
        // data, QUIRKS M11), and the failure is thrown once the phone has answered.
        var readFailure: Error?
        while !finished {
            // Fill the buffer completely unless the file ends. Read exactly `size` bytes, as the
            // header promised: a file that grows while it's sent must not overrun the data
            // phase, and one that shrinks fails instead of leaving the phone waiting.
            let headerBytes = sent == 0 ? 12 : 0
            while offset < chunk {
                let buffered = UInt64(offset - headerBytes)
                let wanted = min(chunk - offset, Int(clamping: size - sent - buffered))
                if wanted == 0 { finished = true; break }
                if readFailure != nil {
                    memset(buffer.mutableBytes + offset, 0, wanted)
                    offset += wanted
                    continue
                }
                let n = Darwin.read(fd, buffer.mutableBytes + offset, wanted)
                if n < 0 {
                    if errno == EINTR { continue }
                    readFailure = DeviceFSError.localRead(errnoDescription())
                    continue
                }
                if n == 0 {
                    readFailure = DeviceFSError.localRead("the file got shorter while it was sent")
                    continue
                }
                offset += n
            }
            let payload = offset - headerBytes
            buffer.length = offset
            var written = 0
            try bulkOut.__sendIORequest(with: buffer, bytesTransferred: &written, completionTimeout: MtpTuning.sendChunkTimeout)
            buffer.length = chunk
            sent += UInt64(payload)
            if payload > 0 { progress(payload) }
            offset = 0
            if sent >= size { finished = true }
        }
        if length % UInt64(maxPacket) == 0 { try write([]) } // zero-length packet ends the phase
        _ = try readResponse(op: PTPOp.sendObject.rawValue, transaction: tx, timeout: MtpTuning.transferTimeout)
        if let readFailure { throw readFailure }
    }

    static func ptpDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        return formatter.string(from: date)
    }

    /// Creates a folder; returns its handle.
    public func createFolder(named name: String, storage: UInt32, parent: UInt32) throws -> UInt32 {
        let data = try objectInfoDataset(name: name, folder: true, size: 0, storage: storage, parent: parent, date: "")
        let response = try transact(PTPOp.sendObjectInfo.rawValue, [storage, parent], dataOut: data)
        guard response.count >= 3 else { throw MtpError.protocolViolation("SendObjectInfo response") }
        return response[2]
    }

    /// 64-bit size of one object (ObjectInfo's size field is 32-bit).
    public func objectSize64(_ handle: UInt32) throws -> UInt64 {
        var r = PTPReader(try transact(PTPOp.getObjectPropValue.rawValue, [handle, UInt32(MTPProp.objectSize)]).0)
        return try r.u64()
    }

    public func rename(_ handle: UInt32, to name: String) throws {
        try transact(PTPOp.setObjectPropValue.rawValue, [handle, UInt32(MTPProp.objectFileName)], dataOut: try ptpString(name))
    }

    /// Sets an object's modification date (some phones ignore the date sent with the file).
    public func setModified(_ handle: UInt32, to date: Date) throws {
        try transact(PTPOp.setObjectPropValue.rawValue, [handle, UInt32(MTPProp.dateModified)],
                     dataOut: try ptpString(Self.ptpDate(date)))
    }

    /// Moves an object (folders with their contents) under `parent` on `storage`.
    public func move(_ handle: UInt32, storage: UInt32, parent: UInt32) throws {
        try transact(PTPOp.moveObject.rawValue, [handle, storage, parent])
    }

    /// Copies an object (folders with their contents); returns the copy's handle.
    public func copy(_ handle: UInt32, storage: UInt32, parent: UInt32) throws -> UInt32 {
        let (_, response) = try transact(PTPOp.copyObject.rawValue, [handle, storage, parent], timeout: MtpTuning.copyTimeout)
        guard let copied = response.first else { throw MtpError.protocolViolation("CopyObject response") }
        return copied
    }

    /// Deletes an object; Android removes folders with their contents.
    public func delete(_ handle: UInt32) throws {
        try transact(PTPOp.deleteObject.rawValue, [handle, 0])
    }

    public func storageIDs() throws -> [UInt32] {
        var r = PTPReader(try transact(PTPOp.getStorageIDs.rawValue).0)
        return try r.u32Array()
    }

    /// Children of `parent` (0xFFFFFFFF = storage root).
    public func objectHandles(storage: UInt32, parent: UInt32) throws -> [UInt32] {
        var r = PTPReader(try transact(PTPOp.getObjectHandles.rawValue, [storage, 0, parent]).0)
        return try r.u32Array()
    }

    /// The object's thumbnail as the phone stores or makes it (JPEG).
    public func thumbnail(_ handle: UInt32) throws -> [UInt8] {
        try transact(PTPOp.getThumb.rawValue, [handle]).0
    }

    public func objectInfo(_ handle: UInt32) throws -> MtpObjectInfo {
        try MtpObjectInfo(dataset: transact(PTPOp.getObjectInfo.rawValue, [handle]).0, handle: handle)
    }

    /// The properties a listing needs.
    public static let listingProperties: [UInt16] = [
        MTPProp.objectFileName, MTPProp.objectFormat, MTPProp.objectSize, MTPProp.dateModified,
    ]

    /// Every property of every child of `parent` in one request (depth 1).
    public func objectPropList(children parent: UInt32) throws -> [MtpObjectInfo] {
        try objectPropList(children: parent, property: 0xFFFF_FFFF)
    }

    /// One request per property (each covering all children), merged. Works around stacks
    /// that reject "all properties" (0xFFFFFFFF) for some folders.
    public func objectPropListByProperty(children parent: UInt32,
                                         properties: [UInt16] = MtpSession.listingProperties) throws -> [MtpObjectInfo] {
        var merged: [UInt32: MtpObjectInfo] = [:]
        var order: [UInt32] = []
        for property in properties {
            for item in try objectPropList(children: parent, property: UInt32(property)) {
                if merged[item.handle] == nil {
                    merged[item.handle] = item
                    order.append(item.handle)
                } else {
                    switch property {
                    case MTPProp.objectFileName: merged[item.handle]?.name = item.name
                    case MTPProp.objectFormat: merged[item.handle]?.format = item.format
                    case MTPProp.objectSize: merged[item.handle]?.size = item.size
                    case MTPProp.dateModified: merged[item.handle]?.modified = item.modified
                    default: break
                    }
                }
            }
        }
        return order.compactMap { merged[$0] }
    }

    /// Raw GetObjectPropList for experiments: returns the number of (handle, property) pairs.
    public func rawPropList(_ handle: UInt32, format: UInt32, property: UInt32, group: UInt32, depth: UInt32) throws -> Int {
        let (data, _) = try transact(PTPOp.getObjectPropList.rawValue, [handle, format, property, group, depth], timeout: 60)
        var r = PTPReader(data)
        return Int(try r.u32())
    }

    /// GetObjectPropList for one property (or 0xFFFFFFFF) over the children of `parent`.
    public func objectPropList(children parent: UInt32, property: UInt32) throws -> [MtpObjectInfo] {
        let (data, _) = try transact(PTPOp.getObjectPropList.rawValue, [parent, 0, property, 0, 1], timeout: MtpTuning.listingTimeout)
        return try MtpObjectInfo.list(propListDataset: data, parent: parent)
    }
}
