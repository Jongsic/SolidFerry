import Foundation
import os
import Testing
@testable import TransferKit
import DeviceCore

private let differs = ExistingItem.file(sizeMatches: false, dateMatches: false)
private let sameSizeOtherDate = ExistingItem.file(sizeMatches: true, dateMatches: false)
private let identical = ExistingItem.file(sizeMatches: true, dateMatches: true)

@Test func newFilesAlwaysTransfer() {
    for existing in ExistingFilePolicy.allCases {
        #expect(FileDecision.decide(.none, TransferPolicy(existing: existing)) == .transfer)
    }
}

@Test func sizeOrDatePolicy() {
    let policy = TransferPolicy(existing: .ifSizeOrDateDiffers, whenDifferent: .overwrite)
    #expect(FileDecision.decide(identical, policy) == .skipIdentical)
    #expect(FileDecision.decide(sameSizeOtherDate, policy) == .overwrite)
    #expect(FileDecision.decide(differs, policy) == .overwrite)
    let keepBoth = TransferPolicy(existing: .ifSizeOrDateDiffers, whenDifferent: .keepBoth)
    #expect(FileDecision.decide(differs, keepBoth) == .keepBoth)
}

@Test func sizeOnlyMatchIgnoresDates() {
    let policy = TransferPolicy(existing: .ifSizeOrDateDiffers, whenDifferent: .overwrite, sizeOnlyMatch: true)
    #expect(FileDecision.decide(sameSizeOtherDate, policy) == .skipIdentical)
    #expect(FileDecision.decide(differs, policy) == .overwrite)
}

@Test func hashPolicyOnlyHashesSameSize() {
    let policy = TransferPolicy(existing: .ifHashDiffers, whenDifferent: .overwrite)
    #expect(FileDecision.decide(sameSizeOtherDate, policy) == .needsHash)
    #expect(FileDecision.decide(differs, policy) == .overwrite)
    #expect(FileDecision.afterHash(equal: true, policy) == .skipIdentical)
    #expect(FileDecision.afterHash(equal: false, policy) == .overwrite)
}

@Test func otherPolicies() {
    #expect(FileDecision.decide(identical, TransferPolicy(existing: .skip)) == .skipExisting)
    #expect(FileDecision.decide(identical, TransferPolicy(existing: .overwrite)) == .overwrite)
    #expect(FileDecision.decide(identical, TransferPolicy(existing: .keepBoth)) == .keepBoth)
    #expect(FileDecision.decide(identical, TransferPolicy(existing: .ask)) == .ask)
    #expect(FileDecision.decide(.directory, TransferPolicy(existing: .overwrite)) == .typeConflict)
}

@Test func existingItemComparesSizeAndDate() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("a.jpg")
    try Data(count: 10).write(to: file)
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)

    #expect(ExistingItem.at(file, remoteSize: 10, remoteModified: date.addingTimeInterval(1)) == identical)
    #expect(ExistingItem.at(file, remoteSize: 10, remoteModified: date.addingTimeInterval(60)) == sameSizeOtherDate)
    #expect(ExistingItem.at(file, remoteSize: 11, remoteModified: date) == .file(sizeMatches: false, dateMatches: true))
    #expect(ExistingItem.at(dir, remoteSize: 10, remoteModified: date) == .directory)
    #expect(ExistingItem.at(dir.appendingPathComponent("missing"), remoteSize: 1, remoteModified: nil) == ExistingItem.none)
}

@Test func uniqueDestinationSkipsTakenAndReservedNames() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data().write(to: dir.appendingPathComponent("a (1).jpg"))
    var reserved = FolderNames()
    let first = uniqueDestination(for: dir.appendingPathComponent("a.jpg"), reserved: &reserved)
    let second = uniqueDestination(for: dir.appendingPathComponent("a.jpg"), reserved: &reserved)
    #expect(first.lastPathComponent == "a (2).jpg")
    #expect(second.lastPathComponent == "a (3).jpg")
    #expect(uniqueDestination(for: dir.appendingPathComponent("README"), reserved: &reserved).lastPathComponent == "README (1)")
    // The Mac's disk ignores case: "A (4).jpg" would be the same file as a reserved "a (4).jpg".
    reserved.insert(dir.appendingPathComponent("A (4).jpg").path)
    #expect(uniqueDestination(for: dir.appendingPathComponent("a.jpg"), reserved: &reserved).lastPathComponent == "a (5).jpg")
}

@Test func localMD5MatchesKnownValue() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data("hello\n".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    #expect(try localMD5(of: file) == "b1946ac92492d2347c6235b4d2611184")
}

@Test func folderKeepBothRenamesTakenTopLevelFolders() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("Camera"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    var plan = TransferPlan()
    plan.directories = ["Camera", "Camera/sub", "Other"]
    let entry = RemoteEntry(ref: RemoteRef(path: "/sdcard/DCIM/Camera/a.jpg"), name: "a.jpg", kind: .file, size: 1, modified: nil)
    plan.files = [PlannedFile(entry: entry, relativePath: "Camera/sub/a.jpg")]

    #expect(plan.applyingFolderPolicy(.merge, destination: dir).directories == plan.directories)
    let renamed = plan.applyingFolderPolicy(.keepBoth, destination: dir)
    #expect(renamed.directories == ["Camera (1)", "Camera (1)/sub", "Other"])
    #expect(renamed.files.map(\.relativePath) == ["Camera (1)/sub/a.jpg"])
}

@Test func oldSavedPolicyDecodesWithDefaults() throws {
    let json = #"{"existing":"skip","whenDifferent":"keepBoth","sizeOnlyMatch":true}"#
    let policy = try JSONDecoder().decode(TransferPolicy.self, from: Data(json.utf8))
    #expect(policy.existing == .skip)
    #expect(policy.existingFolder == .merge)
}

@Test func defaultPolicyNeverTouchesExistingFiles() {
    let policy = TransferPolicy()
    for existing in [identical, sameSizeOtherDate, differs] {
        #expect(FileDecision.decide(existing, policy) == .skipExisting)
    }
    #expect(policy.existingFolder == .merge)
}

