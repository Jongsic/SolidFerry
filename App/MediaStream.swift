import AVFoundation
import AVKit
import DeviceCore
import os
import SwiftUI

/// Plays a device file as AVFoundation reads it: the player asks for the parts it needs
/// (the start, the index, wherever you jump to) and only those are read from the device,
/// into memory. Nothing is written on this Mac.
private let mediaLog = Logger(subsystem: WorkNames.subsystem, category: "media")

final class DeviceMediaLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    /// A made-up scheme, so AVFoundation asks this loader instead of opening the URL.
    private static let scheme = "\(WorkNames.tag)-media"

    /// After a read fails on `fs`: the device's connection to carry on with once it's back
    /// (over Wi-Fi, or plugged in again), or nil when the read failed for another reason.
    typealias Reconnect = @Sendable (_ fs: any DeviceFileSystem, _ error: Error) async -> (any DeviceFileSystem)?

    private let entry: RemoteEntry
    private let size: UInt64
    private let contentType: String
    private let reconnect: Reconnect
    /// The connection reads go to; replaced when the device comes back.
    private let connection: OSAllocatedUnfairLock<any DeviceFileSystem>
    let queue = DispatchQueue(label: "\(WorkNames.subsystem).media")
    /// Reads under way, by request; only touched on `queue`.
    private var reads: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(entry: RemoteEntry, size: UInt64, fs: any DeviceFileSystem, contentType: String, reconnect: @escaping Reconnect) {
        self.entry = entry
        self.size = size
        self.contentType = contentType
        self.reconnect = reconnect
        connection = OSAllocatedUnfairLock(initialState: fs)
    }

    func makeAsset() -> AVURLAsset {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "device"
        components.path = "/" + entry.name
        let asset = AVURLAsset(url: components.url!)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        if let info = loadingRequest.contentInformationRequest {
            info.contentType = contentType
            info.contentLength = Int64(size)
            info.isByteRangeAccessSupported = true
        }
        guard let dataRequest = loadingRequest.dataRequest else {
            loadingRequest.finishLoading()
            return true
        }
        let start = UInt64(max(dataRequest.requestedOffset, 0))
        let end = dataRequest.requestsAllDataToEndOfResource
            ? size : min(size, start + UInt64(max(dataRequest.requestedLength, 0)))
        guard start < end else {
            loadingRequest.finishLoading()
            return true
        }
        let id = ObjectIdentifier(loadingRequest)
        let request = Unchecked(loadingRequest)
        mediaLog.debug("read \(start, privacy: .public)..<\(end, privacy: .public) asked")
        let queue = queue
        reads[id] = Task { [weak self] in
            var failure: Error?
            let started = ContinuousClock.now
            do {
                try await self?.read(start..<end, into: request)
            } catch is CancellationError where Task.isCancelled {
                mediaLog.debug("read \(start, privacy: .public)..<\(end, privacy: .public) stopped after \(ContinuousClock.now - started, privacy: .public)")
                return
            } catch {
                failure = error
            }
            mediaLog.debug("read \(start, privacy: .public)..<\(end, privacy: .public) done in \(ContinuousClock.now - started, privacy: .public), \(failure.map { "\($0)" } ?? "ok", privacy: .public)")
            queue.async { [weak self, failure] in
                self?.reads[id] = nil
                guard !request.value.isCancelled, !request.value.isFinished else { return }
                if let failure { request.value.finishLoading(with: failure) } else { request.value.finishLoading() }
            }
        }
        return true
    }

    /// Reads `range` into the request; when the connection drops partway, carries on from where
    /// it stopped once the device is back.
    private func read(_ range: Range<UInt64>, into request: Unchecked<AVAssetResourceLoadingRequest>) async throws {
        let next = OSAllocatedUnfairLock(initialState: range.lowerBound)
        let queue = queue
        while true {
            let fs = connection.withLock { $0 }
            do {
                try await fs.read(entry, range: next.withLock { $0 }..<range.upperBound) { data in
                    next.withLock { $0 += UInt64(data.count) }
                    queue.async { request.value.dataRequest?.respond(with: data) }
                }
                return
            } catch is CancellationError where Task.isCancelled {
                throw CancellationError()
            } catch {
                // Otherwise a closed connection (MTP ends its queued requests with
                // CancellationError): carried on over the next one like any other drop.
                guard let replacement = await reconnect(fs, error) else { throw error }
                try Task.checkCancellation()
                connection.withLock { $0 = replacement }
                mediaLog.debug("read carries on from \(next.withLock { $0 }, privacy: .public) on a new connection")
            }
        }
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        reads.removeValue(forKey: ObjectIdentifier(loadingRequest))?.cancel()
    }

    /// Stops every read (the window closed).
    func stop() {
        queue.async {
            self.reads.values.forEach { $0.cancel() }
            self.reads = [:]
        }
    }
}

/// AVFoundation's request objects aren't Sendable; they're only used on the loader's queue.
private struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

extension ViewerKind {
    /// Whether AVFoundation plays this kind of file (MP4, MOV, MP3, M4A, WAV, …; not MKV).
    static func plays(_ type: UTType) -> Bool {
        type.conforms(to: .audiovisualContent)
            && AVURLAsset.audiovisualTypes().contains(AVFileType(rawValue: type.identifier))
    }
}

/// The system player with its usual controls.
struct ViewerPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
