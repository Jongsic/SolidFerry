import DeviceCore
import Foundation
import os
import TransferKit

/// The two-device suite (`sferry devtest-pair A:adb B:mtp`): copying between phones the way the
/// app does (`DeviceToDevice`), deciding what to skip the way the app does (`ExistingItem`,
/// `FileDecision`), and both phones busy at once.
///
/// Safety: as the one-device suite, only /sdcard/Download/xfer-devtest-pair-… on each
/// phone, with generated files, deleted at the end with the local scratch folder.
struct PairTestSuite: DeviceTestHelpers {
    let a: any DeviceFileSystem
    let b: any DeviceFileSystem
    /// Working folders on A and B.
    let remoteA: RemoteRef
    let remoteB: RemoteRef
    let local: URL
    var quick = false

    typealias Test = DeviceTestSuite.Test

    private var smallCount: Int { quick ? 10 : 100 }
    private static let oldDate = Date(timeIntervalSince1970: 1_704_132_245) // 2024-01-02 03:04:05 +09:00
    private var sizesWrap: Bool { !a.capabilities.exactLargeSizes || !b.capabilities.exactLargeSizes }

    /// Generated files, by path below "src": a few kinds of size, a folder, an old date.
    private func makeSources() throws -> [(path: String, url: URL, modified: Date?)] {
        let folder = local.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
        var files: [(String, URL, Date?)] = []
        func add(_ path: String, _ data: Data, modified: Date? = nil) throws {
            let url = folder.appendingPathComponent(path)
            try data.write(to: url)
            files.append((path, url, modified))
        }
        for i in 1...smallCount { try add("s\(i).txt", Data("small \(i)\n".utf8)) }
        try add("big.bin", Data((0..<5_000_000).map { _ in UInt8.random(in: 0...255) }))
        try add("sub/deep.txt", Data("deep\n".utf8))
        try add("old.txt", Data("dated\n".utf8), modified: Self.oldDate)
        return files
    }

    /// Copies everything under `from` on `source` into `into` on `target`, as the app does.
    private func copyTree(_ from: RemoteRef, on source: any DeviceFileSystem,
                          into: RemoteRef, on target: any DeviceFileSystem) async throws -> TransferPlan {
        let root = try await source.entry(at: from)
        let plan = try await TransferPlanner.expand([root], in: source)
        for directory in plan.directories { try await target.makeDirectory(into.appending(directory)) }
        for file in plan.files {
            try await DeviceToDevice.copy(file.entry, from: source, to: into.appending(file.relativePath), on: target) { _ in }
        }
        return plan
    }

    /// The files under `dir` on `fs` by path below it ("sub/deep.txt").
    private func tree(_ dir: RemoteRef, on fs: any DeviceFileSystem) async throws -> [String: RemoteEntry] {
        let plan = try await TransferPlanner.expand([try await fs.entry(at: dir)], in: fs)
        return Dictionary(plan.files.map { (Self.belowRoot($0.relativePath), $0.entry) }, uniquingKeysWith: { a, _ in a })
    }

    /// "src/sub/deep.txt" → "sub/deep.txt".
    private static func belowRoot(_ relativePath: String) -> String {
        String(relativePath.drop { $0 != "/" }.dropFirst())
    }

    /// What the app would do with each file of `plan` already at `into` on B.
    private func decisions(_ plan: TransferPlan, into: RemoteRef, policy: TransferPolicy) async throws -> [String: FileDecision] {
        let there = try await tree(into.appending("src"), on: b)
        var result: [String: FileDecision] = [:]
        for file in plan.files {
            let item = ExistingItem.remote(there[Self.belowRoot(file.relativePath)], localSize: file.entry.size ?? 0, localModified: file.entry.modified,
                                           remoteSizeWraps: sizesWrap)
            result[file.relativePath] = FileDecision.decide(item, policy)
        }
        return result
    }

