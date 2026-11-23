import AppKit
import DeviceCore
import Foundation
import Observation
import os
import TransferKit

/// App-wide transfer queue. Copy requests become jobs here; each receiving device runs one job
/// at a time (devices don't block each other; a device that's only the source of a copy can
/// be busy with another job meanwhile), its files in parallel when the backend allows. Jobs
/// can be paused, reordered, retried and resolved ("ask" conflicts) independently.
@MainActor @Observable
final class TransferQueue {
    private(set) var jobs: [TransferJob] = []

    private let hub: DeviceHub
    /// Running job per device ID.
    private var running: [String: (job: TransferJob, task: Task<Void, Never>)] = [:]
    private var retryScheduled = false

    /// Bumped when the transfers window should come forward (a job was added, or one needs
    /// a decision). Windows observe it and call `openWindow`.
    private(set) var windowRequest = 0

    init(hub: DeviceHub) {
        self.hub = hub
        // Finished jobs first (their results stay until removed), then the ones to resume.
        jobs = (QueueStore.loadFinished() + QueueStore.load()).map(TransferJob.init(saved:))
        Self.removeLeftoverZips()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.persist(wait: true)
                // Files cut off mid-download start over when the job resumes.
                for job in self.jobs { self.removePartialDownloads(job, running: true) }
            }
        }
    }

    /// Zips of jobs cut off by a quit or a crash (they can be gigabytes); a job that still needs
    /// its zip builds it again when it runs.
    private static func removeLeftoverZips() {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory
        for name in (try? fm.contentsOfDirectory(atPath: temporary.path)) ?? [] where name.hasPrefix("\(WorkNames.tag)-zip-") {
            try? fm.removeItem(at: temporary.appendingPathComponent(name))
        }
    }

    /// Saves unfinished jobs for the next launch.
    private func persist(wait: Bool = false) {
        lastPersist = .now
        QueueStore.save(jobs.filter { !$0.state.isFinished }.map(\.saved), wait: wait)
    }

    private var lastPersist = ContinuousClock.now

    /// Deletes the hidden partial files of downloads that didn't finish (`running`: only
    /// the ones in progress).
    private func removePartialDownloads(_ job: TransferJob, running: Bool = false) {
        for item in job.items where item.state != .done && (!running || item.state == .running) {
            if let url = item.destination.localURL { unlink(partialDownloadURL(for: url).path) }
        }
    }

    /// The open connection to a device, for dialogs that need to look at another device.
    func fileSystem(of deviceID: String) -> (any DeviceFileSystem)? {
        hub.session(deviceID)?.fileSystem
    }

    var activeJobs: [TransferJob] { jobs.filter { running[$0.deviceID]?.job === $0 } }
    var activeJob: TransferJob? { activeJobs.first }
    var hasUnfinishedJobs: Bool { jobs.contains { !$0.state.isFinished } }
    var needsAttention: Bool { jobs.contains { $0.state == .needsDecision } }

    // MARK: Commands

    func enqueue(_ job: TransferJob) {
        jobs.append(job)
        persist()
        if UserDefaults.standard.bool(forKey: SettingsKey.showTransfersOnStart) { windowRequest += 1 }
        pump()
        // Not starting now (another job ahead, paused, device away): what the dialog saw on the
        // device may change before it does.
        if !isRunning(job) { job.runtime.lookedUp = [:] }
    }

    private func isRunning(_ job: TransferJob) -> Bool {
        running[job.deviceID]?.job === job
    }

    func pause(_ job: TransferJob) {
        guard !job.state.isFinished else { return }
        if isRunning(job) {
            job.stopReason = .pause
            running[job.deviceID]?.task.cancel()
        } else {
            job.state = .paused
        }
        persist()
    }

    func resume(_ job: TransferJob) {
        if job.state == .paused { job.state = .queued }
        pump()
    }

    func cancel(_ job: TransferJob) {
        guard !job.state.isFinished else { return }
        job.state = .cancelled
        if isRunning(job) {
            job.stopReason = .cancel
            running[job.deviceID]?.task.cancel()
        } else {
            finish(job, error: CancellationError())
        }
        removePartialDownloads(job)
        persist()
    }

    /// Runs the failed files again, once the job has stopped: a running job has already
    /// picked the files it sends, so ones made pending meanwhile would be left out and the job
    /// still reported done.
    func retry(_ job: TransferJob) {
        guard !isRunning(job), job.canRetry else { return }
        job.runtime.lostConnections = [:]
        // The zip was removed when the job ended; build it again.
        if job.packAsZip { job.setItems([]) }
        for i in job.items.indices where job.items[i].decision != .typeConflict {
            // A folder in a file's place is still there; that one stays failed.
            if case .failed = job.items[i].state { job.setState(i, .pending) }
        }
        if job.items.isEmpty {
            job.downloadPlan = nil
            job.uploadPlan = nil
        }
        job.finishedAt = nil
        QueueStore.removeFinished([job.id])
        job.state = .queued
        pump()
    }

    func remove(_ job: TransferJob) {
        guard !isRunning(job) else { return }
        if !job.state.isFinished { finish(job, error: CancellationError()) }
        removePartialDownloads(job)
        jobs.removeAll { $0 === job }
        QueueStore.removeFinished([job.id])
        persist()
    }

    func clearFinished() {
        QueueStore.removeFinished(jobs.filter(\.state.isFinished).map(\.id))
        jobs.removeAll { $0.state.isFinished }
        persist()
    }

    /// Puts `moving` just before `target` (at the end without one): each device runs its jobs
    /// in this order.
    func reorder(_ moving: [TransferJob], before target: TransferJob?) {
        let ids = Set(moving.map(\.id))
        guard target.map({ !ids.contains($0.id) }) ?? true else { return }
        jobs.removeAll { ids.contains($0.id) }
        let at = target.flatMap { t in jobs.firstIndex { $0 === t } } ?? jobs.count
        jobs.insert(contentsOf: moving, at: at)
        persist()
    }

    func job(_ id: UUID) -> TransferJob? { jobs.first { $0.id == id } }

    func resolveConflict(in job: TransferJob, at index: Int, answer: ConflictChoice, applyToRest: Bool) {
        let targets = applyToRest ? job.conflictIndexes : [index]
        var reserved = FolderNames(job.items.compactMap { $0.destination.localURL?.path })
        for i in targets {
            switch answer {
            case .skip:
                job.update(i) { $0.decision = .skipExisting; $0.state = .skipped }
            case .overwrite:
                job.update(i) { $0.decision = .overwrite }
            case .keepBoth:
                let destination = renamedDestination(job, job.items[i].destination, reserved: &reserved)
                job.update(i) { $0.decision = .keepBoth; $0.destination = destination }
            }
        }
        if job.conflictIndexes.isEmpty, job.state == .needsDecision {
            job.state = .queued
            pump()
        }
        persist()
    }

    // MARK: Scheduling

    private func isRunnable(_ job: TransferJob) -> Bool {
        guard job.state == .queued || job.state == .waitingForDevice,
              hub.session(job.deviceID)?.fileSystem != nil else { return false }
        if let source = job.route.sourceDeviceID, hub.session(source)?.fileSystem == nil { return false }
        return job.runtime.lostConnections.allSatisfy { device, generation in
            hub.session(device)?.connectionGeneration != generation
        }
    }

    private func pump() {
        // First runnable job of every device that isn't busy.
        for job in jobs where running[job.deviceID] == nil && isRunnable(job) {
            // Cleared here, not when the task starts, so a pause or cancel in between counts.
            job.stopReason = nil
            let task = Task {
                await run(job)
                running[job.deviceID] = nil
                persist()
                pump()
            }
            running[job.deviceID] = (job, task)
        }
        // Jobs whose device is gone wait; look again shortly. Those whose device is back but
        // busy with another job are just waiting their turn.
        for job in jobs where job.state == .queued && !isRunnable(job) {
            job.state = .waitingForDevice
        }
        for job in jobs where job.state == .waitingForDevice && isRunnable(job) {
            job.state = .queued
        }
        if jobs.contains(where: { $0.state == .waitingForDevice }), !retryScheduled {
            retryScheduled = true
            Task {
                try? await Task.sleep(for: .seconds(2))
                retryScheduled = false
                pump()
            }
        }
    }

    // MARK: Execution

    private func run(_ job: TransferJob) async {
        guard let fs = hub.session(job.deviceID)?.fileSystem else {
            job.state = .waitingForDevice
            return
        }
        // Device to device: the source has to be there too (also for a job resumed with its
        // plan already made).
        if let source = job.route.sourceDeviceID, hub.session(source)?.fileSystem == nil {
            job.state = .waitingForDevice
            return
        }
        /// Throws once the job was cancelled or paused, before it moves on to the next step.
        func checkStop() throws {
            if job.stopReason != nil || Task.isCancelled { throw CancellationError() }
        }
        do {
            switch job.route {
            case .download(let sources, _) where job.downloadPlan == nil:
                job.state = .planning
                job.downloadPlan = try await TransferPlanner.expand(sources, in: fs)
            case .upload(let sources, _) where job.uploadPlan == nil:
                job.state = .planning
                job.uploadPlan = try await stoppable { stop in try UploadPlanner.expand(sources, stop: stop) }
            case .deviceCopy(let sources, let from, _, _, _) where job.downloadPlan == nil:
                guard let sourceFS = hub.session(from)?.fileSystem else {
                    job.state = .waitingForDevice
                    return
                }
                job.state = .planning
                do {
                    // Within one phone, a folder whose name is free at the destination (or that
                    // gets a new one, "keep both") goes over whole: what's in it isn't needed.
                    var merging: @Sendable (RemoteEntry) -> Bool = { _ in true }
                    if from == job.deviceID, case .deviceCopy(_, _, _, let destination, _) = job.route {
                        let taken = FolderNames(try await fs.folderListing(destination).keys)
                        let merge = job.policy.existingFolder == .merge
                        merging = { merge && taken.contains($0.name) }
                    }
                    job.downloadPlan = try await TransferPlanner.expand(sources, in: sourceFS, expanding: merging)
                } catch where sourceFS.isConnectionLoss(error) {
                    throw ConnectionLost(deviceID: from, fs: sourceFS) // the job's backend may not know the source's errors
                }
            default: break
            }
            try checkStop()
            if job.items.isEmpty {
                let hashing: Bool = switch job.route {
                case .download, .upload: fs.capabilities.deviceHashing
                case .deviceCopy: false
                }
                job.policy = job.policy.normalized(hashAvailable: hashing, toMac: job.route.isDownload)
                switch job.route {
                case .download: try await classifyDownload(job, fs: fs)
                case .upload where job.packAsZip: try await prepareZip(job, fs: fs)
                case .upload: try await classifyUpload(job, fs: fs)
                case .deviceCopy: try await classifyDeviceCopy(job, fs: fs)
                }
            }
            try checkStop()
            if !job.conflictIndexes.isEmpty {
                job.state = .needsDecision
                windowRequest += 1
                return
            }
            try await createDirectories(job, fs: fs)
            try checkStop()
            if job.startedAt == nil { job.startedAt = .now }
            job.state = .running
            try await transferFiles(job, fs: fs)
            try checkStop()
            await dateFolders(job, fs: fs)
            await recordResults(job, fs: fs)
            if !fs.capabilities.keepsUploadDates {
                // Seen on a file sent through this connection; for next time. ("Kept" is only
                // remembered from `UploadDates.probe`: a connection that hasn't seen a date
                // dropped yet doesn't know they're kept.)
                UploadDates.remember(.ignored, job.deviceID, fs: fs)
            }
            job.state = .completed
            switch job.route {
            case .upload(_, let to):
                notifyChanged(job.deviceID, to.path)
            case .deviceCopy(let sources, let from, _, let to, let move):
                notifyChanged(job.deviceID, to.path)
                if move {
                    try? await removeEmptiedSourceFolders(job)
                    for parent in Set(sources.compactMap(\.ref.parentPath)) { notifyChanged(from, parent) }
                }
            case .download: break
            }
            finish(job, error: job.counts.failed > 0 ? CocoaError(.fileWriteUnknown) : nil)
        } catch {
            for i in job.items.indices where job.items[i].state == .running { job.setState(i, .pending) }
            job.runtime.inFlight = [:]
            job.doneBytes = job.counts.doneBytes
            job.bytesPerSecond = 0
            job.currentName = nil
            switch job.stopReason {
            case .cancel:
                job.state = .cancelled
                finish(job, error: CancellationError())
                return
            case .pause:
                job.state = .paused
                return
            case nil:
                break
            }
            if let lost = error as? ConnectionLost {
                // The device whose connection dropped (for device copies, maybe the source).
                hub.session(lost.deviceID)?.connectionBroke(lost.fs)
                job.runtime.lostConnections[lost.deviceID] = hub.session(lost.deviceID)?.connectionGeneration
                job.state = .waitingForDevice
            } else if fs.isConnectionLoss(error) || hub.session(job.deviceID)?.fileSystem !== fs {
                if fs.isConnectionLoss(error) { hub.session(job.deviceID)?.connectionBroke(fs) }
                let source = job.route.sourceDeviceID
                let device = source.flatMap { hub.session($0)?.fileSystem == nil ? $0 : nil } ?? job.deviceID
                job.runtime.lostConnections[device] = hub.session(device)?.connectionGeneration
                job.state = .waitingForDevice // device went away mid-job
            } else {
                job.state = .failed(UserMessage.describe(error))
                finish(job, error: error)
            }
        }
    }

    /// Decides every file against what's at the destination now (not when it was queued).
    /// Looks at what's already on this Mac for every file, off the main thread: tens of
    /// thousands of lookups on a network or spinning disk would otherwise stall the app.
    private func classifyDownload(_ job: TransferJob, fs: any DeviceFileSystem) async throws {
        guard let original = job.downloadPlan, case .download(_, let destination) = job.route else { return }
        let policy = job.policy, choices = job.choices, sizesWrap = !fs.capabilities.exactLargeSizes
        let (plan, items) = try await stoppable { stop in
            let plan = original.applyingFolderPolicy(policy.existingFolder, destination: destination)
            return (plan, try Self.downloadItems(plan, into: destination, policy: policy, choices: choices,
                                                 sizesWrap: sizesWrap, stop: stop))
        }
        job.downloadPlan = plan
        job.setItems(items)
    }

    private nonisolated static func downloadItems(_ plan: TransferPlan, into destination: URL, policy: TransferPolicy,
                                                  choices: [String: ConflictChoice], sizesWrap: Bool,
                                                  stop: () -> Bool) throws -> [JobItem] {
        try plan.placedLocally(into: destination, policy: policy, choices: choices, sizesWrap: sizesWrap, stop: stop).map { placed in
            let file = placed.file
            let values = placed.existing == .none
                ? nil : try? destination.appendingPathComponent(file.relativePath).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return JobItem(name: file.entry.name, relativePath: file.relativePath, size: file.entry.size,
                           modified: file.entry.modified, source: .remote(file.entry.ref),
                           destination: .local(placed.target),
                           existingSize: values?.fileSize.map(UInt64.init), existingModified: values?.contentModificationDate,
                           decision: placed.decision, state: Self.initialState(placed.decision))
        }
    }

    /// Builds the job's zip on this Mac (a temporary file, removed when the job ends) and makes
    /// it the job's one item. A name that's taken gets "(1)" rather than replacing anything.
    private func prepareZip(_ job: TransferJob, fs: any DeviceFileSystem) async throws {
        guard let plan = job.uploadPlan, case .upload(let sources, let destination) = job.route else { return }
        let stamp = Date().formatted(.verbatim("\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)).\(minute: .twoDigits)",
                                                timeZone: .current, calendar: .current))
        let package = plan.zipPackage(sources: sources, otherwiseNamed: "Files \(stamp)")
        var taken = FolderNames(await fs.tidyLeftovers(try await fs.folderListing(destination)).keys)
        let name = taken.contains(package.fileName) ? uniqueName(package.fileName, taken: &taken) : package.fileName
        // Built again (paused while it was being built): the earlier, unfinished one goes.
        if let earlier = job.runtime.temporaryZip { try? FileManager.default.removeItem(at: earlier) }
        let folder = WorkNames.scratch("zip")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        job.runtime.temporaryZip = folder
        let zip = folder.appendingPathComponent(name)
        job.state = .zipping(total: package.totalBytes)
        job.doneBytes = 0
        let written = OSAllocatedUnfairLock<UInt64>(initialState: 0)
        let ticker = Task { [weak job] in
            while !Task.isCancelled, let job {
                job.doneBytes = written.withLock { $0 }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { ticker.cancel() }
        do {
            try await stoppable { stop in
                try ZipWriter.write(package.items, to: zip) { count in
                    if stop() { throw CancellationError() }
                    written.withLock { $0 += UInt64(count) }
                }
            }
        } catch {
            // An unfinished zip is of no use (it can be gigabytes); it's built again on resume.
            try? FileManager.default.removeItem(at: folder)
            job.runtime.temporaryZip = nil
            throw error
        }
        let size = (try? zip.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init) ?? package.totalBytes
        job.setItems([JobItem(name: name, relativePath: name, size: size, modified: nil, source: .local(zip),
                             destination: .remote(destination.appending(name)), existingSize: nil, existingModified: nil,
                             decision: .transfer, state: .pending)])
        job.note = String(localized: "On the device, unzip “\(name)” in its file manager (My Files) to get the files with their dates. You can delete the zip afterwards.")
    }

    /// Same for uploads: lists each destination folder on the device once.
    private func classifyUpload(_ job: TransferJob, fs: any DeviceFileSystem) async throws {
        guard let original = job.uploadPlan, case .upload(_, let destination) = job.route else { return }
        var placer = DeviceFolderPlacer(on: fs, destination: destination, policy: Self.comparable(job.policy, uploadingTo: job.deviceID, fs: fs),
                                        choices: job.choices, sizesWrap: !fs.capabilities.exactLargeSizes,
                                        lookedUp: job.runtime.lookedUp, tidying: true)
        job.runtime.lookedUp = [:]
        let top = try await placer.listing(of: destination)
        let plan = original.applyingFolderPolicy(job.policy.existingFolder, existingNames: FolderNames(top.keys))
        job.uploadPlan = plan
        placer.reserve(plan.files.map(\.relativePath))
        try await placer.prepare(plan.files.map(\.relativePath))
        var items: [JobItem] = []
        for file in plan.files {
            let placed = try await placer.place(file.relativePath, size: file.size, modified: file.modified)
            items.append(JobItem(name: file.url.lastPathComponent, relativePath: file.relativePath, size: file.size,
                                 modified: file.modified, source: .local(file.url), destination: .remote(placed.target),
                                 existingSize: placed.existing?.size, existingModified: placed.existing?.modified,
                                 decision: placed.decision, state: Self.initialState(placed.decision)))
        }
        job.setItems(items)
        job.runtime.remoteNames = placer.names
    }

    private func notifyChanged(_ deviceID: String, _ path: String) {
        NotificationCenter.default.post(name: .remoteFolderChanged, object: nil, userInfo: ["deviceID": deviceID, "path": path])
    }

    /// Device to device. On the same device a selected item whose name is free at the
    /// destination is one copy/move operation (a whole folder at once); only items merging
    /// into an existing folder, or colliding with a file, are decided file by file.
    private func classifyDeviceCopy(_ job: TransferJob, fs: any DeviceFileSystem) async throws {
        guard let original = job.downloadPlan, case .deviceCopy(let sources, let from, _, let destination, _) = job.route else { return }
        let sameDevice = from == job.deviceID
        let sizesWrap = !fs.capabilities.exactLargeSizes || hub.session(from)?.fileSystem?.capabilities.exactLargeSizes == false
        var placer = DeviceFolderPlacer(on: fs, destination: destination, policy: Self.comparable(job.policy, uploadingTo: job.deviceID, fs: fs),
                                        choices: job.choices, sizesWrap: sizesWrap, lookedUp: job.runtime.lookedUp, tidying: true)
        job.runtime.lookedUp = [:]
        let top = try await placer.listing(of: destination)
        let plan = original.applyingFolderPolicy(job.policy.existingFolder, existingNames: FolderNames(top.keys))
        job.downloadPlan = plan
        placer.reserve(plan.files.map(\.relativePath))

        var items: [JobItem] = []
        var wholeTops = Set<String>()
        if sameDevice {
            for whole in original.wholeItems(sources, placedAs: plan, takenAtDestination: FolderNames(top.keys)) {
                placer.reserve([whole.name])
                wholeTops.insert(whole.name)
                items.append(JobItem(name: whole.source.name, relativePath: whole.name, size: whole.bytes,
                                     modified: whole.source.modified, source: .remote(whole.source.ref),
                                     destination: .remote(destination.appending(whole.name)),
                                     existingSize: nil, existingModified: nil, decision: .transfer, state: .pending,
                                     isFolder: whole.source.isDirectory))
            }
        }

        let fileByFile = plan.files.filter { !wholeTops.contains(String($0.relativePath.split(separator: "/").first ?? "")) }
        try await placer.prepare(fileByFile.map(\.relativePath))
        for file in fileByFile {
            let placed = try await placer.place(file.relativePath, size: file.entry.size ?? 0, modified: file.entry.modified)
            items.append(JobItem(name: file.entry.name, relativePath: file.relativePath, size: file.entry.size,
                                 modified: file.entry.modified, source: .remote(file.entry.ref), destination: .remote(placed.target),
                                 existingSize: placed.existing?.size, existingModified: placed.existing?.modified,
                                 decision: placed.decision, state: Self.initialState(placed.decision)))
        }
        job.runtime.remoteNames = placer.names
        job.setItems(items)
    }

    /// After a move that merged file by file, delete source folders left empty. Never
    /// deletes a folder that still has anything in it.
    private func removeEmptiedSourceFolders(_ job: TransferJob) async throws {
        guard case .deviceCopy(let sources, let from, _, _, true) = job.route,
              let sourceFS = hub.session(from)?.fileSystem, let plan = job.downloadPlan else { return }
        let movedFolders = Set(job.items.filter(\.isFolder).compactMap { $0.source.remoteRef?.path })
        for source in sources where source.isDirectory && !movedFolders.contains(source.ref.path) {
            let dirs = plan.directories.filter { $0 == source.name || $0.hasPrefix(source.name + "/") }
                .sorted { $0.count > $1.count } // deepest first
            for dir in dirs {
                let ref = RemoteRef(path: (source.ref.parentPath ?? "/")).appending(dir)
                var empty = true
                for try await batch in sourceFS.list(ref) where !batch.isEmpty { empty = false }
                if empty { try? await sourceFS.delete([ref]) }
            }
        }
    }

    private nonisolated static func initialState(_ decision: FileDecision) -> ItemState {
        switch decision {
        case .transfer, .overwrite, .keepBoth, .needsHash, .ask, .setDate: .pending
        case .skipIdentical, .skipExisting: .skipped
        case .typeConflict: .failed(String(localized: "A folder with the same name exists."))
        }
    }

    private func renamedDestination(_ job: TransferJob, _ destination: Endpoint, reserved: inout FolderNames) -> Endpoint {
        switch destination {
        case .local(let url): return .local(uniqueDestination(for: url, reserved: &reserved))
        case .remote(let ref):
            let dir = ref.parentPath ?? "/"
            var taken = job.runtime.remoteNames[dir] ?? FolderNames()
            let renamed = RemoteRef(path: dir).appending(uniqueName(ref.name, taken: &taken))
            job.runtime.remoteNames[dir] = taken
            return .remote(renamed)
        }
    }

    /// The decision for a file "copy if contents differ" compared, once its hashes are in.
    private func decide(_ i: Int, same: Bool, in job: TransferJob, reserved: inout FolderNames) {
        let decision = FileDecision.afterHash(equal: same, dateMatches: job.items[i].datesMatch, job.policy)
        let destination = decision == .keepBoth
            ? renamedDestination(job, job.items[i].destination, reserved: &reserved) : job.items[i].destination
        job.update(i) {
            $0.decision = decision
            $0.destination = destination
            if decision == .skipIdentical { $0.state = .skipped }
        }
    }

    private func createDirectories(_ job: TransferJob, fs: any DeviceFileSystem) async throws {
        switch job.route {
        case .download(_, let destination):
            // Off the main thread: a slow disk would hold up the app.
            let dirs = job.downloadPlan?.directories ?? []
            job.destinationVolume = try await Task.detached {
                try DiskWait.during {
                    let fm = FileManager.default
                    try fm.createDirectory(at: destination, withIntermediateDirectories: true)
                    for dir in dirs {
                        try? fm.createDirectory(at: destination.appendingPathComponent(dir), withIntermediateDirectories: true)
                    }
                    return try? destination.resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName
                }
            }.value
        case .deviceCopy(_, _, _, let destination, _):
            // Folders for file-by-file items (whole-folder operations create their own).
            let wholeTops = Set(job.items.filter(\.isFolder).map(\.relativePath))
            let dirs = (job.downloadPlan?.directories ?? []).filter { !wholeTops.contains(String($0.split(separator: "/").first ?? "")) }
            try await makeMissing(dirs.map { destination.appending($0) }, job: job, fs: fs)
        case .upload where job.packAsZip:
            break // the folders are inside the zip
        case .upload(_, let destination):
            let dirs = job.uploadPlan?.directories ?? []
            let made = Set(try await makeMissing(dirs.map { destination.appending($0) }, job: job, fs: fs).map(\.path))
            // The folders made here take the date they have on this Mac (folders already there
            // keep theirs), once their files are in.
            guard fs.capabilities.setsFolderDates, let dates = job.uploadPlan?.directoryDates else { return }
            for dir in dirs {
                let path = destination.appending(dir).path
                if made.contains(path), let date = dates[dir] { job.runtime.foldersToDate[path] = date }
            }
        }
    }

    /// Makes the job's folders on the phone that planning didn't see there, all at once.
    @discardableResult
    private func makeMissing(_ refs: [RemoteRef], job: TransferJob, fs: any DeviceFileSystem) async throws -> [RemoteRef] {
        let missing = refs.filter { job.runtime.remoteNames[$0.parentPath ?? ""]?.contains($0.name) != true }
        guard !missing.isEmpty else { return [] }
        try await fs.makeDirectories(missing)
        for ref in missing { job.runtime.remoteNames[ref.parentPath ?? "", default: FolderNames()].insert(ref.name) }
        return missing
    }

    /// Dates the folders the job made, now that nothing more goes into them (a file arriving
    /// would change a folder's date again). If the phone refuses, they keep the date they were
    /// made; the files are what the job was for.
    private func dateFolders(_ job: TransferJob, fs: any DeviceFileSystem) async {
        let dates = job.runtime.foldersToDate
        guard !dates.isEmpty else { return }
        do {
            try await fs.setFolderDates(dates)
        } catch {
            transferLog.error("folder dates not set: \(String(describing: error), privacy: .public)")
        }
        job.runtime.foldersToDate = [:]
    }

    // MARK: Phones that don't keep upload dates

    /// The policy to compare with when sending to `deviceID`: on a phone that stamps uploads
    /// with the upload time, a file sent earlier always "differs" by date, so only sizes count
    /// (otherwise every upload would send everything again).
    static func comparable(_ policy: TransferPolicy, uploadingTo deviceID: String, fs: any DeviceFileSystem) -> TransferPolicy {
        guard UploadDates.known(deviceID, fs: fs) == .ignored else { return policy }
        var adjusted = policy
        adjusted.sizeOnlyMatch = true
        return adjusted
    }

    /// Files at once where the backend runs connections side by side (ADB).
    private static let parallelTransfers = 3
    /// How often a running job's progress is saved, to resume after a crash.
    private static let saveInterval: Duration = .seconds(5)

    private func transferFiles(_ job: TransferJob, fs: any DeviceFileSystem) async throws {
        var reserved = FolderNames(job.items.compactMap { $0.destination.localURL?.path })
        // Files compared by contents are all decided first, so what goes is settled before
        // anything is sent (and the speed shown is the transfer's alone).
        try await compareContents(job, fs: fs, reserved: &reserved)
        try await setDates(job)
        job.state = .running
        let pending = job.items.indices.filter { job.items[$0].state == .pending && job.items[$0].decision.transfers }
        // Otherwise (MTP) two at once. The connection still takes one request at a time, but the
        // next file is already waiting when one ends, rather than the line standing empty while
        // this picks and opens it. Between two phones, one also comes in from the source while
        // the other goes out to the target.
        let limit = fs.capabilities.parallelTransfers ? Self.parallelTransfers : 2
        let sizesWrap = !fs.capabilities.exactLargeSizes
        job.doneBytes = job.counts.doneBytes

        let onDevice = job.route.sourceDeviceID == job.deviceID
        let ticker = Task { [weak job] in
            // The speed is what moved over the last few seconds: per tick it jumps between
            // bursts and pauses (files finishing, a disk taking its time).
            var samples: [(time: ContinuousClock.Instant, bytes: UInt64)] = []
            var lastMove = ContinuousClock.now
            while !Task.isCancelled, let job {
                try? await Task.sleep(for: .milliseconds(250))
                // Stopped while asleep: the job has settled its numbers; don't overwrite them.
                if Task.isCancelled { break }
                let inFlight = job.runtime.inFlight.values.reduce(0) { $0 + $1.withLock { $0 } }
                let bytes = job.counts.doneBytes + UInt64(inFlight)
                let now = ContinuousClock.now
                // A file that stopped or failed midway takes its bytes back: start over from there.
                if let last = samples.last, bytes < last.bytes { samples = [] }
                if samples.last?.bytes != bytes { lastMove = now }
                samples.append((now, bytes))
                samples.removeAll { now - $0.time > Self.speedWindow }
                job.doneBytes = bytes
                if let first = samples.first, now - first.time >= .milliseconds(500) {
                    job.bytesPerSecond = Double(bytes - first.bytes) / ((now - first.time) / .seconds(1))
                }
                job.waiting = if now - lastMove < Self.standstill || job.runtime.inFlight.isEmpty {
                    nil
                } else if onDevice {
                    .onDevice
                } else if job.route.isDownload, let disk = DiskWait.longest, disk >= .milliseconds(500) {
                    .disk
                } else {
                    .device
                }
            }
        }
        defer {
            ticker.cancel()
            job.waiting = nil
        }

        // Downloads share connections only where they're cheap to run side by side (ADB); MTP
        // has one pipe anyway.
        let units = TransferUnits.plan(pending.map { i in
            let item = job.items[i]
            let download = if case (.remote, .local) = (item.source, item.destination) { true } else { false }
            return (i, item.size, download && fs.capabilities.parallelTransfers)
        })

        try await withThrowingTaskGroup(of: [(Int, ItemFailure?)].self) { group in
            var next = units.makeIterator()
            @MainActor func launch() async throws -> Bool {
                guard let unit = next.next() else { return false }
                let counter = OSAllocatedUnfairLock(initialState: 0)
                for i in unit { job.setState(i, .running) }
                job.runtime.inFlight[unit[0]] = counter
                job.currentName = job.items[unit[0]].name
                if unit.count > 1 {
                    let unitItems = unit.map { job.items[$0] }
                    let bundled = UserDefaults.standard.bool(forKey: SettingsKey.bundleSmallFiles)
                    group.addTask {
                        let results = OSAllocatedUnfairLock(initialState: [(Int, ItemFailure?)]())
                        var going: [Int] = [] // positions in the unit
                        for (k, item) in unitItems.enumerated() {
                            switch Self.placeSincePlanned(item, sizesWrap: sizesWrap) {
                            case .free: going.append(k)
                            case .thisFile: results.withLock { $0.append((unit[k], nil)) }
                            case .taken(let name): results.withLock { $0.append((unit[k], ItemFailure(DeviceFSError.alreadyExists(name), fs: fs))) }
                            }
                        }
                        let items = going.map { k in
                            let item = unitItems[k]
                            guard case (.remote(let ref), .local(let url)) = (item.source, item.destination) else { fatalError() }
                            return DownloadItem(RemoteEntry(ref: ref, name: item.name, kind: .file, size: item.size, modified: item.modified),
                                                to: url, replacing: item.decision == .overwrite)
                        }
                        if items.isEmpty { return results.withLock { $0 } }
                        do {
                            let progress: @Sendable (Int) -> Void = { n in counter.withLock { $0 += n } }
                            let report: @Sendable (Int, Error?) -> Void = { [going] k, error in
                                results.withLock { $0.append((unit[going[k]], error.map { ItemFailure($0, fs: fs) })) }
                            }
                            if bundled {
                                try await fs.downloadBundled(items, progress: progress, completed: report)
                            } else {
                                try await fs.downloadMany(items, progress: progress, completed: report)
                            }
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            if Task.isCancelled { throw CancellationError() }
                            // The rest of the batch failed the same way (usually: unplugged).
                            let failure = ItemFailure(error, fs: fs)
                            results.withLock { done in
                                let reported = Set(done.map(\.0))
                                done += unit.filter { !reported.contains($0) }.map { ($0, failure) }
                            }
                        }
                        return results.withLock { $0 }
                    }
                    return true
                }
                let i = unit[0]
                let item = job.items[i]
                let sourceFS = job.route.sourceDeviceID.flatMap { hub.session($0)?.fileSystem }
                let moveRoute: Bool = if case .deviceCopy(_, _, _, _, true) = job.route { true } else { false }
                let sameDevice = job.route.sourceDeviceID == job.deviceID
                let writing = item.size.map { $0 <= Self.directWriteLimit } == true ? Self.uploadWriting : .safe
                group.addTask {
                    do {
                        let progress: @Sendable (Int) -> Void = { n in counter.withLock { $0 += n } }
                        switch (item.source, item.destination) {
                        case (.remote(let ref), .local(let url)):
                            switch Self.placeSincePlanned(item, sizesWrap: sizesWrap) {
                            case .free: break
                            case .thisFile: return [(i, nil)]
                            case .taken(let name): throw DeviceFSError.alreadyExists(name)
                            }
                            let entry = RemoteEntry(ref: ref, name: item.name, kind: .file, size: item.size, modified: item.modified)
                            try await fs.download(entry, to: url, replacing: item.decision == .overwrite, progress: progress)
                        case (.local(let url), .remote(let ref)):
                            try await Self.placed(item, at: ref, on: fs, writing: writing) {
                                try await fs.upload(url, to: ref, modified: item.modified, replacing: item.decision == .overwrite,
                                                    writing: writing, progress: progress)
                            }
                        case (.remote(let from), .remote(let to)) where sameDevice:
                            let replacing = item.decision == .overwrite
                            if moveRoute {
                                try await fs.moveOnDevice(from, to: to, replacing: replacing)
                            } else {
                                try await fs.copyOnDevice(from, to: to, replacing: replacing)
                            }
                            progress(Int(item.size ?? 0))
                        case (.remote(let from), .remote(let to)):
                            // Another device (sferry devtest-pair checks this path).
                            guard let sourceFS else { throw DeviceFSError.unsupported }
                            let entry = RemoteEntry(ref: from, name: item.name, kind: .file, size: item.size, modified: item.modified)
                            do {
                                try await Self.placed(item, at: to, on: fs, writing: writing) {
                                    try await DeviceToDevice.copy(entry, from: sourceFS, to: to, on: fs, replacing: item.decision == .overwrite,
                                                                  writing: writing, progress: progress)
                                }
                            } catch let failed as DeviceToDevice.SourceFailed {
                                if sourceFS.isConnectionLoss(failed.underlying) { throw SourceConnectionLost(underlying: failed.underlying, fs: sourceFS) }
                                throw failed.underlying
                            }
                        default:
                            throw DeviceFSError.unsupported
                        }
                        return [(i, nil)]
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        if Task.isCancelled { throw CancellationError() }
                        return [(i, ItemFailure(error, fs: fs))]
                    }
                }
                return true
            }
            for _ in 0..<limit {
                guard try await launch() else { break }
            }
            while let results = try await group.next() {
                var lost: (deviceID: String, fs: any DeviceFileSystem)?
                for (i, failure) in results {
                    job.runtime.inFlight[i] = nil
                    if let failure {
                        if let dropped = failure.lost {
                            // Unplugged: put it back and wait for the device rather than failing
                            // every remaining file.
                            job.setState(i, .pending)
                            lost = dropped.onSource ? job.route.sourceDeviceID.map { ($0, dropped.fs) } : (job.deviceID, dropped.fs)
                        } else {
                            job.setState(i, .failed(failure.message))
                        }
                    } else {
                        job.setState(i, .done)
                    }
                }
                if let lost {
                    group.cancelAll()
                    throw ConnectionLost(deviceID: lost.deviceID, fs: lost.fs)
                }
                if ContinuousClock.now - lastPersist > Self.saveInterval { persist() }
                job.doneBytes = job.counts.doneBytes + UInt64(job.runtime.inFlight.values.reduce(0) { $0 + $1.withLock { $0 } })
                _ = try await launch()
            }
        }
        job.currentName = nil
        job.bytesPerSecond = 0
    }

    // MARK: Before and after the files go

    /// Files compared by contents at a time: one command on the phone, this Mac's side in
    /// parallel meanwhile. Small enough for the count on screen to move.
    private static let compareBatch = 50
    /// The speed shown covers this much time.
    static let speedWindow: Duration = .seconds(3)
    /// Nothing moved for this long: say what the job waits on instead of a speed.
    static let standstill: Duration = .seconds(1)

    /// "Copy if contents differ": hashes both sides of every same-size file in the way and
    /// decides it, in the files' order, before anything is sent.
    private func compareContents(_ job: TransferJob, fs: any DeviceFileSystem, reserved: inout FolderNames) async throws {
        let indexes = job.items.indices.filter { job.items[$0].decision == .needsHash && job.items[$0].state == .pending }
        guard !indexes.isEmpty else { return }
        job.state = .comparing
        job.compared = CompareProgress(done: 0, total: indexes.count)
        defer {
            job.compared = nil
            job.currentName = nil
        }
        let download = job.route.isDownload
        for start in stride(from: 0, to: indexes.count, by: Self.compareBatch) {
            if job.stopReason != nil { throw CancellationError() }
            let batch = Array(indexes[start..<min(start + Self.compareBatch, indexes.count)])
            job.currentName = job.items[batch[0]].name
            let refs = batch.map { job.items[$0].source.remoteRef ?? job.items[$0].destination.remoteRef }
            let urls = batch.map { job.items[$0].source.localURL ?? job.items[$0].destination.localURL }
            async let local = localMD5s(urls)
            // A backend without hashing (a remembered policy reused for an MTP device) treats
            // same-size files as different rather than guessing they're equal.
            let remote = fs.capabilities.deviceHashing ? try await fs.contentHashes(refs.compactMap { $0 }) : [:]
            let localHashes = try await local
            // Stopped meanwhile: hashes may be missing, which would read as "different".
            try Task.checkCancellation()
            if job.stopReason != nil { throw CancellationError() }
            for (n, i) in batch.enumerated() {
                let remoteHash = refs[n].flatMap { remote[$0.path] }, localHash = localHashes[n]
                job.update(i) {
                    $0.incomingHash = download ? remoteHash : localHash
                    $0.existingHash = download ? localHash : remoteHash
                }
                decide(i, same: remoteHash != nil && remoteHash == localHash, in: job, reserved: &reserved)
            }
            job.compared?.done = start + batch.count
        }
    }

    /// Files already on this Mac that only take the incoming file's date.
    private func setDates(_ job: TransferJob) async throws {
        let work = job.items.indices.compactMap { i -> (Int, URL, Date)? in
            let item = job.items[i]
            guard item.decision == .setDate, item.state == .pending, let url = item.destination.localURL,
                  let modified = item.modified else { return nil }
            return (i, url, modified)
        }
        guard !work.isEmpty else { return }
        let results = await Task.detached {
            work.map { i, url, modified -> (Int, String?) in
                DiskWait.during {
                    do {
                        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
                        return (i, nil)
                    } catch {
                        return (i, UserMessage.describe(error))
                    }
                }
            }
        }.value
        for (i, failure) in results {
            job.setState(i, failure.map(ItemState.failed) ?? .done)
        }
    }

    /// What's at the destination of every file the job wrote (or dated), for the results
    /// window: on this Mac each file, on a device each folder once. Best effort; a file that
    /// can't be looked at shows no "after".
    private func recordResults(_ job: TransferJob, fs: any DeviceFileSystem) async {
        let written = job.items.indices.filter { job.items[$0].state == .done && !job.items[$0].isFolder }
        guard !written.isEmpty else { return }
        if job.route.isDownload {
            let urls = written.map { job.items[$0].destination.localURL }
            let stamps = await Task.detached {
                urls.map { url -> (UInt64?, Date?)? in
                    // The URL keeps the values read when the job was planned (what was there
                    // before); read the file as it is now.
                    guard var url else { return nil }
                    url.removeAllCachedResourceValues()
                    return DiskWait.during { (try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])).map { ($0.fileSize.map(UInt64.init), $0.contentModificationDate) } }
                }
            }.value
            for (i, stamp) in zip(written, stamps) {
                job.update(i) { $0.afterSize = stamp?.0; $0.afterModified = stamp?.1 }
            }
            return
        }
        let byFolder = Dictionary(grouping: written) { job.items[$0].destination.remoteRef?.parentPath ?? "" }
        for (folder, indexes) in byFolder where !folder.isEmpty {
            guard let listing = try? await fs.folderListing(RemoteRef(path: folder)) else { continue }
            // Big MTP folders list by name; sizes and dates are read for these files only.
            let found = indexes.compactMap { i in job.items[i].destination.remoteRef.flatMap { listing[$0.name] }.map { (i, $0) } }
            guard let entries = try? await fs.completingDetails(found.map(\.1)) else { continue }
            for ((i, _), entry) in zip(found, entries) {
                job.update(i) { $0.afterSize = entry.size; $0.afterModified = entry.modified }
            }
        }
    }

    private func finish(_ job: TransferJob, error: Error?) {
        job.finishedAt = .now
        if job.state.isFinished { QueueStore.saveFinished(job.saved) }
        if let zip = job.runtime.temporaryZip {
            try? FileManager.default.removeItem(at: zip)
            job.runtime.temporaryZip = nil
        }
        // No names or messages: they can carry the user's file names.
        let outcome = if case .failed = job.state { "failed" } else { String(describing: job.state) }
        transferLog.notice("job \(outcome, privacy: .public): copied \(job.counts.done) skipped \(job.counts.skipped) failed \(job.counts.failed)")
        let completions = job.onFinish
        job.onFinish = []
        for completion in completions { completion(error) }
    }
}

