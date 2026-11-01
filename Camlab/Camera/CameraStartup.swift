import Foundation

/// Count only time spent waiting for the same, uninterrupted preview.
nonisolated struct FirstFrameWait {
    private var previewID: UUID?
    private var began = 0.0

    mutating func reset() { previewID = nil }

    mutating func expired(for id: UUID, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        if id != previewID {
            previewID = id
            began = now
        }
        return now - began >= 5
    }
}

nonisolated enum CameraStartupState {
    case starting, waitingForPreview, ready, interrupted, paused
    case permissionRequired, unavailable, failed

    var canRetry: Bool { self == .failed }
}

/// Retry a transient startup failure once, without making the user start the
/// camera manually. Cancellation must never turn into another startup request.
nonisolated enum CameraStartupRetry {
    static func run<T: Sendable>(
        delay: Duration = .milliseconds(350),
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        do { return try await operation() }
        catch is CancellationError { throw CancellationError() }
        catch {
            try await Task.sleep(for: delay)
            try Task.checkCancellation()
            return try await operation()
        }
    }
}
