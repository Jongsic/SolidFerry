import DeviceCore
import Foundation
import Testing
import TransferKit

// The copy dialog's counts, footer numbers and list filters.

private let rows = [
    FileRow(relativePath: "new.jpg", existing: .none, incomingSize: 10, incomingDate: nil, existingSize: nil, existingDate: nil),
    FileRow(relativePath: "same.jpg", existing: .file(sizeMatches: true, dateMatches: true),
            incomingSize: 20, incomingDate: nil, existingSize: 20, existingDate: nil),
    FileRow(relativePath: "touched.jpg", existing: .file(sizeMatches: true, dateMatches: false),
            incomingSize: 30, incomingDate: nil, existingSize: 30, existingDate: nil),
    FileRow(relativePath: "changed.jpg", existing: .file(sizeMatches: false, dateMatches: false),
            incomingSize: 40, incomingDate: nil, existingSize: 41, existingDate: nil),
    FileRow(relativePath: "folder", existing: .directory, incomingSize: nil, incomingDate: nil, existingSize: nil, existingDate: nil),
]

private func summary(_ policy: TransferPolicy, choices: [String: ConflictChoice] = [:]) -> TransferSummary {
    TransferSummary(rows: rows, policy: policy, choices: choices)
}

@Test func summaryWithTheDefaultTouchesNothingThere() {
    let s = summary(TransferPolicy())
    #expect((s.new, s.same, s.different, s.existingCount) == (1, 1, 3, 4))
    #expect((s.sameSize, s.differentSize) == (2, 2))
    #expect((s.copyCount, s.copyBytes, s.skipCount, s.hashCount, s.askCount) == (1, 10, 4, 0, 0))
}

@Test func summaryCopiesWhatDiffers() {
    let s = summary(TransferPolicy(existing: .ifSizeOrDateDiffers, whenDifferent: .overwrite))
    #expect((s.copyCount, s.copyBytes, s.skipCount) == (3, 80, 2))
    // Same size counts as the same file: the date change alone doesn't copy it.
    let bySize = summary(TransferPolicy(existing: .ifSizeOrDateDiffers, sizeOnlyMatch: true))
    #expect((bySize.same, bySize.different) == (2, 2))
    #expect((bySize.copyCount, bySize.copyBytes) == (2, 50))
}

@Test func summaryInHashModeComparesSameSizes() {
    let s = summary(TransferPolicy(existing: .ifHashDiffers))
    #expect((s.hashCount, s.copyCount, s.copyBytes, s.skipCount) == (2, 2, 50, 1))
    #expect(TransferPolicy(existing: .ifHashDiffers).matchesBySizeInList)
    #expect(!TransferPolicy(existing: .ifSizeOrDateDiffers).matchesBySizeInList)
}

@Test func summaryAsksOnlyAboutFilesInTheWay() {
    let s = summary(TransferPolicy(existing: .ask))
    #expect((s.askCount, s.copyCount, s.skipCount) == (3, 1, 1))
}

@Test func perFileChoicesWinForFilesInTheWayOnly() {
    // A choice for a new file or a folder means nothing.
    let s = summary(TransferPolicy(), choices: ["changed.jpg": .overwrite, "new.jpg": .skip, "folder": .overwrite])
    #expect((s.copyCount, s.copyBytes, s.skipCount) == (2, 50, 3))
    let kept = FileRow.choices(["changed.jpg": .overwrite, "new.jpg": .skip, "gone.jpg": .skip, "folder": .keepBoth],
                               stillInTheWayIn: rows)
    #expect(kept == ["changed.jpg": .overwrite])
    #expect(FileRow.choices(["changed.jpg": .overwrite], stillInTheWayIn: nil).isEmpty)
}

@Test func listShowsFilesInTheWayFirst() {
    func names(_ filter: FileFilter, sizeOnly: Bool = false) -> [String] {
        FileRow.visible(rows, filter: filter, sizeOnlyMatch: sizeOnly).map(\.relativePath)
    }
    #expect(names(.all) == ["touched.jpg", "changed.jpg", "same.jpg", "folder", "new.jpg"])
    #expect(names(.different) == ["touched.jpg", "changed.jpg", "folder"])
    #expect(names(.same) == ["same.jpg"])
    #expect(names(.same, sizeOnly: true) == ["same.jpg", "touched.jpg"])
    #expect(names(.new) == ["new.jpg"])
}

// MARK: How files go out

@Test func smallDownloadsGoInBatchesOthersAlone() {
    var files: [(index: Int, size: UInt64?, batchable: Bool)] = (0..<70).map { ($0, 100, true) }
    files.insert((100, TransferUnits.smallFile, true), at: 3)   // too big for a batch
    files.insert((101, 100, false), at: 5)                     // not batchable (an upload, say)
    let units = TransferUnits.plan(files)
    // The ones going alone start as they come; the batch fills up around them.
    #expect(units == [[100], [101], Array(0..<64), Array(64..<70)])
    // Bytes cap a batch too: nine files of just under 1 MB pass 8 MB.
    let near = TransferUnits.plan((0..<20).map { ($0, TransferUnits.smallFile - 1, true) })
    #expect(near.map(\.count) == [9, 9, 2])
}

@Test func aFileThereCountsAsSentOnlyWhenItMustBeComplete() {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let there = RemoteEntry(ref: RemoteRef(path: "/sdcard/a.jpg"), name: "a.jpg", kind: .file, size: 10, modified: date)
    func sent(_ entry: RemoteEntry?, size: UInt64? = 10, modified: Date? = date, temporary: Bool = true, keepsDates: Bool = true) -> Bool {
        ExistingItem.isAlreadySent(entry, size: size, modified: modified, sentUnderTemporaryName: temporary, phoneKeepsDates: keepsDates)
    }
    #expect(sent(there))
    #expect(!sent(there, temporary: false))                       // written straight: may be cut off
    #expect(!sent(there, size: 11))
    #expect(!sent(there, modified: date.addingTimeInterval(60)))  // another file of that size
    #expect(sent(there, modified: date.addingTimeInterval(60), keepsDates: false)) // phone dates its uploads
    #expect(!sent(nil))
    let folder = RemoteEntry(ref: RemoteRef(path: "/sdcard/a.jpg"), name: "a.jpg", kind: .directory, size: nil, modified: nil)
    #expect(!sent(folder))
}
