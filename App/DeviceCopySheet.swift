import AppKit
import DeviceCore
import SwiftUI
import TransferKit

struct DeviceCopyRequest: Identifiable {
    let id = UUID()
    let items: [DraggedEntry]
    let sourceFileSystem: any DeviceFileSystem
    let destinationDeviceID: String
    let destinationDeviceName: String
    let destination: RemoteRef
    let destinationFileSystem: any DeviceFileSystem
    let move: Bool

    var sameDevice: Bool { items.first?.deviceID == destinationDeviceID }
}

/// Copy or move between windows: same options as up/downloads, compared against the
/// destination device folder.
struct DeviceCopySheet: View {
    let request: DeviceCopyRequest
    @Environment(TransferQueue.self) private var queue
    @Environment(\.dismiss) private var dismiss

    @State private var move: Bool
    @State private var policy = PolicyStore.lastPolicy
    @State private var plan: TransferPlan?
    @State private var scanError: String?
    /// Each planned file (after the folder policy) and what's at the destination for it; depends
    /// only on the destination and folder policy, so switching the file policy recounts instantly.
    @State private var rows: [FileRow]?
    @State private var compared: (done: Int, total: Int)?
    /// Which comparison `compared` is for: a progress update of one that was replaced comes late.
    @State private var comparison = 0
    @State private var choices: [String: ConflictChoice] = [:]
    @State private var lookedUp: [String: RemoteEntry] = [:]
    @State private var previewing = false
    /// Bumped by the list's refresh button: the selection and the destination are read again.
    @State private var refreshes = 0
    @State private var sourceConnected: (any DeviceFileSystem)?
    @State private var destinationConnected: (any DeviceFileSystem)?

    /// The devices' connections now (`followsConnection`).
    private var sourceFileSystem: any DeviceFileSystem { sourceConnected ?? request.sourceFileSystem }
    private var destinationFileSystem: any DeviceFileSystem { destinationConnected ?? request.destinationFileSystem }
    private var connections: [ObjectIdentifier] { [ObjectIdentifier(sourceFileSystem), ObjectIdentifier(destinationFileSystem)] }
    @State private var uploadDates = UploadDatesState.checking

    init(request: DeviceCopyRequest) {
        self.request = request
        _move = State(initialValue: request.move && request.sameDevice)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Group {
                    if move {
                        Text("Move to \(request.destination.name)")
                    } else {
                        Text("Copy to \(request.destination.name)")
                    }
                }
                .appFont(.headline)
                Spacer()
                if request.move && !request.sameDevice {
                    // Dragged as a move onto another device.
                    Text("Between devices, files are copied; the originals stay.")
                        .appFont(.caption).foregroundStyle(.secondary)
                }
                if request.sameDevice {
                    SegmentedChoice(selection: $move, options: [
                        (true, String(localized: "Move")), (false, String(localized: "Copy")),
                    ])
                }
            }

            TransferRouteHeader(
                source: .device(request.items.first?.deviceID ?? "", request.items.first?.deviceName ?? "",
                                paths: request.items.map(\.path), title: selectionTitle),
                sourceDetail: plan.map { String(localized: "\($0.files.count) files · \(ByteFormat.string($0.totalBytes))") }
                    ?? (previewing && scanError == nil ? nil : String(localized: "\(request.items.count) items")),
                destination: .deviceFolder(request.destinationDeviceID, request.destinationDeviceName, request.destination)
            ) { EmptyView() }
            if !request.sameDevice {
                Text("Files go through this Mac one at a time and aren’t kept on it.")
                    .appFont(.caption).foregroundStyle(.secondary)
            }

            Divider()

            // Hashes are compared against a local copy; between device folders there is none.
            FileComparisonPanel(policy: $policy, choices: $choices, previewing: $previewing, rows: rows, summary: summary,
                                progress: compared,
                                hashAvailable: false, uploadDates: uploadDates, comparedAs: comparedPolicy,
                                moving: move, refresh: refresh, failure: scanError)
                .onAppear { policy = policy.normalized(hashAvailable: false) }

            Divider()

