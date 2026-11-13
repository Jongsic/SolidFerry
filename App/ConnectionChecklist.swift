import AppKit
import DeviceCore
import SwiftUI

/// Step-by-step connection status: each step is done, failing (with the one thing to do),
/// in progress, or waiting on an earlier step. Fixing a step moves on by itself.
struct ConnectionChecklist: View {
    let device: DeviceDescriptor
    let session: DeviceSession
    @State private var quitting: QuitCandidate?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                StepRow(step: step) { candidate in quitting = candidate }
            }
        }
        .alert(quitting.map { String(localized: "Quit \($0.name)?") } ?? "",
               isPresented: Binding(get: { quitting != nil }, set: { if !$0 { quitting = nil } }),
               presenting: quitting) { candidate in
            Button("Quit", role: .destructive) { candidate.app.terminate() }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("It’s using the device’s file access. Unsaved work in it may be lost.")
        }
    }

    // MARK: Steps

    private var steps: [Step] {
        var steps: [Step] = []
        let wireless = device.link == .wifi
        steps.append(Step(title: String(localized: "Device found"),
                          state: session.mtpDiagnosis.cabled || wireless || device.availableTransports.contains(.adb) ? .done : .failed,
                          detail: nil))

        switch session.targetTransport ?? device.transport {
        case .adb:
            let status = session.adb?.status
            if session.adb == nil, AdbSetup.shared.missing {
                // Chosen by hand, or the phone offers only ADB, but this Mac has no adb
                // (AdbSetupCard below gets it).
                let chosen = session.preference == .adb
                steps.append(Step(
                    title: String(localized: "adb on this Mac"),
                    state: .failed,
                    detail: chosen
                        ? String(localized: "Install adb as shown below, or use Auto to connect with File transfer.")
                        : String(localized: "Install adb as shown below."),
                    action: chosen ? StepAction(title: String(localized: "Use Auto")) { session.preference = .auto } : nil))
                break
            }
            if session.adb == nil, session.preference == .adb, session.usb?.hasADB != true {
                // Chosen by hand, but the phone is only in File transfer.
                steps.append(Step(
                    title: String(localized: "USB debugging allowed"),
                    state: .failed,
                    detail: String(localized: "USB debugging is off on this device. Turn it on in Developer options, or use Auto to connect with File transfer."),
                    action: StepAction(title: String(localized: "Use Auto")) { session.preference = .auto }))
                break
            }
            let allowDetail: String? = switch status {
            case .unauthorized:
                String(localized: "Tap “Allow USB debugging” on the device. If it doesn’t ask, unlock it or plug the cable in again.")
            case .offline: String(localized: "Unplug and reconnect the device.")
            default: nil
            }
            steps.append(Step(
                title: String(localized: "USB debugging allowed"),
                state: status == .ready ? .done : allowDetail != nil ? .failed : .working,
                detail: allowDetail))
            // A failed attempt is tried again by itself; until then it says why.
            let failure = session.fileSystem == nil && !session.isConnecting ? session.error : nil
            steps.append(Step(title: String(localized: "Connected"),
                              state: session.fileSystem != nil ? .done : failure != nil ? .failed : status == .ready ? .working : .waiting,
                              detail: failure))
        case .mtp:
            appendMtpSteps(to: &steps)
        }
        // Everything after the first failure waits on it.
        if let firstFailure = steps.firstIndex(where: { $0.state == .failed }) {
            for i in steps.indices where i > firstFailure && steps[i].state != .done { steps[i].state = .waiting }
        }
        return steps
    }

    private func appendMtpSteps(to steps: inout [Step]) {
        let mtp = session.mtpDiagnosis
        let chargingOnly = !mtp.hasInterface || mtp.problem == .chargingOnly
        // Over USB debugging the app can change the phone's USB mode itself.
        let canFix = session.adb?.status == .ready

        steps.append(Step(
            title: String(localized: "USB set to File transfer"),
            state: chargingOnly ? .failed : .done,
            detail: chargingOnly ? String(localized: "Open the USB notification on the device and choose “File transfer”.") : nil,
            action: chargingOnly && canFix
                ? StepAction(title: String(localized: "Switch Device to File Transfer")) { Task { await session.switchPhoneToFileTransfer() } }
                : nil))

        if !mtp.blockers.isEmpty {
            let candidate = mtp.blockers.lazy.compactMap { QuitCandidate(holder: $0) }.first
            steps.append(Step(
                title: String(localized: "Not used by another app"),
                state: .failed,
                detail: String(localized: "\(OwnerNames.list(mtp.blockers.map(\.name))) is using the device’s file access. Quit that app to connect."),
                quit: candidate))
        } else {
            let photoService = mtp.photoServiceHolds
            steps.append(Step(
                title: String(localized: "Not used by another app"),
                state: .done,
                detail: photoService
                    ? String(localized: "macOS’s photo service connected to the device first. Waiting to take it over…") : nil,
                photoServiceTip: photoService))
        }

        let sessionState: Step.State
        var sessionDetail: String?
        var sessionAction: StepAction?
        if mtp.ready {
            sessionState = .done
        } else if mtp.problem == .unresponsive {
            sessionState = .failed
            sessionDetail = String(localized: "The device stopped responding. Unplug and reconnect it.")
            if canFix {
                sessionAction = StepAction(title: String(localized: "Restart the Device’s File Transfer")) { Task { await session.restartPhoneMtp() } }
            }
        } else if mtp.problem == .unknown {
            sessionState = .failed
            sessionDetail = UserMessage.connectFailure
        } else if mtp.connecting {
            sessionState = .working
            if mtp.phoneBusy { sessionDetail = String(localized: "The device is finishing an earlier request.") }
        } else {
            sessionState = .waiting
        }
        steps.append(Step(title: String(localized: "Device answering"), state: sessionState, detail: sessionDetail, action: sessionAction))

        steps.append(Step(
            title: String(localized: "Storage available"),
            state: session.fileSystem != nil ? .done : mtp.problem == .noStorage ? .failed : .waiting,
            detail: mtp.problem == .noStorage
                ? String(localized: "Unlock the device and choose “File transfer” in its USB notification.") : nil))
    }
}

