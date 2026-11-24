import AppKit
import DeviceCore
import SwiftUI
import TransferKit

extension TransferSummary {
    /// "Copies 12 files (2.3 GB) · sets the date of 4 · skips 3 · compares 2 · asks about 1"
    func footer(moving: Bool = false) -> String {
        var parts = [moving ? String(localized: "Moves \(copyCount) files (\(ByteFormat.string(copyBytes)))")
            : String(localized: "Copies \(copyCount) files (\(ByteFormat.string(copyBytes)))")]
        if dateCount > 0 { parts.append(String(localized: "sets the date of \(dateCount)")) }
        if skipCount > 0 { parts.append(String(localized: "skips \(skipCount)")) }
        if hashCount > 0 { parts.append(String(localized: "compares \(hashCount)")) }
        if askCount > 0 { parts.append(String(localized: "asks about \(askCount)")) }
        return parts.joined(separator: " · ")
    }
}

/// Whether the destination phone keeps the dates of files sent to it (uploads only).
enum UploadDatesState {
    case notApplicable
    case checking
    case kept
    case ignored
}

// MARK: Header

/// One end of a transfer: its name, the full path below it, and on this Mac a button to
/// show it in Finder.
struct RouteEnd {
    let icon: Image
    let title: String
    /// Shown in full, never shortened.
    let path: String
    /// Mac items to show in Finder: a destination folder opens, sources are selected in theirs.
    var finder: [URL] = []
    var opensInFinder = false
    /// A device folder to open in a new window.
    var window: BrowserTarget?

    /// What's sent from a device: "Phone: /sdcard/DCIM". Several share their folder's path.
    /// The button opens the folder they're in.
    static func device(_ deviceID: String, _ deviceName: String, paths: [String], title: String) -> RouteEnd {
        let parent = { (path: String) in RemoteRef(path: path).parentPath ?? "/" }
        return RouteEnd(icon: Image(systemName: "smartphone"), title: title,
                        path: "\(deviceName): \(commonPath(paths, parent: parent))",
                        window: BrowserTarget(deviceID: deviceID, path: paths.first.map(parent)))
    }

    /// The device folder that receives.
    static func deviceFolder(_ deviceID: String, _ deviceName: String, _ folder: RemoteRef) -> RouteEnd {
        RouteEnd(icon: Image(systemName: "smartphone"), title: folder.name, path: "\(deviceName): \(folder.path)",
                 window: BrowserTarget(deviceID: deviceID, path: folder.path))
    }

    /// What's sent from this Mac.
    static func mac(_ urls: [URL], title: String, icon: Image? = nil) -> RouteEnd {
        let path = commonPath(urls.map(\.path), parent: { ($0 as NSString).deletingLastPathComponent })
        return RouteEnd(icon: icon ?? Image(nsImage: NSWorkspace.shared.icon(forFile: urls.first?.path ?? "/")),
                        title: title, path: path, finder: urls)
    }

    /// The folder on this Mac that receives.
    static func macFolder(_ url: URL) -> RouteEnd {
        RouteEnd(icon: Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)), title: url.lastPathComponent,
                 path: url.path, finder: [url], opensInFinder: true)
    }

    /// One item's own path; several items' shared folder.
    private static func commonPath(_ paths: [String], parent: (String) -> String) -> String {
        guard let first = paths.first else { return "" }
        if paths.count == 1 { return first }
        let parents = Set(paths.map(parent))
        return parents.count == 1 ? parents.first! : parent(first)
    }
}

/// "From" and "To" of a transfer dialog: each end's name, then its full path.
struct TransferRouteHeader<Accessory: View>: View {
    let source: RouteEnd
    /// "12 files · 2.3 GB"; nil while scanning.
    let sourceDetail: String?
    let destination: RouteEnd
    @ViewBuilder var accessory: Accessory
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                Text("From").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                end(source) {
                    if let sourceDetail {
                        Text(sourceDetail).foregroundStyle(.secondary).monospacedDigit()
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            GridRow {
                Text("To").foregroundStyle(.secondary)
                end(destination) { accessory }
            }
        }
    }

