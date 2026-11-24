import AdbKit
import DeviceCore
import Foundation
import os
import TransferKit

/// The device test suite (`sferry -s SERIAL devtest adb|mtp`): the same checks for every phone
/// and transport, through `DeviceFileSystem` only, so they test what the app relies on.
///
/// Safety: everything happens in a folder the suite creates (/sdcard/Download/xfer-devtest-…)
/// with files it generates; nothing else on the phone is read or changed, and both that folder
/// and the local scratch folder are deleted at the end. See docs/DEVICE_TESTS.md.
struct DeviceTestSuite: DeviceTestHelpers {
    let fs: any DeviceFileSystem
    let transport: String
    let remote: RemoteRef
    let local: URL
    /// Re-opens the connection after a test that needs the phone to itself (MTP is exclusive).
    let reconnect: (() async throws -> any DeviceFileSystem)?
    let release: (() -> Void)?
    let spawnUpload: ((String, URL) -> Process)?

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func check(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw Failure(description: message()) }
    }

    /// Runs one step of a test, naming it in the error if it throws something unexpected.
    static func step<T>(_ label: String, _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure(description: "\(label): \(error)")
        }
    }

    /// A new folder in the working folder holding these text files: each test makes its own,
    /// so one failing doesn't take the next ones with it.
    func folder(_ name: String, files: [String: String]) async throws -> RemoteRef {
        let dir = remote.appending(name)
        try await fs.makeDirectory(dir)
        for (file, text) in files.sorted(by: { $0.key < $1.key }) {
            try await fs.upload(try makeLocal("\(name)-\(file)", text: text), to: dir.appending(file), modified: nil) { _ in }
        }
        return dir
    }

    // MARK: Tests

    typealias Test = (name: String, run: () async throws -> Void)

    var manyCount: Int { quick ? 60 : 300 }

    /// Skips the slow ones (hundreds of files) for a fast check.
    var quick = false

    func tests() -> [Test] {
        var list: [Test] = [
            ("folder: create and list empty", {
                let dir = remote.appending("empty")
                try await fs.makeDirectory(dir)
                let entries = try await listing(dir, on: fs)
                try Self.check(entries.isEmpty, "expected empty, got \(entries.count)")
                let top = try await listing(remote, on: fs)
                try Self.check(top["empty"]?.isDirectory == true, "new folder not listed as a folder")
            }),
            ("upload: size kept; date kept, or the phone is reported not to keep it", {
                let source = try makeLocal("dated.bin", size: 4096)
                let date = Date(timeIntervalSince1970: 1_700_000_000)
                try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: source.path)
                try await fs.upload(source, to: remote.appending("dated.bin"), modified: date) { _ in }
                let entry = try await listing(remote, on: fs)["dated.bin"]
                try Self.check(entry?.size == 4096, "size \(String(describing: entry?.size))")
                let delta = abs((entry?.modified ?? .distantPast).timeIntervalSince(date))
                // Some phones stamp uploads with the upload time and can't be told otherwise;
                // then the connection must say so, so comparisons don't rely on the date.
                try Self.check(delta <= ExistingItem.dateTolerance || !fs.capabilities.keepsUploadDates,
                               "date off by \(Int(delta)) s and the connection still claims to keep dates")
                if delta > 2 { print("    (this phone doesn't keep upload dates)") }
            }),
            ("date probe matches what an upload does", {
                let kept = try await fs.probeKeepsUploadDates(in: remote)
                let source = try makeLocal("probe-check.bin", size: 10)
                let date = Date(timeIntervalSince1970: 1_600_000_000)
                try await fs.upload(source, to: remote.appending("probe-check.bin"), modified: date) { _ in }
                let stored = try await listing(remote, on: fs)["probe-check.bin"]?.modified
                let actuallyKept = stored.map { abs($0.timeIntervalSince(date)) <= ExistingItem.dateTolerance } ?? false
                try Self.check(kept == actuallyKept, "probe said \(kept), upload kept: \(actuallyKept)")
                try await noLeftovers(remote, on: fs)
                let probes = try await listing(remote, on: fs).keys.filter { $0.contains("dateprobe") }
                try Self.check(probes.isEmpty, "probe file left: \(probes)")
            }),
            ("folder dates: a folder with a file in it takes the date it's given, where the connection can", {
                let dir = remote.appending("dated folder")
                try await fs.makeDirectory(dir)
                try await fs.upload(try makeLocal("in-dated.bin", size: 10), to: dir.appending("in-dated.bin"), modified: nil) { _ in }
                guard fs.capabilities.setsFolderDates else {
                    print("    (this connection can't date folders)")
                    return
                }
                let date = Date(timeIntervalSince1970: 1_500_000_000)
                try await fs.setFolderDates([dir.path: date])
                let entry = try await listing(remote, on: fs)["dated folder"]
                let delta = abs((entry?.modified ?? .distantPast).timeIntervalSince(date))
                try Self.check(delta <= ExistingItem.dateTolerance, "folder date off by \(Int(delta)) s")
            }),
            ("transfer: exact bytes at packet and chunk boundaries", {
                // 512/1024: USB packet sizes; 8 MB: download chunk; 1 MB: upload chunk.
                for size in [0, 1, 511, 512, 513, 1023, 1024, 1_048_564, 1_048_576, 8_388_096, 8_388_608, 8_388_609] {
                    let source = try makeLocal("b\(size).bin", size: size)
                    let target = remote.appending("b\(size).bin")
                    try await fs.upload(source, to: target, modified: nil) { _ in }
                    let back = try await read(target, on: fs)
                    try Self.check(back == (try Data(contentsOf: source)), "\(size) bytes came back different (\(back.count))")
                }
            }),
            ("read into memory (the viewer): exact bytes; a limit stops it", {
                // The files of the test above, read the way the viewer does, with no file here.
                for size in [0, 1, 512, 1_048_576, 8_388_609] {
                    let entry = try await fs.entry(at: remote.appending("b\(size).bin"))
                    let data = try await RemoteContents.data(of: entry, from: fs, limit: 10_000_000) { _ in }
                    let original = try Data(contentsOf: local.appendingPathComponent("b\(size).bin"))
                    try Self.check(data == original, "\(size) bytes read into memory differ (\(data.count))")
                }
                let big = try await fs.entry(at: remote.appending("b8388609.bin"))
                do {
                    _ = try await RemoteContents.data(of: big, from: fs, limit: 1_000_000) { _ in }
                    throw Failure(description: "8 MB read in full past a 1 MB limit")
                } catch is RemoteContents.TooLarge {}
                // The connection still answers after reading stopped halfway.
                _ = try await listing(remote, on: fs)
            }),
            ("range reads (playing media): exact bytes, to the end; stopping one leaves the phone usable", {
                let entry = try await fs.entry(at: remote.appending("b8388609.bin"))
                let original = try Data(contentsOf: local.appendingPathComponent("b8388609.bin"))
                let size = UInt64(original.count)
                let ranges: [Range<UInt64>] = [0..<1, 0..<1000, 511..<1537, 1_048_575..<2_097_153,
                                               size - 609..<size, size - 1..<size, 0..<size]
                for range in ranges {
                    let parts = OSAllocatedUnfairLock(initialState: Data())
                    try await fs.read(entry, range: range) { data in parts.withLock { $0.append(data) } }
                    let data = parts.withLock { $0 }
                    try Self.check(data == original[Int(range.lowerBound)..<Int(range.upperBound)],
                                   "\(range): \(data.count) bytes, not the file's")
                }
                // A player drops what it asked for when it jumps elsewhere.
                let first = AsyncStream<Void>.makeStream()
                let device = fs, started = first.continuation
                let reading = Task {
                    try await device.read(entry, range: 0..<size) { _ in started.finish() }
                }
                for await _ in first.stream {}
                reading.cancel()
                _ = await reading.result
                let parts = OSAllocatedUnfairLock(initialState: Data())
                try await fs.read(entry, range: 4096..<8192) { data in parts.withLock { $0.append(data) } }
                try Self.check(parts.withLock { $0 } == original[4096..<8192], "a range after a stopped one differs")
            }),
            ("names: names Android refuses are rejected up front", {
                let source = try makeLocal("name.txt", text: "x")
                for name in ["q\"uote.txt", "a:b.txt", "a*b.txt", "a?b.txt", "a<b.txt", "a|b.txt", "a\\b.txt"] {
                    do {
                        try await fs.upload(source, to: remote.appending(name), modified: nil) { _ in }
                        throw Failure(description: "uploaded \(name)")
                    } catch DeviceFSError.invalidName {}
                }
                try await noLeftovers(remote, on: fs)
            }),
            ("names: spaces, quote, $, backtick, Korean, emoji, long, hidden", {
                let names = ["with space.txt", "it's.txt", "$HOME `x`.txt", "한글 파일.txt", "emoji 📷.txt",
                             String(repeating: "n", count: 200) + ".txt", ".hidden"]
                for name in names {
                    let source = try makeLocal("name.txt", text: name)
                    try await fs.upload(source, to: remote.appending(name), modified: nil) { _ in }
                }
                let entries = try await listing(remote, on: fs)
                for name in names {
                    try Self.check(entries[name] != nil, "not listed: \(name)")
                    let back = try await read(remote.appending(name), on: fs)
                    try Self.check(String(decoding: back, as: UTF8.self) == name, "wrong content: \(name)")
                }
            }),
            ("overwrite: new content, no temporary files", {
                let target = remote.appending("over.txt")
                try await fs.upload(try makeLocal("old.txt", text: "OLD"), to: target, modified: nil) { _ in }
                try await fs.upload(try makeLocal("new.txt", text: "NEW"), to: target, modified: nil) { _ in }
                try Self.check(try await read(target, on: fs) == Data("NEW".utf8), "content not replaced")
                try await noLeftovers(remote, on: fs)
            }),
            ("overwrite: failed upload keeps the original", {
                let target = remote.appending("keep.txt")
                try await fs.upload(try makeLocal("keep.txt", text: "ORIGINAL"), to: target, modified: nil) { _ in }
                let unreadable = try makeLocal("locked.txt", text: "x")
                try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
                defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadable.path) }
                do {
                    try await fs.upload(unreadable, to: target, modified: nil) { _ in }
                    throw Failure(description: "upload of an unreadable file succeeded")
                } catch is Failure { throw Failure(description: "upload of an unreadable file succeeded") } catch {}
                try Self.check(try await read(target, on: fs) == Data("ORIGINAL".utf8), "original changed")
                try await noLeftovers(remote, on: fs)
            }),
            ("upload as planned: replace, new, and a file that turned up isn't overwritten", {
                // The queue says from planning whether a file is there; every way of writing
                // must honour it (DeviceFileSystem.upload).
                for (index, writing) in [UploadWriting.safe, .directForNewFiles, .direct, .keepingReplaced].enumerated() {
                    let fresh = remote.appending("plan-new-\(index).txt")
                    try await Self.step("\(writing): new file") {
                        try await fs.upload(try makeLocal("n\(index).txt", text: "NEW \(index)"), to: fresh, modified: nil,
                                            replacing: false, writing: writing) { _ in }
                    }
                    try Self.check(try await read(fresh, on: fs) == Data("NEW \(index)".utf8), "\(writing): new file wrong")

                    let replaced = remote.appending("plan-replace-\(index).txt")
                    try await fs.upload(try makeLocal("o\(index).txt", text: "OLD"), to: replaced, modified: nil) { _ in }
                    try await Self.step("\(writing): replace") {
                        try await fs.upload(try makeLocal("r\(index).txt", text: "REPLACED \(index)"), to: replaced, modified: nil,
                                            replacing: true, writing: writing) { _ in }
                    }
                    try Self.check(try await read(replaced, on: fs) == Data("REPLACED \(index)".utf8), "\(writing): not replaced")

                    let appeared = remote.appending("plan-appeared-\(index).txt")
                    try await fs.upload(try makeLocal("a\(index).txt", text: "THERE FIRST"), to: appeared, modified: nil) { _ in }
                    do {
                        try await fs.upload(try makeLocal("b\(index).txt", text: "SENT LATER"), to: appeared, modified: nil,
                                            replacing: false, writing: writing) { _ in }
                        throw Failure(description: "\(writing): a file that turned up was overwritten")
                    } catch DeviceFSError.alreadyExists {
                    } catch let failure as Failure {
                        throw failure
                    } catch {
                        throw Failure(description: "\(writing): file that turned up: \(error)")
                    }
                    try Self.check(try await read(appeared, on: fs) == Data("THERE FIRST".utf8), "\(writing): file that turned up changed")
                }
                try await noLeftovers(remote, on: fs)
            }),
            ("replacing: the file keeps its date, also once it has been read", {
                // Renamed over a file, a Galaxy gives it the time it's first read (QUIRKS A23).
                guard fs.capabilities.keepsUploadDates else {
                    print("    (this phone doesn't keep upload dates)")
                    return
                }
                let date = Date(timeIntervalSince1970: 1_500_000_000)
                for (index, writing) in [UploadWriting.safe, .direct, .keepingReplaced].enumerated() {
                    let target = remote.appending("dated-\(index).txt")
                    try await fs.upload(try makeLocal("dated-old-\(index).txt", text: "OLD"), to: target, modified: nil) { _ in }
                    try await fs.upload(try makeLocal("dated-new-\(index).txt", text: "NEW \(index)"), to: target, modified: date,
                                        replacing: true, writing: writing) { _ in }
                    try Self.check(try await read(target, on: fs) == Data("NEW \(index)".utf8), "\(writing): not replaced")
                    let entry = try await listing(remote, on: fs)["dated-\(index).txt"]
                    let delta = abs((entry?.modified ?? .distantPast).timeIntervalSince(date))
                    try Self.check(delta <= ExistingItem.dateTolerance, "\(writing): date off by \(Int(delta)) s after reading it")
                }
            }),
            ("replacing into the file there: new contents, still the same file, where the connection can", {
                let target = remote.appending("kept.txt")
                try await fs.upload(try makeLocal("kept-old.txt", text: "OLD"), to: target, modified: nil) { _ in }
                let before = try await fileIdentity(target, on: fs)
                try await fs.upload(try makeLocal("kept-new.txt", text: "NEW CONTENTS"), to: target, modified: nil,
                                    replacing: true, writing: .keepingReplaced) { _ in }
                try Self.check(try await read(target, on: fs) == Data("NEW CONTENTS".utf8), "not replaced")
                try await noLeftovers(remote, on: fs)
                guard let before else {
                    print("    (this connection replaces the file)")
                    return
                }
                let after = try await fileIdentity(target, on: fs)
                try Self.check(after == before, "a new file took its place (inode \(before) → \(after.map(String.init) ?? "none"))")
            }),
            ("names differing only in case: the file there isn't overwritten", {
                // Phone storage ignores case (QUIRKS S7): "Note.TXT" is where "note.txt" is.
                let dir = try await folder("case", files: ["note.txt": "THERE", "other.txt": "OTHER"])
                for (index, writing) in [UploadWriting.safe, .directForNewFiles, .direct, .keepingReplaced].enumerated() {
                    do {
                        try await fs.upload(try makeLocal("c\(index).txt", text: "SENT \(index)"), to: dir.appending("NOTE.txt"),
                                            modified: nil, replacing: false, writing: writing) { _ in }
                    } catch DeviceFSError.alreadyExists {}
                    try Self.check(try await read(dir.appending("note.txt"), on: fs) == Data("THERE".utf8), "\(writing): upload replaced it")
                }
                do { _ = try await fs.rename(dir.appending("other.txt"), to: "Note.txt") } catch DeviceFSError.alreadyExists {}
                try Self.check(try await read(dir.appending("note.txt"), on: fs) == Data("THERE".utf8), "rename replaced it")
                do {
                    try await fs.copyOnDevice(dir.appending("other.txt"), to: dir.appending("NoTe.txt"), replacing: false)
                } catch DeviceFSError.alreadyExists {}
                try Self.check(try await read(dir.appending("note.txt"), on: fs) == Data("THERE".utf8), "copy replaced it")
                let names = try await listing(dir, on: fs).keys.sorted()
                try Self.check(names == ["note.txt", "other.txt"], "left: \(names)")
                // Changing only the case renames it (a direct rename leaves the name as it was).
                _ = try await fs.rename(dir.appending("note.txt"), to: "Note.txt")
                let renamed = try await listing(dir, on: fs).keys.sorted()
                try Self.check(renamed == ["Note.txt", "other.txt"], "after a case change: \(renamed)")
                try Self.check(try await read(dir.appending("Note.txt"), on: fs) == Data("THERE".utf8), "case change lost the contents")
            }),
            ("leftovers tidied: partial and replaced original go, unreplaced original and cut-off moves are restored", {
                // As interrupted transfers leave them (QUIRKS M13); the queue tidies when planning.
                let dir = remote.appending("leftovers")
                try await fs.makeDirectory(dir)
                try await fs.upload(try makeLocal("placed.txt", text: "NEW"), to: dir.appending("placed.txt"), modified: nil) { _ in }
                try await fs.upload(try makeLocal("old1.txt", text: "OLD"), to: dir.appending(WorkNames.aside("placed.txt")), modified: nil) { _ in }
                try await fs.upload(try makeLocal("old2.txt", text: "ONLY COPY"), to: dir.appending(WorkNames.aside("lost.txt")), modified: nil) { _ in }
                try await fs.upload(try makeLocal("part.txt", text: "HALF"), to: dir.appending(WorkNames.step("part")), modified: nil) { _ in }
                // A move on the phone cut off while the item had its hidden name (QUIRKS M15): a
                // file, one whose name is taken there meanwhile, and a folder with its contents.
                try await fs.upload(try makeLocal("moved.txt", text: "MOVED"), to: dir.appending(WorkNames.moving("moved.txt")), modified: nil) { _ in }
                try await fs.upload(try makeLocal("clash.txt", text: "CLASH"), to: dir.appending(WorkNames.moving("placed.txt")), modified: nil) { _ in }
                let folder = dir.appending(WorkNames.moving("album"))
                try await fs.makeDirectory(folder)
                try await fs.upload(try makeLocal("inside.txt", text: "INSIDE"), to: folder.appending("inside.txt"), modified: nil) { _ in }
                let after = await fs.tidyLeftovers(try await listing(dir, on: fs))
                let names = Set(try await listing(dir, on: fs).keys)
                try Self.check(names == ["placed.txt", "lost.txt", "moved.txt", "placed (1).txt", "album"] && Set(after.keys) == names,
                               "left: \(names.sorted())")
                try Self.check(try await read(dir.appending("placed.txt"), on: fs) == Data("NEW".utf8), "replacement changed")
                try Self.check(try await read(dir.appending("lost.txt"), on: fs) == Data("ONLY COPY".utf8), "original not restored")
                try Self.check(try await read(dir.appending("moved.txt"), on: fs) == Data("MOVED".utf8), "moved file not restored")
                try Self.check(try await read(dir.appending("placed (1).txt"), on: fs) == Data("CLASH".utf8), "moved file next to its name")
                try Self.check(try await read(dir.appending("album").appending("inside.txt"), on: fs) == Data("INSIDE".utf8),
                               "moved folder's contents")
            }),
            ("names: a name near the limit uploads and replaces (its work names fit too)", {
                // 244 bytes: allowed, but with a temporary name's additions it wouldn't be.
                let name = String(repeating: "가", count: 80) + ".txt"
                let target = remote.appending(name)
                try await fs.upload(try makeLocal("long1.txt", text: "FIRST"), to: target, modified: nil) { _ in }
                try await fs.upload(try makeLocal("long2.txt", text: "SECOND"), to: target, modified: nil,
                                    replacing: true, writing: .safe) { _ in }
                try Self.check(try await read(target, on: fs) == Data("SECOND".utf8), "long name not replaced")
                try await noLeftovers(remote, on: fs)
            }),
            ("many long Korean names: hashes, bundled download and delete stay under adb's request limit", {
                // Over ADB these go as shell commands of many paths; 300 paths of 80 Korean
                // letters (3 bytes each) would make one request over 64 KB if measured in
                // characters. MTP has no such commands.
                guard transport == "adb" else { return }
                let dir = remote.appending("longnames")
                try await fs.makeDirectory(dir)
                let source = try makeLocal("ln.txt", text: "same")
                let stem = String(repeating: "가", count: 80)
                let refs = (0..<300).map { dir.appending("\(stem)-\($0).txt") }
                for ref in refs { try await fs.upload(source, to: ref, modified: nil) { _ in } }
                if fs.capabilities.deviceHashing {
                    let hashes = try await fs.contentHashes(refs)
                    try Self.check(hashes.count == refs.count, "hashes for \(hashes.count) of \(refs.count)")
                }
                let entries = try await listing(dir, on: fs).values.sorted { $0.name < $1.name }
                let into = local.appendingPathComponent("longnames")
                try FileManager.default.createDirectory(at: into, withIntermediateDirectories: true)
                let items = entries.enumerated().map { DownloadItem($1, to: into.appendingPathComponent("\($0).txt"), replacing: nil) }
                let failures = OSAllocatedUnfairLock(initialState: 0)
                try await fs.downloadBundled(items, progress: { _ in }) { _, error in if error != nil { failures.withLock { $0 += 1 } } }
                let failed = failures.withLock { $0 }
                try Self.check(failed == 0 && (try FileManager.default.contentsOfDirectory(atPath: into.path).count) == refs.count,
                               "bundled download: \(failed) failed")
                try await fs.delete(refs)
                try Self.check(try await listing(dir, on: fs).isEmpty, "not all deleted")
            }),
            ("rename: a hidden folder made visible keeps its files' names, and tidying leaves them", {
                // Files renamed inside a hidden folder (each upload ends with a rename) can be
                // listed under their earlier names once it's visible: a partial's (QUIRKS G11).
                let dir = remote.appending(".stash")
                try await fs.makeDirectory(dir)
                for n in 1...5 {
                    try await fs.upload(try makeLocal("f\(n).txt", text: "FILE \(n)"), to: dir.appending("f\(n).txt"), modified: nil) { _ in }
                }
                let visible = try await fs.rename(dir, to: "unhidden")
                let names = ["f1.txt", "f2.txt", "f3.txt", "f4.txt", "f5.txt"]
                let listed = try await listing(visible, on: fs).keys.sorted()
                try Self.check(listed == names, "listed: \(listed)")
                _ = await fs.tidyLeftovers(try await listing(visible, on: fs))
                for (n, name) in names.enumerated() {
                    try Self.check(try await read(visible.appending(name), on: fs) == Data("FILE \(n + 1)".utf8), "\(name) after tidying")
                }
            }),
            ("rename: free name, taken name refused, bad name refused", {
                let a = remote.appending("ren-a.txt"), b = remote.appending("ren-b.txt")
                try await fs.upload(try makeLocal("a.txt", text: "A"), to: a, modified: nil) { _ in }
                try await fs.upload(try makeLocal("b.txt", text: "B"), to: b, modified: nil) { _ in }
                do {
                    _ = try await fs.rename(a, to: "ren-b.txt")
                    throw Failure(description: "rename onto an existing name succeeded")
                } catch DeviceFSError.alreadyExists {}
                do {
                    _ = try await fs.rename(a, to: "x/y")
                    throw Failure(description: "rename to a name with / succeeded")
                } catch DeviceFSError.invalidName {}
                let renamed = try await fs.rename(a, to: "ren-c.txt")
                try Self.check(try await read(renamed, on: fs) == Data("A".utf8), "renamed file content")
                try Self.check(try await read(b, on: fs) == Data("B".utf8), "other file changed")
            }),
            ("copy on the phone: file onto an existing file", {
                let src = remote.appending("src"), dst = remote.appending("dst")
                try await fs.makeDirectory(src)
                try await fs.makeDirectory(dst)
                try await fs.upload(try makeLocal("f.txt", text: "SRC"), to: src.appending("f.txt"), modified: nil) { _ in }
                try await fs.upload(try makeLocal("g.txt", text: "OLD"), to: dst.appending("f.txt"), modified: nil) { _ in }
                try await fs.copyOnDevice(src.appending("f.txt"), to: dst.appending("f.txt"))
                try Self.check(try await read(dst.appending("f.txt"), on: fs) == Data("SRC".utf8), "copy didn't replace")
                try Self.check(try await read(src.appending("f.txt"), on: fs) == Data("SRC".utf8), "copy changed the source")
                try await noLeftovers(dst, on: fs)
            }),
            ("copy and move on the phone as planned: replace, new, keep both", {
                // The queue says from planning what's at the destination (copyOnDevice and
                // moveOnDevice with `replacing`), as for uploads.
                let src = try await folder("plan-src", files: ["a.txt": "NEW A", "b.txt": "NEW B", "c.txt": "NEW C"])
                let dst = try await folder("plan-dst", files: ["a.txt": "OLD A", "c.txt": "OLD C"])
                try await Self.step("copy onto a file there") {
                    try await fs.copyOnDevice(src.appending("a.txt"), to: dst.appending("a.txt"), replacing: true)
                }
                try Self.check(try await read(dst.appending("a.txt"), on: fs) == Data("NEW A".utf8), "not replaced")
                try await Self.step("copy to a free name") {
                    try await fs.copyOnDevice(src.appending("b.txt"), to: dst.appending("b.txt"), replacing: false)
                }
                try Self.check(try await read(dst.appending("b.txt"), on: fs) == Data("NEW B".utf8), "new copy wrong")
                // Planned as new, but a file turned up there since: it stays.
                do {
                    try await fs.copyOnDevice(src.appending("a.txt"), to: dst.appending("b.txt"), replacing: false)
                    throw Failure(description: "copy planned as new replaced a file that turned up")
                } catch DeviceFSError.alreadyExists {}
                try Self.check(try await read(dst.appending("b.txt"), on: fs) == Data("NEW B".utf8), "file that turned up changed")
                // Keep both: moved in under another name, the one there stays.
                try await Self.step("move in under another name") {
                    try await fs.moveOnDevice(src.appending("c.txt"), to: dst.appending("c (1).txt"), replacing: false)
                }
                try Self.check(try await read(dst.appending("c (1).txt"), on: fs) == Data("NEW C".utf8), "moved file wrong")
                try Self.check(try await read(dst.appending("c.txt"), on: fs) == Data("OLD C".utf8), "the one there changed")
                try Self.check(try await listing(src, on: fs)["c.txt"] == nil, "move left the source")
                try await noLeftovers(dst, on: fs)
            }),
            ("copy on the phone: folder", {
                let src = try await folder("cpdir", files: ["f.txt": "SRC"])
                try await fs.copyOnDevice(src, to: remote.appending("cpdir-copy"))
                try Self.check(try await read(remote.appending("cpdir-copy/f.txt"), on: fs) == Data("SRC".utf8), "folder copy")
            }),
            ("move on the phone: file onto an existing file, renamed", {
                let src = try await folder("mv-src", files: ["f.txt": "SRC"])
                let dst = try await folder("mv-dst", files: ["m.txt": "OLD2"])
                try await fs.moveOnDevice(src.appending("f.txt"), to: dst.appending("m.txt"))
                try Self.check(try await read(dst.appending("m.txt"), on: fs) == Data("SRC".utf8), "move didn't replace")
                try Self.check(try await listing(src, on: fs)["f.txt"] == nil, "move left the source")
                try await noLeftovers(dst, on: fs)
            }),
            ("move on the phone: folder, renamed", {
                let src = try await folder("mvdir", files: ["f.txt": "SRC"])
                let dst = try await folder("mvdir-into", files: [:])
                try await fs.moveOnDevice(src, to: dst.appending("moved-folder"))
                try Self.check(try await read(dst.appending("moved-folder/f.txt"), on: fs) == Data("SRC".utf8), "folder move")
                try Self.check(try await listing(remote, on: fs)["mvdir"] == nil, "folder still at the source")
            }),
            ("listing: \(manyCount) files with sizes", {
                let dir = remote.appending("many")
                try await fs.makeDirectory(dir)
                let source = try makeLocal("small.bin", size: 100)
                for i in 0..<manyCount { try await fs.upload(source, to: dir.appending("f\(i).bin"), modified: nil) { _ in } }
                let entries = try await listing(dir, on: fs)
                try Self.check(entries.count == manyCount, "listed \(entries.count) of \(manyCount)")
                try Self.check(entries.values.allSatisfy { $0.size == 100 }, "sizes missing or wrong")
            }),
            ("download: a write that fails on this Mac fails the file; phone usable after", {
                // Files on this Mac can't grow past 1 MB for a moment (as with a full disk).
                let file = remote.appending("big-down.bin")
                try await fs.upload(try makeLocal("big-down.bin", size: 8 << 20), to: file, modified: nil) { _ in }
                let entry = try await fs.entry(at: file)
                let out = local.appendingPathComponent("capped.bin")
                var original = rlimit()
                getrlimit(RLIMIT_FSIZE, &original)
                signal(SIGXFSZ, SIG_IGN)
                var capped = original
                capped.rlim_cur = 1 << 20
                setrlimit(RLIMIT_FSIZE, &capped)
                var failed = false
                do { try await fs.download(entry, to: out) { _ in } } catch { failed = true }
                setrlimit(RLIMIT_FSIZE, &original)
                try Self.check(failed, "the download didn't fail")
                // The connection still answers properly.
                try Self.check(try await read(file, on: fs).count == 8 << 20, "reading after the failed download")
            }),
            ("upload: a file that shrinks while it's sent; phone usable after", {
                let source = try makeLocal("shrinks.bin", size: 64 << 20)
                let target = remote.appending("shrinks.bin")
                let shrink = Task {
                    try? await Task.sleep(for: .milliseconds(30))
                    truncate(source.path, 1 << 20)
                }
                do { try await fs.upload(source, to: target, modified: nil) { _ in } } catch {}
                _ = await shrink.value
                // Whatever became of it (ADB stores what came; MTP refuses it), the phone answers
                // and nothing temporary is left.
                let after = remote.appending("after-shrink.txt")
                try await fs.upload(try makeLocal("after-shrink.txt", text: "AFTER"), to: after, modified: nil) { _ in }
                try Self.check(try await read(after, on: fs) == Data("AFTER".utf8), "a transfer after it")
                try await noLeftovers(remote, on: fs)
            }),
            ("batch download: one bad destination fails alone", {
                let dir = try await folder("batch", files: Dictionary(uniqueKeysWithValues: (0..<20).map { ("f\($0).txt", "file \($0)") }))
                let entries = try await listing(dir, on: fs).values.sorted { $0.name < $1.name }
                let out = local.appendingPathComponent("batch")
                try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                // A folder where one file should go: that file can't be written.
                try FileManager.default.createDirectory(at: out.appendingPathComponent(entries.first!.name), withIntermediateDirectories: true)
                let failures = OSAllocatedUnfairLock(initialState: [Int]())
                try await fs.downloadMany(entries.map { DownloadItem($0, to: out.appendingPathComponent($0.name), replacing: nil) }, progress: { _ in }) { i, error in
                    if error != nil { failures.withLock { $0.append(i) } }
                }
                let failed = failures.withLock { $0 }
                try Self.check(failed == [0], "failed items: \(failed)")
                let written = try FileManager.default.contentsOfDirectory(atPath: out.path).filter { !$0.hasPrefix(".") }
                try Self.check(written.count == entries.count, "\(written.count) entries on disk")
            }),
            ("delete: file and folder with contents", {
                let dir = try await folder("del", files: ["a.txt": "A", "b.txt": "B"])
                try await fs.makeDirectory(dir.appending("inner"))
                try await fs.upload(try makeLocal("del-c.txt", text: "C"), to: dir.appending("inner/c.txt"), modified: nil) { _ in }
                try await fs.upload(try makeLocal("del-file.txt", text: "F"), to: remote.appending("del-file.txt"), modified: nil) { _ in }
                try await fs.delete([dir, remote.appending("del-file.txt")])
                let entries = try await listing(remote, on: fs)
                try Self.check(entries["del"] == nil && entries["del-file.txt"] == nil, "still listed")
            }),
        ]
        if fs.capabilities.deviceHashing {
            list.append(("hashes on the phone match", {
                let source = try makeLocal("hash.bin", size: 100_000)
                let target = remote.appending("hash.bin")
                try await fs.upload(source, to: target, modified: nil) { _ in }
                let hashes = try await fs.contentHashes([target])
                try Self.check(hashes[target.path] == (try localMD5(of: source)), "md5 differs: \(String(describing: hashes[target.path]))")
            }))
        }
        return list
    }

    /// Kills a separate upload process mid-file (as an app quit or crash would), then checks
    /// the original is intact and the phone can be used again.
    func interruptedUploadTest(on fs: inout any DeviceFileSystem) async throws {
        guard let spawnUpload, let reconnect else { return }
        let target = remote.appending("interrupted.txt")
        try await fs.upload(try makeLocal("orig.txt", text: "ORIGINAL"), to: target, modified: nil) { _ in }
        let big = try makeLocal("big.bin", size: 200 << 20)
        release?() // MTP: the child process needs the interface
        let child = spawnUpload(target.path, big)
        let output = Pipe()
        child.standardOutput = output
        try child.run()
        // Kill it once part of the file is out (not on a timer: a fast phone finishes 200 MB
        // in a couple of seconds, and then there's nothing left to interrupt).
        var sent = 0
        for try await line in output.fileHandleForReading.bytes.lines {
            sent = Int(line) ?? sent
            if sent >= 8 << 20 { break }
        }
        kill(child.processIdentifier, SIGKILL)
        child.waitUntilExit()
        try Self.check(sent >= 8 << 20 && sent < 200 << 20, "the upload wasn't caught midway (\(sent) bytes)")
        fs = try await reconnect()
        try Self.check(try await read(target, on: fs) == Data("ORIGINAL".utf8), "original lost or changed")
        try await fs.upload(try makeLocal("after.txt", text: "AFTER"), to: target, modified: nil) { _ in }
        // What the interrupted upload left (MTP keeps it; adbd removes it itself) is tidied
        // the way the queue does when it lists a folder to plan.
        _ = await fs.tidyLeftovers(try await listing(remote, on: fs))
        try Self.check(try await read(target, on: fs) == Data("AFTER".utf8), "upload after the interruption")
        try await noLeftovers(remote, on: fs)
    }
}

