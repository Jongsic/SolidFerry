import AppKit
import SwiftUI
import TransferKit

/// One job in detail (double-click it in the transfers window): its options, and for every file
/// what was there before, what came in, what it did and what's there after. Live while the job
/// runs; kept with finished jobs until they're removed from the transfers window.
struct TransferResultsView: View {
    let jobID: UUID?
    @Environment(TransferQueue.self) private var queue

    var body: some View {
        if let jobID, let job = queue.job(jobID) {
            JobResults(job: job)
                .navigationTitle(Text(verbatim: "\(job.kindTitle): \(job.title)"))
                .navigationSubtitle(Text(verbatim: job.routeDescription))
        } else {
            MessageView(Text("This transfer was removed"), systemImage: "arrow.down.circle")
                .frame(minWidth: 400, minHeight: 240)
        }
    }
}

private struct JobResults: View {
    let job: TransferJob
    @State private var filter = ResultFilter.all

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            JobSummary(job: job)
            Divider()
            ResultFilterBar(job: job, filter: $filter)
            ResultTable(job: job, rows: rows, showsHashes: job.items.contains { $0.incomingHash != nil || $0.existingHash != nil })
        }
        .padding(16)
        .frame(minWidth: 900, idealWidth: 1180, minHeight: 420, idealHeight: 620)
    }

    private var rows: [ResultRow] {
        job.items.indices.lazy.filter { filter.includes(job.items[$0]) }.map { ResultRow(id: $0, item: job.items[$0]) }
    }
}

/// Where from, where to, when, with which options, and how it ended.
private struct JobSummary: View {
    let job: TransferJob

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: "\(job.kindTitle): \(job.title)").appFont(.headline).lineLimit(1).truncationMode(.middle)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Text("Source").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    Text(verbatim: job.sourceLocation).textSelection(.enabled)
                }
                GridRow {
                    Text("Destination").foregroundStyle(.secondary)
                    Text(verbatim: job.destinationLocation).textSelection(.enabled)
                }
                GridRow {
                    Text("Result").foregroundStyle(.secondary)
                    Text(job.statusText).foregroundStyle(job.statusColor)
                }
                if let started = job.startedAt {
                    GridRow {
                        Text("Time").foregroundStyle(.secondary)
                        Text(timeText(started))
                    }
                }
                if let amount = amountText {
                    GridRow {
                        Text("Transferred").foregroundStyle(.secondary)
                        Text(amount)
                    }
                }
                GridRow {
                    Text("Files already there").foregroundStyle(.secondary)
                    Text(policyText)
                }
                GridRow {
                    Text("Folders already there").foregroundStyle(.secondary)
                    Text(job.policy.existingFolder == .merge
                         ? String(localized: "Merge") : String(localized: "Keep both"))
                }
            }
            .appFont(.callout)
        }
    }

    private func timeText(_ started: Date) -> String {
        let start = started.formatted(date: .abbreviated, time: .standard)
        guard let finished = job.finishedAt, job.state.isFinished else { return start }
        let took = Duration.seconds(max(0, finished.timeIntervalSince(started)))
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
        return String(localized: "\(start) – \(finished.formatted(date: .omitted, time: .standard)) (\(took))")
    }

    /// What went over and how fast on average, start to end (comparing included): "3.1 GB · 130 MB/s on average".
    private var amountText: String? {
        let bytes = job.counts.doneBytes
        guard bytes > 0, job.state.isFinished, let started = job.startedAt, let finished = job.finishedAt else { return nil }
        let amount = ByteFormat.string(bytes)
        let seconds = finished.timeIntervalSince(started)
        guard seconds >= 1 else { return amount }
        return String(localized: "\(amount) · \(ByteFormat.string(UInt64(Double(bytes) / seconds)))/s on average")
    }

    /// The file policy as one line: "Copy if size or date differs · overwrite · same size counts as the same".
    private var policyText: String {
        let policy = job.policy
        var parts = [policy.existing.title]
        if policy.existing == .ifSizeOrDateDiffers || policy.existing == .ifHashDiffers {
            parts.append(policy.whenDifferent == .overwrite
                         ? String(localized: "different files overwrite") : String(localized: "different files kept both"))
        }
        if policy.existing == .ifSizeOrDateDiffers, policy.sizeOnlyMatch {
            parts.append(String(localized: "same size counts as the same"))
        }
        if policy.setsDates { parts.append(String(localized: "only the date is set when only the date differs")) }
        if !job.choices.isEmpty { parts.append(String(localized: "\(job.choices.count) chosen file by file")) }
        return parts.joined(separator: " · ")
    }
}

private enum ResultFilter: Hashable {
    case all, copied, dated, skipped, failed, pending

    func includes(_ item: JobItem) -> Bool {
        switch self {
        case .all: true
        case .copied: item.state == .done && item.decision != .setDate
        case .dated: item.state == .done && item.decision == .setDate
        case .skipped: item.state == .skipped
        case .failed: if case .failed = item.state { true } else { false }
        case .pending: item.state == .pending || item.state == .running
        }
    }
}

/// The counts, doubling as filters for the list (as in the copy dialog).
private struct ResultFilterBar: View {
    let job: TransferJob
    @Binding var filter: ResultFilter