    private func end(_ end: RouteEnd, @ViewBuilder trailing: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                end.icon.resizable().scaledToFit().frame(width: 16, height: 16).foregroundStyle(.secondary)
                Text(end.title).lineLimit(1).truncationMode(.middle)
                if !end.finder.isEmpty {
                    Button {
                        if end.opensInFinder, let folder = end.finder.first {
                            NSWorkspace.shared.open(folder)
                        } else {
                            NSWorkspace.shared.activateFileViewerSelecting(end.finder)
                        }
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                    .help("Show in Finder")
                }
                if let window = end.window {
                    Button {
                        openWindow(id: WindowID.browser, value: window)
                    } label: {
                        Image(systemName: "macwindow")
                    }
                    .buttonStyle(.borderless)
                    .help("Open in New Window")
                }
                Spacer(minLength: 8)
                trailing()
            }
            Text(end.path)
                .appFont(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: The files

/// The list of planned files with what happens to each, filtered by the colored counts above
/// it, and the policy for files that are already there. While the destination is still being
/// compared the list says so, so there's always something to look at.
struct FileComparisonPanel: View {
    @Binding var policy: TransferPolicy
    @Binding var choices: [String: ConflictChoice]
    /// The list is a preview, worked out only when asked for: most copies don't need it, and
    /// on a phone it takes reading every folder of the selection and of the destination.
    @Binding var previewing: Bool
    /// nil while comparing.
    let rows: [FileRow]?
    let summary: TransferSummary?
    /// Files compared so far and in all, while comparing (when the comparison can tell).
    var progress: (done: Int, total: Int)?
    let hashAvailable: Bool
    var uploadDates = UploadDatesState.notApplicable
    /// The policy as files are actually compared (an upload to a phone that doesn't keep dates
    /// compares by size), when it differs from the one being edited.
    var comparedAs: TransferPolicy?
    /// Files are moved, not copied (within one phone).
    var moving = false
    /// "Only set the date" is offered (downloads to this Mac).
    var datesApply = false
    /// Reads the selection and the destination again (the list's refresh button).
    var refresh: (() -> Void)?
    /// Why the list couldn't be made: shown in its place, with a way to try again.
    var failure: String?
    /// Uploads: keeping the files they replace, with the policy.
    var keepReplaced: KeepReplacedChoice?
    @State private var filter = FileFilter.all

    private var compared: TransferPolicy { comparedAs ?? policy }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PolicyBar(policy: $policy, hashAvailable: hashAvailable, uploadDates: uploadDates, datesApply: datesApply,
                      keepReplaced: keepReplaced)
                .disabled(previewing && summary == nil && failure == nil)
            Divider()
            // The list is always there and takes the room the window has; before the preview
            // it's empty, with the button that fills it in the middle. Filling it doesn't
            // change its room, so the window keeps the size it's given.
            VStack(alignment: .leading, spacing: 10) {
                files
            }
            .frame(minHeight: Self.filesMinHeight, maxHeight: .infinity, alignment: .top)
            .layoutPriority(1)
        }
        .layoutPriority(1)
        #if DEBUG
        // Development: -dev.dialogFilter new|same|different, for checking it in snapshots.
        .onAppear {
            guard let value = UserDefaults.standard.string(forKey: "dev.dialogFilter") else { return }
            previewing = true
            filter = switch value {
            case "new": .new
            case "same": .same
            case "different": .different
            default: .all
            }
        }
        #endif
    }

    @ViewBuilder private var files: some View {
        FilterBar(summary: previewing ? summary : nil, previewing: previewing && failure == nil,
                  hashMode: policy.existing == .ifHashDiffers, filter: $filter, refresh: refresh)
        ZStack {
            FileTable(rows: previewing ? visibleRows : [], policy: compared, choices: $choices, moving: moving)
            if !previewing {
                PreviewButton { previewing = true }
            } else if let failure {
                VStack(spacing: 10) {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    if let refresh {
                        Button("Try Again", action: refresh)
                    }
                }
                .frame(maxWidth: 420)
                .padding()
            } else if rows == nil {
                VStack(spacing: 8) {
                    ProgressView()
                    if let progress, progress.total > 0 {
                        Text("Comparing with what’s already there… \(progress.done) of \(progress.total)")
                            .monospacedDigit()
                    } else {
                        Text("Comparing with what’s already there…")
                    }
                }
                .foregroundStyle(.secondary)
            } else if visibleRows.isEmpty {
                Text("No files here").foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 120, idealHeight: 300, maxHeight: .infinity)
        .layoutPriority(1)
    }

    /// The least room for the list: its filter bar and a few rows.
    private static let filesMinHeight: CGFloat = 200

    private var visibleRows: [FileRow] {
        rows.map { FileRow.visible($0, filter: filter, sizeOnlyMatch: compared.matchesBySizeInList) } ?? []
    }
}

/// Fills the list: a large button in the middle of it while it's empty, small enough to fit
/// the list at the window's least height.
private struct PreviewButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "list.bullet.rectangle").imageScale(.large)
                Text("Preview results and choose per file")
            }
            .appFont(.title2, weight: .medium)
        }
        .buttonStyle(LargeTileButtonStyle())
        .padding()
    }
}