@Test func uploadPlanWalksFoldersAndSkipsDSStore() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let trip = dir.appendingPathComponent("Trip")
    try FileManager.default.createDirectory(at: trip.appendingPathComponent("Day 1"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data(count: 3).write(to: trip.appendingPathComponent("a.jpg"))
    try Data(count: 5).write(to: trip.appendingPathComponent("Day 1/b.jpg"))
    try Data().write(to: trip.appendingPathComponent(".DS_Store"))
    let single = dir.appendingPathComponent("note.txt")
    try Data(count: 7).write(to: single)

    let plan = try UploadPlanner.expand([trip, single])
    #expect(plan.directories == ["Trip", "Trip/Day 1"])
    #expect(Set(plan.files.map(\.relativePath)) == ["Trip/a.jpg", "Trip/Day 1/b.jpg", "note.txt"])
    #expect(plan.totalBytes == 15)

    let renamed = plan.applyingFolderPolicy(.keepBoth, existingNames: ["Trip"])
    #expect(renamed.directories == ["Trip (1)", "Trip (1)/Day 1"])
    #expect(renamed.files.contains { $0.relativePath == "Trip (1)/Day 1/b.jpg" })
}

@Test func remoteExistingComparison() {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let entry = RemoteEntry(ref: RemoteRef(path: "/sdcard/a.jpg"), name: "a.jpg", kind: .file, size: 10, modified: date)
    #expect(ExistingItem.remote(nil, localSize: 10, localModified: date) == .none)
    #expect(ExistingItem.remote(entry, localSize: 10, localModified: date.addingTimeInterval(1)) == identical)
    #expect(ExistingItem.remote(entry, localSize: 11, localModified: date) == .file(sizeMatches: false, dateMatches: true))
    var taken: FolderNames = ["a.jpg", "A (1).JPG"]
    #expect(uniqueName("a.jpg", taken: &taken) == "a (2).jpg") // "a (1).jpg" is taken in another case
    #expect(uniqueName("Trip", taken: &taken, isDirectory: true) == "Trip (1)")
}

@Test func namesInAFolderAreTheSameRegardlessOfCaseAndComposition() {
    // QUIRKS S7: the phone (and macOS) treat these as one name.
    let composed = "한글.txt".precomposedStringWithCanonicalMapping
    let decomposed = "한글.txt".decomposedStringWithCanonicalMapping
    #expect(Array(composed.utf8) != Array(decomposed.utf8)) // (Swift's == already treats them as equal)
    let names: FolderNames = ["Photo.JPG", composed]
    #expect(names.contains("photo.jpg") && names.contains(decomposed))
    #expect(!names.contains("photo.jpeg"))
}

@Test func aFileInAnotherCaseIsTheOneThereNotANewFile() async throws {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let there = ["photo.jpg": RemoteEntry(ref: RemoteRef(path: "/sdcard/In/photo.jpg"), name: "photo.jpg", kind: .file, size: 1, modified: date)]
    var placer = DeviceFolderPlacer(destination: RemoteRef(path: "/sdcard/In"),
                                    policy: TransferPolicy(existing: .ifSizeOrDateDiffers, whenDifferent: .keepBoth),
                                    sizesWrap: false) { _ in there }
    let placed = try await placer.place("Photo.JPG", size: 2, modified: date)
    #expect(placed.existing?.name == "photo.jpg")
    #expect(placed.decision == .keepBoth && placed.target.name == "Photo (1).JPG")
}

// MARK: Batch rename

@Test func batchRenameKeepsExtensionAndNumbers() throws {
    var rules = BatchRenameRules()
    rules.find = "img_"
    rules.replace = "Trip "
    rules.numbering = true
    rules.numberPosition = .after
    rules.start = 9
    rules.digits = 2
    #expect(try rules.apply(to: "IMG_0001.JPG", index: 0, isDirectory: false) == "Trip 0001 09.JPG")
    #expect(try rules.apply(to: "IMG_0002.JPG", index: 1, isDirectory: false) == "Trip 0002 10.JPG")
    rules.numberPosition = .replace
    #expect(try rules.apply(to: "IMG_0002.JPG", index: 1, isDirectory: false) == "10.JPG")
    #expect(try rules.apply(to: "Folder.v2", index: 1, isDirectory: true) == "10")
    #expect(try rules.apply(to: ".nomedia", index: 0, isDirectory: false) == "09")
}

@Test func batchRenameRegexAndCase() throws {
    var rules = BatchRenameRules()
    rules.find = #"(\d{4})(\d{2})(\d{2})"#
    rules.replace = "$1-$2-$3"
    rules.useRegex = true
    rules.caseChange = .lower
    #expect(try rules.apply(to: "PXL_20240131.MP4", index: 0, isDirectory: false) == "pxl_2024-01-31.MP4")
    rules.includeExtension = true
    #expect(try rules.apply(to: "PXL_20240131.MP4", index: 0, isDirectory: false) == "pxl_2024-01-31.mp4")
    rules.find = "("
    let rows = BatchRename.preview([("a", false)], rules: rules, others: [])
    #expect(rows[0].problem == .badPattern)
}

@Test func batchRenameFlagsConflicts() {
    var rules = BatchRenameRules()
    rules.find = "b"
    rules.replace = "a"
    let rows = BatchRename.preview([("a.txt", false), ("b.txt", false), ("c.txt", false)], rules: rules, others: ["C.TXT"])
    #expect(rows[0].problem == .duplicate) // "a.txt" stays, "b.txt" → "a.txt"
    #expect(rows[1].problem == .duplicate)
    rules.find = "c"
    rules.replace = "d"
    let taken = BatchRename.preview([("c.txt", false)], rules: rules, others: ["d.txt"])
    #expect(taken[0].problem == .taken)
}

@Test func batchRenameSwapGoesThroughTemporaryNames() {
    let rows = [BatchRenameRow(oldName: "a", newName: "b", problem: nil),
                BatchRenameRow(oldName: "b", newName: "a", problem: nil),
                BatchRenameRow(oldName: "c", newName: "d", problem: nil)]
    let steps = BatchRename.steps(rows)
    var names: Set<String> = ["a", "b", "c"]
    for step in steps {
        #expect(names.contains(step.from))
        #expect(!names.contains(step.to))
        names.remove(step.from)
        names.insert(step.to)
    }
    #expect(names == ["a", "b", "d"])
}

@Test func hashPolicyFallsBackWithoutHashes() {
    let policy = TransferPolicy(existing: .ifHashDiffers, whenDifferent: .overwrite)
    #expect(policy.normalized(hashAvailable: true).existing == .ifHashDiffers)
    #expect(policy.normalized(hashAvailable: false).existing == .ifSizeOrDateDiffers)
    #expect(policy.normalized(hashAvailable: false).whenDifferent == .overwrite)
    #expect(TransferPolicy(existing: .skip).normalized(hashAvailable: false).existing == .skip)
}

@Test func wrappedSizesCompareLow32Bits() {
    let fiveGB: UInt64 = 5_000_000_000
    let reported = UInt64(UInt32(truncatingIfNeeded: fiveGB)) // what a v1 listing says
    let entry = RemoteEntry(ref: RemoteRef(path: "/sdcard/v.mp4"), name: "v.mp4", kind: .file, size: reported, modified: nil)
    #expect(ExistingItem.remote(entry, localSize: fiveGB, localModified: nil) == .file(sizeMatches: false, dateMatches: false))
    #expect(ExistingItem.remote(entry, localSize: fiveGB, localModified: nil, remoteSizeWraps: true) == .file(sizeMatches: true, dateMatches: false))
}

@Test func fileNamesAndroidAllows() {
    for ok in ["a.txt", "it's.txt", "한글.txt", "emoji 📷", ".hidden", String(repeating: "n", count: 255)] {
        #expect(FileNames.isAllowed(ok), "\(ok)")
    }
    for bad in ["", ".", "..", "a/b", "a\0b", "q\"t", "a:b", "a*b", "a?b", "a<b", "a>b", "a|b", "a\\b", String(repeating: "n", count: 256)] {
        #expect(!FileNames.isAllowed(bad), "\(bad)")
    }
}

// MARK: Zip

@Test func zipWriterProducesAnArchiveUnzipAccepts() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zipt-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let a = dir.appendingPathComponent("a.txt")
    try Data("hello".utf8).write(to: a)
    let b = dir.appendingPathComponent("b.bin")
    try Data((0..<300_000).map { UInt8($0 % 251) }).write(to: b)
    let fileDate = Date(timeIntervalSince1970: 1_577_934_245) // 2020-01-02, odd seconds
    let folderDate = Date(timeIntervalSince1970: 1_514_768_461)
    let zip = dir.appendingPathComponent("out.zip")
    try ZipWriter.write([
        ZipItem(path: "Trip", source: nil, modified: folderDate),
        ZipItem(path: "Trip/한글 a.txt", source: a, modified: fileDate),
        ZipItem(path: "Trip/sub", source: nil, modified: folderDate),
        ZipItem(path: "Trip/sub/b.bin", source: b, modified: fileDate),
    ], to: zip)

    let test = Process()
    test.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    test.arguments = ["-tq", zip.path]
    try test.run()
    test.waitUntilExit()
    #expect(test.terminationStatus == 0)

    // Unpack with Info-ZIP (reads the extended timestamp) and check names, contents and
    // second-exact dates.
    let out = dir.appendingPathComponent("x")
    let unzip = Process()
    unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    unzip.arguments = ["-q", zip.path, "-d", out.path]
    try unzip.run()
    unzip.waitUntilExit()
    let extracted = out.appendingPathComponent("Trip/한글 a.txt")
    #expect(try Data(contentsOf: extracted) == Data("hello".utf8))
    #expect(try Data(contentsOf: out.appendingPathComponent("Trip/sub/b.bin")) == Data(contentsOf: b))
    let modified = try extracted.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    #expect(modified.map { abs($0.timeIntervalSince(fileDate)) < 1 } == true)
}

