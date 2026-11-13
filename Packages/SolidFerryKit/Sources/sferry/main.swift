import os
import AdbKit
import DeviceCore
import CryptoKit
import Foundation
import ImageIO
import IOKit
import IOUSBHost
import MtpKit
import TransferKit
import UsbKit

// sferry: developer tool for exercising the backends against real phones, measuring, and running
// the device test suite. Not part of the app. Commands marked [writes] change files on the
// phone; [risky] ones can leave a phone's MTP server stuck (see QUIRKS M8).

func fail(_ message: String) -> Never {
    note(message)
    exit(1)
}

/// A summary or progress line on stderr (stdout stays the command's output).
func note(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func usage() -> Never {
    fail("""
    usage: sferry [-s SERIAL] COMMAND …

    Devices
      devices                              adb devices with properties
      usb                                  Android USB interfaces and who holds MTP
      mdns | pair ADDR CODE | connect ADDR wireless debugging
      usb-reset [seize]                    experiment: host-side USB reset (macOS refuses it)

    Device tests (docs/DEVICE_TESTS.md; only touch their own folder)
      devtest adb|mtp [quick]
      devtest-pair SERIAL_A:adb|mtp SERIAL_B:adb|mtp [quick]
      copy-bench SERIAL_A:adb|mtp SERIAL_B:adb|mtp MB   [writes] device-to-device copy: straight across vs
                                           through a file on this Mac (A and B may be one device's two connections)

    ADB
      ls [PATH] | md5 REMOTE… | plan REMOTE… LOCAL_DIR POLICY
      pull REMOTE [LOCAL_DIR] | sync REMOTE… LOCAL_DIR POLICY
      push LOCAL REMOTE                    [writes]
      mkdir PATH | mv PATH NAME | rm PATH… [writes]
      renumber DIR START                   [writes] batch rename every file to its number
      bench-pull DIR COUNT PARALLEL LOCAL | bench-many DIR COUNT BATCH PARALLEL LOCAL [MISSING_AT]

    MTP (needs the phone in File transfer; the app must not be using it)
      mtp-info | mtp-ls PATH [LIMIT] | mtp-proplist PATH | mtp-read PATH | mtp-roothandles
      mtp-reuse-name FOLDER                        experiment: delete a file, send one of the same name
      mtp-sendtest | mtp-datetest          [writes] timing and date checks in /Download
      mtp-cancel-test                      [risky]
      mtpfs ls|stat|get|plan|complete PATH …
      mtpfs mkdir|mv|rm|put|cp|move|renumber|time-ops|cp-then-move PATH …   [writes]
      mtpfs race PATH

      upload-bench adb|mtp [COUNT] [KB]    [writes] temporary name vs straight, own folder

    Other
      make-zip OUT.zip FOLDER              zip a folder the way the app does

    Environment
      DRX_TAR=1                            bench-many: bundle with tar
      MTP_CHUNK_MB=N                       mtp-read: chunk size (default 8)
    """)
}

func elapsedMs(since start: ContinuousClock.Instant) -> String {
    let d = ContinuousClock.now - start
    return String(format: "%.1fms", d / .milliseconds(1))
}

var args = Array(CommandLine.arguments.dropFirst())
let serialOption: String? = {
    guard let i = args.firstIndex(of: "-s"), i + 1 < args.count else { return nil }
    defer { args.removeSubrange(i...i + 1) }
    return args[i + 1]
}()
guard let command = args.first else { usage() }
let operands = Array(args.dropFirst())

/// The `index`th operand, or the usage text when there are fewer.
func operand(_ index: Int) -> String {
    guard index < operands.count else { usage() }
    return operands[index]
}

/// Whether the command talks to the adb server (which is then started if needed). MTP, USB
/// and zip commands work on a Mac without adb.
func needsAdb(_ command: String) -> Bool {
    switch command {
    case "make-zip", "usb", "usb-reset", "mtpfs": false
    case "devtest", "devtest-upload", "upload-bench", "thumb": operands.first == "adb"
    case "devtest-pair", "copy-bench": operands.prefix(2).contains { $0.hasSuffix(":adb") }
    default: !command.hasPrefix("mtp-")
    }
}

let client = AdbClient()

extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var result: [T] = []
        for element in self { result.append(try await transform(element)) }
        return result
    }
}

@MainActor func pickSerial() async throws -> String {
    if let serialOption { return serialOption }
    let ready = try await client.devices().filter { $0.state == .device }
    guard ready.count == 1 else {
        fail(ready.isEmpty ? "no ready device" : "multiple devices; pick one with -s")
    }
    return ready[0].serial
}

