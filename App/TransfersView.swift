import AppKit
import SwiftUI
import TransferKit

/// Compact queue status shown at the bottom of every browser window while jobs exist.
struct TransferBar: View {
    @Environment(TransferQueue.self) private var queue
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if queue.hasUnfinishedJobs {
            HStack(spacing: 10) {
                Image(systemName: queue.needsAttention ? "exclamationmark.circle.fill" : "arrow.down.circle")
                    .foregroundStyle(queue.needsAttention ? .orange : .accentColor)
                    .appFont(.title3)
                VStack(alignment: .leading, spacing: 3) {
                    Text(summary).lineLimit(1).truncationMode(.middle)
                    if let job = queue.activeJob {
                        ProgressView(value: job.fractionDone).controlSize(.small)
                    }
                }
                if queue.activeJobs.count > 1 {
                    Text("+\(queue.activeJobs.count - 1)").foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer(minLength: 8)
                Button("Show") { openWindow(id: WindowID.transfers) }
            }
            .buttonStyle(.borderless)
            .appFont(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }

    private var summary: String {
        if let job = queue.activeJob { return job.statusText }
        if queue.needsAttention { return String(localized: "Some files need your decision") }
        if queue.jobs.allSatisfy({ $0.state.isFinished || $0.state == .paused }) { return String(localized: "Transfers paused") }
        return String(localized: "Waiting")
    }
}

/// The transfers window: a section per device. Each device runs one job at a time, in the
/// order shown (drag to reorder); different devices run side by side.
struct TransfersView: View {
    @Environment(TransferQueue.self) private var queue
    @Environment(\.openWindow) private var openWindow
    @State private var resolving: TransferJob?
    @State private var selection = Set<UUID>()
    @AppStorage(SettingsKey.showTransfersOnStart) private var showOnStart = true

    var body: some View {
        List(selection: $selection) {
            ForEach(sections, id: \.deviceID) { section in
                Section {
                    ForEach(section.unfinished) { job in
                        row(job)
                    }
                    .onMove { from, to in
                        let moving = from.map { section.unfinished[$0] }
                        queue.reorder(moving, before: to < section.unfinished.count ? section.unfinished[to] : nil)
                    }
                    ForEach(section.finished) { job in
                        row(job)
                    }
                } header: {
                    DeviceHeader(section: section)
                }
            }
        }
        // A click selects (so it's clear the list answers); a double-click or Return shows the details.
        .contextMenu(forSelectionType: UUID.self) { ids in
            Button("Show Details") { showResults(ids) }
        } primaryAction: { ids in
            showResults(ids)
        }
        .overlay {
            if queue.jobs.isEmpty {
                MessageView(Text("No Transfers"), systemImage: "arrow.down.circle",
                            description: Text("Transfers you start appear here."))
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    queue.clearFinished()
                } label: {
                    Label("Clear Finished", systemImage: "checkmark.circle")
                }
                .disabled(!queue.jobs.contains { $0.state.isFinished })
            }
        }
        .sheet(item: $resolving) { job in
            ConflictSheet(job: job)
        }
        // Bring up the question as soon as a job is waiting for one.
        .onChange(of: queue.jobs.first { $0.state == .needsDecision }?.id, initial: true) { _, id in
            if resolving == nil, let id { resolving = queue.jobs.first { $0.id == id } }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Toggle("Open this window when a transfer starts", isOn: $showOnStart)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
        }
        .frame(minWidth: 520, minHeight: 300)
    }

    private func row(_ job: TransferJob) -> some View {
        JobRow(job: job, resolve: { resolving = job }, showResults: { showResults([job.id]) })
    }

    private func showResults(_ ids: Set<UUID>) {
        for id in ids { openWindow(id: WindowID.transferResults, value: id) }
    }

    /// Jobs by device, devices in the order their first job was queued. Within one: the jobs
    /// still to do in queue order (the running one first), then finished ones as they ended.
    private var sections: [DeviceSection] {
        var order: [String] = []
        var byDevice: [String: [TransferJob]] = [:]
        for job in queue.jobs {
            if byDevice[job.deviceID] == nil { order.append(job.deviceID) }
            byDevice[job.deviceID, default: []].append(job)
        }
        return order.map { id in
            let jobs = byDevice[id] ?? []
            let unfinished = jobs.filter { !$0.state.isFinished }
            return DeviceSection(deviceID: id, deviceName: jobs.last?.deviceName ?? id,
                                 unfinished: unfinished.filter(\.state.isActive) + unfinished.filter { !$0.state.isActive },
                                 finished: jobs.filter(\.state.isFinished)
                                     .sorted { ($0.finishedAt ?? .distantPast) < ($1.finishedAt ?? .distantPast) })
        }
    }
}

private struct DeviceSection {
    let deviceID: String
    let deviceName: String
    let unfinished: [TransferJob]
    let finished: [TransferJob]
}

/// The device's name and what it's doing: one job runs at a time per device.
private struct DeviceHeader: View {
    let section: DeviceSection