/// Zip64 written where values pass `beyond` (4 GB in real use; small here so a test can
/// reach it): Info-ZIP and Python both read it back, names, contents and dates intact.
@Test(arguments: [3, 100] as [UInt64])
func zipWriterUsesZip64PastTheLimit(beyond: UInt64) throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zip64-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let small = dir.appendingPathComponent("small.txt")
    try Data("hi".utf8).write(to: small)
    let big = dir.appendingPathComponent("big.bin")
    try Data((0..<300_000).map { UInt8($0 % 249) }).write(to: big)
    let fileDate = Date(timeIntervalSince1970: 1_577_934_245)
    let zip = dir.appendingPathComponent("out.zip")
    try ZipWriter.write([
        ZipItem(path: "Trip", source: nil, modified: fileDate),
        ZipItem(path: "Trip/big.bin", source: big, modified: fileDate),
        ZipItem(path: "Trip/small.txt", source: small, modified: fileDate),
    ], to: zip, beyond: beyond)
    let bytes = try Data(contentsOf: zip)
    #expect(bytes.range(of: Data([0x50, 0x4B, 0x06, 0x06])) != nil) // Zip64 end record

    func run(_ tool: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
    #expect(try run("/usr/bin/unzip", ["-tq", zip.path]) == 0)
    #expect(try run("/usr/bin/python3", ["-c", "import zipfile,sys; z=zipfile.ZipFile(sys.argv[1]); sys.exit(z.testzip() is not None or z.getinfo('Trip/big.bin').file_size != 300000)", zip.path]) == 0)
    let out = dir.appendingPathComponent("x")
    #expect(try run("/usr/bin/unzip", ["-q", zip.path, "-d", out.path]) == 0)
    #expect(try Data(contentsOf: out.appendingPathComponent("Trip/big.bin")) == Data(contentsOf: big))
    #expect(try Data(contentsOf: out.appendingPathComponent("Trip/small.txt")) == Data("hi".utf8))
    let modified = try out.appendingPathComponent("Trip/big.bin").resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    #expect(modified.map { abs($0.timeIntervalSince(fileDate)) < 1 } == true)
}