do {
    if needsAdb(command) { try await AdbServer.ensureRunning(client: client) }

    switch command {
    case "devices":
        for device in try await client.devices() {
            let props = device.properties.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            print(device.serial, device.state, props)
        }

    case "usb":
        for d in UsbProbe.androidDevices() {
            let owners = d.mtpOwners.map { "\($0.name)(\($0.pid))" }.joined(separator: ", ")
            print(String(format: "%04x:%04x", d.vendorID, d.productID), d.productName, d.serial ?? "-",
                  "MTP=\(d.hasMTP)", "ADB=\(d.hasADB)", owners.isEmpty ? "" : "MTP owners: \(owners)")
        }

    case "ls":
        let fs = try await AdbFileSystem.connect(client: client, serial: try await pickSerial())
        let path = operands.first ?? "/sdcard"
        let start = ContinuousClock.now
        var count = 0
        var firstBatch: String?
        for try await batch in fs.list(RemoteRef(path: path)) {
            if firstBatch == nil { firstBatch = elapsedMs(since: start) }
            count += batch.count
            for entry in batch {
                let marker = entry.isDirectory ? "d" : entry.kind == .symlink ? "l" : "-"
                let size = entry.size.map(String.init) ?? "-"
                print(marker, size.padding(toLength: 12, withPad: " ", startingAt: 0), entry.name)
            }
        }
        let v2 = fs.features.contains(AdbFeature.lsV2) ? "LIS2" : "LIST"
        note("\(count) entries via \(v2) · first batch \(firstBatch ?? "-") · total \(elapsedMs(since: start))")

    case "plan":
        let fs = try await AdbFileSystem.connect(client: client, serial: try await pickSerial())
        let start = ContinuousClock.now
        let sources = try await operands.asyncMap { try await fs.entry(at: RemoteRef(path: $0)) }
        let plan = try await TransferPlanner.expand(sources, in: fs)
        print("\(plan.files.count) files, \(plan.directories.count) dirs, \(plan.totalBytes) bytes in \(elapsedMs(since: start))")

    case "bench-pull":
        // sferry bench-pull DIR COUNT PARALLEL LOCAL_DIR  — first COUNT files of DIR
        guard operands.count == 4, let count = Int(operand(1)), let parallel = Int(operand(2)) else { usage() }
        let fs = try await AdbFileSystem.connect(client: client, serial: try await pickSerial())
        var files: [RemoteEntry] = []
        for try await batch in fs.list(RemoteRef(path: operand(0))) { files += batch.filter { $0.kind == .file } }
        files = Array(files.sorted { $0.name < $1.name }.prefix(count))
        let local = URL(fileURLWithPath: operand(3))
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let start = ContinuousClock.now
        try await withThrowingTaskGroup(of: Void.self) { group in
            var it = files.makeIterator()
            for _ in 0..<parallel { if let f = it.next() { group.addTask { try await fs.download(f, to: local.appendingPathComponent(f.name)) { _ in } } } }
            while try await group.next() != nil {
                if let f = it.next() { group.addTask { try await fs.download(f, to: local.appendingPathComponent(f.name)) { _ in } } }
            }
        }
        let d = ContinuousClock.now - start
        let secs = d / .seconds(1)
        let mb = Double(files.reduce(0) { $0 + ($1.size ?? 0) }) / 1e6
        print(String(format: "%d files, %.1f MB, parallel %d: %.2fs · %.1f MB/s · %.1f files/s", files.count, mb, parallel, secs, mb / secs, Double(files.count) / secs))

    case "bench-many":
        // sferry bench-many DIR COUNT BATCH PARALLEL LOCAL_DIR [MISSING_AT] — pipelined batches;
        // MISSING_AT puts a nonexistent file at that index to exercise resuming.
        guard operands.count >= 5, let count = Int(operand(1)), let batchSize = Int(operand(2)),
              let parallel = Int(operand(3)) else { usage() }
        let fs = try await AdbFileSystem.connect(client: client, serial: try await pickSerial())
        var files: [RemoteEntry] = []
        for try await batch in fs.list(RemoteRef(path: operand(0))) { files += batch.filter { $0.kind == .file } }
        files = Array(files.sorted { $0.name < $1.name }.prefix(count))
        if operands.count > 5, let missing = Int(operand(5)) {
            files.insert(RemoteEntry(ref: RemoteRef(path: operand(0) + "/does-not-exist"), name: "does-not-exist",
                                     kind: .file, size: 0, modified: nil), at: missing)
        }
        let local = URL(fileURLWithPath: operand(4))
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let batches = stride(from: 0, to: files.count, by: batchSize).map { Array(files[$0..<min($0 + batchSize, files.count)]) }
        let failures = OSAllocatedUnfairLock(initialState: [String]())
        let start = ContinuousClock.now
        try await withThrowingTaskGroup(of: Void.self) { group in
            var it = batches.makeIterator()
            func add(_ b: [RemoteEntry]) {
                group.addTask {
                    let items = b.map { DownloadItem($0, to: local.appendingPathComponent($0.name), replacing: nil) }
                    let report: @Sendable (Int, Error?) -> Void = { i, error in
                        if let error { failures.withLock { $0.append("\(b[i].name): \(error)") } }
                    }
                    if ProcessInfo.processInfo.environment["DRX_TAR"] != nil {
                        try await fs.downloadBundled(items, progress: { _ in }, completed: report)
                    } else {
                        try await fs.downloadMany(items, progress: { _ in }, completed: report)
                    }
                }
            }
            for _ in 0..<parallel { if let b = it.next() { add(b) } }
            while try await group.next() != nil { if let b = it.next() { add(b) } }
        }
        let d = ContinuousClock.now - start
        let secs = d / .seconds(1)
        let mb = Double(files.reduce(0) { $0 + ($1.size ?? 0) }) / 1e6
        let written = (try? FileManager.default.contentsOfDirectory(atPath: local.path).count) ?? 0
        print(String(format: "%d files, %.1f MB, batch %d × %d: %.2fs · %.1f files/s · %d on disk", files.count, mb, batchSize, parallel, secs, Double(files.count) / secs, written))
        failures.withLock { $0.forEach { print("failed:", $0) } }

    case "mtp-info":
        guard let serial = serialOption else { fail("-s SERIAL required") }
        let start = ContinuousClock.now
        let mtp = try MtpSession(serial: serial)
        print("opened in \(elapsedMs(since: start))")
        try mtp.openSession()
        let info = try mtp.deviceInfo()
        print("device: \(info.manufacturer) \(info.model) \(info.version) ext=\(info.vendorExtension)")
        for (name, op) in [("GetObjectPropList", 0x9805), ("GetThumb", 0x100A), ("GetPartialObject64", 0x95C1), ("SendPartialObject", 0x95C2),
                           ("CopyObject", 0x101A), ("MoveObject", 0x1019), ("SetObjectPropValue", 0x9804)] {
            print("  \(name): \(info.operations.contains(UInt16(op)) ? "yes" : "no")")
        }
        print("storages: \(try mtp.storageIDs().map { String(format: "0x%08X", $0) })")
        mtp.closeSession()

    case "make-zip":
        // sferry make-zip OUT.zip FOLDER — zips FOLDER's contents (dates kept) the way the app does
        guard operands.count == 2 else { fail("make-zip OUT.zip FOLDER") }
        let root = URL(fileURLWithPath: operand(1)).standardizedFileURL
        var items: [ZipItem] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys)
        while let url = walker?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: Set(keys))
            let path = String(url.standardizedFileURL.path.dropFirst(root.path.count + 1))
            guard !path.hasSuffix(".DS_Store") else { continue }
            items.append(ZipItem(path: path, source: values.isDirectory == true ? nil : url,
                                 modified: values.contentModificationDate ?? Date()))
        }
        try ZipWriter.write(items, to: URL(fileURLWithPath: operand(0)))
        print("wrote \(items.count) items to \(operand(0))")

    case "devtest":
        // sferry -s SERIAL devtest adb|mtp [quick] — the device test suite (docs/DEVICE_TESTS.md)
        guard let serial = serialOption, let transport = operands.first, ["adb", "mtp"].contains(transport) else {
            fail("-s SERIAL devtest adb|mtp")
        }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let passed = try await runDeviceTests(
            transport: transport, serial: serial, quick: operands.dropFirst().first == "quick",
            open: { () async throws -> any DeviceFileSystem in
                if transport == "adb" { return try await AdbFileSystem.connect(client: client, serial: serial) }
                return try await MtpFileSystem.open(serial: serial)
            },
            release: { ($0 as? MtpFileSystem)?.close() },
            spawnUpload: { remotePath, local in
                let process = Process()
                process.executableURL = executable
                process.arguments = ["-s", serial, "devtest-upload", transport, remotePath, local.path]
                process.standardError = FileHandle.nullDevice
                return process
            })
        exit(passed ? 0 : 1)

    case "devtest-pair":
        // sferry devtest-pair SERIAL_A:adb|mtp SERIAL_B:adb|mtp [quick] — two phones (docs/DEVICE_TESTS.md)
        let ends = operands.prefix(2).map { $0.split(separator: ":").map(String.init) }
        guard ends.count == 2, ends.allSatisfy({ $0.count == 2 && ["adb", "mtp"].contains($0[1]) }), ends[0][0] != ends[1][0] else {
            fail("devtest-pair SERIAL_A:adb|mtp SERIAL_B:adb|mtp [quick]")
        }
        let passed = try await runPairTests(operand(0), operand(1), quick: operands.dropFirst(2).first == "quick",
            open: { (end: String) async throws -> any DeviceFileSystem in
                let parts = end.split(separator: ":").map(String.init)
                if parts[1] == "adb" { return try await AdbFileSystem.connect(client: client, serial: parts[0]) }
                return try await MtpFileSystem.open(serial: parts[0])
            },
            release: { ($0 as? MtpFileSystem)?.close() })
        exit(passed ? 0 : 1)

    case "copy-bench":
        // sferry copy-bench A:adb|mtp B:adb|mtp MB — a generated file in A's own folder, copied to
        // B's own folder both ways, timed, and read back to compare. Both
        // folders are deleted at the end.
        let ends = operands.prefix(2).map { $0.split(separator: ":").map(String.init) }
        guard operands.count == 3, let megabytes = Int(operand(2)), ends.allSatisfy({ $0.count == 2 && ["adb", "mtp"].contains($0[1]) }),
              operand(0) != operand(1) else {
            fail("copy-bench SERIAL_A:adb|mtp SERIAL_B:adb|mtp MB")
        }
        func open(_ end: [String]) async throws -> any DeviceFileSystem {
            end[1] == "adb" ? try await AdbFileSystem.connect(client: client, serial: end[0]) : try await MtpFileSystem.open(serial: end[0])
        }
        let a = try await open(ends[0]), b = try await open(ends[1])
        defer { (a as? MtpFileSystem)?.close(); (b as? MtpFileSystem)?.close() }
        let stamp = Int(Date().timeIntervalSince1970)
        let folderA = RemoteRef(path: "/sdcard/Download/\(WorkNames.tag)-copybench-\(stamp)-a")
        let folderB = RemoteRef(path: "/sdcard/Download/\(WorkNames.tag)-copybench-\(stamp)-b")
        let local = WorkNames.scratch("copybench")
        defer { try? FileManager.default.removeItem(at: local) }
        do {
            var bytes = [UInt8](repeating: 0, count: megabytes << 20)
            for i in bytes.indices { bytes[i] = UInt8(truncatingIfNeeded: i &* 2_654_435_761 >> 13) }
            try Data(bytes).write(to: local)
            try await a.makeDirectory(folderA)
            try await b.makeDirectory(folderB)
            let source = folderA.appending("big.bin")
            try await a.upload(local, to: source, modified: Date(timeIntervalSince1970: 1_704_132_245)) { _ in }
            let entry = try await a.entry(at: source)
            print("A \(operand(0)) → B \(operand(1)), \(megabytes) MB; A and B: \(a.capabilities.streamsFiles), \(b.capabilities.streamsFiles) streaming")
            for (name, viaMac) in [("straight", false), ("via Mac", true), ("straight", false)] {
                let target = folderB.appending("\(name == "straight" ? "s" : "m")-\(Int.random(in: 0..<1_000_000)).bin")
                let start = ContinuousClock.now
                try await DeviceToDevice.copy(entry, from: a, to: target, on: b, throughMac: viaMac) { _ in }
                let seconds = start.duration(to: .now) / .seconds(1)
                let copied = try await b.entry(at: target)
                var check = copied.size == entry.size ? "size ok" : "SIZE \(copied.size ?? 0) ≠ \(entry.size ?? 0)"
                // The bytes, read back from B (generated data; the copy on this Mac goes right away).
                let back = WorkNames.scratch("copybench-back")
                try await b.download(copied, to: back) { _ in }
                check += (try Data(contentsOf: back)) == Data(bytes) ? ", bytes ok" : ", BYTES DIFFER"
                try? FileManager.default.removeItem(at: back)
                print(String(format: "  %-9@ %6.2f s  %6.1f MB/s  %@", name, seconds, Double(megabytes) / seconds, check))
            }
        } catch {
            print("failed: \(error)")
        }
        try? await a.delete([folderA])
        try? await b.delete([folderB])
        print("deleted \(folderA.path) on A and \(folderB.path) on B")

    case "upload-bench":
        // sferry -s SERIAL upload-bench adb|mtp [COUNT] [KB] — uploads through a temporary name
        // vs straight under the name, new files and replacing. Own folder, deleted at the end.
        guard let serial = serialOption, let transport = operands.first, ["adb", "mtp"].contains(transport) else {
            fail("-s SERIAL upload-bench adb|mtp [COUNT] [KB]")
        }
        let count = operands.count > 1 ? Int(operand(1)) ?? 100 : 100
        let kilobytes = operands.count > 2 ? Int(operand(2)) ?? 2 : 2
        let fs: any DeviceFileSystem = transport == "adb"
            ? try await AdbFileSystem.connect(client: client, serial: serial)
            : try await MtpFileSystem.open(serial: serial)
        defer { (fs as? MtpFileSystem)?.close() }
        let folder = RemoteRef(path: "/sdcard/Download/\(WorkNames.tag)-bench-\(Int(Date().timeIntervalSince1970))")
        let local = WorkNames.scratch("bench")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: local) }
        let files = try (0..<count).map { i -> URL in
            let url = local.appendingPathComponent("f\(i).txt")
            try Data(repeating: UInt8(i % 256), count: kilobytes * 1_000).write(to: url)
            return url
        }
        try await fs.makeDirectory(folder)
        print("\(serial) via \(transport), \(count) files of \(kilobytes) KB in \(folder.path)")
        // `dated`: with the files' dates, as the queue sends them; `together`: files at once, as the queue does.
        func round(_ label: String, _ dir: String, replacing: Bool, _ writing: UploadWriting,
                   dated: Bool = false, together: Int = 1) async throws {
            let start = ContinuousClock.now
            let date = Date(timeIntervalSince1970: 1_700_000_000)
            try await withThrowingTaskGroup(of: Void.self) { group in
                for (i, url) in files.enumerated() {
                    if i >= together { try await group.next() }
                    group.addTask {
                        try await fs.upload(url, to: folder.appending("\(dir)/f\(i).txt"), modified: dated ? date : nil,
                                            replacing: replacing, writing: writing) { _ in }
                    }
                }
                try await group.waitForAll()
            }
            let seconds = start.duration(to: .now) / .seconds(1)
            print(String(format: "  %-32@ %6.2f s  (%5.1f ms/file)", label as NSString, seconds, seconds * 1000 / Double(count)))
        }
        do {
            for dir in ["safe", "direct", "dated", "together"] { try await fs.makeDirectory(folder.appending(dir)) }
            // As the queue does: it knows from planning whether each file is new.
            try await round("new files, temporary name", "safe", replacing: false, .safe)
            try await round("  … with dates", "dated", replacing: false, .safe, dated: true)
            try await round("  … with dates, 2 at a time", "together", replacing: false, .safe, dated: true, together: 2)
            try await round("new files, straight", "direct", replacing: false, .direct)
            try await round("replacing, temporary name", "safe", replacing: true, .safe)
            try await round("replacing, straight", "direct", replacing: true, .direct)
        } catch {
            print("failed: \(error)")
        }
        try await fs.delete([folder])
        print("removed \(folder.path)")

    case "devtest-upload":
        // Used by devtest: an upload that the suite kills midway.
        guard let serial = serialOption, operands.count == 3 else { fail("-s SERIAL devtest-upload adb|mtp REMOTE LOCAL") }
        let fs: any DeviceFileSystem
        if operand(0) == "adb" { fs = try await AdbFileSystem.connect(client: client, serial: serial) } else { fs = try await MtpFileSystem.open(serial: serial) }
        // Reports bytes sent so the suite can stop it midway.
        let total = OSAllocatedUnfairLock(initialState: 0)
        try await fs.upload(URL(fileURLWithPath: operand(2)), to: RemoteRef(path: operand(1)), modified: nil) { n in
            let sent = total.withLock { $0 += n; return $0 }
            print(sent)
            fflush(stdout)
        }

    case "usb-reset":
        // sferry -s SERIAL usb-reset [seize] — experiment: reset the phone's USB port from the Mac
        guard let serial = serialOption else { fail("-s SERIAL") }
        var iterator: io_iterator_t = 0
        IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator)
        var found: io_service_t = 0
        while case let service = IOIteratorNext(iterator), service != 0 {
            let value = IORegistryEntryCreateCFProperty(service, "USB Serial Number" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
            if value == serial { found = service; break }
            IOObjectRelease(service)
        }
        IOObjectRelease(iterator)
        guard found != 0 else { fail("device not found") }
        let options: IOUSBHostObjectInitOptions = operands.first == "seize" ? [.deviceSeize] : []
        let start = ContinuousClock.now
        let device = try IOUSBHostDevice(__ioService: found, options: options, queue: nil, interestHandler: nil)
        print("opened device in \(elapsedMs(since: start))")
        try device.reset()
        print("reset requested in \(elapsedMs(since: start))")
        device.destroy()

    case "mtp-roothandles":
        // sferry -s SERIAL mtp-roothandles — counts only: which root handles answer ObjectInfo
        guard let serial = serialOption else { fail("-s SERIAL") }
        let raw = try RawMtp.open(serial: serial)
        defer { raw.close() }
        let mtp = raw.session, storage = raw.storage
        let handles = try mtp.objectHandles(storage: storage, parent: 0xFFFF_FFFF)
        var valid: [UInt32] = [], invalid: [UInt32] = [], folders = 0, hidden = 0
        for h in handles {
            do {
                let info = try mtp.objectInfo(h)
                valid.append(h)
                if info.isFolder { folders += 1 }
                if info.name.hasPrefix(".") { hidden += 1 }
            } catch { invalid.append(h) }
        }
        print("root handles: \(handles.count), valid \(valid.count) (folders \(folders), hidden \(hidden)), invalid \(invalid.count)")
        print("valid handle range: \(valid.min() ?? 0)…\(valid.max() ?? 0)")
        print("invalid handle range: \(invalid.min() ?? 0)…\(invalid.max() ?? 0)")
        if let h = invalid.first {
            for (label, prop) in [("parent", UInt16(0xDC0B)), ("format", UInt16(0xDC02)), ("storage", UInt16(0xDC01))] {
                do {
                    let (data, _) = try mtp.transact(0x9803, [h, UInt32(prop)])
                    print("invalid \(h) \(label): \(data.prefix(8).map { String(format: "%02x", $0) }.joined())")
                } catch { print("invalid \(h) \(label): \(error)") }
            }
        }
        let all = try mtp.objectHandles(storage: storage, parent: 0)
        print("all objects in storage: \(all.count); invalid ones among them: \(Set(invalid).intersection(all).count)")

    case "mtp-datetest":
        // sferry -s SERIAL mtp-datetest — upload a file to /Download with an old date, try to set the date
        guard let serial = serialOption else { fail("-s SERIAL") }
        let raw = try RawMtp.open(serial: serial)
        defer { raw.close() }
        let mtp = raw.session, storage = raw.storage
        guard let download = try raw.find("/Download") else { fail("no Download") }
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("\(WorkNames.tag)-datetest")
        try Data("x".utf8).write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let fd = open(local.path, O_RDONLY)
        let handle = try mtp.sendObjectInfo(name: "\(WorkNames.tag)-datetest.txt", size: 1, storage: storage, parent: download.handle, modified: date)
        try mtp.sendObject(from: fd, size: 1) { _ in }
        close(fd)
        print("after upload:", try mtp.objectInfo(handle).modified.map { "\($0)" } ?? "-")
        do {
            try mtp.setModified(handle, to: date)
            print("set date: ok; now", try mtp.objectInfo(handle).modified.map { "\($0)" } ?? "-")
        } catch { print("set date failed:", error) }
        try mtp.delete(handle)

    case "mtp-sendtest":
        // sferry -s SERIAL mtp-sendtest — times SendObjectInfo and SendObject for tiny files in /Download
        guard let serial = serialOption else { fail("-s SERIAL") }
        let raw = try RawMtp.open(serial: serial)
        defer { raw.close() }
        let mtp = raw.session, storage = raw.storage
        guard let download = try raw.find("/Download") else { fail("no Download") }
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("\(WorkNames.tag)-sendtest")
        try Data("x".utf8).write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }
        for i in 0..<4 {
            let fd = open(local.path, O_RDONLY)
            var t = ContinuousClock.now
            let handle = try mtp.sendObjectInfo(name: "\(WorkNames.tag)-sendtest-\(i).txt", size: 1, storage: storage,
                                                parent: download.handle, modified: nil)
            let info = elapsedMs(since: t)
            t = ContinuousClock.now
            try mtp.sendObject(from: fd, size: 1) { _ in }
            print("SendObjectInfo \(info), SendObject \(elapsedMs(since: t))")
            close(fd)
            try mtp.delete(handle)
        }

    case "mtp-ls":
        // sferry -s SERIAL mtp-ls /DCIM/Camera [PERFILE_LIMIT]
        guard let serial = serialOption, let path = operands.first else { fail("-s SERIAL mtp-ls PATH [LIMIT]") }
        let limit = operands.count > 1 ? Int(operand(1)) ?? 300 : 300
        let raw = try RawMtp.open(serial: serial)
        defer { raw.close() }
        let mtp = raw.session, storage = raw.storage
        // Resolve the path one level at a time with the bulk listing.
        let resolveStart = ContinuousClock.now
        let parent = try raw.folder(path, allProperties: true)
        print("resolved \(path) in \(elapsedMs(since: resolveStart))")

        var start = ContinuousClock.now
        var bulk: [MtpObjectInfo] = []
        do {
            bulk = try mtp.objectPropList(children: parent)
            print("GetObjectPropList(all): \(bulk.count) entries in \(elapsedMs(since: start))")
        } catch {
            print("GetObjectPropList(all) failed: \(error)")
        }
        start = ContinuousClock.now
        let byProp = try mtp.objectPropListByProperty(children: parent)
        print("GetObjectPropList(per property ×\(MtpSession.listingProperties.count)): \(byProp.count) entries in \(elapsedMs(since: start))")
        if bulk.isEmpty { bulk = byProp }

        start = ContinuousClock.now
        let handles = try mtp.objectHandles(storage: storage, parent: parent)
        print("GetObjectHandles: \(handles.count) handles in \(elapsedMs(since: start))")
        start = ContinuousClock.now
        let sample = Array(handles.prefix(limit))
        let infos = try sample.map { try mtp.objectInfo($0) }
        let d = ContinuousClock.now - start
        let milliseconds: Double = d / .milliseconds(1)
        let perItem = milliseconds / Double(max(1, infos.count))
        print(String(format: "GetObjectInfo × %d: %@ (%.2f ms each → %.1fs for all %d)",
                     infos.count, elapsedMs(since: start), perItem, perItem * Double(handles.count) / 1000, handles.count))

        // Do both methods agree?
        let bulkByHandle = Dictionary(uniqueKeysWithValues: bulk.map { ($0.handle, $0) })
        var mismatches = 0
        for info in infos {
            guard let b = bulkByHandle[info.handle] else { mismatches += 1; continue }
            if b.name != info.name || (info.size != 0xFFFF_FFFF && b.size != info.size) || b.format != info.format { mismatches += 1 }
        }
        if let first = bulk.first(where: { !$0.isFolder }) {
            print("sample: \(first.name) size=\(first.size) modified=\(first.modified.map { String(Int($0.timeIntervalSince1970)) } ?? "-")")
        }
        let dates = bulk.compactMap(\.modified).count
        print("compared \(infos.count): \(mismatches) mismatches; handles in list but not bulk: \(Set(handles).subtracting(bulkByHandle.keys).count); bulk entries with dates: \(dates)/\(bulk.count)")

    case "mtp-read":
        // sferry -s SERIAL mtp-read PATH — reads a file over MTP into memory (nothing is
        // written to disk) and prints its MD5 and speed.
        guard let serial = serialOption, let path = operands.first else { fail("-s SERIAL mtp-read PATH") }
        let raw = try RawMtp.open(serial: serial)
        defer { raw.close() }
        let mtp = raw.session
        let target = try raw.find(path)
        guard let file = target, !file.isFolder else { fail("not a file") }
        var hasher = Insecure.MD5()
        var total = 0
        let start = ContinuousClock.now
        let chunk = UInt64(ProcessInfo.processInfo.environment["MTP_CHUNK_MB"].flatMap(Int.init) ?? 8) << 20
        try mtp.readObject(file.handle, size: file.size, chunk: chunk) { bytes in
            hasher.update(bufferPointer: bytes)
            total += bytes.count
        }
        let d = ContinuousClock.now - start
        let secs = d / .seconds(1)
        let md5 = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        print(String(format: "%@ %d bytes (expected %llu) in %.2fs · %.1f MB/s", md5, total, file.size, secs, Double(total) / 1e6 / secs))

    case "mtp-cancel-test":
        // sferry -s SERIAL mtp-cancel-test BIG_FILE SMALL_FILE — reads BIG_FILE in memory, cancels
        // after 0.5 s, then checks the session still works by reading SMALL_FILE (MD5).
        guard let serial = serialOption, operands.count == 2 else { fail("-s SERIAL mtp-cancel-test BIG SMALL") }
        let raw = try RawMtp.open(serial: serial)
        defer { raw.close() }
        let mtp = raw.session
        func resolve(_ path: String) throws -> MtpObjectInfo {
            guard let found = try raw.find(path) else { fail("\(path) is the storage itself") }
            return found
        }
        let big = try resolve(operand(0)), small = try resolve(operand(1))
        nonisolated(unsafe) let session = mtp
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var readBytes = 0
        nonisolated(unsafe) var outcome = ""
        DispatchQueue.global().async {
            do {
                try session.readObject(big.handle, size: big.size) { readBytes += $0.count }
                outcome = "finished (not cancelled)"
            } catch {
                outcome = "\(error)"
            }
            done.signal()
        }
        try await Task.sleep(for: .milliseconds(500))
        let cancelAt = ContinuousClock.now
        mtp.cancelCurrentTransaction()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { done.wait(); c.resume() }
        }
        print("read \(readBytes) of \(big.size) bytes, then: \(outcome) — unblocked \(elapsedMs(since: cancelAt)) after cancel")
        let check = ContinuousClock.now
        print("storages after cancel: \(try mtp.storageIDs().count) (\(elapsedMs(since: check)))")
        var hasher = Insecure.MD5()
        try mtp.readObject(small.handle, size: small.size) { hasher.update(bufferPointer: $0) }
        print("small file md5 after cancel: \(hasher.finalize().map { String(format: "%02x", $0) }.joined())")

    case "mtpfs":
        // sferry -s SERIAL mtpfs ls PATH | stat PATH | get PATH LOCAL | mkdir PATH | mv PATH NAME | rm PATH
        guard let serial = serialOption, operands.count >= 2 else { fail("-s SERIAL mtpfs ls|stat|get|mkdir|mv|rm PATH …") }
        let openStart = ContinuousClock.now
        let fs = try await MtpFileSystem.open(serial: serial)
        defer { fs.close() }
        print("open: \(elapsedMs(since: openStart)) roots=\(fs.roots.map { "\($0.ref.path)=\($0.name)" })")
        let ref = RemoteRef(path: operand(1))
        switch operand(0) {
        case "ls":
            let start = ContinuousClock.now
            var batches = 0
            var latest: [String: RemoteEntry] = [:]
            for try await batch in fs.list(ref) {
                batches += 1
                for entry in batch { latest[entry.id] = entry }
                print("batch \(batches): \(batch.count) entries, partial=\(batch.filter(\.isPartial).count) at \(elapsedMs(since: start))")
            }
            let all = Array(latest.values), files = all.filter { !$0.isDirectory }
            print("files with size: \(files.filter { $0.size != nil }.count)/\(files.count), with date: \(all.filter { $0.modified != nil }.count)/\(all.count)")
            for file in files where (file.size ?? 0) >= 1 << 32 { print("4 GB or more: \(file.name) \(file.size!)") }
        case "plan":
            // mtpfs plan DIR — how long planning a transfer of DIR takes (sizes and dates of every
            // file below it, as the queue gets them)
            let start = ContinuousClock.now
            let folder = try await fs.entry(at: ref)
            let plan = try await TransferPlanner.expand([folder], in: fs)
            print("planned \(plan.files.count) files, \(plan.totalBytes) bytes, with size \(plan.files.filter { $0.entry.size != nil }.count) in \(elapsedMs(since: start))")
        case "complete":
            // mtpfs complete DIR — every file of DIR picked by name only, then its details filled
            // in (as for a selection made before a big folder's details came)
            let names = try await fs.listNames(ref).filter { !$0.isDirectory }
            let start = ContinuousClock.now
            let filled = try await fs.completingDetails(names)
            print("\(names.filter(\.isPartial).count) of \(names.count) by name only; filled \(filled.filter { $0.size != nil && !$0.isPartial }.count) in \(elapsedMs(since: start))")
        case "stat":
            let e = try await fs.entry(at: ref)
            print(e.name, e.kind, e.size ?? 0, e.modified.map { Int($0.timeIntervalSince1970) } ?? 0)
        case "get":
            let e = try await fs.entry(at: ref)
            let dest = URL(fileURLWithPath: operand(2))
            let start = ContinuousClock.now
            try await fs.download(e, to: dest) { _ in }
            print("downloaded \(e.size ?? 0) bytes in \(elapsedMs(since: start))")
        case "mkdir":
            try await fs.makeDirectory(ref)
            print("ok")
        case "mv":
            print(try await fs.rename(ref, to: operand(2)).path)
        case "renumber":
            try await renumber(ref, start: Int(operand(2)) ?? 1, fs: fs)
        case "rm":
            try await fs.delete([ref])
            print("ok")
        case "time-ops":
            // mtpfs time-ops DIR — how long a small upload and a rename take on this phone
            let local = FileManager.default.temporaryDirectory.appendingPathComponent("\(WorkNames.tag)-timeops.txt")
            try Data("x".utf8).write(to: local)
            defer { try? FileManager.default.removeItem(at: local) }
            for i in 0..<5 {
                var t = ContinuousClock.now
                try await fs.upload(local, to: ref.appending("t\(i).txt"), modified: nil) { _ in }
                let up = elapsedMs(since: t)
                t = ContinuousClock.now
                _ = try await fs.rename(ref.appending("t\(i).txt"), to: "r\(i).txt")
                print("upload \(up), rename \(elapsedMs(since: t))")
            }
        case "cp-then-move":
            // mtpfs cp-then-move SRC TMP DST — copy a folder and move the copy, in one session
            try await fs.copyOnDevice(ref, to: RemoteRef(path: operand(2)))
            print("copied")
            try await fs.moveOnDevice(RemoteRef(path: operand(2)), to: RemoteRef(path: operand(3)))
            print("moved")
        case "cp", "move":
            // mtpfs cp|move SRC DST_PATH
            let dst = RemoteRef(path: operand(2))
            if operand(0) == "cp" { try await fs.copyOnDevice(ref, to: dst) } else { try await fs.moveOnDevice(ref, to: dst) }
            print("ok")
        case "put":
            // mtpfs put REMOTE_PATH LOCAL_FILE
            let local = URL(fileURLWithPath: operand(2))
            let modified = (try? local.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let start = ContinuousClock.now
            try await fs.upload(local, to: ref, modified: modified) { _ in }
            print("uploaded in \(elapsedMs(since: start))")
        case "browse-during":
            // mtpfs browse-during FILE FOLDER — downloads FILE (to a scratch file, deleted) while
            // listing FOLDER every 50 ms: how long browsing waits behind a download.
            let e = try await fs.entry(at: ref)
            let folder = RemoteRef(path: operand(2))
            let dest = WorkNames.scratch("browse")
            defer { try? FileManager.default.removeItem(at: dest) }
            let done = OSAllocatedUnfairLock(initialState: false)
            let started = ContinuousClock.now
            let download = Task {
                defer { done.withLock { $0 = true } }
                try await fs.download(e, to: dest) { _ in }
            }
            var waits: [Double] = []
            while !done.withLock({ $0 }) {
                let t = ContinuousClock.now
                _ = try await fs.listAll(folder)
                waits.append((ContinuousClock.now - t) / .milliseconds(1))
                try await Task.sleep(for: .milliseconds(50))
            }
            try await download.value
            let took = (ContinuousClock.now - started) / .seconds(1)
            let sorted = waits.sorted()
            print(String(format: "downloaded %.0f MB in %.2fs while listing %d times: median %.0f ms, worst %.0f ms",
                         Double(e.size ?? 0) / 1e6, took, waits.count, sorted[sorted.count / 2], sorted.last ?? 0))
        case "race":
            // Start listing PATH, abandon it after the names, immediately list OTHER: how long
            // until OTHER's names arrive while PATH's details are in flight?
            let other = RemoteRef(path: operand(2))
            let start = ContinuousClock.now
            let first = Task { () -> Int in
                var n = 0
                for try await batch in fs.list(ref) { n = batch.count; break } // leave after names
                return n
            }
            let names = try await first.value
            print("\(ref.path): names (\(names)) at \(elapsedMs(since: start)); leaving")
            let switchAt = ContinuousClock.now
            for try await batch in fs.list(other) {
                print("\(other.path): \(batch.count) entries partial=\(batch.filter(\.isPartial).count) at +\(elapsedMs(since: switchAt))")
            }
        default:
            usage()
        }

    case "mtp-reuse-name":
        // sferry -s SERIAL mtp-reuse-name FOLDER — experiment: after deleting a file, how soon does
        // the phone accept a new file of the same name (SendObjectInfo)? FOLDER must exist and
        // is only written to with a file named xfer-reuse.txt.
        guard let serial = serialOption, let path = operands.first else { fail("-s SERIAL mtp-reuse-name FOLDER") }
        let raw = try RawMtp.open(serial: serial)
        defer { raw.close() }
        let mtp = raw.session, storage = raw.storage
        let parent = try raw.folder(path)
        let local = WorkNames.scratch("reuse")
        try Data("reuse".utf8).write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }
        let name = "\(WorkNames.tag)-reuse.txt"
        func send(_ sentName: String = name) throws -> UInt32 {
            let fd = open(local.path, O_RDONLY)
            defer { close(fd) }
            let handle = try mtp.sendObjectInfo(name: sentName, size: 5, storage: storage, parent: parent, modified: nil)
            try mtp.sendObject(from: fd, size: 5) { _ in }
            return handle
        }
        let cases: [(String, Bool, Bool)] = [("sent under the name, deleted", false, false),
                                             ("sent under the name, deleted, folder listed", true, false),
                                             ("sent under another name and renamed, deleted", false, true),
                                             ("sent under another name and renamed, deleted, folder listed", true, true)]
        func named() throws -> [UInt32] {
            try mtp.objectHandles(storage: storage, parent: parent).filter { try mtp.objectInfo($0).name == name }
        }
        // Step by step, with the phone's own view of the folder (adb ls) after each step.
        func disk() -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["adb", "-s", serial, "shell", "ls -A '\(path)' | tr '\\n' ' '"]
            let pipe = Pipe()
            p.standardOutput = pipe
            try? p.run()
            p.waitUntilExit()
            return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
        func mtpNames() throws -> String {
            try mtp.objectHandles(storage: storage, parent: parent).map { "\($0)=\(try mtp.objectInfo($0).name)" }.joined(separator: " ")
        }
        if operands.count > 1 {
            let first = try send(WorkNames.step("part"))
            print("sent \(first)       mtp: \(try mtpNames())   disk: \(disk())")
            try mtp.rename(first, to: name)
            let pause = Int(operand(1)) ?? 1000
            if pause > 0 {
                print("renamed          mtp: \(try mtpNames())   disk: \(disk())")
                usleep(useconds_t(pause * 1000))
                print("\(pause) ms later    mtp: \(try mtpNames())   disk: \(disk())")
            }
            try mtp.delete(first)
            print("deleted \(first)    mtp: \(try mtpNames())   disk: \(disk())")
            usleep(1_000_000)
            print("1 s later        mtp: \(try mtpNames())   disk: \(disk())")
            break
        }
        for (label, listFirst, renamed) in cases {
            let first = try renamed ? send(WorkNames.step("part")) : send()
            if renamed { try mtp.rename(first, to: name) }
            try mtp.delete(first)
            let start = ContinuousClock.now
            var attempts = 0
            var handle: UInt32?
            while handle == nil, ContinuousClock.now - start < .seconds(10) {
                attempts += 1
                if listFirst { _ = try mtp.objectHandles(storage: storage, parent: parent) }
                do { handle = try send() } catch MtpError.response(_, 0x2002) { usleep(20_000) }
            }
            print("\(label): \(handle == nil ? "still refused" : "accepted") after \(attempts) tries, \(elapsedMs(since: start))")
            if let handle { try mtp.delete(handle) }
        }

    case "mtp-proplist":
        // sferry -s SERIAL mtp-proplist PATH — tries the ways GetObjectPropList can select properties
        guard let serial = serialOption, let path = operands.first else { fail("-s SERIAL mtp-proplist PATH [timing-only]") }
        let raw = try RawMtp.open(serial: serial)
        defer { raw.close() }
        let mtp = raw.session
        let parent = try raw.folder(path)
        let cases: [(String, UInt32, UInt32, UInt32)] = [
            ("all properties (0xFFFFFFFF)", 0, 0xFFFF_FFFF, 0),
            ("one property: file name", 0, 0xDC07, 0),
            ("group 1 (property 0)", 0, 0, 1),
            ("group 0 (property 0)", 0, 0, 0),
            ("all properties, folders only (format 0x3001)", 0x3001, 0xFFFF_FFFF, 0),
            ("all properties, JPEG only (format 0x3801)", 0x3801, 0xFFFF_FFFF, 0),
            ("all properties, PNG only (format 0x380B)", 0x380B, 0xFFFF_FFFF, 0),
        ]
        for (name, code) in [("file name", 0xDC07), ("format", 0xDC02), ("size", 0xDC04), ("date modified", 0xDC09)] as [(String, UInt32)] {
            let t = ContinuousClock.now
            let n = try mtp.rawPropList(parent, format: 0, property: code, group: 0, depth: 1)
            print("timing \(name): \(n) values in \(elapsedMs(since: t))")
        }
        if operands.count > 1 { break }
        for (label, format, property, group) in cases {
            do {
                let n = try mtp.rawPropList(parent, format: format, property: property, group: group, depth: 1)
                print("\(label): OK, \(n) values")
            } catch {
                print("\(label): \(error)")
            }
        }

    case "push":
        // sferry push LOCAL REMOTE_PATH
        guard operands.count == 2 else { usage() }
        let fs = try await AdbFileSystem.connect(client: client, serial: try await pickSerial())
        let local = URL(fileURLWithPath: operand(0))
        let modified = (try? local.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let size = Double((try? local.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) / 1e6
        let start = ContinuousClock.now
        try await fs.upload(local, to: RemoteRef(path: operand(1)), modified: modified) { _ in }
        let d = ContinuousClock.now - start
        let secs = d / .seconds(1)
        print(String(format: "pushed %.1f MB in %.2fs · %.1f MB/s", size, secs, size / secs))

    case "cp", "move":
        // sferry cp|move SRC DST_PATH (on the device)
        guard operands.count == 2 else { usage() }
        let fs = try await AdbFileSystem.connect(client: client, serial: try await pickSerial())
        if command == "cp" {
            try await fs.copyOnDevice(RemoteRef(path: operand(0)), to: RemoteRef(path: operand(1)))
        } else {
            try await fs.moveOnDevice(RemoteRef(path: operand(0)), to: RemoteRef(path: operand(1)))
        }
        print("ok")

    case "mkdir":
        let fs = try await AdbFileSystem.connect(client: client, serial: try await pickSerial())
        try await fs.makeDirectory(RemoteRef(path: operand(0)))
    case "mdns":
        for service in try await client.mdnsServices() {
            print(service.kind, service.instance, service.address, service.deviceSerial ?? "-")
        }
    case "pair":
        // sferry pair ADDRESS CODE
        try await client.pair(address: operand(0), code: operand(1))
        print("paired")
    case "connect":
        try await client.connect(address: operand(0))
        print("connected")

    case "renumber":
        // sferry renumber DIR START — names every file "<n>.<ext>" from START, via BatchRename
        let fs = try await AdbFileSystem.connect(client: client, serial: try await pickSerial())
        try await renumber(RemoteRef(path: operand(0)), start: Int(operand(1)) ?? 1, fs: fs)
    case "mv":
        let fs = try await AdbFileSystem.connect(client: client, serial: try await pickSerial())
        print(try await fs.rename(RemoteRef(path: operand(0)), to: operand(1)).path)
    case "rm":
        let fs = try await AdbFileSystem.connect(client: client, serial: try await pickSerial())
        try await fs.delete(operands.map { RemoteRef(path: $0) })

    case "thumb":
        // sferry -s SERIAL thumb adb|mtp PATH… — the small picture the device keeps for each file
        // (`storedThumbnail`): its size, dimensions and time. Nothing is written.
        guard let serial = serialOption, operands.count >= 2, ["adb", "mtp"].contains(operand(0)) else {
            fail("-s SERIAL thumb adb|mtp PATH…")
        }
        let fs: any DeviceFileSystem = operand(0) == "adb"
            ? try await AdbFileSystem.connect(client: client, serial: serial) : try await MtpFileSystem.open(serial: serial)
        defer { fs.close() }
        for path in operands.dropFirst() {
            let start = ContinuousClock.now
            let entry = try await fs.entry(at: RemoteRef(path: path))
            let data = try await fs.storedThumbnail(of: entry)
            let size = data.flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }
                .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
                .map { "\($0[kCGImagePropertyPixelWidth] ?? "?")×\($0[kCGImagePropertyPixelHeight] ?? "?")" }
            print("\(path): \(data.map { "\($0.count) bytes, \(size ?? "not a picture")" } ?? "none") in \(elapsedMs(since: start))")
        }

    case "md5":
        let fs = try await AdbFileSystem.connect(client: client, serial: try await pickSerial())
        let hashes = try await fs.contentHashes(operands.map { RemoteRef(path: $0) })
        for path in operands { print(hashes[path] ?? "-", path) }

    case "sync":
        // sferry sync REMOTE... LOCAL_DIR POLICY — the app's planning and decisions (merging
        // folders, no per-file choices: the app's defaults), without its queue.
        guard operands.count >= 3, let policyKind = ExistingFilePolicy(rawValue: operands.last!) else { usage() }
        let fs = try await AdbFileSystem.connect(client: client, serial: try await pickSerial())
        let local = URL(fileURLWithPath: operands[operands.count - 2])
        var sources: [RemoteEntry] = []
        for path in operands.dropLast(2) { sources.append(try await fs.entry(at: RemoteRef(path: path))) }
        let policy = TransferPolicy(existing: policyKind)
        let plan = try await TransferPlanner.expand(sources, in: fs)
        print("plan: \(plan.files.count) files, \(plan.directories.count) dirs, \(plan.totalBytes) bytes")
        var decisions = try plan.placedLocally(into: local, policy: policy, sizesWrap: !fs.capabilities.exactLargeSizes)
            .map { ($0.file, $0.target, $0.decision) }
        let hashIdx = decisions.indices.filter { decisions[$0].2 == .needsHash }
        if !hashIdx.isEmpty {
            let remote = try await fs.contentHashes(hashIdx.map { decisions[$0].0.entry.ref })
            for i in hashIdx {
                // Only two known, equal hashes mean "same"; a missing one means "differs".
                let remoteHash = remote[decisions[i].0.entry.ref.path]
                let localHash = try? localMD5(of: decisions[i].1)
                let equal = remoteHash != nil && remoteHash == localHash
                decisions[i].2 = FileDecision.afterHash(equal: equal, policy)
                if decisions[i].2 == .keepBoth {
                    var reserved = FolderNames(decisions.map(\.1.path))
                    decisions[i].1 = uniqueDestination(for: decisions[i].1, reserved: &reserved)
                }
            }
        }
        for dir in plan.directories { try FileManager.default.createDirectory(at: local.appendingPathComponent(dir), withIntermediateDirectories: true) }
        for (file, dest, decision) in decisions {
            if decision.transfers { try await fs.download(file.entry, to: dest) { _ in } }
            print(decision, file.relativePath, "->", dest.lastPathComponent)
        }

    case "pull":
        guard let remote = operands.first else { usage() }
        let localDir = URL(fileURLWithPath: operands.count > 1 ? operand(1) : FileManager.default.currentDirectoryPath)
        let fs = try await AdbFileSystem.connect(client: client, serial: try await pickSerial())
        let entry = try await fs.entry(at: RemoteRef(path: remote))
        guard entry.kind == .file else { fail("only single files can be pulled") }
        let destination = localDir.appendingPathComponent(entry.name)
        let start = ContinuousClock.now
        try await fs.download(entry, to: destination) { _ in }
        let d = ContinuousClock.now - start
        let seconds = d / .seconds(1)
        let mb = Double(entry.size ?? 0) / 1_000_000
        note(String(format: "%@ · %.1f MB in %.2fs · %.1f MB/s", destination.path, mb, seconds, mb / max(seconds, 0.001)))

    default:
        usage()
    }
} catch {
    fail("error: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
}

/// Batch-renames every file in `dir` to its number, the way the app's Rename sheet does.
func renumber(_ dir: RemoteRef, start: Int, fs: any DeviceFileSystem) async throws {
    let entries = try await fs.listAll(dir)
    let files = entries.filter { !$0.isDirectory }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    var rules = BatchRenameRules()
    rules.numbering = true
    rules.numberPosition = .replace
    rules.start = start
    rules.digits = 1
    let rows = BatchRename.preview(files.map { ($0.name, false) }, rules: rules,
                                   others: Set(entries.filter(\.isDirectory).map(\.name)))
    let steps = BatchRename.steps(rows)
    for step in steps {
        print("\(step.from) → \(step.to)")
        _ = try await fs.rename(dir.appending(step.from), to: step.to)
    }
}
