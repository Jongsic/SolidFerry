import AdbKit
import Foundation
import Observation
import SwiftUI

/// Getting adb for someone who has none: with Homebrew when it's there (a developer's Mac; it
/// keeps adb updated), or Google's own platform-tools downloaded into the app's folder
/// (`AdbServer.appInstalled`). Offered where a phone could use ADB; the device monitor finds
/// the new adb by itself.
@MainActor @Observable
final class AdbSetup {
    enum State: Equatable {
        case idle
        case installing
        case failed(String)
    }

    static let shared = AdbSetup()

    private(set) var state = State.idle
    /// No adb on this Mac (the device monitor says so). Not an error by itself: phones in File
    /// transfer don't need it.
    var missing = false

    static let brewCommand = "brew install android-platform-tools"
    private nonisolated static let downloadURL = URL(string: "https://dl.google.com/android/repository/platform-tools-latest-darwin.zip")!
    /// Google's team ID: a download whose adb isn't signed by it isn't used.
    private nonisolated static let googleTeam = "EQHXZ8M8AV"

    /// Homebrew, where it's usually installed (apps don't get the shell's PATH).
    static var brew: URL? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    func installWithBrew() {
        guard state != .installing, let brew = Self.brew else { return }
        run {
            let output = try await Self.run(brew, ["install", "android-platform-tools"],
                                            environment: ["HOMEBREW_NO_AUTO_UPDATE": "1", "NONINTERACTIVE": "1"])
            guard AdbServer.locateBinary() != nil else { throw Failure(lastLine(of: output)) }
        }
    }