@Test func zipWriterStaysPlainBelowTheLimit() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zip32-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let a = dir.appendingPathComponent("a.txt")
    try Data("hello".utf8).write(to: a)
    let zip = dir.appendingPathComponent("out.zip")
    try ZipWriter.write([ZipItem(path: "a.txt", source: a, modified: Date())], to: zip)
    let bytes = try Data(contentsOf: zip)
    #expect(bytes.range(of: Data([0x50, 0x4B, 0x06, 0x06])) == nil)
    #expect(bytes[4] == 10) // version needed 1.0, as before
}

@Test func crc32KnownValue() {
    var crc = CRC32()
    crc.update(Data("123456789".utf8))
    #expect(crc.value == 0xCBF4_3926)
}

@Test func zipPackageUnpacksIntoTheSameLayout() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("zpk-\(UUID().uuidString)")
    let trip = root.appendingPathComponent("Trip")
    try FileManager.default.createDirectory(at: trip.appendingPathComponent("Day 1"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("a".utf8).write(to: trip.appendingPathComponent("a.jpg"))
    try Data("b".utf8).write(to: trip.appendingPathComponent("Day 1/b.jpg"))
    let folder = try UploadPlanner.expand([trip]).zipPackage(sources: [trip], otherwiseNamed: "Files")
    #expect(folder.fileName == "Trip.zip")
    #expect(Set(folder.items.map(\.path)) == ["Day 1", "a.jpg", "Day 1/b.jpg"])

    let loose = [trip.appendingPathComponent("a.jpg"), trip.appendingPathComponent("Day 1")]
    let files = try UploadPlanner.expand(loose).zipPackage(sources: loose, otherwiseNamed: "Files 2026-11-08")
    #expect(files.fileName == "Files 2026-11-08.zip")
    #expect(Set(files.items.map(\.path)) == ["a.jpg", "Day 1", "Day 1/b.jpg"])
}

@Test func keepBothFolderWithDotsKeepsItsName() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("kb-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Photos.2023"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var reserved = FolderNames()
    let folder = uniqueDestination(for: root.appendingPathComponent("Photos.2023"), reserved: &reserved, isDirectory: true)
    #expect(folder.lastPathComponent == "Photos.2023 (1)")
    let file = uniqueDestination(for: root.appendingPathComponent("a.jpg"), reserved: &reserved)
    #expect(file.lastPathComponent == "a (1).jpg")
}

@Test func remoteRefPaths() {
    #expect(RemoteRef(path: "/sdcard/DCIM/a.jpg").parentPath == "/sdcard/DCIM")
    #expect(RemoteRef(path: "/sdcard").parentPath == "/")
    #expect(RemoteRef(path: "/").parentPath == nil)
    #expect(RemoteRef(path: "/sdcard/DCIM").name == "DCIM")
    #expect(RemoteRef(path: "/").appending("sdcard").path == "/sdcard")
    #expect(RemoteRef(path: "/sdcard/").appending("a").path == "/sdcard/a")
}

@Test func perFileChoiceWinsOverPolicyForFilesInTheWay() {
    let policy = TransferPolicy(existing: .overwrite)
    let differs = ExistingItem.file(sizeMatches: false, dateMatches: false)
    #expect(FileDecision.decide(differs, policy, choice: nil) == .overwrite)
    #expect(FileDecision.decide(differs, policy, choice: .skip) == .skipExisting)
    #expect(FileDecision.decide(differs, policy, choice: .keepBoth) == .keepBoth)
    // New files and folders in the way ignore a choice.
    #expect(FileDecision.decide(.none, policy, choice: .skip) == .transfer)
    #expect(FileDecision.decide(.directory, policy, choice: .overwrite) == .typeConflict)
}

@Test func devicesOfOneModelGetTheirSerialsEnd() {
    func device(_ serial: String, _ name: String) -> DeviceDescriptor {
        DeviceDescriptor(transport: .adb, serial: serial, name: name, link: .usb, status: .ready)
    }
    let named = DeviceDescriptor.distinguishingNames([
        device("HVA0AAAA", "Lenovo TB J606F"), device("HVA0BBBB", "Lenovo TB J606F"),
        device("R5XX00ABCDE", "SM-S911N"),
        device("AB12345", "Pixel"), device("CD12345", "Pixel"),
    ]).map(\.name)
    #expect(named == ["Lenovo TB J606F (AAAA)", "Lenovo TB J606F (BBBB)", "SM-S911N",
                      "Pixel (B12345)", "Pixel (D12345)"])
}

@Test func asideNamesGiveBackTheOriginal() {
    let aside = WorkNames.aside("photo 1.jpg")
    #expect(WorkNames.originalName(ofAside: aside) == "photo 1.jpg")
    #expect(WorkNames.originalName(ofAside: WorkNames.aside(".hidden")) == ".hidden")
    #expect(WorkNames.originalName(ofAside: "photo.jpg") == nil)
    #expect(WorkNames.originalName(ofAside: WorkNames.step("part")) == nil)
    #expect(WorkNames.isPartial(WorkNames.step("part")))
    #expect(!WorkNames.isPartial(aside))
}

@Test func workNamesFitWhereTheNameFits() {
    let long = String(repeating: "가", count: 80) + ".jpg" // 244 bytes: fits, its work names wouldn't
    #expect(WorkNames.fits(long))
    for work in [WorkNames.partial(long), WorkNames.aside(long), WorkNames.step("part")] {
        #expect(WorkNames.fits(work), "\(work)")
    }
    #expect(WorkNames.partial(long) == WorkNames.partial(long))
    #expect(WorkNames.originalName(ofAside: WorkNames.aside(long)) == nil)
    #expect(WorkNames.originalName(ofAside: WorkNames.aside("a.jpg")) == "a.jpg")
    #expect(WorkNames.originalName(ofMoving: WorkNames.moving("a.jpg")) == "a.jpg")
    #expect(WorkNames.originalName(ofMoving: WorkNames.aside("a.jpg")) == nil)
    #expect(WorkNames.originalName(ofMoving: WorkNames.moving(long)) == nil)
}

