import AVFoundation
import DeviceCore
import PDFKit
import SwiftUI
import TransferKit
import UniformTypeIdentifiers
import os

/// What the preview panel shows of one file beyond what the list knows: a small picture (the
/// one stored in a photo, a PDF's first page, a video frame), the start of a text file, and what
/// the file says about itself.
struct FilePreview: Sendable {
    var picture: CGImage?
    /// The picture's own size (pixels; a PDF page's points), so a small one isn't enlarged.
    var actualSize: CGSize?
    var text: String?
    var details: [PreviewDetail] = []
    /// Every tag the file has (a photo's Exif, GPS, …; a PDF's or a video's own).
    var metadata: FileMetadata?
    /// Not read: the whole file was needed and it's larger than this (Settings ▸ Viewer).
    var tooLarge: UInt64?
}

/// Reads as little of a file as gives its preview.
enum FilePreviewLoader {
    /// A photo's details and its stored small picture are near the start: JPEG keeps them in
    /// the first 64 KB, HEIC a little further in.
    static let pictureStart: UInt64 = 256 * 1024
    static let textStart: UInt64 = 16 * 1024
    static let pictureSize = 640
    /// Read whole rather than asking for less: quicker than asking the device for its own
    /// small picture (a second or two).
    static let wholeUpTo: UInt64 = 1_000_000

    /// Largest file read whole for a preview (Settings ▸ Viewer).
    static var limit: UInt64 {
        UInt64(max(UserDefaults.standard.integer(forKey: SettingsKey.previewLimitMB), 1)) * 1_000_000
    }

    static func load(_ entry: RemoteEntry, from fs: any DeviceFileSystem) async throws -> FilePreview {
        guard let kind = ViewerKind(name: entry.name), let size = entry.size, size > 0 else { return FilePreview() }
        switch kind {
        case .image:
            var preview = FilePreview()
            if size > wholeUpTo {
                // A photo keeps a small picture near its start, with its details.
                if fs.capabilities.readsRanges {
                    let start = try await read(entry, bytes: pictureStart, from: fs)
                    if let found = FileDecoding.picturePreview(from: start, complete: false, maxPixels: pictureSize) {
                        preview = FilePreview(picture: found.picture, actualSize: found.size, details: found.details, metadata: found.metadata)
                        if found.picture != nil { return preview }
                    }
                }
                // None in it (PNG, screenshots): the one the device keeps, if it has one.
                if let stored = try await storedThumbnail(of: entry, from: fs) {
                    preview.picture = stored
                    return preview
                }
            }
            // Or the whole picture, if not too large.
            guard size <= limit else {
                preview.tooLarge = limit
                return preview
            }
            let data = try await RemoteContents.data(of: entry, from: fs, limit: Int(limit)) { _ in }
            let found = FileDecoding.picturePreview(from: data, complete: true, maxPixels: pictureSize)
            return FilePreview(picture: found?.picture, actualSize: found?.size, details: found?.details ?? [], metadata: found?.metadata)
        case .text:
            let complete = size <= textStart
            let data: Data
            if complete || !fs.capabilities.readsRanges {
                guard size <= kind.limit else { return FilePreview() }
                data = try await RemoteContents.data(of: entry, from: fs, limit: Int(kind.limit)) { _ in }.prefix(Int(textStart))
            } else {
                data = try await read(entry, bytes: textStart, from: fs)
            }
            return FilePreview(text: FileDecoding.textStart(from: data, complete: complete))
        case .pdf:
            guard size <= limit else { return FilePreview(tooLarge: limit) }
            let data = try await RemoteContents.data(of: entry, from: fs, limit: Int(limit)) { _ in }
            guard let document = PDFDocument(data: data), let page = document.page(at: 0) else { return FilePreview() }
            // The page's own shape, not a square around it.
            let bounds = page.bounds(for: .cropBox)
            let scale = CGFloat(pictureSize) / max(bounds.width, bounds.height, 1)
            let picture = page.thumbnail(of: NSSize(width: bounds.width * scale, height: bounds.height * scale), for: .cropBox)
                .cgImage(forProposedRect: nil, context: nil, hints: nil)
            let attributes = Dictionary(uniqueKeysWithValues: (document.documentAttributes ?? [:]).map { ("\($0.key)", $0.value) })
            return FilePreview(picture: picture, actualSize: bounds.size, details: [PreviewDetail(label: String(localized: "Pages"), value: "\(document.pageCount)")],
                               metadata: attributes.isEmpty ? nil : FileDecoding.metadata(attributes, general: "PDF"))
        case .media:
            guard fs.capabilities.readsRanges, let type = FileOpening.type(of: entry.name) else { return FilePreview() }
            return try await media(entry, size: size, type: type, from: fs)
        }
    }

