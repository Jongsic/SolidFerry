import DeviceCore
import SwiftUI

/// "It's working" feedback for waits where there's nothing to show yet, so people don't
/// click away (which, over MTP, only queues more work behind the request they're waiting on).

/// Connecting to a device: which step, and for how long.
struct ConnectingCard: View {
    let deviceName: String
    let stage: ConnectStage?
    let since: Date?

    var body: some View {
        WaitingCard(title: title, detail: detail, since: since, suggestPhotoServiceSetting: stage == .phoneBusy)
    }

    private var title: String {
        switch stage {
        case .claiming: String(localized: "Getting access to \(deviceName)…")
        case .openingSession, nil: String(localized: "Connecting to \(deviceName)…")
        case .waitingForStorage: String(localized: "Waiting for \(deviceName) to open its storage…")
        case .phoneBusy: String(localized: "\(deviceName) is finishing an earlier request…")
        }
    }

    private var detail: String? {
        switch stage {
        case .claiming: String(localized: "If macOS’s photo service connected to the device first, the connection is taken over from it.")
        case .waitingForStorage: String(localized: "Unlock the device and choose “File transfer” in its USB notification.")
        case .phoneBusy: String(localized: "macOS’s photo service connected to the device first and asked it for its photos. Waiting for the device to finish — keep it plugged in.")
        case .openingSession, nil: nil
        }
    }
}

/// A folder is being listed and nothing has arrived yet.
struct ListingWaitCard: View {
    let folderName: String
    let since: Date?
    let fileSystem: (any DeviceFileSystem)?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let waited = since.map { context.date.timeIntervalSince($0) } ?? 0
            // Don't flash for quick listings.
            if waited > 0.4 {
                let detail = detail(at: context.date)
                WaitingCard(title: String(localized: "Receiving the list of “\(folderName)”…"),
                            detail: detail, since: since, suggestPhotoServiceSetting: isPhotosScanWait(at: context.date))
            }
        }
    }

    private func isPhotosScanWait(at now: Date) -> Bool {
        fileSystem?.currentActivity()?.finishingEarlierRequest == true
    }

    private func detail(at now: Date) -> String? {
        guard let activity = fileSystem?.currentActivity() else { return nil }
        switch activity.current {
        case .details where activity.queuedBrowsing > 0:
            return String(localized: "Finishing sizes and dates of the previous folder first.")
        case .transfer where activity.queuedBrowsing > 0:
            return String(localized: "Waiting for a pause in the file being transferred.")
        case .browsing:
            if activity.finishingEarlierRequest {
                return String(localized: "macOS’s photo service connected to the device first and asked it for its photos. Waiting for the device to finish that.")
            }
            if let since = activity.since, now.timeIntervalSince(since) > 2 {
                return String(localized: "The device is still answering (\(Int(now.timeIntervalSince(since))) s).")
            }
            return nil
        default:
            return nil
        }
    }
}

struct WaitingCard: View {
    let title: String
    let detail: String?
    let since: Date?
    /// Offer the setting that prevents this kind of wait.
    var suggestPhotoServiceSetting = false

    var body: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.regular)
            Text(title).appFont(.headline).multilineTextAlignment(.center)
            if let detail {
                Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if suggestPhotoServiceSetting {
                PhotoServiceSettingButton()
            }
            if let since {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Duration.seconds(max(0, context.date.timeIntervalSince(since))).formatted(.units(allowed: [.minutes, .seconds], width: .narrow)))
                        .appFont(.callout).monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: 360)
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

/// Opens Settings at the option that keeps macOS's photo service from connecting first.
struct PhotoServiceSettingButton: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Stop the Photo Service from Connecting First…") {
            SettingsNavigator.shared.target = .photoService
            openSettings()
        }
    }
}