@Test func localHashesAllComeBackAFewAtATime() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hashes-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let urls: [URL?] = try (0..<10).map { i in
        let url = dir.appendingPathComponent("\(i)")
        try Data("file \(i % 2)".utf8).write(to: url)
        return url
    } + [nil, dir.appendingPathComponent("missing")]
    let hashes = try await localMD5s(urls, atOnce: 3)
    #expect(hashes.count == 10)
    #expect(hashes[0] == hashes[2] && hashes[0] != hashes[1])
    #expect(hashes[10] == nil && hashes[11] == nil)
}

@Test func listingsKeepTheLatestOfEachEntryInFirstOrder() {
    func entry(_ name: String, size: UInt64?, partial: Bool) -> RemoteEntry {
        RemoteEntry(ref: RemoteRef(path: "/sdcard/\(name)"), name: name, kind: .file, size: size, modified: nil, isPartial: partial)
    }
    var listing = ListingAccumulator()
    listing.add([entry("b", size: nil, partial: true), entry("a", size: nil, partial: true)])
    listing.add([entry("c", size: 3, partial: false)])
    listing.add([entry("a", size: 1, partial: false), entry("b", size: 2, partial: false)])
    #expect(listing.entries.map(\.name) == ["b", "a", "c"])
    #expect(listing.entries.map(\.size) == [2, 1, 3])
    #expect(listing.entries.allSatisfy { !$0.isPartial })
}

@Test func planningWalksFoldersWithRelativePathsAndSizes() async throws {
    let phone = FakeDeviceFileSystem()
    let camera = phone.add("/sdcard/DCIM/Camera", kind: .directory)
    phone.add("/sdcard/DCIM/Camera/a.jpg", size: 10)
    phone.add("/sdcard/DCIM/Camera/2024", kind: .directory)
    phone.add("/sdcard/DCIM/Camera/2024/b.jpg", size: 20)
    phone.add("/sdcard/DCIM/Camera/link", kind: .symlink)
    phone.add("/sdcard/DCIM/Camera/2024/socket", kind: .other)
    let note = phone.add("/sdcard/note.txt", size: 5)

    let plan = try await TransferPlanner.expand([camera, note], in: phone)
    #expect(Set(plan.files.map(\.relativePath)) == ["Camera/a.jpg", "Camera/2024/b.jpg", "note.txt"])
    #expect(plan.directories == ["Camera", "Camera/2024"]) // parents first
    #expect(plan.totalBytes == 35) // sizes from the detailed half of the listing
    #expect(plan.files.allSatisfy { !$0.entry.isPartial })
}

@Test func planningSkipsNamesThatWouldLeaveTheDestination() async throws {
    let phone = FakeDeviceFileSystem()
    let camera = phone.add("/sdcard/DCIM/Camera", kind: .directory)
    phone.add("/sdcard/DCIM/Camera/a.jpg", size: 10)
    phone.add("/sdcard/DCIM/Camera/x1", size: 1, name: "../../x.plist")
    phone.add("/sdcard/DCIM/Camera/x2", kind: .directory, name: "..")
    let plan = try await TransferPlanner.expand([camera], in: phone)
    #expect(plan.files.map(\.relativePath) == ["Camera/a.jpg"])
    #expect(plan.directories == ["Camera"])
}

@Test func aFolderThatGoesOverWholeIsntWalked() async throws {
    let phone = FakeDeviceFileSystem()
    let camera = phone.add("/sdcard/DCIM/Camera", kind: .directory)
    phone.add("/sdcard/DCIM/Camera/a.jpg", size: 10)
    let music = phone.add("/sdcard/Music", kind: .directory)
    phone.add("/sdcard/Music/s.mp3", size: 3)
    let plan = try await TransferPlanner.expand([camera, music], in: phone, expanding: { $0.name == "Music" })
    #expect(plan.directories == ["Camera", "Music"])
    #expect(plan.files.map(\.relativePath) == ["Music/s.mp3"])
    let whole = plan.wholeItems([camera, music], placedAs: plan, takenAtDestination: ["Music"])
    #expect(whole.map(\.name) == ["Camera"] && whole.first?.bytes == nil) // not walked: size unknown
}

@Test func planningLooksUpASelectedFileWithoutDetails() async throws {
    let phone = FakeDeviceFileSystem()
    phone.add("/sdcard/v.mp4", size: 1_000)
    // As selected while the listing showed names only.
    let selected = RemoteEntry(ref: RemoteRef(path: "/sdcard/v.mp4"), name: "v.mp4", kind: .file, size: nil, modified: nil, isPartial: true)
    let plan = try await TransferPlanner.expand([selected], in: phone)
    #expect(plan.files.first?.entry.size == 1_000)
    #expect(plan.totalBytes == 1_000)
}

@Test func placingIntoAPhoneFolderListsEachFolderOnceAndKeepsNamesApart() async throws {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let existing: [String: [String: RemoteEntry]] = [
        "/sdcard/In": ["a.jpg": RemoteEntry(ref: RemoteRef(path: "/sdcard/In/a.jpg"), name: "a.jpg", kind: .file, size: 10, modified: date),
                       "b.jpg": RemoteEntry(ref: RemoteRef(path: "/sdcard/In/b.jpg"), name: "b.jpg", kind: .file, size: 99, modified: date)],
    ]
    let reads = Locked(0)
    var placer = DeviceFolderPlacer(destination: RemoteRef(path: "/sdcard/In"),
                                    policy: TransferPolicy(existing: .ifSizeOrDateDiffers, whenDifferent: .keepBoth),
                                    choices: ["c.jpg": .skip], sizesWrap: false) { folder in
        reads.add(1)
        return existing[folder.path] ?? [:]
    }
    let same = try await placer.place("a.jpg", size: 10, modified: date)
    let different = try await placer.place("b.jpg", size: 20, modified: date)
    let new = try await placer.place("c.jpg", size: 5, modified: date)
    let nested = try await placer.place("Sub/d.jpg", size: 5, modified: date)
    #expect(same.decision == .skipIdentical)
    #expect(different.decision == .keepBoth && different.target.name == "b (1).jpg")
    #expect(new.decision == .transfer) // nothing there: the "skip" choice is for files in the way
    #expect(nested.decision == .transfer && nested.target.path == "/sdcard/In/Sub/d.jpg")
    #expect(reads.value == 2) // /sdcard/In and /sdcard/In/Sub, once each
    #expect(placer.names["/sdcard/In"] == ["a.jpg", "b.jpg", "b (1).jpg"])
}