/// Runs the suite and prints one line per test; returns false if any failed.
func runDeviceTests(transport: String, serial: String, quick: Bool,
                    open: @escaping () async throws -> any DeviceFileSystem,
                    release: @escaping (any DeviceFileSystem) -> Void,
                    spawnUpload: @escaping (String, URL) -> Process) async throws -> Bool {
    var fs = try await open()
    let stamp = Int(Date().timeIntervalSince1970)
    let remote = RemoteRef(path: "/sdcard/Download/\(WorkNames.tag)-devtest-\(stamp)")
    let local = WorkNames.scratch("devtest")
    try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: local) }
    try await fs.makeDirectory(remote)
    print("device \(serial) via \(transport), working in \(remote.path)")

    var failed = 0
    func report(_ name: String, _ body: () async throws -> Void) async {
        let start = ContinuousClock.now
        do {
            try await body()
            print("  ✔︎ \(name) (\(start.duration(to: .now).formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow))))")
        } catch {
            failed += 1
            print("  ✘ \(name): \(error)")
        }
    }

    let current = fs
    var suite = DeviceTestSuite(fs: current, transport: transport, remote: remote, local: local,
                                reconnect: open, release: { release(current) }, spawnUpload: spawnUpload)
    suite.quick = quick
    // XFER_DEVTEST_ONLY=text runs only the tests whose name contains it.
    let only = ProcessInfo.processInfo.environment["XFER_DEVTEST_ONLY"]
    func wanted(_ name: String) -> Bool { only.map { name.localizedCaseInsensitiveContains($0) } ?? true }
    for test in suite.tests() where wanted(test.name) { await report(test.name, test.run) }
    let interrupted = "interrupted upload keeps the original; phone usable after"
    if wanted(interrupted) {
        await report(interrupted) { try await suite.interruptedUploadTest(on: &fs) }
    }
    if transport == "mtp", wanted("a connection given up on stops quickly; phone usable after") {
        await report("a connection given up on stops quickly; phone usable after") {
            // The app gives up on an MTP connection that's waiting when it switches to ADB.
            release(fs)
            let start = ContinuousClock.now
            let opener = UnsafeOpen(open: open)
            let attempt = Task { try await opener.open() }
            try await Task.sleep(for: .milliseconds(30))
            attempt.cancel()
            if let opened = try? await attempt.value { release(opened) } // finished before the cancel
            let took = start.duration(to: .now)
            fs = try await open()
            try DeviceTestSuite.check(took < .seconds(3), "giving up took \(took)")
            _ = try await suite.listing(remote, on: fs)
        }
    }
    // XFER_DEVTEST_KEEP=1 leaves the folder on the phone when something failed, to look at.
    if failed > 0, ProcessInfo.processInfo.environment["XFER_DEVTEST_KEEP"] != nil {
        print("kept \(remote.path)")
        return false
    }
    // Clean up on the phone whatever happened (reconnecting if a test left no connection).
    do {
        do {
            try await fs.delete([remote])
        } catch {
            release(fs)
            fs = try await open()
            try await fs.delete([remote])
        }
        print("removed \(remote.path)")
    } catch {
        print("couldn't remove \(remote.path): \(error) — delete it on the phone")
    }
    release(fs)
    print(failed == 0 ? "all passed" : "\(failed) failed")
    return failed == 0
}

