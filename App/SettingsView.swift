import SwiftUI

/// Which part of Settings to bring into view when it opens from elsewhere in the app.
@MainActor @Observable
final class SettingsNavigator {
    static let shared = SettingsNavigator()

    enum Target: Hashable {
        case photoService
    }

    var target: Target?
}

/// Settings' tabs, as in other Mac apps: each shows all of its settings at once.
enum SettingsTab: String {
    case general, devices, transfers, viewer
}

/// App menu ▸ Settings (⌘,).
struct SettingsView: View {
    @AppStorage(SettingsKey.settingsTab) private var tab = SettingsTab.general

    var body: some View {
        TabView(selection: $tab) {
            SettingsPage { TextSizeSection() }
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            SettingsPage { DeviceSettings() }
                .tabItem { Label("Devices", systemImage: "cable.connector") }
                .tag(SettingsTab.devices)
            SettingsPage { TransferSettings() }
                .tabItem { Label("Transfers", systemImage: "arrow.up.arrow.down") }
                .tag(SettingsTab.transfers)
            SettingsPage { ViewerSettings() }
                .tabItem { Label("Viewer", systemImage: "eye") }
                .tag(SettingsTab.viewer)
        }
        .onChange(of: SettingsNavigator.shared.target, initial: true) { _, target in
            if target == .photoService { tab = .devices }
        }
        #if DEBUG
        // Development: -dev.settingsSection general|devices|transfers|viewer, for snapshots.
        .onAppear {
            if let name = UserDefaults.standard.string(forKey: "dev.settingsSection"), let shown = SettingsTab(rawValue: name) {
                tab = shown
            }
        }
        #endif
    }
}

/// One tab: its sections at their full height, so nothing needs scrolling.
private struct SettingsPage<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .scaledFrame(width: 520)
            .fixedSize(horizontal: false, vertical: true)
            .textArea(.panels)
            .scaledButtons()
    }
}

/// Connecting devices: macOS's photo service, Wi-Fi.
private struct DeviceSettings: View {
    @State private var photoServiceBlocked = false
    /// Disabled, but still loaded in this login session (macOS refused to unload it).
    @State private var stillRunning = false
    @State private var loaded = false
    @State private var confirming = false
    @State private var working = false
    @State private var failure: String?
    @State private var highlighted = false
    @AppStorage(SettingsKey.autoWifi) private var autoWifi = true