@Test func aKeepBothNameOnThePhoneIsntOneAnotherFileOfTheJobGoesTo() async throws {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let there = ["a.jpg": RemoteEntry(ref: RemoteRef(path: "/sdcard/In/a.jpg"), name: "a.jpg", kind: .file, size: 1, modified: date)]
    var placer = DeviceFolderPlacer(destination: RemoteRef(path: "/sdcard/In"),
                                    policy: TransferPolicy(existing: .ifSizeOrDateDiffers, whenDifferent: .keepBoth),
                                    sizesWrap: false) { _ in there }
    // "a.jpg" comes first here: without the reservation its new name would be "a (1).jpg".
    placer.reserve(["a.jpg", "a (1).jpg"])
    let renamed = try await placer.place("a.jpg", size: 2, modified: date)
    let other = try await placer.place("a (1).jpg", size: 3, modified: date)
    #expect(renamed.decision == .keepBoth && renamed.target.name == "a (2).jpg")
    #expect(other.decision == .transfer && other.target.name == "a (1).jpg")
    #expect(placer.names["/sdcard/In"] == ["a.jpg", "a (1).jpg", "a (2).jpg"])
}

@Test func aBigFolderListedByNameGetsDetailsOnlyWhereFilesAreComing() async throws {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    // 1,000 names without sizes or dates, as MTP lists a big folder (DeviceFileSystem.listNames).
    let names = Dictionary(uniqueKeysWithValues: (0..<1000).map { i in
        ("p\(i).jpg", RemoteEntry(ref: RemoteRef(path: "/sdcard/DCIM/p\(i).jpg"), name: "p\(i).jpg", kind: .file,
                                  size: nil, modified: nil, isPartial: true))
    })
    let asked = Locked(0)
    var placer = DeviceFolderPlacer(destination: RemoteRef(path: "/sdcard/DCIM"), policy: TransferPolicy(existing: .ifSizeOrDateDiffers),
                                    sizesWrap: false, details: { entries in
        asked.add(entries.count)
        return entries.map { RemoteEntry(ref: $0.ref, name: $0.name, kind: .file, size: 10, modified: date) }
    }) { _ in names }
    let same = try await placer.place("p1.jpg", size: 10, modified: date)
    let new = try await placer.place("new.jpg", size: 10, modified: date)
    #expect(same.decision == .skipIdentical && same.existing?.size == 10)
    #expect(new.decision == .transfer)
    _ = try await placer.place("p1.jpg", size: 10, modified: date) // looked up once, then known
    #expect(asked.value == 1)
    let rows = try await placer.rows([("p2.jpg", 10, date), ("other.jpg", 3, nil)]) { _ in }
    #expect(rows.map(\.existingSize) == [10, nil])
    #expect(asked.value == 2)
    // The queue's placer after the dialog's: what the dialog looked up isn't asked again.
    var next = DeviceFolderPlacer(destination: RemoteRef(path: "/sdcard/DCIM"), policy: TransferPolicy(existing: .ifSizeOrDateDiffers),
                                  sizesWrap: false, details: { entries in
        asked.add(entries.count)
        return entries.map { RemoteEntry(ref: $0.ref, name: $0.name, kind: .file, size: 10, modified: date) }
    }, lookedUp: placer.lookedUp) { _ in names }
    #expect(try await next.place("p2.jpg", size: 10, modified: date).decision == .skipIdentical)
    #expect(asked.value == 2)
}

@Test func aBigFolderIsAskedAboutOnceForAllTheFilesComingToIt() async throws {
    let names = Dictionary(uniqueKeysWithValues: (0..<1000).map { i in
        ("p\(i).jpg", RemoteEntry(ref: RemoteRef(path: "/sdcard/DCIM/p\(i).jpg"), name: "p\(i).jpg", kind: .file,
                                  size: nil, modified: nil, isPartial: true))
    })
    let calls = Locked(0)
    var placer = DeviceFolderPlacer(destination: RemoteRef(path: "/sdcard/DCIM"), sizesWrap: false, details: { entries in
        calls.add(1)
        // p0.jpg went away since the listing: it comes back without details.
        return entries.map { $0.name == "p0.jpg" ? $0 : RemoteEntry(ref: $0.ref, name: $0.name, kind: .file, size: 1, modified: nil) }
    }) { _ in names }
    let coming = (0..<300).map { "p\($0).jpg" } + ["new.jpg"]
    try await placer.prepare(coming)
    #expect(calls.value == 1)
    #expect(try await placer.entry(at: "p5.jpg")?.size == 1)
    #expect(try await placer.entry(at: "p0.jpg") == nil) // gone
    #expect(calls.value == 1)
}

/// A counter for @Sendable closures in tests.
final class Locked: @unchecked Sendable {
    private let lock = NSLock()
    private var count: Int
    init(_ count: Int) { self.count = count }
    func add(_ n: Int) { lock.withLock { count += n } }
    var value: Int { lock.withLock { count } }
}

// MARK: Leftovers