    /// The first `bytes` of the file.
    /// The first `bytes` of a file (all of it when it's shorter). Only when `readsRanges`.
    static func read(_ entry: RemoteEntry, bytes: UInt64, from fs: any DeviceFileSystem) async throws -> Data {
        let collected = OSAllocatedUnfairLock(initialState: Data())
        try await fs.read(entry, range: 0..<min(bytes, entry.size ?? bytes)) { chunk in
            collected.withLock { $0.append(chunk) }
        }
        return collected.withLock { $0 }
    }

    /// The small picture the device keeps for this file; nil when it has none, or when asking
    /// failed (the file itself can still be read).
    private static func storedThumbnail(of entry: RemoteEntry, from fs: any DeviceFileSystem) async throws -> CGImage? {
        let data = try? await fs.storedThumbnail(of: entry)
        try Task.checkCancellation()
        guard let data else { return nil }
        return FileDecoding.picturePreview(from: data, complete: true, maxPixels: pictureSize)?.picture
    }

    /// How long, how large, and a frame (or a song's cover), reading only what the player needs.
    private static func media(_ entry: RemoteEntry, size: UInt64, type: UTType, from fs: any DeviceFileSystem) async throws -> FilePreview {
        let loader = DeviceMediaLoader(entry: entry, size: size, fs: fs, contentType: type.identifier) { _, _ in nil }
        defer { loader.stop() }
        let asset = loader.makeAsset()
        var preview = FilePreview()
        let duration = try await asset.load(.duration)
        if duration.isNumeric {
            preview.details.append(PreviewDetail(label: String(localized: "Duration"),
                                                 value: Duration.seconds(duration.seconds).formatted(.time(pattern: duration.seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))))
        }
        var tags: [String: Any] = [:]
        for item in try await asset.load(.metadata) {
            guard let key = item.identifier?.rawValue ?? item.key.map({ "\($0)" }), let value = try? await item.load(.value) else { continue }
            tags[key] = value
        }
        if !tags.isEmpty { preview.metadata = FileDecoding.metadata(tags, general: String(localized: "Media")) }
        if let track = try await asset.loadTracks(withMediaType: .video).first {
            let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
            let shown = natural.applying(transform)
            preview.actualSize = CGSize(width: abs(shown.width), height: abs(shown.height))
            preview.details.insert(PreviewDetail(label: String(localized: "Dimensions"), value: "\(Int(abs(shown.width))) × \(Int(abs(shown.height)))"), at: 0)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: pictureSize, height: pictureSize)
            let at = duration.isNumeric ? CMTime(seconds: min(1, duration.seconds / 2), preferredTimescale: 600) : .zero
            preview.picture = try? await generator.image(at: at).image
        } else {
            let artwork = AVMetadataItem.metadataItems(from: try await asset.load(.commonMetadata), filteredByIdentifier: .commonIdentifierArtwork)
            if let data = try await artwork.first?.load(.dataValue) {
                let found = FileDecoding.picturePreview(from: data, complete: true, maxPixels: pictureSize)
                preview.picture = found?.picture
                preview.actualSize = found?.size
            }
        }
        return preview
    }
}

/// The previews read so far, and the one being read.
@MainActor @Observable
final class PreviewPanelModel {
    /// The file shown (its key) and its preview, once read.
    private(set) var shownKey: String?
    private(set) var preview: FilePreview?
    private(set) var loading = false
    private var cache: [String: FilePreview] = [:]
    private var order: [String] = []

    /// The file as listed, and the size limit it was read under.
    static func key(_ entry: RemoteEntry, deviceID: String) -> String {
        "\(deviceID)\n\(entry.ref.path)\n\(entry.size ?? 0)\n\(entry.modified?.timeIntervalSince1970 ?? 0)\n\(FilePreviewLoader.limit)"
    }

