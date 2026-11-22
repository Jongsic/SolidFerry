import AppKit
import DeviceCore
import Foundation
import Observation
import os
import TransferKit

enum JobState: Equatable {
    case queued
    case waitingForDevice
    case planning
    /// Building the zip for a packAsZip upload on this Mac; `doneBytes` counts what's in it.
    case zipping(total: UInt64)
    case comparing
    case needsDecision
    case running
    case paused
    case completed
    case failed(String)
    case cancelled

    var isFinished: Bool {
        switch self {
        case .completed, .failed, .cancelled: true
        default: false
        }
    }

    var isActive: Bool {
        switch self {
        case .planning, .zipping, .comparing, .running: true
        default: false
        }
    }
}

enum ItemState: Equatable, Codable {
    case pending
    case running
    case done
    case skipped
    case failed(String)
}

/// One side of a transfer.
enum Endpoint: Hashable, Codable {
    case local(URL)
    case remote(RemoteRef)

    var localURL: URL? { if case .local(let url) = self { url } else { nil } }
    var remoteRef: RemoteRef? { if case .remote(let ref) = self { ref } else { nil } }
}

struct JobItem: Codable {
    let name: String
    let relativePath: String
    let size: UInt64?
    let modified: Date?
    let source: Endpoint
    var destination: Endpoint
    /// What was at the destination when the job was planned (for "ask" and hash checks).
    let existingSize: UInt64?
    let existingModified: Date?
    var decision: FileDecision
    var state: ItemState
    /// A whole folder handled in one operation (same-device copy/move into a free name).
    var isFolder = false
    /// Content hashes, when the file was compared by contents: the incoming file's and the one
    /// that was in the way.
    var incomingHash: String?
    var existingHash: String?
    /// What's at the destination once the job is done with the file (the results window).
    var afterSize: UInt64?
    var afterModified: Date?
}

extension JobItem {
    private enum CodingKeys: String, CodingKey {
        case name, relativePath, size, modified, source, destination, existingSize, existingModified, decision, state, isFolder
        case incomingHash, existingHash, afterSize, afterModified
    }

    /// Fields added later are optional, so transfers saved by an older version still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        relativePath = try c.decode(String.self, forKey: .relativePath)
        size = try c.decodeIfPresent(UInt64.self, forKey: .size)
        modified = try c.decodeIfPresent(Date.self, forKey: .modified)
        source = try c.decode(Endpoint.self, forKey: .source)
        destination = try c.decode(Endpoint.self, forKey: .destination)
        existingSize = try c.decodeIfPresent(UInt64.self, forKey: .existingSize)
        existingModified = try c.decodeIfPresent(Date.self, forKey: .existingModified)
        decision = try c.decode(FileDecision.self, forKey: .decision)
        state = try c.decode(ItemState.self, forKey: .state)
        isFolder = try c.decodeIfPresent(Bool.self, forKey: .isFolder) ?? false
        incomingHash = try c.decodeIfPresent(String.self, forKey: .incomingHash)
        existingHash = try c.decodeIfPresent(String.self, forKey: .existingHash)
        afterSize = try c.decodeIfPresent(UInt64.self, forKey: .afterSize)
        afterModified = try c.decodeIfPresent(Date.self, forKey: .afterModified)
    }

    /// The two files' dates count as the same (as `ExistingItem` compares them).
    var datesMatch: Bool {
        guard let modified, let existingModified else { return false }
        return abs(modified.timeIntervalSince(existingModified)) <= ExistingItem.dateTolerance
    }
}

/// Where a job reads from and writes to.
enum TransferRoute: Codable {
    /// Device → this Mac.
    case download(sources: [RemoteEntry], to: URL)
    /// This Mac → device.
    case upload(sources: [URL], to: RemoteRef)
    /// Device → device (the job's device is the destination). Same device: copied or moved
    /// on the phone; different devices: copied through a temporary file on this Mac.
    case deviceCopy(sources: [RemoteEntry], fromDeviceID: String, fromDeviceName: String, to: RemoteRef, move: Bool)