/// A big rounded rectangle that reads as a button: tinted, outlined, darker while pressed.
private struct LargeTileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10)
        configuration.label
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 36)
            .frame(minHeight: 80)
            .background(Color.accentColor.opacity(configuration.isPressed ? 0.24 : 0.12), in: shape)
            .overlay(shape.strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1))
            .contentShape(shape)
    }
}

/// The colored counts, doubling as filters for the list (click again to show all).
private struct FilterBar: View {
    let summary: TransferSummary?
    /// Before the preview there's nothing to count yet.
    let previewing: Bool
    let hashMode: Bool
    @Binding var filter: FileFilter
    let refresh: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            if let summary {
                pill(.all, count: summary.new + summary.existingCount, title: String(localized: "All"),
                     symbol: "doc.on.doc.fill", tint: .gray)
                pill(.new, count: summary.new, title: String(localized: "new"), symbol: "plus.circle.fill", tint: .blue)
                if hashMode {
                    pill(.same, count: summary.sameSize, title: String(localized: "same size, to compare"),
                         symbol: "questionmark.circle.fill", tint: .gray)
                    pill(.different, count: summary.differentSize, title: String(localized: "different"),
                         symbol: "exclamationmark.circle.fill", tint: .orange)
                } else {
                    pill(.same, count: summary.same, title: String(localized: "same"), symbol: "equal.circle.fill", tint: .green)
                    pill(.different, count: summary.different, title: String(localized: "different"),
                         symbol: "exclamationmark.circle.fill", tint: .orange)
                }
                if summary.existingCount == 0 {
                    Text("Nothing is in the way.").foregroundStyle(.secondary).padding(.leading, 4)
                }
            } else if previewing {
                Text("Counting…").foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if previewing, let refresh {
                Button(action: refresh) {
                    Label("Refresh", systemImage: "arrow.clockwise").labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .disabled(summary == nil)
                .help("Read the files and the destination again")
            }
        }
        .frame(minHeight: 24)
    }

    @ViewBuilder
    private func pill(_ value: FileFilter, count: Int, title: String, symbol: String, tint: Color) -> some View {
        let selected = filter == value
        Button {
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
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .help(value == .all ? String(localized: "Show all files") : String(localized: "Show only these files"))
    }
}

/// The upload choice of keeping the files it replaces (`TransferJob.keepsReplacedFiles`).
struct KeepReplacedChoice {
    var isOn: Binding<Bool>
    /// The connection can (`FSCapabilities.keepsReplacedFiles`); otherwise shown off, with why.
    let available: Bool
}

/// The policy for every file in the way, in two compact rows: a menu for files and a
/// segmented control for folders, with one line saying what the file choice does.
struct PolicyBar: View {
    @Binding var policy: TransferPolicy
    let hashAvailable: Bool
    var uploadDates = UploadDatesState.notApplicable
    var datesApply = false
    var keepReplaced: KeepReplacedChoice?

    private var differs: Bool { policy.existing == .ifSizeOrDateDiffers || policy.existing == .ifHashDiffers }