    func download() {
        guard state != .installing else { return }
        run {
            let downloadFailed = Failure(String(localized: "The download didn’t finish. Check your internet connection and try again."))
            let (zip, response) = try await URLSession.shared.download(from: Self.downloadURL)
            defer { try? FileManager.default.removeItem(at: zip) }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw downloadFailed }
            let target = AdbServer.appInstalled.deletingLastPathComponent() // …/platform-tools
            let folder = target.deletingLastPathComponent()
            let unpacked = folder.appendingPathComponent(".unpacking-\(UUID().uuidString)")
            let fm = FileManager.default
            try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: unpacked) }
            do {
                _ = try await Self.run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", zip.path, unpacked.path])
            } catch {
                throw downloadFailed
            }
            let adb = unpacked.appendingPathComponent("platform-tools/adb")
            let requirement = "=anchor apple generic and certificate leaf[subject.OU] = \"\(Self.googleTeam)\""
            do {
                _ = try await Self.run(URL(fileURLWithPath: "/usr/bin/codesign"), ["-v", "-R", requirement, adb.path])
            } catch {
                throw Failure(String(localized: "The downloaded adb isn’t signed by Google, so it wasn’t installed."))
            }
            try? fm.removeItem(at: target)
            try fm.moveItem(at: unpacked.appendingPathComponent("platform-tools"), to: target)
        }
    }

    private func run(_ work: @escaping @Sendable () async throws -> Void) {
        state = .installing
        Task {
            do {
                try await work()
                state = .idle
            } catch let failure as Failure {
                state = .failed(failure.message)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    private struct Failure: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    /// Runs a tool off the main thread; its output, or a `Failure` with its last line.
    private nonisolated static func run(_ tool: URL, _ arguments: [String], environment: [String: String] = [:]) async throws -> String {
        try await Task.detached {
            let process = Process()
            process.executableURL = tool
            process.arguments = arguments
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(decoding: data, as: UTF8.self)
            guard process.terminationStatus == 0 else { throw Failure(lastLine(of: output)) }
            return output
        }.value
    }
}

private func lastLine(of output: String) -> String {
    output.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
}

/// What it takes to connect a phone over ADB, from where it is now: adb on this Mac (with a
/// button to get it) and USB debugging on the phone. Shown where ADB isn't available: under a
/// phone's connection steps, in its connection panel, and from the browser's suggestion.
struct AdbGuide: View {
    let session: DeviceSession
    var setup = AdbSetup.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if setup.missing {
                VStack(alignment: .leading, spacing: 6) {
                    Text("1. Install adb on this Mac").fontWeight(.semibold)
                    AdbInstall()
                }
            }
            if session.adb?.status == .unauthorized {
                Text("Tap “Allow USB debugging” on the device.").fontWeight(.semibold)
            } else if session.usb?.hasADB != true {
                VStack(alignment: .leading, spacing: 4) {
                    (setup.missing ? Text("2. Turn on USB debugging on the device") : Text("Turn on USB debugging on the device"))
                        .fontWeight(.semibold)
                    Text("Settings › About phone (on a Galaxy, › Software information): tap Build number seven times. Then Settings › Developer options: turn on USB debugging, and allow this Mac when the device asks.")
                        .appFont(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Getting adb: Homebrew when it's there, or Google's download; shows how it's going.
struct AdbInstall: View {
    var setup = AdbSetup.shared

    var body: some View {
        switch setup.state {
        case .installing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Installing adb… This can take a few minutes.")
            }
        case .failed(let message):
            Text("Couldn’t install adb: \(message)").appFont(.caption).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            buttons
        case .idle:
            buttons
        }
    }

    @ViewBuilder private var buttons: some View {
        if AdbSetup.brew != nil {
            Button("Install with Homebrew") { setup.installWithBrew() }
            Text(verbatim: AdbSetup.brewCommand)
                .appFont(.caption).monospaced().foregroundStyle(.secondary).textSelection(.enabled)
            Button("Download from Google instead") { setup.download() }
                .buttonStyle(.link)
        } else {
            Button("Download adb from Google") { setup.download() }
        }
        Text("Downloads Android SDK Platform-Tools for this app only. By downloading, you agree to the [Android SDK terms](https://developer.android.com/studio/terms).")
            .appFont(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// `AdbGuide` as a card of its own, for a phone that's waiting on ADB.
struct AdbSetupCard: View {
    let session: DeviceSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Connect over USB debugging (ADB)", systemImage: "wrench.and.screwdriver")
                .appFont(.headline)
            // With ADB chosen, File transfer isn't used (the steps above offer Auto instead).
            if session.preference != .adb {
                Text("Or choose “File transfer” in the device’s USB notification, which needs nothing installed.")
                    .appFont(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            AdbGuide(session: session)
        }
        .frame(maxWidth: 380, alignment: .leading)
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

/// Suggesting ADB for a phone connected over MTP: what it brings, in what was seen.
@MainActor
enum AdbSuggestion {
    static func benefit(for session: DeviceSession) -> String {
        // Said only for a phone seen to drop the dates of files sent over this connection.
        let datesDropped = session.fileSystem.map { $0.transport == .mtp && UploadDates.known(session.serial, fs: $0) == .ignored } ?? false
        return datesDropped
            ? String(localized: "With USB debugging, many small files copy much faster, and files sent to this device keep their dates.")
            : String(localized: "With USB debugging, many small files copy much faster.")
    }

    private static func key(_ serial: String) -> String { "adbSuggestionClosed.\(serial)" }

    /// Closed for this phone; it isn't suggested again.
    static func isClosed(_ serial: String) -> Bool { UserDefaults.standard.bool(forKey: key(serial)) }
    static func close(_ serial: String) { UserDefaults.standard.set(true, forKey: key(serial)) }
}

/// Above the files of a phone connected over MTP that could use ADB, until it's closed.
struct AdbSuggestionBar: View {
    let session: DeviceSession
    @State private var closed = false
    @State private var showsHow = false

    var body: some View {
        if !closed, !AdbSuggestion.isClosed(session.serial) {
            HStack(spacing: 8) {
                Image(systemName: "bolt.fill").foregroundStyle(.yellow)
                Text(AdbSuggestion.benefit(for: session)).lineLimit(2)
                Spacer(minLength: 8)
                Button("Show How") { showsHow = true }
                    .controlSize(.small)
                    .popover(isPresented: $showsHow, arrowEdge: .bottom) {
                        AdbGuide(session: session)
                            .frame(width: 360, alignment: .leading)
                            .padding(16)
                    }
                Button {
                    AdbSuggestion.close(session.serial)
                    closed = true
                } label: {
                    Label("Don’t Show Again", systemImage: "xmark").labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Don’t Show Again")
            }
            .appFont(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.yellow.opacity(0.08))
            Divider()
        }
    }
}
