import Foundation

/// Every setting stored in UserDefaults, with its default in one place (registered at launch,
/// so `@AppStorage` and model code agree without repeating defaults).
enum SettingsKey {
    // Settings window
    static let autoWifi = "autoWifi"
    static let bundleSmallFiles = "bundleSmallFiles"
    static let zipWhenDatesNotKept = "zipWhenDatesNotKept"
    static let writeNewFilesDirectly = "writeNewFilesDirectly"
    static let writeReplacedFilesDirectly = "writeReplacedFilesDirectly"
    /// A file that replaces one on the device keeps the time it was created there (it's
    /// copied into that file rather than taking its place).
    static let keepReplacedFiles = "keepReplacedFiles"
    /// Largest file written directly, in MB; 0 = any size.
    static let directWriteLimitMB = "directWriteLimitMB"
    /// Largest picture / text file shown in the viewer, in MB.
    static let viewerImageLimitMB = "viewerImageLimitMB"
    static let viewerTextLimitMB = "viewerTextLimitMB"
    static let viewerPDFLimitMB = "viewerPDFLimitMB"
    /// JSON shown laid out (one value per line) rather than as written.
    static let viewerIndentJSON = "viewerIndentJSON"
    /// The file list's preview panel is open.
    static let showPreviewPanel = "showPreviewPanel"
    /// The preview panel reads the selected file from the device (pictures, text, details).
    static let previewReadsDevice = "previewReadsDevice"
    /// The preview panel's "All Details" is open, and shows the tags as stored.
    static let previewShowsAllDetails = "previewShowsAllDetails"
    static let previewShowsRawDetails = "previewShowsRawDetails"
    /// Largest file the preview panel reads whole (a picture with no small picture in it, a
    /// PDF), in MB.
    static let previewLimitMB = "previewLimitMB"
    /// The Settings tab last shown.
    static let settingsTab = "settingsTab"
    // View options
    static let sizeDisplay = "sizeDisplay"
    static let toolbarStyle = "toolbarStyle"
    static let showHidden = "showHidden"
    /// The file list's search is a regular expression.
    static let searchUsesRegex = "searchUsesRegex"
    static let showTransfersOnStart = "showTransfersOnStart"
    static let batchRenameRules = "batchRenameRules"
    // Text size
    static let textPreset = "text.preset"
    static let textMinimum = "text.minimum"
    static func textSize(_ area: String) -> String { "text.\(area)" }
    // Remembered between transfers
    static let lastTransferPolicy = "lastTransferPolicy"
    static let lastDownloadFolder = "lastDownloadFolder"
    // Per device (by serial)
    static func favorites(_ serial: String) -> String { "favorites.\(serial)" }
    static func transport(_ serial: String) -> String { "transport.\(serial)" }
    /// Whether the phone keeps upload dates over that kind of connection (backend type name).
    static func uploadDates(_ serial: String, connection: String) -> String { "uploadDates.\(serial).\(connection)" }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            autoWifi: true,
            bundleSmallFiles: false,
            zipWhenDatesNotKept: false,
            writeNewFilesDirectly: false,
            writeReplacedFilesDirectly: false,
            keepReplacedFiles: false,
            directWriteLimitMB: 16,
            viewerImageLimitMB: 50,
            viewerTextLimitMB: 5,
            viewerPDFLimitMB: 50,
            viewerIndentJSON: true,
            showPreviewPanel: false,
            previewReadsDevice: true,
            previewLimitMB: 10,
            showHidden: false,
            showTransfersOnStart: true,
        ])
    }
}