    var body: some View {
        let running = section.unfinished.filter(\.state.isActive).count
        let waiting = section.unfinished.count - running
        HStack(spacing: 8) {
            Image(systemName: "iphone").foregroundStyle(.secondary)
            Text(section.deviceName).fontWeight(.semibold)
            Spacer(minLength: 8)
            Group {
                if running > 0 && waiting > 0 {
                    Text("1 running · \(waiting) waiting")
                } else if running > 0 {
                    Text("Running")
                } else if waiting > 0 {
                    Text("\(waiting) waiting")
                } else {
                    Text("Done")
                }
            }
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .appFont(.callout)
    }
}

private struct JobRow: View {
    let job: TransferJob
    let resolve: () -> Void
    let showResults: () -> Void
    @Environment(TransferQueue.self) private var queue
    @Environment(\.textScale) private var scale

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if let folder = job.localDestination {
                    Image(nsImage: FolderIcons.icon(for: folder)).resizable()
                } else {
                    Image(systemName: "arrow.up.to.line.circle.fill").resizable().foregroundStyle(Color.accentColor)
                }
            }
            .scaledFrame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(job.title).appFont(.body, weight: .medium).lineLimit(1).truncationMode(.middle)
                Text(job.routeDescription)
                    .appFont(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if !job.state.isFinished {
                    ProgressView(value: job.fractionDone).controlSize(.small)
                }
                Text(job.statusText)
                    .appFont(.caption)
                    .foregroundStyle(job.statusColor)
                    .lineLimit(2)
                if job.state.isFinished, job.counts.failed > 0 {
                    FailedFiles(job: job)
                }
                if job.state == .completed, let note = job.note {
                    Label(note, systemImage: "hand.point.right")
                        .appFont(.caption)
                        .foregroundStyle(.blue)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            controls
        }
        .padding(.vertical, 4)
    }

    /// Icon buttons at the window's text size.
    @ViewBuilder private var controls: some View {
        HStack(spacing: 10) {
            if job.state == .needsDecision {
                Button("Resolve…", action: resolve).buttonStyle(.borderless)
            }
            if job.isStopping {
                ProgressView().controlSize(.small)
            } else if job.state == .paused {
                icon("Resume", "play.fill") { queue.resume(job) }
            } else if !job.state.isFinished && job.state != .needsDecision {
                icon("Pause", "pause.fill") { queue.pause(job) }
            }
            if job.canRetry {
                icon("Retry", "arrow.clockwise") { queue.retry(job) }
            }
            if job.state == .completed, let folder = job.localDestination {
                icon("Show in Finder", "folder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
            }
            icon("Details", "info.circle", action: showResults)
            if job.state.isFinished {
                icon("Remove", "xmark") { queue.remove(job) }
            } else {
                icon("Cancel", "xmark.circle.fill") { queue.cancel(job) }
                    .disabled(job.stopReason == .cancel)
            }
        }
    }

    private func icon(_ title: LocalizedStringKey, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: scale.size(.body)))
                .frame(minWidth: scale.size(.body) * 1.3, minHeight: scale.size(.body) * 1.3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(Text(title))
        .accessibilityLabel(Text(title))
    }
}

/// Folder icons for the jobs' destinations, read once: drawing a row asks every time, and
/// asking a busy external disk could hold up the window.
@MainActor
enum FolderIcons {
    private static var icons: [URL: NSImage] = [:]