    var body: some View {
        // Each choice reads as a line: what it's for, the choice, what it does.
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                Text("For files already there:")
                    .gridColumnAlignment(.trailing)
                MenuChoice(selection: $policy.existing, items: ExistingFilePolicy.allCases.map { option in
                    .option(option, option.title, enabled: !(option == .ifHashDiffers && !hashAvailable))
                })
                explanation(policy.existing.explanation, warning: policy.existing == .overwrite)
            }
            if differs || policy.existing == .ifSizeOrDateDiffers {
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    differentFiles.gridCellColumns(2)
                }
                if showsDatesNote {
                    GridRow {
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        datesNote.gridCellColumns(2)
                    }
                }
            }
            if datesApply && [.skip, .ifSizeOrDateDiffers, .ifHashDiffers].contains(policy.existing) {
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    Toggle("When only the date differs, just set the date", isOn: $policy.datesOnlyWhenSameSize)
                        .help(policy.existing == .ifHashDiffers
                              ? "A file already here with the same contents gets the date from the device; nothing is copied."
                              : "A file already here with the same size gets the date from the device; nothing is copied.")
                        .gridCellColumns(2)
                }
            }
            if let keepReplaced {
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    keepReplacedRow(keepReplaced).gridCellColumns(2)
                }
            }
            GridRow {
                Text("For folders already there:")
                    .gridColumnAlignment(.trailing)
                SegmentedChoice(selection: $policy.existingFolder, options: [
                    (.merge, String(localized: "Merge")), (.keepBoth, String(localized: "Keep both")),
                ])
                explanation(policy.existingFolder == .merge
                            ? String(localized: "Files go into the existing folder; what’s already in it stays.")
                            : String(localized: "A new folder such as “Camera (1)” is made; the existing one is left as is."))
            }
        }
    }

    private func explanation(_ text: String, warning: Bool = false) -> some View {
        Text(text)
            .appFont(.caption)
            .foregroundStyle(warning ? Color.orange : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// For the "…differs" policies: how a different file comes in, and what counts as the same.
    private var differentFiles: some View {
        HStack(spacing: 16) {
            if differs {
                HStack(spacing: 6) {
                    Text("Different files:")
                    SegmentedChoice(selection: $policy.whenDifferent, options: [
                        (.overwrite, String(localized: "Overwrite")), (.keepBoth, String(localized: "Keep both")),
                    ])
                }
            }
            if policy.existing == .ifSizeOrDateDiffers {
                if uploadDates == .ignored {
                    // The phone stamps what it receives with the time it arrived, so dates
                    // can't tell an earlier copy apart (TransferQueue.comparable).
                    Toggle("Same size means the same file", isOn: .constant(true))
                        .disabled(true)
                        .help("This device doesn’t keep the dates of files sent to it, so files are compared by size.")
                } else {
                    Toggle("Same size means the same file", isOn: $policy.sizeOnlyMatch)
                        .help("Other tools often reset the date to when the file was copied.")
                }
            }
        }
    }

    /// Shown on every connection; usable where the connection can keep the file it replaces.
    private func keepReplacedRow(_ choice: KeepReplacedChoice) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle("Keep the creation time of files being replaced", isOn: choice.available ? choice.isOn : .constant(false))
                .disabled(!choice.available)
            Group {
                if choice.available {
                    Text("Apps that sort by when files were added still show them where they were. If copying stops partway, a file being replaced is left incomplete.")
                } else {
                    Text("Available when the device is connected over ADB.")
                }
            }
            .appFont(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var showsDatesNote: Bool {
        (uploadDates == .ignored && policy.existing == .ifSizeOrDateDiffers) || uploadDates == .checking
    }

    @ViewBuilder private var datesNote: some View {
        Group {
            if uploadDates == .checking {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Checking whether this device keeps file dates…")
                }
            } else {
                Text("This device doesn’t keep the dates of files sent to it, so files are compared by size.")
            }
        }
        .appFont(.caption).foregroundStyle(.secondary)
    }
}

/// The planned files: what's there, what's coming, and what happens to each. A file in the
/// way can be decided differently from the policy. Lazy, so tens of thousands of rows are fine.
struct FileTable: View {
    let rows: [FileRow]
    let policy: TransferPolicy
    @Binding var choices: [String: ConflictChoice]
    var moving = false

    var body: some View {
        Table(rows) {
            TableColumn("Name") { row in
                HStack(spacing: 6) {
                    statusIcon(row)
                    Text(row.relativePath).lineLimit(1).truncationMode(.middle)
                }
                .help(row.relativePath)
            }
            .width(min: 120, ideal: 180)
            TableColumn("Already there") { row in
                if row.existing == .none {
                    Text(verbatim: "—").foregroundStyle(.tertiary)
                } else {
                    details(row.existingSize, row.existingDate, folder: row.existing == .directory)
                }
            }
            .width(min: 150, ideal: 180)
            TableColumn("Incoming") { row in
                details(row.incomingSize, row.incomingDate, folder: false)
            }
            .width(min: 150, ideal: 180)
            TableColumn("Action") { row in
                actionCell(row)
            }
            .width(min: 140, ideal: 160)
        }
        .tableStyle(.bordered(alternatesRowBackgrounds: true))
    }

    @ViewBuilder private func statusIcon(_ row: FileRow) -> some View {
        switch row.kind(sizeOnlyMatch: policy.matchesBySizeInList) {
        case .same: Image(systemName: "equal.circle.fill").foregroundStyle(.green).help("Same file")
        case .different: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).help("Different file")
        case .folderInTheWay: Image(systemName: "folder.fill.badge.minus").foregroundStyle(.secondary).help("A folder has this name")
        case .new: Image(systemName: "plus.circle.fill").foregroundStyle(.blue).help("New file")
        }
    }

    private func details(_ size: UInt64?, _ date: Date?, folder: Bool) -> some View {
        Group {
            if folder {
                Text("Folder")
            } else {
                Text(verbatim: [size.map(ByteFormat.string), date?.formatted(.listTimestamp)].compactMap { $0 }.joined(separator: "  "))
            }
        }
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .lineLimit(1)
    }

    /// The decision for one file: the policy's unless picked here (only files in the way).
    @ViewBuilder private func actionCell(_ row: FileRow) -> some View {
        switch row.existing {
        case .none:
            Text(FileDecision.transfer.actionTitle(moving: moving)).foregroundStyle(.secondary)
        case .directory:
            Text("Skipped (a folder has this name)").foregroundStyle(.secondary).lineLimit(1)
        case .file:
            let policyDecision = FileDecision.decide(row.existing, policy)
            MenuChoice(selection: Binding(
                get: { choices[row.relativePath].map(RowAction.choice) ?? .policy },
                set: { action in
                    if case .choice(let choice) = action { choices[row.relativePath] = choice } else { choices[row.relativePath] = nil }
                }
            ), items: [.option(RowAction.policy, String(localized: "As set above: \(policyDecision.actionTitle(moving: moving))")), .divider]
                + ConflictChoice.allCases.map { .option(RowAction.choice($0), $0.title) },
            weight: choices[row.relativePath] == nil ? .regular : .semibold)
        }
    }

    private enum RowAction: Hashable {
        case policy
        case choice(ConflictChoice)
    }
}