@Test func leftoversAreTidiedWithoutTouchingWhatIsntOurs() async throws {
    let fs = FakeDeviceFileSystem()
    let dir = "/sdcard/D"
    fs.add(dir, kind: .directory)
    fs.add("\(dir)/a.jpg")
    fs.add("\(dir)/\(WorkNames.aside("a.jpg"))")                 // replaced: goes
    fs.add("\(dir)/\(WorkNames.aside("lost.jpg"))")              // only copy: gets its name back
    fs.add("\(dir)/Album", kind: .directory)
    let keptAside = fs.add("\(dir)/\(WorkNames.aside("Album"))") // a folder took the name: stays aside
    fs.add("\(dir)/\(WorkNames.moving("b.jpg"))")               // a move cut off: gets its name back
    fs.add("\(dir)/\(WorkNames.moving("a.jpg"))", size: 7)      // one arriving next to "a.jpg": "a (1).jpg"
    let stuck = fs.add("\(dir)/\(WorkNames.step("part"))")       // can't be deleted
    fs.add("\(dir)/\(WorkNames.step("part"))")                   // goes, though the batch failed
    fs.undeletable = [stuck.ref.path]
    let listing = Dictionary(try await fs.listAll(RemoteRef(path: dir)).map { ($0.name, $0) }, uniquingKeysWith: { _, b in b })
    let after = await fs.tidyLeftovers(listing)
    let names = Set(fs.paths.filter { $0.hasPrefix(dir + "/") }.map { String($0.dropFirst(dir.count + 1)) })
    #expect(names == ["a.jpg", "a (1).jpg", "b.jpg", "lost.jpg", "Album", keptAside.name, stuck.name])
    // The listing it returns is what's there now.
    #expect(Set(after.keys) == names)
}

// MARK: Device to device

@Test func deviceCopyProgressCountsEachByteOnceAcrossBothHalves() async throws {
    let source = FakeDeviceFileSystem(), target = FakeDeviceFileSystem()
    let entry = source.add("/sdcard/a.bin", size: 1001, modified: Date(timeIntervalSince1970: 1_700_000_000))
    let steps = OSAllocatedUnfairLock(initialState: [Int]())
    try await DeviceToDevice.copy(entry, from: source, to: RemoteRef(path: "/sdcard/b.bin"), on: target) { n in
        steps.withLock { $0.append(n) }
    }
    let reported = steps.withLock { $0 }
    #expect(reported.reduce(0, +) == 1001)
    // Halfway through, about half: it moved while the file came in, not only while it went out.
    let comingIn = (1001 + source.chunk - 1) / source.chunk
    #expect(reported.prefix(comingIn).reduce(0, +) == 500)
    #expect(try await target.entry(at: RemoteRef(path: "/sdcard/b.bin")).size == 1001)
}

@Test func deviceCopyNamesTheSourceWhenReadingFails() async throws {
    let source = FakeDeviceFileSystem(), target = FakeDeviceFileSystem()
    let missing = RemoteEntry(ref: RemoteRef(path: "/sdcard/gone.bin"), name: "gone.bin", kind: .file, size: 5, modified: nil)
    await #expect(throws: DeviceToDevice.SourceFailed.self) {
        try await DeviceToDevice.copy(missing, from: source, to: RemoteRef(path: "/sdcard/x"), on: target) { _ in }
    }
}

@Test func deviceCopyStreamsWhenBothSidesCan() async throws {
    let source = FakeDeviceFileSystem(), target = FakeDeviceFileSystem()
    source.streams = true
    target.streams = true
    let entry = source.add("/sdcard/a.bin", size: 100_001, modified: Date(timeIntervalSince1970: 1_700_000_000))
    let counted = Locked(0)
    try await DeviceToDevice.copy(entry, from: source, to: RemoteRef(path: "/sdcard/b.bin"), on: target) { counted.add($0) }
    #expect(counted.value == 100_001)
    let copied = try await target.entry(at: RemoteRef(path: "/sdcard/b.bin"))
    #expect(copied.size == 100_001)
    #expect(copied.modified == entry.modified)
}

@Test func streamedCopyBlamesTheSourceWhenItStopsAndPlacesNothing() async throws {
    let source = FakeDeviceFileSystem(), target = FakeDeviceFileSystem()
    source.streams = true
    target.streams = true
    source.readFailsAfter = 50
    let entry = source.add("/sdcard/a.bin", size: 1000)
    await #expect(throws: DeviceToDevice.SourceFailed.self) {
        try await DeviceToDevice.copy(entry, from: source, to: RemoteRef(path: "/sdcard/b.bin"), on: target) { _ in }
    }
    #expect(!target.paths.contains("/sdcard/b.bin"))
}

@Test func streamedCopyReportsTheTargetsErrorAndStopsTheSource() async throws {
    let source = FakeDeviceFileSystem(), target = FakeDeviceFileSystem()
    source.streams = true
    target.streams = true
    target.uploadFailsAfter = 64
    // Far more than the pipe holds: the source only finishes because the target stopped.
    let entry = source.add("/sdcard/a.bin", size: 64 << 20)
    source.chunk = 1 << 20
    await #expect(throws: FakeDeviceFileSystem.Unplugged.self) {
        try await DeviceToDevice.copy(entry, from: source, to: RemoteRef(path: "/sdcard/b.bin"), on: target) { _ in }
    }
}

@Test func streamedCopyFailsWhenTheSourceHasMoreThanItsSize() async throws {
    let source = FakeDeviceFileSystem(), target = FakeDeviceFileSystem()
    source.streams = true
    target.streams = true
    source.add("/sdcard/a.bin", size: 500)
    let listed = RemoteEntry(ref: RemoteRef(path: "/sdcard/a.bin"), name: "a.bin", kind: .file, size: 400, modified: nil)
    await #expect(throws: (any Error).self) {
        try await DeviceToDevice.copy(listed, from: source, to: RemoteRef(path: "/sdcard/b.bin"), on: target) { _ in }
    }
    #expect(!target.paths.contains("/sdcard/b.bin"))
}

// MARK: Zip64 boundary

