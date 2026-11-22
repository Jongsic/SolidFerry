import AppKit
import DeviceCore
import SwiftUI
import TransferKit

struct DownloadRequest: Identifiable {
    let id = UUID()
    let deviceID: String
    let deviceName: String
    let entries: [RemoteEntry]
    let fileSystem: any DeviceFileSystem
    /// Set for a Finder drop: the folder is fixed and the promises complete with the job.
    var droppedAt: URL?
    var completions: [(Error?) -> Void] = []
}

/// "Download to Mac": scans the selection, shows what already exists at the destination,
/// lets the user pick the conflict policy, then queues the job. Used for the Download
/// button and for Finder drops alike; it starts from the options used last time.
struct DownloadSheet: View {
    let request: DownloadRequest
    @Environment(TransferQueue.self) private var queue
    @Environment(\.dismiss) private var dismiss

    @State private var destination: URL
    @State private var policy = PolicyStore.lastPolicy
    @State private var queued = false
    @State private var plan: TransferPlan?
    @State private var scanned = 0
    @State private var scanError: String?
    /// Each planned file (after the folder policy) and what's at the destination for it; depends
    /// only on the destination and folder policy, so switching the file policy recounts instantly.
    @State private var rows: [FileRow]?
    @State private var compared: (done: Int, total: Int)?
    @State private var choices: [String: ConflictChoice] = [:]
    @State private var previewing = false
    /// Bumped by the list's refresh button: the selection and the destination are read again.
    @State private var refreshes = 0

    init(request: DownloadRequest) {
        self.request = request
        _destination = State(initialValue: request.droppedAt ?? PolicyStore.lastDestination)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Download to Mac").appFont(.headline)

            TransferRouteHeader(
                source: .device(request.deviceID, request.deviceName, paths: request.entries.map(\.ref.path), title: selectionTitle),
                sourceDetail: planDetail,
                destination: .macFolder(destination)
            ) {
                if request.droppedAt == nil {
                    Button("Change…", action: chooseDestination).controlSize(.small)
                } else {
                    Text("Dropped in Finder").foregroundStyle(.secondary)
                }
            }

            if let scanError {
                Text(scanError).foregroundStyle(.red)
            }

            Divider()

            FileComparisonPanel(policy: $policy, choices: $choices, previewing: $previewing, rows: rows, summary: summary,
                                progress: compared, hashAvailable: request.fileSystem.capabilities.deviceHashing,
                                datesApply: true, refresh: refresh)
                .onAppear { policy = policy.normalized(hashAvailable: request.fileSystem.capabilities.deviceHashing, toMac: true) }

            Divider()

            TransferDialogFooter(outcome: summary?.footer(), canStart: true, cancel: { dismiss() }, start: start)
        }
        .padding(20)
        .scaledFrame(minWidth: 780)
        .navigationTitle("Download to Mac")
        .textArea(.panels)
        .scaledButtons()
        .task(id: ScanKey(previewing: previewing, refreshes: refreshes)) { if previewing, plan == nil { await scan() } }
        .onDisappear {
            // Closed without queueing: release Finder's wait on the promises.
            if !queued { request.completions.forEach { $0(CocoaError(.userCancelled)) } }
        }
        .task(id: StatKey(files: plan?.files.count, destination: destination, folders: policy.existingFolder, refreshes: refreshes)) {
            await statDestination()
        }
    }

    private struct ScanKey: Equatable {
        let previewing: Bool
        let refreshes: Int
    }

    private struct StatKey: Equatable {
        let files: Int?
        let destination: URL
        let folders: ExistingFolderPolicy
        let refreshes: Int
    }

    private func refresh() {
        plan = nil
        rows = nil
        scanned = 0
        scanError = nil
        refreshes += 1
    }

    /// "12 files · 2.3 GB", or the scan's progress; before a preview, what was selected.
    private var planDetail: String? {
        if let plan { return String(localized: "\(plan.files.count) files · \(ByteFormat.string(plan.totalBytes))") }
        guard previewing else { return String(localized: "\(request.entries.count) items") }
        return scanned > 0 ? String(localized: "Scanning… \(scanned)") : nil
    }

    private var selectionTitle: String {
        guard let first = request.entries.first else { return "" }
        return request.entries.count == 1 ? first.name : String(localized: "\(first.name) and \(request.entries.count - 1) more")
    }

    private var summary: TransferSummary? {
        guard let rows else { return nil }
        return TransferSummary(rows: rows, policy: policy, choices: choices)
    }

    private func scan() async {
        scanError = nil
        do {
            plan = try await TransferPlanner.expand(request.entries, in: request.fileSystem, progress: { count in
                Task { @MainActor in scanned = count }
            })
        } catch is CancellationError {
            // Replaced by a newer scan (or the dialog closed); that one reports.
        } catch {
            if !Task.isCancelled { scanError = UserMessage.describe(error) }
        }
    }

    /// Stats every planned file at the destination off the main thread.
    private func statDestination() async {
        guard let plan else { return }
        let destination = destination
        let effective = plan.applyingFolderPolicy(policy.existingFolder, destination: destination)
        let sizesWrap = !request.fileSystem.capabilities.exactLargeSizes
        rows = nil
        compared = nil
        let result = try? await stoppable { stop in
            try effective.files.map { file -> FileRow in
                if stop() { throw CancellationError() }
                let url = destination.appendingPathComponent(file.relativePath)
                let item = ExistingItem.at(url, remoteSize: file.entry.size, remoteModified: file.entry.modified,
                                           remoteSizeWraps: sizesWrap)
                let values = item == .none ? nil : try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                return FileRow(relativePath: file.relativePath, existing: item,
                               incomingSize: file.entry.size, incomingDate: file.entry.modified,
                               existingSize: values?.fileSize.map(UInt64.init), existingDate: values?.contentModificationDate)
            }
        }
        // A newer comparison (another folder or policy) may have started meanwhile.
        guard !Task.isCancelled, let result else { return }
        rows = result
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = destination
        panel.prompt = String(localized: "Choose")
        if panel.runModal() == .OK, let url = panel.url { destination = url }
    }

    private var keptChoices: [String: ConflictChoice] { FileRow.choices(choices, stillInTheWayIn: rows) }

    private func start() {
        PolicyStore.remember(policy, toMac: true)
        if request.droppedAt == nil { PolicyStore.lastDestination = destination }
        queued = true
        queue.enqueue(TransferJob(deviceID: request.deviceID, deviceName: request.deviceName,
                                  sources: request.entries, destination: destination, policy: policy,
                                  plan: plan, choices: keptChoices, completions: request.completions))
        dismiss()
    }
}
