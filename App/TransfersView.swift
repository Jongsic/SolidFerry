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
                Button {
                    queue.toggleAllPaused()
                } label: {
                    Image(systemName: queue.isAllPaused ? "play.fill" : "pause.fill")
                }
                .help(queue.isAllPaused ? Text("Resume All") : Text("Pause All"))
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
        if queue.isAllPaused { return String(localized: "Transfers paused") }
        if let job = queue.activeJob { return job.statusText }
        if queue.needsAttention { return String(localized: "Some files need your decision") }
        return String(localized: "Waiting")
    }
}

/// The transfers window: every job, reorderable, with per-job controls.
struct TransfersView: View {
    @Environment(TransferQueue.self) private var queue
    @State private var resolving: TransferJob?
    @AppStorage(SettingsKey.showTransfersOnStart) private var showOnStart = true

    var body: some View {
        List {
            ForEach(queue.jobs) { job in
                JobRow(job: job, resolve: { resolving = job })
            }
            .onMove { queue.move(from: $0, to: $1) }
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
                    queue.toggleAllPaused()
                } label: {
                    if queue.isAllPaused {
                        Label("Resume All", systemImage: "play.fill")
                    } else {
                        Label("Pause All", systemImage: "pause.fill")
                    }
                }
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
}

private struct JobRow: View {
    let job: TransferJob
    let resolve: () -> Void
    @Environment(TransferQueue.self) private var queue

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if let folder = job.localDestination {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: folder.path)).resizable()
                } else {
                    Image(systemName: "arrow.up.to.line.circle.fill").resizable().foregroundStyle(Color.accentColor)
                }
            }
            .frame(width: 32, height: 32)
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

    @ViewBuilder private var controls: some View {
        HStack(spacing: 6) {
            if job.state == .needsDecision {
                Button("Resolve…", action: resolve)
            }
            if job.state == .paused {
                Button { queue.resume(job) } label: { Label("Resume", systemImage: "play.fill").labelStyle(.iconOnly) }.help(Text("Resume"))
            } else if !job.state.isFinished && job.state != .needsDecision {
                Button { queue.pause(job) } label: { Label("Pause", systemImage: "pause.fill").labelStyle(.iconOnly) }.help(Text("Pause"))
            }
            if job.canRetry {
                Button { queue.retry(job) } label: { Label("Retry", systemImage: "arrow.clockwise").labelStyle(.iconOnly) }.help(Text("Retry"))
            }
            if job.state == .completed, let folder = job.localDestination {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([folder])
                } label: { Label("Show in Finder", systemImage: "magnifyingglass").labelStyle(.iconOnly) }.help(Text("Show in Finder"))
            }
            if job.state.isFinished {
                Button { queue.remove(job) } label: { Label("Remove", systemImage: "xmark").labelStyle(.iconOnly) }.help(Text("Remove"))
            } else {
                Button { queue.cancel(job) } label: { Label("Cancel", systemImage: "xmark.circle.fill").labelStyle(.iconOnly) }.help(Text("Cancel"))
            }
        }
        .buttonStyle(.borderless)
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
    var statusText: String {
        switch state {
        case .queued: return String(localized: "Waiting")
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
        case .comparing: return String(localized: "Comparing contents…")
        case .needsDecision: return String(localized: "\(counts.asking) files need your decision")
        case .paused: return String(localized: "Paused")
        case .cancelled: return String(localized: "Cancelled")
        case .failed(let message): return message
        case .running:
            var parts = [String(localized: "\(counts.done) of \(counts.transfers)")]
            if bytesPerSecond > 0 { parts.append(String(localized: "\(ByteFormat.string(UInt64(bytesPerSecond)))/s")) }
            if let seconds = secondsRemaining {
                let left = Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
                parts.append(String(localized: "\(left) left"))
            }
            if let currentName { parts.append(currentName) }
            return parts.joined(separator: " · ")
        case .completed:
            var text = String(localized: "Copied \(counts.done), skipped \(counts.skipped)")
            if counts.failed > 0 { text += " · " + String(localized: "\(counts.failed) failed") }
            return text
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
