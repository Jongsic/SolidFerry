import DeviceCore
import Foundation
import Testing

private func folder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("partial-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func write(_ text: String, _ partial: PartialDownload) throws {
    try Array(text.utf8).withUnsafeBytes { try partial.write($0) }
}

@Test func aFileThatTurnedUpDuringTheDownloadIsKept() throws {
    let dir = try folder()
    defer { try? FileManager.default.removeItem(at: dir) }
    let target = dir.appendingPathComponent("a.jpg")
    let partial = try PartialDownload.open(for: target, replacing: nil)
    try write("downloaded", partial)
    try "theirs".write(to: target, atomically: false, encoding: .utf8)
    #expect(throws: DeviceFSError.self) { try partial.finish(modified: nil) }
    #expect(try String(contentsOf: target, encoding: .utf8) == "theirs")
    #expect(!FileManager.default.fileExists(atPath: partialDownloadURL(for: target).path))
}

@Test func aFileThatWasThereIsReplaced() throws {
    let dir = try folder()
    defer { try? FileManager.default.removeItem(at: dir) }
    let target = dir.appendingPathComponent("a.jpg")
    try "old".write(to: target, atomically: false, encoding: .utf8)
    let partial = try PartialDownload.open(for: target, replacing: nil)
    try write("new", partial)
    try partial.finish(modified: nil)
    #expect(try String(contentsOf: target, encoding: .utf8) == "new")
}

@Test func twoDownloadsOfOneNameDontShareThePartialFile() throws {
    let dir = try folder()
    defer { try? FileManager.default.removeItem(at: dir) }
    let target = dir.appendingPathComponent("a.jpg")
    let first = try PartialDownload.open(for: target, replacing: nil)
    #expect(throws: DeviceFSError.self) { _ = try PartialDownload.open(for: target, replacing: nil) }
    try write("first", first)
    try first.finish(modified: nil)
    // Free again once the first is done: one planned to replace the file there does.
    let second = try PartialDownload.open(for: target, replacing: true)
    try write("second", second)
    try second.finish(modified: nil)
    #expect(try String(contentsOf: target, encoding: .utf8) == "second")
}

/// Planned as new, but another download of the name finished before this one started (two
/// phones into one Mac folder): that file stays.
@Test func plannedAsNewKeepsAFileThatTurnedUpBeforeItStarted() throws {
    let dir = try folder()
    defer { try? FileManager.default.removeItem(at: dir) }
    let target = dir.appendingPathComponent("a.jpg")
    try "theirs".write(to: target, atomically: false, encoding: .utf8)
    let partial = try PartialDownload.open(for: target, replacing: false)
    try write("mine", partial)
    #expect(throws: DeviceFSError.self) { try partial.finish(modified: nil) }
    #expect(try String(contentsOf: target, encoding: .utf8) == "theirs")
    #expect(!FileManager.default.fileExists(atPath: partialDownloadURL(for: target).path))
}