    func show(_ entry: RemoteEntry, deviceID: String, fs: (any DeviceFileSystem)?) async {
        let key = Self.key(entry, deviceID: deviceID)
        shownKey = key
        loading = false
        if let cached = cache[key] {
            preview = cached
            loading = false
            return
        }
        preview = nil
        guard let fs, ViewerKind(name: entry.name) != nil else { return }
        // Moving through the list quickly: only the file stopped on is read.
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled else { return }
        loading = true
        defer { if shownKey == key { loading = false } }
        let found: FilePreview
        do {
            found = try await FilePreviewLoader.load(entry, from: fs)
            guard !Task.isCancelled else { return }
            remember(found, as: key)
        } catch {
            // Not remembered: a read cut short (the device unplugged, say) is tried again next time.
            guard !Task.isCancelled else { return }
            found = FilePreview()
        }
        if shownKey == key { preview = found }
    }

    func clear() {
        shownKey = nil
        preview = nil
        loading = false
    }

    private func remember(_ preview: FilePreview, as key: String) {
        cache[key] = preview
        order.append(key)
        if order.count > 60 { cache[order.removeFirst()] = nil }
    }
}

/// Beside the file list: the selected file's preview and details, as Finder's preview column.
struct PreviewPanel: View {
    let selected: [RemoteEntry]
    let deviceID: String?
    let fs: (any DeviceFileSystem)?
    let open: (RemoteEntry) -> Void
    @State private var model = PreviewPanelModel()
    @AppStorage(SettingsKey.previewReadsDevice) private var readsDevice = true
    @AppStorage(SettingsKey.previewShowsAllDetails) private var showsAllDetails = false
    @AppStorage(SettingsKey.previewShowsRawDetails) private var showsRaw = false
    /// Read here so a new limit reads the file again.
    @AppStorage(SettingsKey.previewLimitMB) private var limitMB = 10
    /// The picture's place, the same whether it's read yet or not, so nothing below moves.
    private static let pictureHeight: CGFloat = 400
    /// The labels' column, the same for every file, so the values don't move as details arrive.
    private static let labelWidth: CGFloat = 80
    /// A scroller that takes room (not one shown over the content, as with a trackpad).
    private static var scrollerRoom: CGFloat {
        NSScroller.scrollerWidth(for: .regular, scrollerStyle: NSScroller.preferredScrollerStyle)
    }
    /// Tag names are longer ("Date Time Original").
    private static let tagWidth: CGFloat = 120

    private struct Request: Hashable {
        let key: String?
        let reads: Bool
        let connection: ObjectIdentifier?
    }

    private var entry: RemoteEntry? { selected.count == 1 ? selected.first : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Toggle("Read previews from the device", isOn: $readsDevice)
                .toggleStyle(.checkbox)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Divider()
            GeometryReader { space in
                ScrollView {
                    // The scroller's room is kept even when nothing scrolls, so opening All
                    // Details doesn't narrow (and rewrap) what's above it.
                    content
                        .frame(width: max(space.size.width - 24 - Self.scrollerRoom, 0))
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .appFont(.callout)
        .task(id: Request(key: entry.flatMap { e in deviceID.map { PreviewPanelModel.key(e, deviceID: $0) } },
                          reads: readsDevice, connection: fs.map { ObjectIdentifier($0) })) {
            if let entry, let deviceID, entry.kind == .file {
                await model.show(entry, deviceID: deviceID, fs: readsDevice ? fs : nil)
            } else {
                model.clear()
            }
        }
    }

    @ViewBuilder private var content: some View {
        if let entry {
            VStack(spacing: 12) {
                picture(for: entry)
                VStack(spacing: 2) {
                    Text(entry.name).appFont(.headline).multilineTextAlignment(.center).textSelection(.enabled)
                    Text(FileIcons.kind(for: entry)).foregroundStyle(.secondary)
                }
                Divider()
                details(for: entry)
                if let metadata = shown(entry)?.metadata, !metadata.groups.isEmpty {
                    Divider()
                    allDetails(metadata)
                }
            }
        } else if selected.isEmpty {
            Text("No Selection").foregroundStyle(.secondary).padding(.top, 40)
        } else {
            VStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(for: .data)).resizable().frame(width: 96, height: 96)
                Text("\(selected.count) items").appFont(.headline)
                let bytes = selected.compactMap(\.size).reduce(0, +)
                if bytes > 0 { Text(ByteFormat.string(bytes)).foregroundStyle(.secondary) }
            }
            .padding(.top, 24)
        }
    }