/// A file one byte under the limit is written plainly; at the limit it gets Zip64 sizes.
@Test func zip64StartsExactlyAtTheLimit() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zipb-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("f.bin")
    try Data(repeating: 1, count: 1000).write(to: file)
    func localSizes(beyond: UInt64) throws -> (UInt8, [UInt8]) {
        let zip = dir.appendingPathComponent("\(beyond).zip")
        try ZipWriter.write([ZipItem(path: "f.bin", source: file, modified: Date())], to: zip, beyond: beyond)
        let bytes = [UInt8](try Data(contentsOf: zip))
        return (bytes[4], Array(bytes[22..<26]))  // version needed, size field
    }
    let below = try localSizes(beyond: 1001)
    #expect(below.0 == 10 && below.1 == [0xE8, 0x03, 0x00, 0x00])
    let at = try localSizes(beyond: 1000)
    #expect(at.0 == 45 && at.1 == [0xFF, 0xFF, 0xFF, 0xFF])
}

// MARK: Placing a download on this Mac

@Test func keepBothNeverPicksANameAnotherFileOfTheDownloadGoesTo() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("place-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data("on the Mac".utf8).write(to: dir.appendingPathComponent("a.jpg"))
    func planned(_ name: String, size: UInt64) -> PlannedFile {
        PlannedFile(entry: RemoteEntry(ref: RemoteRef(path: "/sdcard/DCIM/\(name)"), name: name, kind: .file, size: size, modified: nil),
                    relativePath: name)
    }
    // The phone has "a.jpg" (different from the Mac's) and "a (1).jpg".
    var plan = TransferPlan()
    plan.files = [planned("a.jpg", size: 99), planned("a (1).jpg", size: 5)]
    let placed = try plan.placedLocally(into: dir, policy: TransferPolicy(existing: .keepBoth), sizesWrap: false)
    #expect(placed.map(\.decision) == [.keepBoth, .transfer])
    #expect(placed.map(\.target.lastPathComponent) == ["a (2).jpg", "a (1).jpg"])
}

@Test func withinOnePhoneItemsWhoseNameIsFreeGoOverWhole() {
    func entry(_ path: String, folder: Bool = false, size: UInt64? = nil) -> RemoteEntry {
        let ref = RemoteRef(path: path)
        return RemoteEntry(ref: ref, name: ref.name, kind: folder ? .directory : .file, size: size, modified: nil)
    }
    func file(_ path: String, _ size: UInt64) -> PlannedFile { PlannedFile(entry: entry("/sdcard/src/" + path, size: size), relativePath: path) }
    var original = TransferPlan()
    original.directories = ["Camera", "Camera/sub", "Other"]
    original.files = [file("Camera/a.jpg", 3), file("Camera/sub/b.jpg", 4), file("Other/c.jpg", 5), file("x.jpg", 9)]
    // "Camera" is taken at the destination; "keep both" folders renames it.
    let placed = original.applyingFolderPolicy(.keepBoth, existingNames: ["Camera", "x.jpg"])
    let selected = [entry("/sdcard/src/Camera", folder: true), entry("/sdcard/src/Other", folder: true), entry("/sdcard/src/x.jpg", size: 9)]
    let whole = original.wholeItems(selected, placedAs: placed, takenAtDestination: ["Camera", "x.jpg"])
    #expect(whole.map(\.name) == ["Camera (1)", "Other"]) // x.jpg's name is taken: it goes file by file
    #expect(whole.map(\.bytes) == [7, 5])
}

@Test func zipDatesStayInsideWhatDOSTimeCanSay() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
    }
    // Two-second steps: odd seconds round down.
    let (time, day) = ZipWriter.dosDateTime(date(2024, 1, 2, 3, 4, 5))
    #expect(time == UInt16(3 << 11 | 4 << 5 | 2) && day == UInt16(44 << 9 | 1 << 5 | 2))
    // Before 1980 and after 2107 clamp to what fits.
    #expect(ZipWriter.dosDateTime(date(1975, 6, 1, 0, 0, 0)).1 >> 9 == 0)
    #expect(ZipWriter.dosDateTime(date(2150, 6, 1, 0, 0, 0)).1 >> 9 == 127)
}

// MARK: Reading into memory (the viewer)

@Test func remoteContentsReadsTheWholeFile() async throws {
    let fs = FakeDeviceFileSystem()
    fs.streams = true
    let entry = fs.add("/sdcard/a.txt", size: 3_000_001)
    let counted = Locked(0)
    let data = try await RemoteContents.data(of: entry, from: fs, limit: 5_000_000) { counted.add($0) }
    #expect(data.count == 3_000_001)
    #expect(data.allSatisfy { $0 == 0x61 })
    #expect(counted.value == 3_000_001)
}

@Test func remoteContentsStopsPastTheLimit() async throws {
    let fs = FakeDeviceFileSystem()
    fs.streams = true
    // Far more than the pipe holds: the source only finishes because reading stopped.
    let entry = fs.add("/sdcard/a.bin", size: 64 << 20)
    fs.chunk = 1 << 20
    await #expect(throws: RemoteContents.TooLarge.self) {
        _ = try await RemoteContents.data(of: entry, from: fs, limit: 1_000_000) { _ in }
    }
}

@Test func remoteContentsReportsTheSourcesError() async throws {
    let fs = FakeDeviceFileSystem()
    fs.streams = true
    fs.readFailsAfter = 50
    let entry = fs.add("/sdcard/a.bin", size: 1000)
    await #expect(throws: FakeDeviceFileSystem.Unplugged.self) {
        _ = try await RemoteContents.data(of: entry, from: fs, limit: 5000) { _ in }
    }
}

@Test func remoteContentsStopsWhenCancelled() async throws {
    let fs = FakeDeviceFileSystem()
    fs.streams = true
    let entry = fs.add("/sdcard/a.bin", size: 1 << 40)
    fs.chunk = 1 << 20
    let started = AsyncStream<Void>.makeStream()
    let reading = Task {
        try await RemoteContents.data(of: entry, from: fs, limit: Int.max) { _ in started.continuation.finish() }
    }
    for await _ in started.stream {}
    reading.cancel()
    await #expect(throws: CancellationError.self) { _ = try await reading.value }
}