    var body: some View {
        Section {
            Toggle("Stop macOS Photos from taking Android devices", isOn: Binding(
                get: { photoServiceBlocked },
                set: { wanted in
                    if wanted { confirming = true } else { apply(false) }
                }
            ))
            .disabled(!loaded || working)
            .padding(4)
            .background(highlighted ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6))
            Text("When an Android device is plugged in, the Photos app (and its widget) asks macOS’s photo service to read the device. That service grabs the device first, and the device keeps working on that scan afterwards, so the first folder can take many seconds to appear. Turning this on stops the service from starting. This only matters for devices in File transfer (MTP) mode; ADB connections aren’t affected.")
                .appFont(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if photoServiceBlocked && stillRunning {
                // macOS's System Integrity Protection won't let any app (or an admin)
                // unload a running system service; the saved setting applies at login.
                Text("Saved. macOS’s System Integrity Protection doesn’t let apps stop the photo service while you’re logged in, so it takes effect after you log out and back in (or restart).")
                    .appFont(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let failure {
                Text(failure).appFont(.callout).foregroundStyle(.red)
            }
        } header: {
            Text("Connecting devices")
        }
        .task {
            await refresh()
            loaded = true
        }
        .onChange(of: SettingsNavigator.shared.target, initial: true) { _, target in
            guard target == .photoService else { return }
            SettingsNavigator.shared.target = nil
            Task {
                try? await Task.sleep(for: .milliseconds(200))
                withAnimation { highlighted = true }
                try? await Task.sleep(for: .seconds(2))
                withAnimation { highlighted = false }
            }
        }
        .alert("Stop the photo service?", isPresented: $confirming) {
            Button("Turn On") { apply(true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("While this is on, Photos and Image Capture can’t import from cameras or devices on this Mac. You can turn it off here at any time. A device that’s already plugged in may need to be reconnected.")
        }
        Section {
            Toggle("Also connect over Wi-Fi when the device allows it", isOn: $autoWifi)
            Text("A device that has wireless debugging on and has allowed this Mac stays connected after you unplug the cable.")
                .appFont(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Wi-Fi")
        }
    }

    private func apply(_ blocked: Bool) {
        working = true
        failure = nil
        Task {
            do {
                try await PhotoServiceControl.setBlocked(blocked)
            } catch {
                failure = error.localizedDescription
            }
            await refresh()
            working = false
        }
    }

    private func refresh() async {
        #if DEBUG
        // Development: -dev.photoService on|off shows that state without reading macOS's, for snapshots.
        if let shown = UserDefaults.standard.string(forKey: "dev.photoService") {
            photoServiceBlocked = shown == "on"
            stillRunning = false
            return
        }
        #endif
        photoServiceBlocked = await PhotoServiceControl.isBlocked()
        stillRunning = photoServiceBlocked ? await PhotoServiceControl.isLoaded() : false
    }
}

private struct TransferSettings: View {
    @AppStorage(SettingsKey.bundleSmallFiles) private var bundleSmallFiles = false
    @AppStorage(SettingsKey.zipWhenDatesNotKept) private var zipWhenDatesNotKept = false
    @AppStorage(SettingsKey.writeNewFilesDirectly) private var writeNewFilesDirectly = false
    @AppStorage(SettingsKey.writeReplacedFilesDirectly) private var writeReplacedFilesDirectly = false
    @AppStorage(SettingsKey.directWriteLimitMB) private var directWriteLimitMB = 16
    @AppStorage(SettingsKey.keepReplacedFiles) private var keepReplacedFiles = false

    var body: some View {
        Section {
            Toggle("Keep file dates on devices that change them: send as a zip", isOn: $zipWhenDatesNotKept)
            Text("Some devices give files the date they arrive (Galaxy in File transfer mode). With this on, uploads to them start out as one zip to unpack on the device, which keeps the dates. You can still choose per upload.")
                .appFont(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Keep the creation time of files being replaced (ADB)", isOn: $keepReplacedFiles)
            Text("Over ADB, a file on the device that's replaced keeps the time it was first created there, so apps that sort by when files were added (such as photo pickers when attaching) still show it where it was. If copying stops partway, that file is left incomplete; send it again.")
                .appFont(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("File dates")
        }
        Section {
            Toggle("Bundle small files when transferring", isOn: $bundleSmallFiles)
            Text("When receiving many small files from a device over ADB, the device sends them together in one stream. Faster on some devices, slower on others; try it if receiving many small files feels slow.")
                .appFont(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Write new files to the device directly", isOn: $writeNewFilesDirectly)
                .onChange(of: writeNewFilesDirectly) { _, on in if !on { writeReplacedFilesDirectly = false } }
            Text("Written under their own name instead of a temporary one first, which is faster for many small files. If copying stops, the files being copied at that moment are left incomplete on the device; copy them again.")
                .appFont(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LabeledContent("Largest file") {
                MenuChoice(selection: $directWriteLimitMB,
                           items: [1, 4, 16, 64].map { .option($0, ByteFormat.string(UInt64($0) * 1_000_000)) }
                               + [.option(0, String(localized: "Any size"))])
            }
            .disabled(!writeNewFilesDirectly)
            .padding(.leading, 20)
            Toggle("Also files that replace existing ones", isOn: $writeReplacedFilesDirectly)
                .disabled(!writeNewFilesDirectly || keepReplacedFiles)
                .padding(.leading, 20)
            Group {
                if keepReplacedFiles {
                    Text("Not while replaced files keep their creation time.")
                } else {
                    Text("If copying stops, the files being replaced at that moment lose their originals.")
                }
            }
                .appFont(.callout)
                .foregroundStyle(writeReplacedFilesDirectly && !keepReplacedFiles ? Color.orange : Color.secondary)
                .padding(.leading, 20)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Speed")
        }
    }
}

private struct ViewerSettings: View {
    @AppStorage(SettingsKey.viewerImageLimitMB) private var viewerImageLimitMB = 50
    @AppStorage(SettingsKey.viewerTextLimitMB) private var viewerTextLimitMB = 5
    @AppStorage(SettingsKey.viewerPDFLimitMB) private var viewerPDFLimitMB = 50
    @AppStorage(SettingsKey.previewLimitMB) private var previewLimitMB = 10

    var body: some View {
        Section {
            LabeledContent("Pictures up to") {
                MenuChoice(selection: $viewerImageLimitMB,
                           items: [10, 50, 100, 200].map { .option($0, ByteFormat.string(UInt64($0) * 1_000_000)) })
            }
            LabeledContent("PDFs up to") {
                MenuChoice(selection: $viewerPDFLimitMB,
                           items: [10, 50, 100, 200].map { .option($0, ByteFormat.string(UInt64($0) * 1_000_000)) })
            }
            LabeledContent("Text files up to") {
                MenuChoice(selection: $viewerTextLimitMB,
                           items: [1, 5, 20, 50].map { .option($0, ByteFormat.string(UInt64($0) * 1_000_000)) })
            }
            Text("Double-clicking a picture, PDF or text file shows it in a window, without saving it on this Mac; videos and music play as they’re read, at any size. Larger files and other kinds open in an app: they’re received to a temporary folder that’s emptied when you quit.")
                .appFont(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Viewer")
        }
        Section {
            LabeledContent("Previews read files up to") {
                MenuChoice(selection: $previewLimitMB,
                           items: [5, 10, 20, 50].map { .option($0, ByteFormat.string(UInt64($0) * 1_000_000)) })
            }
            Text("The preview beside the file list reads only the start of a photo, or the small picture the device keeps. A picture without either, or a PDF, is read whole when it’s no larger than this; larger ones show their icon.")
                .appFont(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Preview Panel")
        }
    }
}

/// Text size: a preset for the whole app, or a size per part of the window.
private struct TextSizeSection: View {
    private let settings = TextSettings.shared

    var body: some View {
        Section {
            LabeledContent("Text size") {
                SegmentedChoice(selection: Binding(get: { settings.preset }, set: { settings.apply($0) }),
                                options: [(TextPreset.standard, String(localized: "Standard")),
                                          (.large, String(localized: "Large")),
                                          (.extraLarge, String(localized: "Extra Large"))]
                                    + (settings.preset == .custom ? [(.custom, String(localized: "Custom"))] : []))
            }
            Group {
                switch settings.preset {
                case .standard: Text("macOS’s usual sizes.")
                case .large: Text("No text smaller than 16 pt, the size of normal text on the web.")
                case .extraLarge: Text("Body text at 19 pt, nothing smaller than 18 pt.")
                case .custom: Text("Sizes set below.")
                }
            }
            .appFont(.callout)
            .foregroundStyle(.secondary)

            ForEach(TextArea.allCases) { area in
                let size = settings.bases[area] ?? 13
                Stepper(value: Binding(get: { size }, set: { settings.setCustomBase($0, for: area) }), in: 10...32) {
                    LabeledContent(area.title) {
                        Text(verbatim: "\(Int(size)) pt").monospacedDigit()
                    }
                }
            }
            Stepper(value: Binding(get: { settings.minimum }, set: { settings.setCustomMinimum($0) }), in: 0...24) {
                LabeledContent("Smallest text") {
                    if settings.minimum == 0 {
                        Text("No limit")
                    } else {
                        Text(verbatim: "\(Int(settings.minimum)) pt").monospacedDigit()
                    }
                }
            }
            Text("Captions and notes follow each part’s size but never go below the smallest size. The toolbar and menus keep macOS’s size.")
                .appFont(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Text")
        }
    }
}