    static func icon(for url: URL) -> NSImage {
        if let icon = icons[url] { return icon }
        let generic = NSWorkspace.shared.icon(for: .folder)
        icons[url] = generic
        Task.detached {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            await MainActor.run { icons[url] = icon }
        }
        return generic
    }
}

/// Which files failed and why, folded under a finished job.
private struct FailedFiles: View {
    let job: TransferJob
    private static let shown = 50

    var body: some View {
        DisclosureGroup("Failed Files") {
            let failures = job.items.lazy.compactMap { item -> (String, String)? in
                if case .failed(let message) = item.state { (item.relativePath, message) } else { nil }
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(failures.prefix(Self.shown).enumerated()), id: \.offset) { _, failure in
                    Text(verbatim: "\(failure.0): \(failure.1)")
                        .lineLimit(2).truncationMode(.middle)
                        .textSelection(.enabled)
                }
                if job.counts.failed > Self.shown {
                    Text("\(job.counts.failed - Self.shown) more").foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 4)
        }
        .appFont(.caption)
    }
}

extension TransferJob {
    /// Paused or cancelled, and still settling (the file under way finishes or stops first).
    var isStopping: Bool { stopReason != nil && !state.isFinished && state != .paused }

    var statusText: String {
        if isStopping {
            return stopReason == .cancel ? String(localized: "Cancelling…") : String(localized: "Pausing…")
        }
        switch state {
        case .queued: return String(localized: "Waiting for its turn")
        case .waitingForDevice:
            // Name the device when there are two.
            if case .deviceCopy(_, let fromID, let fromName, _, _) = route, fromID != deviceID {
                let waitingOn = runtime.lostConnections.keys.contains(fromID) ? fromName : deviceName
                return String(localized: "Waiting for \(waitingOn) to reconnect")
            }
            return String(localized: "Waiting for the device to reconnect")
        case .planning: return String(localized: "Scanning…")
        case .zipping(let total):
            return String(localized: "Making the zip… \(ByteFormat.string(doneBytes)) of \(ByteFormat.string(total))")
        case .comparing:
            var parts = [compared.map { String(localized: "Comparing contents… \($0.done) of \($0.total)") }
                ?? String(localized: "Comparing contents…")]
            if let currentName { parts.append(currentName) }
            return parts.joined(separator: " · ")
        case .needsDecision: return String(localized: "\(counts.asking) files need your decision")
        case .paused: return String(localized: "Paused")
        case .cancelled: return String(localized: "Cancelled")
        case .failed(let message): return message
        case .running:
            var parts = [String(localized: "\(counts.done) of \(counts.transfers)")]
            if let waiting {
                parts.append(waitingText(waiting))
            } else {
                if bytesPerSecond > 0 { parts.append(String(localized: "\(ByteFormat.string(UInt64(bytesPerSecond)))/s")) }
                if let seconds = secondsRemaining {
                    let left = Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
                    parts.append(String(localized: "\(left) left"))
                }
            }
            if let currentName { parts.append(currentName) }
            return parts.joined(separator: " · ")
        case .completed:
            var parts = [route.isMove ? String(localized: "Moved \(counts.done)") : String(localized: "Copied \(counts.done)")]
            if counts.datesSet > 0 { parts.append(String(localized: "dates set \(counts.datesSet)")) }
            parts.append(String(localized: "skipped \(counts.skipped)"))
            if counts.failed > 0 { parts.append(String(localized: "\(counts.failed) failed")) }
            return parts.joined(separator: " · ")
        }
    }

