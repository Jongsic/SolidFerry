#if DEBUG
import AppKit
import AVFoundation
import DeviceCore
import Foundation
import OSLog
import TransferKit

/// Development builds only: launch arguments that drive the app without clicking, for
/// measuring and for exercising whole pipelines on test devices. Applied through the same
/// APIs the UI uses.
///
///     -dev.open SERIAL:/path                      open a window there
///     -dev.upload SERIAL|/device/folder|/local/path [-dev.zip YES]
///     -dev.download SERIAL|/device/folder|/local/folder   (several of a kind: separated by ";")
///     -dev.deviceCopy SERIAL[>TO_SERIAL]|/device/source|/device/folder|copy|move
///     -dev.policy skip|overwrite|…                policy for the jobs above
///     -dev.deviceName NAME                        the device name the jobs above show
///     -dev.resumeSaved YES                        resume jobs saved at the last quit
///     -dev.pauseAfter SECONDS                     pause the jobs above that long after one starts
///                                                 running, and resume them once they've stopped
///                                                 (scripts/pause-test.sh)
///     -dev.quitWhenDone FILE                      once the jobs above finish, write their results
///                                                 (JSON) to FILE and quit — for scripts/queue-test.sh
///     -dev.wifi SERIAL                            press "Connect over Wi-Fi" once it's ready
///     -dev.snapshot DIR                           capture every window into DIR (DevelopmentSnapshots)
///     -dev.snapshotDelay SECONDS                  first capture after this long (4)
///     -dev.snapshotCount N                        then N − 1 more (1)
///     -dev.snapshotEvery SECONDS                  that far apart (3)
///     -dev.showDialog download|upload:/path       open that dialog (BrowserView)
///     -dev.showDialog view:NAME;NAME…             open those files of the folder in the viewer
///     -dev.showDialog select:NAME;NAME…           select those files of the folder
///     -dev.showDialog filter:TEXT;TEXT…          type each into the name filter in turn, 1.5 s apart,
///                                                 logging how long it took (category "development")
///     -dev.showDialog selectEach:NAME;NAME…       select each of those in turn, -dev.selectEvery
///                                                 SECONDS apart (2)
///     -dev.dialogFilter new|same|different        the dialog list's filter (FileComparisonPanel) with its
///                                                 preview open
///     -dev.connectionPanel SERIAL                 open that device's connection panel
///     -dev.showWindow settings|transfers|wireless with -dev.snapshot: open that window
///     -dev.openTabs SERIAL:/path;…                more browser windows, as tabs of the first
///     -dev.settingsSection general|devices|transfers|viewer  show that Settings tab
///     -dev.photoService on|off                    Settings shows the photo service setting that way,
///                                                 without reading or changing macOS's
///     -dev.openWith default                       with view: above, "Open in <default app>" instead
///     -dev.press ACTION@SECONDS[@viewer];…       that long after launch, in the key window or the
///                                                 frontmost file list: a key (space|return|down|up|escape|backspace|shift-backspace;
///                                                 @viewer: into the frontmost viewer), find (⌘F),
///                                                 type:TEXT, or menu:NAME:ITEM (right-click that row,
///                                                 choose that item)
///     -dev.closeViewerAfter SECONDS               close each viewer that long after it opens (while it's
///                                                 still reading), then open it once more
///     -dev.imageZoom SCALE|fit;…                  in the viewer, set a picture's zoom to each in turn, 3 s apart
///     -dev.seek SECONDS;SECONDS…                  in the viewer, jump to each time in turn, 8 s apart,
///                                                 as dragging the slider does, and play on; logs how long
///                                                 each took and where the player is every second
///                                                 (category "development")
///
/// Real settings can be given the same way for one run without saving them, e.g.
/// `-transport.SERIAL adb|mtp|auto` or `-lastDownloadFolder /path`.
@MainActor
enum DevelopmentLaunchArguments {
    private static let defaults = UserDefaults.standard

    /// Where a fresh window opens.
    static var initialTarget: BrowserTarget? {
        guard let spec = defaults.string(forKey: "dev.open"), let colon = spec.firstIndex(of: ":") else { return nil }
        return BrowserTarget(deviceID: String(spec[..<colon]), path: String(spec[spec.index(after: colon)...]))
    }