    var isDownload: Bool { if case .download = self { true } else { false } }
    var isMove: Bool { if case .deviceCopy(_, _, _, _, true) = self { true } else { false } }
    /// The device files come from, when it's not the job's (destination) device.
    var sourceDeviceID: String? { if case .deviceCopy(_, let from, _, _, _) = self { from } else { nil } }
}

enum StopReason {
    case cancel
    case pause
}

/// What a running job is waiting on while no bytes move (said instead of a speed of zero).
enum JobWait: Equatable {
    /// This Mac's disk hasn't taken the last data yet (a busy external drive).
    case disk
    /// The device hasn't answered yet: sending (downloads) or saving (uploads) the data.
    case device
    /// The phone copies or moves files within itself; there's no progress until each is done.
    case onDevice
}

/// How far comparing contents has got.
struct CompareProgress: Equatable {
    var done: Int
    let total: Int
}

/// One copy request between a device and this Mac.
@MainActor @Observable
final class TransferJob: Identifiable {
    let id: UUID
    let deviceID: String
    let deviceName: String
    let route: TransferRoute
    /// Adjusted when the job starts to what its connections can do (see `normalized`).
    var policy: TransferPolicy

    var state: JobState = .queued
    var downloadPlan: TransferPlan?
    var uploadPlan: UploadPlan?
    /// One per file. Changed only through `setItems` and `update`, which keep `counts` in step,
    /// so what's on screen reads numbers instead of going through every file.
    private(set) var items: [JobItem] = []
    private(set) var counts = ItemCounts()
    /// What the progress bar shows: the files done, plus what's in flight (or the zip so far).
    var doneBytes: UInt64 = 0
    var bytesPerSecond: Double = 0
    var currentName: String?
    /// While running: set when nothing has moved for a moment, to say what it's waiting on.
    var waiting: JobWait?
    /// While comparing contents (state `.comparing`).
    var compared: CompareProgress?
    /// When it first started running, and when it ended (the results window).
    var startedAt: Date?
    var finishedAt: Date?
    /// The name of the Mac disk a download writes to (looked up when it starts).
    var destinationVolume: String?

    /// File-promise completions from a Finder drop, called when the job ends.
    var onFinish: [(Error?) -> Void] = []
    /// Why the running task was stopped. Decides the state it settles in, so a cancelled job
    /// can't be revived by a step that finished just as it was cancelled.
    var stopReason: StopReason?
    /// The queue's bookkeeping while it runs the job; nothing on screen reads it.
    @ObservationIgnored var runtime = JobRuntime()

    /// Decisions made per file in the dialog (path below the destination → choice); they win
    /// over the policy for those files.
    let choices: [String: ConflictChoice]
    /// Upload as one zip archive, unpacked on the phone, so file dates survive on phones that
    /// can't set them over this connection (see UploadDates and ZipWriter).
    let packAsZip: Bool
    /// Shown with the finished job: what's left to do on the phone.
    var note: String?

    init(deviceID: String, deviceName: String, route: TransferRoute, policy: TransferPolicy,
         downloadPlan: TransferPlan? = nil, uploadPlan: UploadPlan? = nil, packAsZip: Bool = false,
         choices: [String: ConflictChoice] = [:], lookedUp: [String: RemoteEntry] = [:],
         completions: [(Error?) -> Void] = []) {
        id = UUID()
        self.packAsZip = packAsZip
        self.choices = choices
        self.onFinish = completions
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.route = route
        self.policy = policy
        self.downloadPlan = downloadPlan
        self.uploadPlan = uploadPlan
        runtime.lookedUp = lookedUp
    }

    /// A job saved at the last quit; an unfinished one comes back paused.
    init(saved: SavedJob) {
        id = saved.id ?? UUID()
        startedAt = saved.startedAt
        finishedAt = saved.finishedAt
        note = saved.note
        packAsZip = saved.packAsZip ?? false
        choices = saved.choices ?? [:]
        deviceID = saved.deviceID
        deviceName = saved.deviceName
        route = saved.route
        policy = saved.policy
        downloadPlan = saved.downloadPlan
        uploadPlan = saved.uploadPlan
        items = saved.items.map { item in
            var item = item
            if item.state == .running { item.state = .pending }
            return item
        }
        counts = ItemCounts(items)
        runtime.remoteNames = saved.remoteNames ?? [:]
        runtime.foldersToDate = saved.foldersToDate ?? [:]
        doneBytes = counts.doneBytes
        state = saved.ended?.state ?? .paused
    }

