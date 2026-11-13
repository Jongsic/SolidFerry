import Darwin
import DeviceCore
import Foundation
import os

// File operations and hashes as toybox shell commands.

extension AdbFileSystem {
    public func makeDirectory(_ ref: RemoteRef) async throws {
        guard FileNames.isAllowed(ref.name) else { throw DeviceFSError.invalidName(ref.name) }
        try await run("mkdir -- " + Self.shellQuote(ref.path))
    }

    /// `mkdir -p` in as few commands as adb takes (each shell command costs tens of ms).
    public func makeDirectories(_ refs: [RemoteRef]) async throws {
        if let bad = refs.first(where: { !FileNames.isAllowed($0.name) }) { throw DeviceFSError.invalidName(bad.name) }
        let quoted = refs.map { Self.shellQuote($0.path) }
        for range in Self.argumentBatches(quoted) {
            try await run("mkdir -p -- " + quoted[range].joined(separator: " "))
        }
    }

    public func rename(_ ref: RemoteRef, to newName: String) async throws -> RemoteRef {
        guard FileNames.isAllowed(newName) else { throw DeviceFSError.invalidName(newName) }
        guard let parent = ref.parentPath else { throw DeviceFSError.invalidName(newName) }
        let target = RemoteRef(path: parent).appending(newName)
        if newName != ref.name, FolderNames.same(newName, ref.name) {
            // Only the case (or composition) changes: storage sees one name, and a direct mv
            // succeeds without changing anything. Through a hidden name it takes (QUIRKS S7).
            let step = Self.shellQuote(RemoteRef(path: parent).appending(WorkNames.moving(newName)).path)
            try await run("mv -n -- \(Self.shellQuote(ref.path)) \(step) && mv -n -- \(step) \(Self.shellQuote(target.path))")
            return target
        }
        // toybox `mv -n` exits 0 without doing anything when the target exists (QUIRKS A10), so
        // check in the same shell step; `-L` also catches a dangling symlink, which `-e` misses.
        try await runIfFree(target, "mv -n -- \(Self.shellQuote(ref.path)) \(Self.shellQuote(target.path))")
        return target
    }

    /// `cp -f` and `mv -f` replace a file there. Planned as new (`replacing == false`), whatever
    /// turned up there since stays (and a folder there isn't copied into).
    public func copyOnDevice(_ source: RemoteRef, to destination: RemoteRef, replacing: Bool?) async throws {
        let command = "cp -rpf -- " + Self.shellQuote(source.path) + " " + Self.shellQuote(destination.path)
        if replacing == false { try await runIfFree(destination, command) } else { try await run(command) }
    }

    public func moveOnDevice(_ source: RemoteRef, to destination: RemoteRef, replacing: Bool?) async throws {
        let command = "mv -f -- " + Self.shellQuote(source.path) + " " + Self.shellQuote(destination.path)
        if replacing == false { try await runIfFree(destination, command) } else { try await run(command) }
    }

    /// Runs `command` only if nothing is at `target`, checked in the same shell step; throws
    /// `alreadyExists` otherwise. `-L` also catches a dangling symlink, which `-e` misses.
    func runIfFree(_ target: RemoteRef, _ command: String) async throws {
        let quoted = Self.shellQuote(target.path)
        let output = try await run("if [ -e \(quoted) ] || [ -L \(quoted) ]; then echo \(Self.existsMarker); else \(command); fi")
        if output.contains(Self.existsMarker) { throw DeviceFSError.alreadyExists(target.name) }
    }

    public func delete(_ refs: [RemoteRef]) async throws {
        if let unsafe = refs.first(where: { !Self.isSafeToDelete($0.path) }) { throw DeviceFSError.invalidName(unsafe.path) }
        let quoted = refs.map { Self.shellQuote($0.path) }
        for range in Self.argumentBatches(quoted) {
            try await run("rm -rf -- " + quoted[range].joined(separator: " "))
        }
    }

    /// Never let a malformed path turn into "rm -rf /" or a parent folder: absolute, at least
    /// two levels deep, no "." or "..".
    static func isSafeToDelete(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        guard path.hasPrefix("/"), !parts.contains(where: { $0 == "." || $0 == ".." }) else { return false }
        // Under /storage the top levels are storages themselves: /storage/emulated/0 (and
        // /storage/self/primary) is the internal storage, /storage/1234-ABCD a card.
        if parts.first == "storage" {
            let storageDepth = parts.count > 1 && (parts[1] == "emulated" || parts[1] == "self") ? 3 : 2
            return parts.count > storageDepth
        }
        return parts.count >= 2
    }

    /// Splits shell arguments into runs whose joined length stays within `limit` bytes: adb
    /// takes a command as one request of at most 64 KB, counted in UTF-8 (a Korean letter is
    /// 3 bytes). An argument longer than the limit on its own still goes, alone.
    static func argumentBatches(_ arguments: [String], limit: Int = 30_000) -> [Range<Int>] {
        var batches: [Range<Int>] = []
        var start = 0, length = 0
        for (index, argument) in arguments.enumerated() {
            let bytes = argument.utf8.count + 1
            if length + bytes > limit, index > start {
                batches.append(start..<index)
                start = index
                length = 0
            }
            length += bytes
        }
        if start < arguments.count { batches.append(start..<arguments.count) }
        return batches
    }

