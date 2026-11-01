import Foundation

/// Reserve downstream space before exposure. Only two requests may hold a
/// full-resolution JPEG, and completed originals leave in shutter order.
struct PhotoCaptureBuffer {
    struct Shot {
        let id = UUID()
        let createdAt = Date()
        let previewID: UUID
        let burstID: UUID?
        let style: StyleAdjustment
        let nativeWorkflow: Bool
        let backgroundTask: PhotoBackgroundTask
        fileprivate(set) var submitted = false
        fileprivate(set) var exposed = false
        fileprivate(set) var staging = false
        fileprivate(set) var result: Result<SavedPhoto, Error>?
    }

    private(set) var shots: [Shot] = []
    var isEmpty: Bool { shots.isEmpty }

    func hasRoom(responsive: Bool, saveSlots: Int) -> Bool {
        guard shots.count < 2, shots.count < saveSlots else { return false }
        return shots.allSatisfy { $0.staging || (responsive && $0.submitted) }
    }

    mutating func append(_ shot: Shot) { shots.append(shot) }

    mutating func markSubmitted(_ id: UUID) {
        guard let index = shots.firstIndex(where: { $0.id == id }) else { return }
        shots[index].submitted = true
    }

    mutating func recordExposure(_ id: UUID) -> Shot? {
        guard let index = shots.firstIndex(where: { $0.id == id }), !shots[index].exposed else { return nil }
        shots[index].exposed = true
        return shots[index]
    }

    mutating func beginStaging(_ id: UUID) -> Shot? {
        guard let index = shots.firstIndex(where: { $0.id == id }), !shots[index].staging else { return nil }
        shots[index].staging = true
        return shots[index]
    }

    /// Persist each original as soon as it arrives, even if an older request
    /// is stalled. Hand the save worker only the contiguous, file-backed prefix.
    mutating func finishStaging(_ result: Result<SavedPhoto, Error>, id: UUID) -> [Shot] {
        guard let index = shots.firstIndex(where: { $0.id == id }), shots[index].staging,
              shots[index].result == nil else { return [] }
        shots[index].result = result
        let ready = Array(shots.prefix { $0.result != nil })
        shots.removeFirst(ready.count)
        return ready
    }

    func contains(_ id: UUID) -> Bool { shots.contains { $0.id == id } }
}