    var saved: SavedJob {
        // A finished job keeps its files for the results window (and a retry); an unfinished zip
        // upload builds its zip, its one file, again.
        let ended = SavedJob.Ended(state)
        return SavedJob(deviceID: deviceID, deviceName: deviceName, route: route, policy: policy,
                        downloadPlan: downloadPlan, uploadPlan: uploadPlan,
                        items: packAsZip && ended == nil ? [] : items, packAsZip: packAsZip, choices: choices,
                        remoteNames: items.isEmpty || runtime.remoteNames.isEmpty ? nil : runtime.remoteNames,
                        foldersToDate: runtime.foldersToDate.isEmpty ? nil : runtime.foldersToDate,
                        id: id, startedAt: startedAt, finishedAt: finishedAt, ended: ended, note: note)
    }

    /// Download convenience (Finder drops, the Download button).
    convenience init(deviceID: String, deviceName: String, sources: [RemoteEntry], destination: URL,
                     policy: TransferPolicy, plan: TransferPlan? = nil, choices: [String: ConflictChoice] = [:],
                     completions: [(Error?) -> Void] = []) {
        self.init(deviceID: deviceID, deviceName: deviceName, route: .download(sources: sources, to: destination),
                  policy: policy, downloadPlan: plan, choices: choices, completions: completions)
    }

    var title: String {
        let names: [String] = switch route {
        case .download(let sources, _): sources.map(\.name)
        case .upload(let sources, _): sources.map(\.lastPathComponent)
        case .deviceCopy(let sources, _, _, _, _): sources.map(\.name)
        }
        guard let first = names.first else { return "" }
        return names.count == 1 ? first : String(localized: "\(first) and \(names.count - 1) more")
    }

    /// What the job does, for its details window: "Download", "Upload", "Copy" or "Move".
    var kindTitle: String {
        switch route {
        case .download: String(localized: "Download")
        case .upload: String(localized: "Upload")
        case .deviceCopy(_, _, _, _, let move): move ? String(localized: "Move") : String(localized: "Copy")
        }
    }

    /// The folder the files came from: "Galaxy:/sdcard/DCIM" or "~/Desktop".
    var sourceLocation: String {
        switch route {
        case .download(let sources, _): "\(deviceName):\(sources.first?.ref.parentPath ?? "/")"
        case .upload(let sources, _): sources.first?.deletingLastPathComponent().abbreviatingWithTildeInPath ?? ""
        case .deviceCopy(let sources, _, let fromName, _, _): "\(fromName):\(sources.first?.ref.parentPath ?? "/")"
        }
    }

    /// The folder they go to: "~/Downloads" or "Galaxy:/sdcard/DCIM".
    var destinationLocation: String {
        switch route {
        case .download(_, let to): to.abbreviatingWithTildeInPath
        case .upload(_, let to), .deviceCopy(_, _, _, let to, _): "\(deviceName):\(to.path)"
        }
    }

    /// "Galaxy:/sdcard/DCIM → ~/Downloads" or "~/Desktop → Galaxy:/sdcard/DCIM".
    var routeDescription: String {
        "\(sourceLocation) \(route.isMove ? "⇢" : "→") \(destinationLocation)"
    }

    /// The Mac folder to reveal when done (downloads).
    var localDestination: URL? {
        if case .download(_, let to) = route { to } else { nil }
    }

    var plannedBytes: UInt64 { downloadPlan?.totalBytes ?? uploadPlan?.totalBytes ?? 0 }

    /// A new list of files (a plan, or the zip that stands for them); progress starts from
    /// what's done among them.
    func setItems(_ new: [JobItem]) {
        items = new
        counts = ItemCounts(new)
        doneBytes = counts.doneBytes
    }