struct Step {
    enum State { case done, failed, working, waiting }
    let title: String
    var state: State
    let detail: String?
    var quit: QuitCandidate?
    var action: StepAction?
    /// Offer the setting that keeps macOS's photo service off the phone.
    var photoServiceTip = false
}

struct StepAction {
    let title: String
    let run: () -> Void
}

/// An app holding the phone that can be asked to quit.
struct QuitCandidate: Identifiable {
    let app: NSRunningApplication
    let name: String
    var id: pid_t { app.processIdentifier }

    init?(holder: MtpDiagnosis.Holder) {
        guard let pid = holder.pid, let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        self.app = app
        name = app.localizedName ?? OwnerNames.friendly(holder.name)
    }
}

private struct StepRow: View {
    let step: Step
    let onQuit: (QuitCandidate) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            icon.frame(width: 14)
            VStack(alignment: .leading, spacing: 3) {
                Text(step.title).foregroundStyle(step.state == .waiting ? .secondary : .primary)
                if let detail = step.detail {
                    Text(detail).appFont(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let quit = step.quit {
                    Button("Quit \(quit.name)…") { onQuit(quit) }
                        .controlSize(.small)
                }
                if let action = step.action {
                    Button(action.title, action: action.run)
                        .controlSize(.small)
                }
                if step.photoServiceTip {
                    PhotoServiceSettingButton()
                        .controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder private var icon: some View {
        switch step.state {
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .working: ProgressView().controlSize(.mini)
        case .waiting: Image(systemName: "pause.circle").foregroundStyle(.tertiary)
        }
    }
}
