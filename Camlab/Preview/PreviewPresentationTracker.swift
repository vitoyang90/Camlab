import Foundation

/// A resized or dropped first drawable may never be presented. Observe later
/// frames until one really reaches the screen; reject callbacks from old runs.
nonisolated final class PreviewPresentationTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var startupID: UUID?
    private var reported = false

    func begin(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard startupID != id else { return }
        startupID = id
        reported = false
    }

    func shouldObserve(_ id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return startupID == id && !reported
    }

    func record(_ id: UUID, presentedTime: TimeInterval) -> Bool {
        guard presentedTime.isFinite, presentedTime > 0 else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard startupID == id, !reported else { return false }
        reported = true
        return true
    }
}
