import Foundation
import Observation

/// Keeps only file-backed jobs. One full-resolution render/save runs at a time.
@MainActor @Observable
final class PhotoSaveQueue {
    // Waiting jobs retain file URLs. Only the running job decodes a full-size image.
    let capacity = 16
    private(set) var photoIDs: Set<UUID> = []
    var count: Int { photoIDs.count }
    var hasCapacity: Bool { count < capacity }
    private struct Job {
        let id: UUID
        let operation: @MainActor () async throws -> Void
        let completion: @MainActor (Result<Void, Error>) async -> Void
    }
    private var jobs: [Job] = []
    private var running = false
    private var foreground = true
    private var backgroundExpired = false
    private var backgroundTask: PhotoBackgroundTask?
    private let makeBackgroundTask: @MainActor (@escaping @MainActor () -> Void) -> PhotoBackgroundTask

    init(makeBackgroundTask: @escaping @MainActor (@escaping @MainActor () -> Void) -> PhotoBackgroundTask = {
        PhotoBackgroundTask(name: "Save captured photos", expiration: $0)
    }) {
        self.makeBackgroundTask = makeBackgroundTask
    }

    func setForeground(_ value: Bool) {
        foreground = value
        if value {
            backgroundExpired = false
            if running, backgroundTask == nil { beginBackgroundTask() }
            startIfNeeded()
        }
    }

    private func beginBackgroundTask() {
        backgroundExpired = false
        let task = makeBackgroundTask { [weak self] in
            self?.backgroundExpired = true
            self?.backgroundTask = nil
        }
        if !backgroundExpired { backgroundTask = task }
    }

    private func startIfNeeded() {
        guard !running, !jobs.isEmpty, foreground || !backgroundExpired else { return }
        running = true
        beginBackgroundTask()
        Task { await drain() }
    }

    @discardableResult
    func enqueue(id: UUID, operation: @escaping @MainActor () async throws -> Void,
                 completion: @escaping @MainActor (Result<Void, Error>) async -> Void) -> Bool {
        guard hasCapacity, !photoIDs.contains(id) else { return false }
        photoIDs.insert(id)
        jobs.append(Job(id: id, operation: operation, completion: completion))
        startIfNeeded()
        return true
    }

    private func drain() async {
        while !jobs.isEmpty, foreground || !backgroundExpired {
            let job = jobs.removeFirst()
            let result: Result<Void, Error>
            do { try await job.operation(); result = .success(()) }
            catch { result = .failure(error) }
            photoIDs.remove(job.id)
            await job.completion(result)
        }
        running = false
        backgroundTask?.finish()
        backgroundTask = nil
    }
}