    /// The preview read for this entry (not the last file's, while this one is read).
    private func shown(_ entry: RemoteEntry) -> FilePreview? {
        model.shownKey == deviceID.map { PreviewPanelModel.key(entry, deviceID: $0) } ? model.preview : nil
    }

    @ViewBuilder private func picture(for entry: RemoteEntry) -> some View {
        let shown = shown(entry)
        Group {
            if let picture = shown?.picture {
                Image(decorative: picture, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    // A white page on the panel still shows its edges.
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator))
                    // Fills the place, but a picture smaller than that stays at its own size.
                    .frame(maxWidth: shown?.actualSize?.width ?? .infinity, maxHeight: shown?.actualSize?.height ?? .infinity)
            } else if let text = shown?.text {
                Text(text)
                    .appFont(.caption, design: .monospaced)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator))
                    .clipped()
            } else {
                VStack(spacing: 6) {
                    Image(nsImage: NSWorkspace.shared.icon(for: entry.isDirectory ? .folder : FileOpening.type(of: entry.name) ?? .data))
                        .resizable()
                        .frame(width: 128, height: 128)
                    if let limit = shown?.tooLarge {
                        Text("Larger than \(ByteFormat.string(limit)), not previewed (Settings ▸ Viewer)")
                            .appFont(.caption).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.pictureHeight)
        .overlay(alignment: .bottomTrailing) {
            if model.loading { ProgressView().controlSize(.small).padding(4) }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if entry.kind == .file { open(entry) } }
    }

    private func details(for entry: RemoteEntry) -> some View {
        let shown = shown(entry)
        var rows: [PreviewDetail] = []
        if let size = entry.size, entry.kind == .file {
            rows.append(PreviewDetail(label: String(localized: "Size"),
                                      value: "\(ByteFormat.string(size)) (\(String(localized: "\(size) bytes")))"))
        }
        if let modified = entry.modified {
            rows.append(PreviewDetail(label: String(localized: "Modified"), value: modified.formatted(date: .abbreviated, time: .shortened)))
        }
        rows.append(PreviewDetail(label: String(localized: "Where"), value: entry.ref.parentPath ?? "/"))
        rows += shown?.details ?? []
        return Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 4) {
            ForEach(rows, id: \.self) { row in
                GridRow {
                    Text(row.label).foregroundStyle(.secondary)
                        .scaledFrame(width: Self.labelWidth, alignment: .trailing)
                    Text(row.value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// Every tag, by group or as stored.
    private func allDetails(_ metadata: FileMetadata) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // The whole row opens it, not only the arrow.
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showsAllDetails.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .appFont(.caption, weight: .semibold)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(showsAllDetails ? 90 : 0))
                    Text("All Details (\(metadata.groups.reduce(0) { $0 + $1.entries.count }))")
                }
            }
            .buttonStyle(RowButtonStyle())
            if showsAllDetails {
                VStack(alignment: .leading, spacing: 10) {
                    SegmentedChoice(selection: $showsRaw,
                                    options: [(false, String(localized: "By Group")), (true, String(localized: "Raw"))])
                    if showsRaw {
                        // A block of its own, as code in a document, so it reads as text to copy.
                        Text(metadata.raw)
                            .appFont(.caption, design: .monospaced)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                    } else {
                        ForEach(metadata.groups, id: \.self) { group in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(group.name).appFont(.subheadline, weight: .semibold)
                                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 2) {
                                    ForEach(group.entries, id: \.self) { row in
                                        GridRow {
                                            Text(row.label).foregroundStyle(.secondary)
                                                .scaledFrame(width: Self.tagWidth, alignment: .trailing)
                                            Text(row.value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                    }
                                }
                                .appFont(.caption)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.top, 6)
            }
        }
    }
}

/// A row that answers the pointer: lit while hovered, darker while pressed.
private struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Row(configuration: configuration) }

    private struct Row: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 5)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.14 : hovering ? 0.07 : 0)))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}