    static func apply(to queue: TransferQueue, hub: DeviceHub) {
        let jobs = enqueueJobs(on: queue)
        if let path = defaults.string(forKey: "dev.quitWhenDone") {
            Task {
                while !jobs.allSatisfy(\.state.isFinished) { try? await Task.sleep(for: .milliseconds(300)) }
                writeResults(jobs, to: URL(fileURLWithPath: path))
                NSApp.terminate(nil)
            }
        }
        if defaults.bool(forKey: "dev.resumeSaved") { queue.jobs.forEach(queue.resume) }
        if defaults.object(forKey: "dev.pauseAfter") != nil {
            let delay = defaults.double(forKey: "dev.pauseAfter")
            Task {
                while !jobs.contains(where: { $0.state == .running }) {
                    if jobs.allSatisfy(\.state.isFinished) { return }
                    try? await Task.sleep(for: .milliseconds(20))
                }
                try? await Task.sleep(for: .seconds(delay))
                jobs.forEach(queue.pause)
                // A running job settles in "paused" once its task has stopped.
                while !jobs.allSatisfy({ $0.state == .paused || $0.state.isFinished }) { try? await Task.sleep(for: .milliseconds(50)) }
                pausedJobs = Set(jobs.filter { $0.state == .paused }.map(\.id))
                jobs.forEach(queue.resume)
            }
        }
        if let serial = defaults.string(forKey: "dev.wifi") {
            Task {
                // Wait for the phone to be ready over adb, then ask once.
                for _ in 0..<60 {
                    if let session = hub.session(serial), session.adb?.status == .ready {
                        session.connectOverWifi()
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
        }
    }

    /// Jobs that -dev.pauseAfter caught before they finished.
    private static var pausedJobs = Set<UUID>()

    /// One object per job: how it ended, and how many files were copied, skipped and failed.
    private static func writeResults(_ jobs: [TransferJob], to url: URL) {
        let results = jobs.map { job -> [String: Any] in
            let state: String = switch job.state {
            case .completed: "completed"
            case .failed(let message): "failed: \(message)"
            default: "\(job.state)"
            }
            let failures = job.items.compactMap { item -> String? in
                if case .failed(let message) = item.state { "\(item.name): \(message)" } else { nil }
            }
            return ["route": job.routeDescription, "state": state, "copied": job.counts.done,
                    "skipped": job.counts.skipped, "failed": job.counts.failed, "failures": failures,
                    "paused": pausedJobs.contains(job.id)]
        }
        if let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url)
        }
    }

    /// The jobs asked for, in the order they were queued.
    private static func enqueueJobs(on queue: TransferQueue) -> [TransferJob] {
        var jobs: [TransferJob] = []
        func enqueue(_ job: TransferJob) {
            queue.enqueue(job)
            jobs.append(job)
        }
        // The name jobs show for their device (-dev.deviceName), as if queued from its window.
        func name(_ serial: String) -> String { defaults.string(forKey: "dev.deviceName") ?? serial }
        let policy = TransferPolicy(existing: defaults.string(forKey: "dev.policy").flatMap(ExistingFilePolicy.init) ?? .skip,
                                    whenDifferent: .overwrite)
        // Several jobs of a kind: specs separated by ";".
        func specs(_ key: String, parts: Int) -> [[String]] {
            (defaults.string(forKey: key) ?? "").split(separator: ";").compactMap { spec in
                let fields = spec.split(separator: "|").map(String.init)
                return fields.count == parts ? fields : nil
            }
        }
        for s in specs("dev.upload", parts: 3) {
            enqueue(TransferJob(deviceID: s[0], deviceName: name(s[0]),
                                      route: .upload(sources: [URL(fileURLWithPath: s[2])], to: RemoteRef(path: s[1])),
                                      policy: policy, packAsZip: defaults.bool(forKey: "dev.zip")))
        }
        for s in specs("dev.deviceCopy", parts: 4) {
            let ref = RemoteRef(path: s[1])
            // Good enough for test data: a name with an extension is a file.
            let entry = RemoteEntry(ref: ref, name: ref.name, kind: ref.name.contains(".") ? .file : .directory, size: nil, modified: nil)
            // "FROM>TO" copies between two devices.
            let serials = s[0].split(separator: ">").map(String.init)
            let from = serials[0], to = serials.last!
            enqueue(TransferJob(deviceID: to, deviceName: name(to),
                                      route: .deviceCopy(sources: [entry], fromDeviceID: from, fromDeviceName: name(from),
                                                         to: RemoteRef(path: s[2]), move: s[3] == "move"),
                                      policy: policy))
        }
        for s in specs("dev.download", parts: 3) {
            let ref = RemoteRef(path: s[1])
            let entry = RemoteEntry(ref: ref, name: ref.name, kind: .directory, size: nil, modified: nil)
            enqueue(TransferJob(deviceID: s[0], deviceName: name(s[0]),
                                      route: .download(sources: [entry], to: URL(fileURLWithPath: s[2])), policy: policy))
        }
        return jobs
    }

    /// -dev.seek: jumps the player to each time, 8 s apart, and logs when the picture moved on.
    static func seek(_ player: AVPlayer) {
        let times = (defaults.string(forKey: "dev.seek") ?? "").split(separator: ";").compactMap { Double($0) }
        guard !times.isEmpty else { return }
        let log = Logger(subsystem: WorkNames.subsystem, category: "development")
        // Where the player is, every second.
        Task {
            let started = ContinuousClock.now
            while player.currentItem != nil {
                let loaded = player.currentItem?.loadedTimeRanges.map { range in
                    let r = range.timeRangeValue
                    return String(format: "%.1f-%.1f", r.start.seconds, r.end.seconds)
                }.joined(separator: ",") ?? ""
                log.notice("at \(ContinuousClock.now - started, privacy: .public): \(player.currentTime().seconds, privacy: .public) s, status \(player.timeControlStatus.rawValue, privacy: .public) \(player.reasonForWaitingToPlay?.rawValue ?? "", privacy: .public), loaded \(loaded, privacy: .public)")
                try? await Task.sleep(for: .seconds(1))
            }
        }
        Task {
            for seconds in times {
                try? await Task.sleep(for: .seconds(8))
                let started = ContinuousClock.now
                let target = CMTime(seconds: seconds, preferredTimescale: 600)
                let done = await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
                let seeked = ContinuousClock.now - started
                // Stopped at the end: press play again.
                player.play()
                // Playing again: the clock moves past where it landed.
                let landed = player.currentTime().seconds
                while player.currentTime().seconds < landed + 0.5, ContinuousClock.now - started < .seconds(30) {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                let playing = ContinuousClock.now - started
                log.notice("seek \(seconds, privacy: .public) s: finished \(done, privacy: .public) in \(seeked, privacy: .public), landed \(landed, privacy: .public) s, playing again after \(playing, privacy: .public)")
            }
        }
    }
}

/// -dev.closeViewerAfter: closes a viewer while it's still reading, then opens it once more.
@MainActor
enum DevelopmentViewer {
    private static var reopened = Set<String>()

    /// -dev.imageZoom: sets the picture's zoom to each value in turn.
    static func zoomSteps(_ zoom: ImageZoom) {
        let steps = (UserDefaults.standard.string(forKey: "dev.imageZoom") ?? "").split(separator: ";")
        guard !steps.isEmpty else { return }
        Task {
            for step in steps {
                try? await Task.sleep(for: .seconds(3))
                if step == "fit" { zoom.mode = .fit } else if let scale = Double(step) { zoom.mode = .scale(scale) }
            }
        }
    }

    static func closeEarly(_ window: NSWindow, reopen: @escaping @MainActor () -> Void) {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "dev.closeViewerAfter") != nil, !reopened.contains(window.title) else { return }
        reopened.insert(window.title)
        let delay = defaults.double(forKey: "dev.closeViewerAfter")
        Task {
            try? await Task.sleep(for: .seconds(delay))
            window.close()
            try? await Task.sleep(for: .seconds(1))
            reopen()
        }
    }
}
#endif