    func tests() throws -> [Test] {
        let sources = try makeSources()
        let srcA = remoteA.appending("src")
        let copied = remoteB.appending("copied")
        let check = DeviceTestSuite.check
        let original = { (path: String) in try Data(contentsOf: local.appendingPathComponent("src").appendingPathComponent(path)) }

        return [
            ("setup: files on A", {
                try await a.makeDirectory(srcA)
                try await a.makeDirectory(srcA.appending("sub"))
                for file in sources {
                    try await a.upload(file.url, to: srcA.appending(file.path), modified: file.modified) { _ in }
                }
                let there = try await tree(srcA, on: a)
                try check(there.count == sources.count, "\(there.count) of \(sources.count) files on A")
            }),
            ("copy A → B: exact bytes, folders kept", {
                try await b.makeDirectory(copied)
                let plan = try await copyTree(srcA, on: a, into: copied, on: b)
                try check(plan.files.count == sources.count, "planned \(plan.files.count) of \(sources.count)")
                for file in sources where file.path == "big.bin" || file.path == "sub/deep.txt" || file.path == "old.txt" || file.path == "s1.txt" {
                    let data = try await read(copied.appending("src/\(file.path)"), on: b)
                    try check(data == (try original(file.path)), "\(file.path) differs on B")
                }
                let sizes = try await tree(copied.appending("src"), on: b)
                for file in sources {
                    let expected = UInt64(try original(file.path).count)
                    try check(sizes[file.path]?.size == expected, "\(file.path): size \(String(describing: sizes[file.path]?.size)) on B, expected \(expected)")
                }
            }),
            ("copy A → B: progress adds up to exactly the size", {
                // Streamed, only what reaches B counts; through this Mac, half of each byte in
                // and half out.
                let entry = try await a.entry(at: srcA.appending("big.bin"))
                let counted = OSAllocatedUnfairLock(initialState: 0)
                try await DeviceToDevice.copy(entry, from: a, to: remoteB.appending("progress.bin"), on: b) { bytes in
                    counted.withLock { $0 += bytes }
                }
                let total = counted.withLock { $0 }
                try check(total == Int(entry.size ?? 0), "progress \(total) of \(entry.size ?? 0)")
            }),
            ("copy A → B: date kept, or B is reported not to keep it", {
                let keeps = try await b.probeKeepsUploadDates(in: remoteB)
                let entry = try await b.entry(at: copied.appending("src/old.txt"))
                // The date the file has on A: a phone that stamps uploads with their arrival
                // time (A over MTP on a Galaxy) didn't keep the one it was set up with.
                let onA = try await a.entry(at: srcA.appending("old.txt")).modified ?? Self.oldDate
                if keeps {
                    let delta = abs((entry.modified ?? .distantPast).timeIntervalSince(onA))
                    try check(delta <= ExistingItem.dateTolerance, "date off by \(Int(delta)) s on B, which reports keeping dates")
                } else {
                    print("    (B gives uploads the time they arrive; the app compares by size there)")
                }
            }),
            ("copy again: every file is the same and skipped", {
                let keeps = try await b.probeKeepsUploadDates(in: remoteB)
                let plan = try await TransferPlanner.expand([try await a.entry(at: srcA)], in: a)
                let policy = TransferPolicy(existing: .ifSizeOrDateDiffers, sizeOnlyMatch: !keeps)
                let decided = try await decisions(plan, into: copied, policy: policy)
                let notSkipped = decided.filter { $0.value != .skipIdentical }.keys.sorted()
                try check(notSkipped.isEmpty, "not skipped: \(notSkipped.prefix(5))")
            }),
            ("a file changed on B is found and replaced", {
                let changed = try makeLocal("changed.txt", text: "changed on B, longer than before\n")
                try await b.upload(changed, to: copied.appending("src/s2.txt"), modified: nil) { _ in }
                let keeps = try await b.probeKeepsUploadDates(in: remoteB)
                let plan = try await TransferPlanner.expand([try await a.entry(at: srcA)], in: a)
                let policy = TransferPolicy(existing: .ifSizeOrDateDiffers, whenDifferent: .overwrite, sizeOnlyMatch: !keeps)
                let decided = try await decisions(plan, into: copied, policy: policy)
                let toCopy = decided.filter { $0.value != .skipIdentical }.keys.sorted()
                try check(toCopy == ["src/s2.txt"], "would copy \(toCopy.prefix(5)), expected only src/s2.txt")
                guard let file = plan.files.first(where: { $0.relativePath == "src/s2.txt" }) else {
                    throw DeviceTestSuite.Failure(description: "s2.txt not planned")
                }
                try await DeviceToDevice.copy(file.entry, from: a, to: copied.appending("src/s2.txt"), on: b) { _ in }
                let data = try await read(copied.appending("src/s2.txt"), on: b)
                try check(data == (try original("s2.txt")), "s2.txt not replaced on B")
            }),
            ("both phones at once: download from A while uploading to B", {
                let big = local.appendingPathComponent("src/big.bin")
                let back = local.appendingPathComponent("big-from-A.bin")
                let entry = try await a.entry(at: srcA.appending("big.bin"))
                async let fromA: Void = a.download(entry, to: back) { _ in }
                async let toB: Void = b.upload(big, to: remoteB.appending("big-at-once.bin"), modified: nil) { _ in }
                _ = try await (fromA, toB)
                try check(try Data(contentsOf: back) == (try original("big.bin")), "download from A differs")
                let data = try await read(remoteB.appending("big-at-once.bin"), on: b)
                try check(data == (try original("big.bin")), "upload to B differs")
            }),
            ("copy B → A: exact bytes", {
                try await a.makeDirectory(remoteA.appending("back"))
                _ = try await copyTree(copied.appending("src/sub"), on: b, into: remoteA.appending("back"), on: a)
                let data = try await read(remoteA.appending("back/sub/deep.txt"), on: a)
                try check(data == (try original("sub/deep.txt")), "deep.txt differs on A")
            }),
            ("copy A → B stopped halfway (a pause): the whole file on B or none, both phones carry on", {
                // A pause cancels the copy. An ADB upload stops where it is and its partial
                // file goes; an MTP upload is one transaction and finishes, and keeps, the file.
                let file = try makeLocal("stopped.bin", size: 32 << 20)
                defer { try? FileManager.default.removeItem(at: file) }
                try await a.upload(file, to: remoteA.appending("stopped.bin"), modified: nil) { _ in }
                let entry = try await a.entry(at: remoteA.appending("stopped.bin"))
                let destination = remoteB.appending("stopped.bin")
                let stop = AsyncStream<Void>.makeStream()
                let counted = OSAllocatedUnfairLock(initialState: 0)
                let copying = Task {
                    try await DeviceToDevice.copy(entry, from: a, to: destination, on: b) { bytes in
                        if counted.withLock({ $0 += bytes; return $0 }) >= 4 << 20 { stop.continuation.finish() }
                    }
                }
                for await _ in stop.stream {}
                copying.cancel()
                let result = await copying.result
                let there = await b.tidyLeftovers(try await listing(remoteB, on: b))
                if let placed = there[destination.name] {
                    try check(try await read(destination, on: b) == (try Data(contentsOf: file)),
                              "B has \(placed.size ?? 0) bytes that aren't the file")
                } else {
                    if case .success = result { throw DeviceTestSuite.Failure(description: "the copy reports success but B has no file") }
                }
                try await noLeftovers(remoteB, on: b)
                print("    (\(there[destination.name] == nil ? "stopped, nothing on B" : "finished the file first"))")
                // Both still answer: the next copy goes through.
                let small = try await a.entry(at: srcA.appending("s1.txt"))
                try await DeviceToDevice.copy(small, from: a, to: remoteB.appending("after-stop.txt"), on: b) { _ in }
                try check(try await read(remoteB.appending("after-stop.txt"), on: b) == (try original("s1.txt")),
                          "the copy after the stop differs")
            }),
            ("no temporary files left on either phone or this Mac", {
                try await noLeftovers(copied.appending("src"), on: b)
                try await noLeftovers(srcA, on: a)
                let temp = FileManager.default.temporaryDirectory
                let ours = try FileManager.default.contentsOfDirectory(atPath: temp.path).filter {
                    WorkNames.isScratch($0) && !$0.hasPrefix("\(WorkNames.tag)-devtest") && !$0.hasPrefix("\(WorkNames.tag)-zip")
                }
                try check(ours.isEmpty, "left in \(temp.path): \(ours.prefix(3))")
            }),
        ]
    }
}

