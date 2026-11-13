import AppKit
import DeviceCore
import SwiftUI
import TransferKit

struct UploadRequest: Identifiable {
    let id = UUID()
    let deviceID: String
    let deviceName: String
    let sources: [URL]
    let destination: RemoteRef
    let fileSystem: any DeviceFileSystem
}

/// "Upload to <device>": same options as downloading, compared against what's on the device.
struct UploadSheet: View {
    let request: UploadRequest
    @Environment(TransferQueue.self) private var queue
    @Environment(\.dismiss) private var dismiss

    @State private var policy = PolicyStore.lastPolicy
    @State private var plan: UploadPlan?
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
    @State private var uploadDates = UploadDatesState.checking
    /// Send as a zip to unpack on the phone (offered when the phone doesn't keep dates).
    @State private var packAsZip = UserDefaults.standard.bool(forKey: SettingsKey.zipWhenDatesNotKept)

    /// The upload as one archive, when that's offered.
    private var zipPackage: ZipPackage? {
        guard uploadDates == .ignored else { return nil }
        return plan?.zipPackage(sources: request.sources, otherwiseNamed: "Files")
    }

    private var sendsZip: Bool { packAsZip && zipPackage != nil }

    private var zipOutcome: String? {
        zipPackage.map { String(localized: "Sends \($0.fileName) (\(ByteFormat.string($0.totalBytes)))") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Upload to \(request.deviceName)").appFont(.headline)

            TransferRouteHeader(
                source: .mac(request.sources, title: selectionTitle),
                sourceDetail: plan.map { String(localized: "\($0.files.count) files · \(ByteFormat.string($0.totalBytes))") },
                destination: .deviceFolder(request.deviceID, request.deviceName, request.destination)
            ) { EmptyView() }

            if let scanError {
                Text(scanError).foregroundStyle(.red)
            }

            Divider()

            if uploadDates == .ignored {
                zipChoice
            }

            if sendsZip, let zipPackage {
                Label("Sent as “\(zipPackage.fileName)”. Unzip it on the device with its file manager (My Files); the files keep their dates.",
                      systemImage: "doc.zipper")
                    .fixedSize(horizontal: false, vertical: true)
                if zipPackage.isLarge {
                    Text("Over 4 GB, so it’s sent in the large zip format. Samsung’s My Files opens it; some file managers, such as Files by Google on Android 11, can’t.")
                        .appFont(.callout).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                FileComparisonPanel(policy: $policy, choices: $choices, previewing: $previewing, rows: rows, summary: summary,
                                    progress: compared,
                                    hashAvailable: request.fileSystem.capabilities.deviceHashing, uploadDates: uploadDates,
                                    comparedAs: comparedPolicy)
                    .onAppear { policy = policy.normalized(hashAvailable: request.fileSystem.capabilities.deviceHashing) }
            }

            Divider()

            TransferDialogFooter(outcome: sendsZip ? zipOutcome : summary?.footer, canStart: plan != nil,
                                 cancel: { dismiss() }, start: start)
        }
        .padding(20)
        .scaledFrame(width: 780)
        .textArea(.panels)
        .scaledButtons()
        .task {
            do {
                let sources = request.sources
                plan = try await stoppable { stop in try UploadPlanner.expand(sources, stop: stop) }
            } catch is CancellationError {
            } catch {
                scanError = UserMessage.describe(error)
            }
        }
        .task {
            // Once per phone and kind of connection; see UploadDates.
            uploadDates = switch await UploadDates.probe(request.deviceID, fs: request.fileSystem, in: request.destination) {
            case .kept: .kept
            case .ignored: .ignored
            case nil: .notApplicable // couldn't tell; compare as usual
            }
        }
        .task(id: StatKey(files: plan?.files.count, folders: policy.existingFolder, previewing: previewing)) { await compare() }
    }

    private struct StatKey: Equatable {
        let files: Int?
        let folders: ExistingFolderPolicy
        let previewing: Bool
    }

    private var selectionTitle: String {
        guard let first = request.sources.first else { return "" }
        return request.sources.count == 1
            ? first.lastPathComponent
            : String(localized: "\(first.lastPathComponent) and \(request.sources.count - 1) more")
    }

    /// The policy as files are actually compared.
    private var comparedPolicy: TransferPolicy {
        TransferQueue.comparable(policy, uploadingTo: request.deviceID, fs: request.fileSystem)
    }

    private var summary: TransferSummary? {
        guard let rows else { return nil }
        return TransferSummary(rows: rows, policy: comparedPolicy, choices: choices)
    }

    /// Lists the device folders the files would land in and compares.
    private func compare() async {
        guard previewing, let plan else { return }
        rows = nil
        compared = nil
        comparison += 1
        let current = comparison
        let fs = request.fileSystem
        // The same placing as the queue's, comparing only (without tidying leftovers).
        var placer = DeviceFolderPlacer(on: fs, destination: request.destination, sizesWrap: !fs.capabilities.exactLargeSizes)
        do {
            let effective = plan.applyingFolderPolicy(policy.existingFolder, existingNames: FolderNames(try await placer.listing(of: request.destination).keys))
            let files = effective.files.map { (relativePath: $0.relativePath, size: Optional($0.size), modified: $0.modified) }
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

    /// The phone stamps files with the time they arrive; a zip unpacked on the phone keeps
    /// their dates (Samsung's My Files does; QUIRKS G7).
    @ViewBuilder private var zipChoice: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Keep file dates: send as a zip to unpack on the device", isOn: $packAsZip)
                .disabled(plan == nil)
            Text("This device gives files the date they arrive. Unpacking a zip on the device keeps the original dates, but takes a step on the device.")
                .appFont(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var keptChoices: [String: ConflictChoice] { FileRow.choices(choices, stillInTheWayIn: rows) }

    private func start() {
        PolicyStore.lastPolicy = policy
        queue.enqueue(TransferJob(deviceID: request.deviceID, deviceName: request.deviceName,
                                  route: .upload(sources: request.sources, to: request.destination), policy: policy,
                                  uploadPlan: plan, packAsZip: sendsZip, choices: sendsZip ? [:] : keptChoices,
                                  lookedUp: lookedUp))
        dismiss()
    }
}