/// Lets the test start an open in a task of its own and cancel it; the suite awaits it before
/// going on, so nothing runs concurrently with it.
private struct UnsafeOpen: @unchecked Sendable {
    let open: () async throws -> any DeviceFileSystem
}

/// Helpers both suites use: files made on this Mac in `local`, and reading what a phone has.
protocol DeviceTestHelpers {
    var local: URL { get }
}

extension DeviceTestHelpers {
    func makeLocal(_ name: String, size: Int) throws -> URL {
        let url = local.appendingPathComponent(name)
        var bytes = [UInt8](repeating: 0, count: size)
        for i in 0..<size { bytes[i] = UInt8.random(in: 0...255) }
        try Data(bytes).write(to: url)
        return url
    }

    func makeLocal(_ name: String, text: String) throws -> URL {
        let url = local.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    /// Over ADB, the file's inode: the same file while it's the same number. Nil elsewhere.
    func fileIdentity(_ ref: RemoteRef, on fs: any DeviceFileSystem) async throws -> UInt64? {
        guard let adb = fs as? AdbFileSystem else { return nil }
        let quoted = "'" + ref.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let printed = String(decoding: try await adb.client.exec(serial: adb.serial, "stat -c %i -- \(quoted)"), as: UTF8.self)
        guard let inode = UInt64(printed.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw DeviceTestSuite.Failure(description: "no inode for \(ref.path): \(printed)")
        }
        return inode
    }

    func listing(_ dir: RemoteRef, on fs: any DeviceFileSystem) async throws -> [String: RemoteEntry] {
        Dictionary(try await fs.listAll(dir).map { ($0.name, $0) }, uniquingKeysWith: { _, later in later })
    }

    func read(_ ref: RemoteRef, on fs: any DeviceFileSystem) async throws -> Data {
        let entry = try await fs.entry(at: ref)
        let url = local.appendingPathComponent("read-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try await fs.download(entry, to: url) { _ in }
        return try Data(contentsOf: url)
    }

    func noLeftovers(_ dir: RemoteRef, on fs: any DeviceFileSystem) async throws {
        let names = try await listing(dir, on: fs).keys
        let leftovers = names.filter(WorkNames.isWorkFile)
        try DeviceTestSuite.check(leftovers.isEmpty, "temporary files left: \(leftovers.sorted())")
    }
}
