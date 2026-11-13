import DeviceCore
import Foundation
import os
import TransferKit

/// Unfinished jobs saved across launches, with each file's decision and progress so a
/// resumed job doesn't plan again (and e.g. "keep both" doesn't copy finished files twice).
struct SavedJob: Codable {
    let deviceID: String
    let deviceName: String
    let route: TransferRoute
    let policy: TransferPolicy
    let downloadPlan: TransferPlan?
    let uploadPlan: UploadPlan?
    let items: [JobItem]
    /// Sent as one zip archive (rebuilt when resumed; the temporary zip doesn't survive).
    var packAsZip: Bool? = nil
    /// Per-file decisions from the dialog.
    var choices: [String: ConflictChoice]? = nil
    /// Names in the phone folders it writes to, as planned: "keep both" names chosen after a
    /// relaunch avoid them.
    var remoteNames: [String: FolderNames]? = nil
}

enum QueueStore {
    private static let writer = DispatchQueue(label: "\(WorkNames.subsystem).queue-store")
    private static let log = Logger(subsystem: WorkNames.subsystem, category: "transfers")
    /// Bumped when the saved format changes incompatibly.
    private static let version = 1

    /// Off for scripted development runs (`-dev.quitWhenDone`, `-dev.snapshot`): their jobs
    /// mustn't land in, or be mixed with, the user's queue (a run stopped at its time limit
    /// leaves its job behind).
    static var isEnabled: Bool {
        #if DEBUG
        UserDefaults.standard.string(forKey: "dev.quitWhenDone") == nil
            && UserDefaults.standard.string(forKey: "dev.snapshot") == nil
        #else
        true
        #endif
    }

    static var url: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent(WorkNames.subsystem, isDirectory: true).appendingPathComponent("Queue.json")
    }

    private struct File: Codable {
        let version: Int
        let jobs: [Lossy<SavedJob>]
    }

    /// One job that couldn't be read doesn't cost the others.
    private struct Lossy<Value: Codable>: Codable {
        let value: Value?

        init(_ value: Value) { self.value = value }

        init(from decoder: Decoder) throws {
            value = try? Value(from: decoder)
        }

        func encode(to encoder: Encoder) throws {
            try value.encode(to: encoder)
        }
    }

    static func load() -> [SavedJob] {
        guard isEnabled, let data = try? Data(contentsOf: url) else { return [] }
        do {
            // A file without a version is a bare array of jobs.
            let saved: [Lossy<SavedJob>]
            if let file = try? JSONDecoder().decode(File.self, from: data) {
                saved = file.jobs
            } else {
                saved = try JSONDecoder().decode([Lossy<SavedJob>].self, from: data)
            }
            let jobs = saved.compactMap(\.value)
            if jobs.count < saved.count {
                log.error("skipped \(saved.count - jobs.count, privacy: .public) saved transfers that couldn't be read")
            }
            return jobs
        } catch {
            // Keep it for a look rather than overwriting it with the next save.
            let aside = url.deletingLastPathComponent().appendingPathComponent("Queue.unreadable.json")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: url, to: aside)
            log.error("saved transfers couldn't be read (moved to \(aside.lastPathComponent, privacy: .public)): \(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// Writes in the background, in order; nothing left to resume removes the file.
    static func save(_ jobs: [SavedJob], wait: Bool = false) {
        guard isEnabled else { return }
        let work: @Sendable () -> Void = {
            do {
                if jobs.isEmpty {
                    if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                    return
                }
                let data = try JSONEncoder().encode(File(version: version, jobs: jobs.map(Lossy.init)))
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch {
                log.error("couldn't save transfers: \(String(describing: error), privacy: .public)")
            }
        }
        if wait { writer.sync(execute: work) } else { writer.async(execute: work) }
    }
}