    /// Runs `md5sum` on the device in batches small enough for one adb request each.
    public func contentHashes(_ refs: [RemoteRef]) async throws -> [String: String] {
        var result: [String: String] = [:]
        var batch: [String] = []
        func flush() async throws {
            guard !batch.isEmpty else { return }
            let output = try await client.exec(serial: serial, "md5sum -- " + batch.joined(separator: " "))
            result.merge(Self.parseMD5Sum(String(decoding: output, as: UTF8.self))) { _, new in new }
        }
        let quoted = refs.map { Self.shellQuote($0.path) }
        for range in Self.argumentBatches(quoted) {
            batch = Array(quoted[range])
            try await flush()
        }
        return result
    }

    static let existsMarker = "__XFER_EXISTS__"
    static let exitMarker = "__XFER_RC="

    /// The media library's thumbnail for a picture (Android 10 and later). Found by the file's
    /// path as the library stores it (`/sdcard` is a link, and on some phones its real path is
    /// an internal mount: QUIRKS A20), then read; nothing when the library doesn't have the file
    /// (not scanned yet). Both steps start a Java tool on the phone, about a second each, so
    /// files the library leaves out — in a hidden folder, or below a folder with `.nomedia` —
    /// aren't asked about, and once the lookup itself fails, nothing more is.
    public func storedThumbnail(of entry: RemoteEntry) async throws -> Data? {
        guard !mediaLibraryFails.withLock({ $0 }),
              !(entry.ref.parentPath ?? "").split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { return nil }
        let images = "content://media/external/images/media"
        let script = """
            r=$(realpath -- \(Self.shellQuote(entry.ref.path))); \
            case $r in \
              /mnt/runtime/*/emulated/*) r=/storage/${r#/mnt/runtime/*/} ;; \
              /mnt/user/*/primary/*) u=${r#/mnt/user/}; r=/storage/emulated/${u%%/*}/${u#*/primary/} ;; \
              /data/media/*) r=/storage/emulated/${r#/data/media/} ;; \
            esac; \
            d=${r%/*}; \
            while [ -n "$d" ]; do [ -e "$d/.nomedia" ] && exit 0; d=${d%/*}; done; \
            p=$(printf '%s\\n' "$r" | sed "s/'/''/g"); \
            q=$(content query --uri \(images) --projection _id --where "_data='$p'" 2>&1); \
            case $q in *"Row: "*) ;; *"No result found"*) exit 0 ;; *) echo \(Self.lookupFailedMarker); printf '%s\\n' "$q" | head -n 3; exit 0 ;; esac; \
            id=$(printf '%s\\n' "$q" | sed -n 's/^Row: 0 _id=\\([0-9]*\\)$/\\1/p'); \
            [ -n "$id" ] && content read --uri \(images)/$id/thumbnail 2>/dev/null
            """
        let data = try await client.exec(serial: serial, script)
        if data.starts(with: Data(Self.lookupFailedMarker.utf8)) {
            mediaLibraryFails.withLock { $0 = true }
            let printed = String(decoding: data.dropFirst(Self.lookupFailedMarker.utf8.count), as: UTF8.self)
            adbLog.info("\(self.serial, privacy: .public): media library lookup fails, not asked again (QUIRKS A20): \(printed)")
            return nil
        }
        return Self.isPicture(data) ? data : nil
    }

    static let lookupFailedMarker = "__XFER_NO_MEDIA_LIBRARY__"

    /// JPEG or PNG, rather than an error message.
    static func isPicture(_ data: Data) -> Bool {
        data.starts(with: [0xFF, 0xD8, 0xFF]) || data.starts(with: [0x89, 0x50, 0x4E, 0x47])
    }

    /// `{ cmd; } 2>&1; echo __XFER_RC=$?` output → exit code and what the command printed
    /// (QUIRKS A11).
    static func parseExitStatus(_ output: String) -> (code: Int, printed: String)? {
        guard let range = output.range(of: exitMarker, options: .backwards),
              let code = Int(output[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return (code, output[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// toybox `md5sum` lines, "<32 hex>  <path>", by path. Anything else is skipped, which
    /// leaves that file "different" (it gets copied rather than wrongly skipped).
    static func parseMD5Sum(_ output: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in output.split(separator: "\n") {
            guard line.count > 34, line.prefix(32).allSatisfy(\.isHexDigit),
                  line[line.index(line.startIndex, offsetBy: 32)...].hasPrefix("  ") else { continue }
            result[String(line.dropFirst(34))] = String(line.prefix(32))
        }
        return result
    }

    /// Runs a shell command and returns its output, throwing the output if it exits non-zero.
    @discardableResult
    func run(_ command: String) async throws -> String {
        let data = try await client.exec(serial: serial, "{ \(command); } 2>&1; echo \(Self.exitMarker)$?")
        guard let (code, printed) = Self.parseExitStatus(String(decoding: data, as: UTF8.self)) else {
            throw AdbError.protocolViolation("no exit status")
        }
        if code != 0 { throw AdbError.commandFailed(printed) }
        return printed
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
