import DeviceCore
import Foundation
import os

let mtpLog = Logger(subsystem: WorkNames.subsystem, category: "mtp")

/// Marks queued work as no longer wanted (e.g. the user left the folder).
public final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool { lock.withLock { cancelled } }

    public func cancel() {
        lock.withLock { cancelled = true }
    }
}

/// Runs MTP work on one thread, highest priority first. MTP handles one transaction at a
/// time and in-flight requests can't be safely cancelled (QUIRKS M2, M8), so responsiveness
/// comes from ordering: browsing jumps ahead of detail fetches, which jump ahead of file
/// transfers (done in chunks so they yield between requests). Queued jobs whose token was
/// cancelled are dropped without touching the device.
final class MtpWorker: @unchecked Sendable {
    enum Priority: Int, CaseIterable {
        case interactive = 0 // listing names, stat, path resolution, file operations
        case details = 1     // sizes and dates of a listed folder
        case transfer = 2    // file data chunks
    }

    private struct Job {
        let token: CancelToken?
        /// Cancelled with the task that queued the job.
        let call: CancelToken
        let priority: Priority
        let enqueued = ContinuousClock.now
        let run: (MtpSession?) -> Void // nil session = dropped (cancelled or closed)
    }

    private let condition = NSCondition()
    private var queues: [[Job]] = Array(repeating: [], count: Priority.allCases.count)
    private var session: MtpSession?
    private var closed = false
    private var running: (priority: Priority, since: Date)?
    /// When browsing last asked for something.
    private var lastInteractive: ContinuousClock.Instant?

    /// What the worker is doing now and how much browsing is waiting.
    /// Whether browsing asked for something within `window`: a download then reads in small
    /// chunks, so each of a listing's requests waits as little as possible behind it.
    func browsedRecently(within window: Duration) -> Bool {
        condition.withLock { lastInteractive.map { ContinuousClock.now - $0 < window } ?? false }
    }

    func snapshot() -> (running: (priority: Priority, since: Date)?, queuedInteractive: Int) {
        condition.withLock { (running, queues[Priority.interactive.rawValue].count) }
    }

    init(session: MtpSession) {
        self.session = session
        // The thread keeps the worker alive until close() ends the loop.
        let thread = Thread { self.loop() }
        thread.name = "MTP worker"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// Queues `body`. It's dropped without touching the device if `token` is cancelled, or the
    /// calling task is, before its turn; once it runs it runs to the end (QUIRKS M8).
    func run<T>(_ priority: Priority, token: CancelToken? = nil,
                _ body: @escaping (MtpSession) throws -> T) async throws -> T {
        let call = CancelToken()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UnsafeSendable<T>, Error>) in
                let job = Job(token: token, call: call, priority: priority) { session in
                    guard let session, token?.isCancelled != true, !call.isCancelled else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    continuation.resume(with: Result { UnsafeSendable(value: try body(session)) })
                }
                condition.withLock {
                    if closed {
                        job.run(nil)
                    } else {
                        queues[priority.rawValue].append(job)
                        if priority == .interactive { lastInteractive = .now }
                        condition.signal()
                    }
                }
            }.value
        } onCancel: {
            call.cancel()
        }
    }

    /// Stops after the current job; queued jobs fail with CancellationError.
    func close() {
        let dropped: [Job] = condition.withLock {
            closed = true
            let all = queues.flatMap { $0 }
            queues = Array(repeating: [], count: Priority.allCases.count)
            condition.signal()
            return all
        }
        dropped.forEach { $0.run(nil) }
    }

    private func loop() {
        while true {
            let job: Job? = condition.withLock {
                while !closed && queues.allSatisfy(\.isEmpty) { condition.wait() }
                guard !closed, let index = queues.firstIndex(where: { !$0.isEmpty }) else { return nil }
                let job = queues[index].removeFirst()
                running = (job.priority, Date())
                return job
            }
            guard let job else { break }
            // Browsing that had to queue behind other work is what makes the list feel slow.
            let waited = ContinuousClock.now - job.enqueued
            if job.priority == .interactive, waited > .milliseconds(200) {
                mtpLog.debug("interactive request waited \(waited.formatted(.units(allowed: [.milliseconds])), privacy: .public) in queue")
            }
            let started = ContinuousClock.now
            job.run(job.token?.isCancelled == true || job.call.isCancelled ? nil : session)
            condition.withLock { running = nil }
            let took = ContinuousClock.now - started
            if took > .milliseconds(500) {
                mtpLog.debug("\(String(describing: job.priority), privacy: .public) request took \(took.formatted(.units(allowed: [.milliseconds])), privacy: .public)")
            }
        }
        session?.closeSession()
        session = nil
    }
}

/// Carries a value out of the worker thread; the worker never touches it afterwards.
struct UnsafeSendable<T>: @unchecked Sendable {
    let value: T
}