/// Runs the two-device suite; returns false if any test failed.
func runPairTests(_ nameA: String, _ nameB: String, quick: Bool,
                  open: @escaping (String) async throws -> any DeviceFileSystem,
                  release: @escaping (any DeviceFileSystem) -> Void) async throws -> Bool {
    let a = try await open(nameA)
    let b = try await open(nameB)
    defer { release(a); release(b) }
    let stamp = Int(Date().timeIntervalSince1970)
    let remoteA = RemoteRef(path: "/sdcard/Download/\(WorkNames.tag)-devtest-pair-\(stamp)")
    let remoteB = remoteA
    let local = WorkNames.scratch("devtest-pair")
    try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: local) }
    try await a.makeDirectory(remoteA)
    try await b.makeDirectory(remoteB)
    print("A: \(nameA), B: \(nameB), working in \(remoteA.path) on each")

    var suite = PairTestSuite(a: a, b: b, remoteA: remoteA, remoteB: remoteB, local: local)
    suite.quick = quick
    var failed = 0
    for test in try suite.tests() {
        let start = ContinuousClock.now
        do {
            try await test.run()
            print("  ✔︎ \(test.name) (\(start.duration(to: .now).formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow))))")
        } catch {
            failed += 1
            print("  ✘ \(test.name): \(error)")
        }
    }
    for (fs, remote, name) in [(a, remoteA, "A"), (b, remoteB, "B")] {
        do {
            try await fs.delete([remote])
            print("removed \(remote.path) on \(name)")
        } catch {
            print("couldn't remove \(remote.path) on \(name): \(error) — delete it on the phone")
        }
    }
    print(failed == 0 ? "all passed" : "\(failed) failed")
    return failed == 0
}