extension ConflictChoice {
    var title: String {
        switch self {
        case .skip: String(localized: "Skip")
        case .overwrite: String(localized: "Overwrite")
        case .keepBoth: String(localized: "Keep both")
        }
    }
}

extension FileDecision {
    /// What happens to a file, in a word or two.
    func actionTitle(moving: Bool = false) -> String {
        switch self {
        case .transfer: moving ? String(localized: "Move") : String(localized: "Copy")
        case .setDate: String(localized: "Set date only")
        case .overwrite: String(localized: "Overwrite")
        case .keepBoth: String(localized: "Keep both")
        case .skipIdentical, .skipExisting, .typeConflict: String(localized: "Skip")
        case .needsHash: String(localized: "Compare contents")
        case .ask: String(localized: "Ask")
        }
    }
}

// MARK: Footer

/// The outcome in one line, and the buttons.
struct TransferDialogFooter: View {
    let outcome: String?
    let canStart: Bool
    let cancel: () -> Void
    let start: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let outcome {
                Text(outcome).appFont(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            Button("Cancel", action: cancel)
                .keyboardShortcut(.cancelAction)
            Button("Add to Queue", action: start)
                .keyboardShortcut(.defaultAction)
                .disabled(!canStart)
        }
    }
}

extension ExistingFilePolicy {
    var title: String {
        switch self {
        case .skip: String(localized: "Skip")
        case .ifSizeOrDateDiffers: String(localized: "Copy if size or date differs")
        case .ifHashDiffers: String(localized: "Copy if contents differ")
        case .keepBoth: String(localized: "Keep both")
        case .overwrite: String(localized: "Overwrite")
        case .ask: String(localized: "Ask for each file")
        }
    }

    /// What the choice does, in one line.
    var explanation: String {
        switch self {
        case .skip: String(localized: "Files already there are left as they are.")
        case .ifSizeOrDateDiffers: String(localized: "Files with the same size and date are skipped; the others are handled as below.")
        case .ifHashDiffers: String(localized: "Same-size files are compared by contents first, which can take a while.")
        case .keepBoth: String(localized: "New files get a name such as “photo (1).jpg”.")
        case .overwrite: String(localized: "Files already there are replaced.")
        case .ask: String(localized: "You choose for each file when the copy starts.")
        }
    }
}