    /// Changes one file, and the counts with it.
    func update(_ i: Int, _ change: (inout JobItem) -> Void) {
        counts.remove(items[i])
        change(&items[i])
        counts.add(items[i])
    }

    func setState(_ i: Int, _ state: ItemState) { update(i) { $0.state = state } }

    var totalBytes: UInt64 { items.isEmpty ? plannedBytes : counts.transferBytes }

    /// Retry has something to do: the job failed, or files did that can go again (a folder in a
    /// file's place stays in the way). Not while the job waits for its device: it goes on by
    /// itself once that's back, on a new connection.
    var canRetry: Bool {
        if state.isActive || state == .waitingForDevice { return false }
        if case .failed = state { return true }
        return items.contains { if case .failed = $0.state { $0.decision != .typeConflict } else { false } }
    }
    var conflictIndexes: [Int] { items.indices.filter { items[$0].decision == .ask } }

    /// By bytes; by items when their sizes aren't known (folders moved whole within a phone).
    var fractionDone: Double {
        if state == .completed { return 1 }
        let total = totalBytes
        if total == 0 { return counts.transfers == 0 ? 0 : Double(counts.done) / Double(counts.transfers) }
        return min(1, Double(doneBytes) / Double(total))
    }

    var secondsRemaining: Double? {
        guard state == .running, bytesPerSecond > 1 else { return nil }
        let seconds = Double(totalBytes - min(doneBytes, totalBytes)) / bytesPerSecond
        // Many tiny files make the byte rate meaningless ("111 hours left"); say nothing then.
        return seconds < 86_400 ? seconds : nil
    }
}

/// A job's files counted by state and decision, kept as they change (`TransferJob.update`).
struct ItemCounts: Equatable {
    var done = 0
    var skipped = 0
    var failed = 0
    /// Files that go, or may (still to be compared by contents), and their size.
    var transfers = 0
    var transferBytes: UInt64 = 0
    /// Size of the files done.
    var doneBytes: UInt64 = 0
    /// Files already there that only got the incoming file's date.
    var datesSet = 0
    /// Files waiting for the user's decision.
    var asking = 0

    init() {}

    init(_ items: [JobItem]) {
        for item in items { add(item) }
    }

    mutating func add(_ item: JobItem) { count(item, adding: true) }
    mutating func remove(_ item: JobItem) { count(item, adding: false) }

    private mutating func count(_ item: JobItem, adding: Bool) {
        let one = adding ? 1 : -1, bytes = item.size ?? 0
        func change(_ total: inout UInt64) { total = adding ? total + bytes : total - bytes }
        switch item.state {
        case .done where item.decision == .setDate:
            datesSet += one
        case .done:
            done += one
            change(&doneBytes)
        case .skipped: skipped += one
        case .failed: failed += one
        case .pending, .running: break
        }
        if item.decision.transfers || item.decision == .needsHash {
            transfers += one
            change(&transferBytes)
        }
        if item.decision == .ask { asking += one }
    }
}

/// What the queue keeps about a job while running it.
struct JobRuntime {
    /// Connections that dropped (device ID → connection generation); the job waits for new
    /// ones instead of spinning on the dead ones. Source and destination are tracked apart.
    var lostConnections: [String: Int] = [:]
    /// Bytes so far of each file in progress (item index → counter its callbacks add to).
    var inFlight: [Int: OSAllocatedUnfairLock<Int>] = [:]
    /// Names already in each device folder written to, for "keep both" naming (saved with the
    /// job: decisions can come after a relaunch).
    var remoteNames: [String: FolderNames] = [:]
    /// Folders the job made on the device, with the date each had on this Mac: set once the
    /// files are in (saved with the job, since a resumed job doesn't make them again).
    var foldersToDate: [String: Date] = [:]
    /// The zip built for a packAsZip job, removed when the job ends.
    var temporaryZip: URL?
    /// Sizes and dates the dialog looked up at the destination (`DeviceFolderPlacer.lookedUp`),
    /// used when planning only if the job starts right away (waiting, they could change);
    /// planning again after that looks for itself.
    var lookedUp: [String: RemoteEntry] = [:]
}