private let transferLog = Logger(subsystem: WorkNames.subsystem, category: "transfers")

/// A device's connection dropped mid-job; the job waits for that device.
private struct ConnectionLost: Error {
    let deviceID: String
    /// The connection that dropped.
    let fs: any DeviceFileSystem
}

extension TransferQueue {
    /// Files up to this size may be written straight under their name (Settings, 16 MB unless
    /// changed). The rename saved is a fixed cost per file, about 70 ms; above 16 MB it's a few
    /// percent of the transfer.
    static var directWriteLimit: UInt64 {
        let mb = UserDefaults.standard.integer(forKey: SettingsKey.directWriteLimitMB)
        return mb > 0 ? UInt64(mb) * 1_000_000 : .max
    }

    /// How uploads land, from Settings: two separate permissions.
    static var uploadWriting: UploadWriting {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: SettingsKey.writeNewFilesDirectly) else { return .safe }
        return defaults.bool(forKey: SettingsKey.writeReplacedFilesDirectly) ? .direct : .directForNewFiles
    }

    enum PlaceOnMac: Sendable { case free, thisFile, taken(String) }

    /// Whether a download's place on this Mac is still as planned. A file that has turned up
    /// where one was to go as new (another job's, or the user's while this one was paused) isn't
    /// replaced; one that is this very file (written before the job's progress was saved, or the
    /// same file from another phone) counts as done.
    nonisolated static func placeSincePlanned(_ item: JobItem, sizesWrap: Bool) -> PlaceOnMac {
        guard item.decision != .overwrite, let url = item.destination.localURL else { return .free }
        switch ExistingItem.at(url, remoteSize: item.size, remoteModified: item.modified, remoteSizeWraps: sizesWrap) {
        case .none: return .free
        case .file(sizeMatches: true, dateMatches: true): return .thisFile
        default: return .taken(url.lastPathComponent)
        }
    }

    /// Runs an upload planned from what was at `ref` then. A file planned as new that's
    /// there now (not overwritten, see `DeviceFileSystem.upload`) counts as done when it's
    /// this very file (`ExistingItem.isAlreadySent`).
    nonisolated static func placed(_ item: JobItem, at ref: RemoteRef, on fs: any DeviceFileSystem, writing: UploadWriting,
                                   _ upload: () async throws -> Void) async throws {
        do {
            try await upload()
        } catch DeviceFSError.alreadyExists(let name) where item.decision != .overwrite {
            let there = try? await fs.entry(at: ref)
            guard ExistingItem.isAlreadySent(there, size: item.size, modified: item.modified,
                                             sentUnderTemporaryName: writing == .safe,
                                             phoneKeepsDates: fs.capabilities.keepsUploadDates) else {
                throw DeviceFSError.alreadyExists(name)
            }
        }
    }
}

/// Device to device: the source phone's connection dropped (not the destination's).
private struct SourceConnectionLost: Error {
    let underlying: Error
    let fs: any DeviceFileSystem
}

extension Notification.Name {
    /// A job changed a device folder (userInfo: deviceID, path); windows showing it reload.
    static let remoteFolderChanged = Notification.Name("RemoteFolderChanged")
    /// "Show hidden files" changed in one window (object: its BrowserModel); the others follow.
    static let showHiddenChanged = Notification.Name("ShowHiddenChanged")
}

private struct ItemFailure: Sendable {
    let message: String
    /// The connection that dropped, and whether it's the source device's (device-to-device copies).
    let lost: (fs: any DeviceFileSystem, onSource: Bool)?

    init(_ error: Error, fs: any DeviceFileSystem) {
        if let source = error as? SourceConnectionLost {
            message = UserMessage.describe(source.underlying)
            lost = (source.fs, true)
        } else {
            message = UserMessage.describe(error)
            lost = fs.isConnectionLoss(error) ? (fs, false) : nil
        }
    }
}