    var body: some View {
        let counts = job.counts
        let pending = job.items.count - counts.done - counts.datesSet - counts.skipped - counts.failed
        HStack(spacing: 6) {
            pill(.all, job.items.count, String(localized: "All"), "doc.on.doc.fill", .gray)
            pill(.copied, counts.done, job.route.isMove ? String(localized: "moved") : String(localized: "copied"),
                 "checkmark.circle.fill", .blue)
            if counts.datesSet > 0 { pill(.dated, counts.datesSet, String(localized: "dates set"), "calendar.circle.fill", .teal) }
            pill(.skipped, counts.skipped, String(localized: "skipped"), "equal.circle.fill", .green)
            if counts.failed > 0 { pill(.failed, counts.failed, String(localized: "failed"), "exclamationmark.circle.fill", .red) }
            if pending > 0 { pill(.pending, pending, String(localized: "to do"), "clock.fill", .orange) }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 24)
    }

    private func pill(_ value: ResultFilter, _ count: Int, _ title: String, _ symbol: String, _ tint: Color) -> some View {
        let selected = filter == value
        return Button {
            filter = selected || value == .all ? .all : value
        } label: {
            HStack(spacing: 4) {
                Image(systemName: symbol).foregroundStyle(selected ? Color.white : tint)
                Text(count.formatted()).fontWeight(.semibold).monospacedDigit()
                Text(title)
            }
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(selected ? tint : tint.opacity(0.12), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(count == 0 && value != .all)
        .opacity(count == 0 && value != .all ? 0.45 : 1)
    }
}

private struct ResultRow: Identifiable {
    let id: Int
    let item: JobItem
}

/// Every file: before, incoming, what happened, after (and the contents' hashes when compared).
private struct ResultTable: View {
    let job: TransferJob
    let rows: [ResultRow]
    let showsHashes: Bool

    var body: some View {
        Table(rows) {
            TableColumn("Name") { row in
                Text(row.item.relativePath).lineLimit(1).truncationMode(.middle).help(row.item.relativePath)
            }
            .width(min: 140, ideal: 220)
            TableColumn("Result") { row in
                Text(result(row.item)).foregroundStyle(color(row.item)).lineLimit(1).help(result(row.item))
            }
            .width(min: 120, ideal: 170)
            TableColumn("Already there") { row in
                details(row.item.existingSize, row.item.existingModified)
            }
            .width(min: 130, ideal: 170)
            TableColumn("Incoming") { row in
                details(row.item.size, row.item.modified)
            }
            .width(min: 130, ideal: 170)
            TableColumn("After") { row in
                if row.item.state == .skipped, row.item.existingSize != nil {
                    Text("Unchanged").foregroundStyle(.secondary)
                } else {
                    details(row.item.afterSize, row.item.afterModified)
                }
            }
            .width(min: 130, ideal: 170)
            TableColumn("Contents") { row in
                hashes(row.item)
            }
            .width(min: showsHashes ? 120 : 0, ideal: showsHashes ? 160 : 0, max: showsHashes ? .infinity : 0)
        }
        .tableStyle(.bordered(alternatesRowBackgrounds: true))
    }

    private func details(_ size: UInt64?, _ date: Date?) -> some View {
        let text = [size.map(ByteFormat.string), date?.formatted(.listTimestamp)].compactMap { $0 }.joined(separator: "  ")
        return Text(verbatim: text.isEmpty ? "—" : text)
            .foregroundStyle(text.isEmpty ? .tertiary : .secondary)
            .monospacedDigit()
            .lineLimit(1)
    }

    @ViewBuilder private func hashes(_ item: JobItem) -> some View {
        if item.incomingHash == nil && item.existingHash == nil {
            Text(verbatim: "—").foregroundStyle(.tertiary)
        } else {
            let same = item.incomingHash != nil && item.incomingHash == item.existingHash
            let short = { (hash: String?) in hash.map { String($0.prefix(8)) } ?? "?" }
            HStack(spacing: 4) {
                Image(systemName: same ? "equal.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(same ? .green : .orange)
                Text(verbatim: "\(short(item.incomingHash)) / \(short(item.existingHash))")
                    .font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
            }
            .help(String(localized: "Incoming MD5: \(item.incomingHash ?? "—")\nAlready there: \(item.existingHash ?? "—")"))
        }
    }

    private func result(_ item: JobItem) -> String {
        switch item.state {
        case .pending: return item.decision == .ask ? String(localized: "Needs your decision") : String(localized: "Not yet")
        case .running: return String(localized: "In progress")
        case .failed(let message): return String(localized: "Failed: \(message)")
        case .skipped:
            if item.decision == .skipIdentical {
                return item.incomingHash != nil ? String(localized: "Skipped: same contents") : String(localized: "Skipped: same file")
            }
            return String(localized: "Skipped: already there")
        case .done:
            switch item.decision {
            case .setDate: return String(localized: "Date set")
            case .overwrite: return String(localized: "Overwritten")
            case .keepBoth:
                let name = item.destination.localURL?.lastPathComponent ?? item.destination.remoteRef?.name ?? item.name
                return String(localized: "Kept both, as “\(name)”")
            default:
                if item.isFolder { return job.route.isMove ? String(localized: "Moved, whole folder") : String(localized: "Copied, whole folder") }
                return job.route.isMove ? String(localized: "Moved") : String(localized: "Copied")
            }
        }
    }

    private func color(_ item: JobItem) -> Color {
        switch item.state {
        case .failed: .red
        case .done: .primary
        default: .secondary
        }
    }
}
