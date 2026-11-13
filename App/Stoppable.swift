import Foundation
import os

/// Runs file-system work on this Mac (walking folders, comparing, zipping) off the main actor.
/// Cancelling the calling task (a job paused, a dialog closed or its inputs changed) is passed
/// on through `stop`, which the work checks as it goes: a detached task isn't cancelled with
/// the one that waits on it.
func stoppable<T: Sendable>(_ work: @escaping @Sendable (_ stop: () -> Bool) throws -> T) async throws -> T {
    let stopped = OSAllocatedUnfairLock(initialState: false)
    return try await withTaskCancellationHandler {
        try await Task.detached(priority: .userInitiated) { try work { stopped.withLock { $0 } } }.value
    } onCancel: {
        stopped.withLock { $0 = true }
    }
}