    /// What a running job is waiting on, instead of a speed of zero.
    private func waitingText(_ waiting: JobWait) -> String {
        switch waiting {
        case .disk:
            if let destinationVolume { return String(localized: "Waiting for “\(destinationVolume)” to save the data") }
            return String(localized: "Waiting for the disk to save the data")
        case .device:
            switch route {
            case .download: return String(localized: "Waiting for \(deviceName) to send the data")
            case .upload: return String(localized: "Waiting for \(deviceName) to save the data")
            case .deviceCopy(_, _, let fromName, _, _): return String(localized: "Waiting for \(fromName) and \(deviceName)")
            }
        case .onDevice:
            return route.isMove ? String(localized: "Moving on the device…") : String(localized: "Copying on the device…")
        }
    }

    var statusColor: Color {
        switch state {
        case .failed: .red
        case .needsDecision: .orange
        case .completed where counts.failed > 0: .orange
        default: .secondary
        }
    }
}

/// "Ask for each file": one conflict at a time, with an apply-to-the-rest option.
private struct ConflictSheet: View {
    let job: TransferJob
    @Environment(TransferQueue.self) private var queue
    @Environment(\.dismiss) private var dismiss
    @State private var applyToRest = false

    var body: some View {
        if let index = job.conflictIndexes.first {
            let item = job.items[index]
            // The file being copied, then the one already at the destination, named by where
            // they are (a device, or this Mac) so every direction reads the same way.
            let (source, destination) = places
            VStack(alignment: .leading, spacing: 14) {
                Text("“\(item.name)” already exists").appFont(.headline)
                Text(item.relativePath).appFont(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    GridRow {
                        Text(verbatim: "")
                        Text("Size").foregroundStyle(.secondary)
                        Text("Date Modified").foregroundStyle(.secondary)
                    }
                    GridRow {
                        Text("Copying from \(source)")
                        Text(item.size.map(ByteFormat.string) ?? "—").monospacedDigit()
                        Text(item.modified?.formatted(.listTimestamp) ?? "—").monospacedDigit()
                    }
                    GridRow {
                        Text("Already in \(destination)")
                        Text(item.existingSize.map(ByteFormat.string) ?? "—").monospacedDigit()
                        Text(item.existingModified?.formatted(.listTimestamp) ?? "—").monospacedDigit()
                    }
                }
                let remaining = job.conflictIndexes.count
                if remaining > 1 {
                    Toggle("Apply to the remaining \(remaining - 1) files", isOn: $applyToRest)
                }
                HStack {
                    Button("Later") { dismiss() }
                    Spacer()
                    Button("Skip") { answer(.skip, index) }
                    // Return never overwrites: with "apply to the remaining" on it would replace them all.
                    Button("Keep Both") { answer(.keepBoth, index) }
                        .keyboardShortcut(.defaultAction)
                    Button("Overwrite") { answer(.overwrite, index) }
                }
            }
            .padding(20)
            .scaledFrame(width: 460)
            .textArea(.panels)
            .scaledButtons()
        } else {
            Color.clear.onAppear { dismiss() }
        }
    }

    /// Where the copied file comes from and where it goes.
    private var places: (String, String) {
        let mac = String(localized: "this Mac")
        return switch job.route {
        case .download: (job.deviceName, mac)
        case .upload: (mac, job.deviceName)
        case .deviceCopy(_, _, let fromName, _, _): (fromName, job.deviceName)
        }
    }

    private func answer(_ answer: ConflictChoice, _ index: Int) {
        queue.resolveConflict(in: job, at: index, answer: answer, applyToRest: applyToRest)
        applyToRest = false
        if job.conflictIndexes.isEmpty { dismiss() }
    }
}