            TransferDialogFooter(outcome: summary?.footer(moving: move), canStart: true, cancel: { dismiss() }, start: start)
        }
        .padding(20)
        .scaledFrame(minWidth: 780)
        .navigationTitle(move ? Text("Move to \(request.destination.name)") : Text("Copy to \(request.destination.name)"))
        .textArea(.panels)
        .scaledButtons()
        .followsConnection(of: request.items.first?.deviceID ?? "", $sourceConnected)
        .followsConnection(of: request.destinationDeviceID, $destinationConnected)
        // A scan that failed is tried again on a new connection.
        .task(id: ScanKey(previewing: previewing, refreshes: refreshes, connections: connections)) {
            guard previewing, plan == nil else { return }
            do {
                plan = try await TransferPlanner.expand(request.items.map(\.entry), in: sourceFileSystem)
            } catch {
                if !(error is CancellationError) { scanError = UserMessage.describe(error) }
            }
        }
        .task(id: ObjectIdentifier(destinationFileSystem)) {
            // Once per phone and kind of connection; see UploadDates.
            uploadDates = .checking
            uploadDates = switch await UploadDates.probe(request.destinationDeviceID, fs: destinationFileSystem, in: request.destination) {
            case .kept: .kept
            case .ignored: .ignored
            case nil: .notApplicable // couldn't tell; compare as usual
            }
        }
        .task(id: StatKey(files: plan?.files.count, folders: policy.existingFolder, refreshes: refreshes, connections: connections)) {
            await compare()
        }
    }

    private struct ScanKey: Equatable {
        let previewing: Bool
        let refreshes: Int
        let connections: [ObjectIdentifier]
    }

    private struct StatKey: Equatable {
        let files: Int?
        let folders: ExistingFolderPolicy
        let refreshes: Int
        let connections: [ObjectIdentifier]
    }

    private func refresh() {
        plan = nil
        rows = nil
        scanError = nil
        refreshes += 1
    }

    private var selectionTitle: String {
        guard let first = request.items.first else { return "" }
        return request.items.count == 1 ? first.name : String(localized: "\(first.name) and \(request.items.count - 1) more")
    }

    /// The policy as files are actually compared.
    private var comparedPolicy: TransferPolicy {
        TransferQueue.comparable(policy, uploadingTo: request.destinationDeviceID, fs: destinationFileSystem)
    }

    private var summary: TransferSummary? {
        guard let rows else { return nil }
        return TransferSummary(rows: rows, policy: comparedPolicy, choices: choices)
    }

    /// Lists the device folders the files would land in and compares.
    private func compare() async {
        guard let plan else { return }
        rows = nil
        compared = nil
        comparison += 1
        let current = comparison
        let fs = destinationFileSystem
        // The same placing as the queue's, comparing only (without tidying leftovers).
        var placer = DeviceFolderPlacer(on: fs, destination: request.destination,
                                        sizesWrap: !fs.capabilities.exactLargeSizes || !sourceFileSystem.capabilities.exactLargeSizes)
        do {
            let effective = plan.applyingFolderPolicy(policy.existingFolder, existingNames: FolderNames(try await placer.listing(of: request.destination).keys))
            let files = effective.files.map { (relativePath: $0.relativePath, size: $0.entry.size, modified: $0.entry.modified) }
            compared = (0, files.count)
            let total = files.count
            let result = try await placer.rows(files) { done in
                Task { @MainActor in if comparison == current { compared = (done, total) } }
            }
            guard !Task.isCancelled else { return }
            rows = result
            lookedUp = placer.lookedUp
        } catch {
            if !Task.isCancelled, !(error is CancellationError) { scanError = UserMessage.describe(error) }
        }
    }

    private var keptChoices: [String: ConflictChoice] { FileRow.choices(choices, stillInTheWayIn: rows) }

    private func start() {
        PolicyStore.remember(policy, toMac: false)
        guard let first = request.items.first else { return }
        queue.enqueue(TransferJob(
            deviceID: request.destinationDeviceID, deviceName: request.destinationDeviceName,
            route: .deviceCopy(sources: request.items.map(\.entry), fromDeviceID: first.deviceID,
                               fromDeviceName: first.deviceName, to: request.destination, move: move && request.sameDevice),
            policy: policy, downloadPlan: plan,
            keepsReplacedFiles: UserDefaults.standard.bool(forKey: SettingsKey.keepReplacedFiles),
            choices: keptChoices, lookedUp: lookedUp))
        dismiss()
    }
}
