import Foundation
import Testing
import UIKit
@testable import Camlab

@MainActor struct PhotoRecoveryTests {
    private final class Permission { var granted = false }
    private func original() -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 32, height: 24), format: format).pngData {
            UIColor.orange.setFill(); $0.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        }
    }

    @Test func relaunchDrainsMoreThanOneFullQueueWithoutDuplicateJobs() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let processor = PhotoProcessor(storageDirectory: folder)
        let queue = PhotoSaveQueue()
        let total = queue.capacity + 2
        var ids: Set<UUID> = []
        var style = PhotoStyle.film.adjustment
        style.intensity = 0.37
        for _ in 0..<total { ids.insert(try await processor.stage(original(), style: style).id) }
        let restored = PhotoProcessor(storageDirectory: folder)
        let delivered = AsyncStream<UUID>.makeStream()
        var saved: [UUID] = []
        let model = CameraModel(defaults: try #require(UserDefaults(suiteName: UUID().uuidString)),
            photoSaveQueue: queue, photoProcessor: restored, savePhoto: { photo, _ in
                #expect(photo.renderStyle == style)
                #expect(photo.width == 32 && photo.height == 24)
                saved.append(photo.id)
                delivered.continuation.yield(photo.id)
                return photo
            }, canRecoverPhotos: { true })
        model.setSceneActive(true)
        await model.restoreLastPhoto()
        await model.restoreLastPhoto() // Duplicate startup/editor callbacks.
        var count = 0
        for await _ in delivered.stream {
            count += 1
            if count == total { break }
        }
        for _ in 0..<100 {
            if await restored.pending().isEmpty { break }
            await Task.yield()
        }
        #expect(Set(saved) == ids && saved.count == total)
        #expect(await restored.pending().isEmpty)
        delivered.continuation.finish()
    }

    @Test func discardingPendingPhotoWithdrawsOnlyThatJobFromRelaunchRecovery() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let processor = PhotoProcessor(storageDirectory: folder)
        let keep = try await processor.stage(original(), style: StyleAdjustment())
        let discard = try await processor.process(original(), style: StyleAdjustment())
        let model = CameraModel(photoProcessor: processor, canRecoverPhotos: { false })
        await model.restoreLastPhoto()
        try await model.deletePhoto(.pending(discard))
        let reopened = PhotoProcessor(storageDirectory: folder)
        #expect(await reopened.pending().map(\.id) == [keep.id])
        #expect(!FileManager.default.fileExists(atPath: discard.originalURL.path))
        #expect(await reopened.latest() == nil)
    }

    @Test func deniedPermissionAndFailedRecoveryKeepOriginalsWithoutRetryLoop() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let processor = PhotoProcessor(storageDirectory: folder)
        let photo = try await processor.stage(original(), style: StyleAdjustment())
        let permission = Permission()
        var attempts = 0
        let attempted = AsyncStream<Void>.makeStream()
        var iterator = attempted.stream.makeAsyncIterator()
        let model = CameraModel(defaults: try #require(UserDefaults(suiteName: UUID().uuidString)),
            photoProcessor: processor, savePhoto: { _, _ in
                attempts += 1
                attempted.continuation.yield(())
                throw CameraFailure("storage unavailable")
            }, canRecoverPhotos: { permission.granted })
        model.setSceneActive(true)
        await model.restoreLastPhoto()
        await model.restoreLastPhoto() // Wait past the concurrent scene-triggered scan.
        #expect(attempts == 0 && model.pendingPhotos.count == 1)
        permission.granted = true
        model.setSceneActive(true)
        _ = await iterator.next()
        for _ in 0..<5 { await model.restoreLastPhoto() }
        #expect(attempts == 1)
        #expect(await processor.pending().map(\.id) == [photo.id])
        #expect(FileManager.default.fileExists(atPath: photo.originalURL.path))
        attempted.continuation.finish()
    }

    @Test func journalSurvivesFreshProcessorAndCorruptionNeverMeansCreateAgain() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let processor = PhotoProcessor(storageDirectory: folder)
        let photo = try await processor.stage(original(), style: PhotoStyle.film.adjustment)
        try PhotoLibraryJournal(phase: .creating, assetIdentifier: "already-created").write(for: photo)
        let recovered = try #require(await PhotoProcessor(storageDirectory: folder).pending().first)
        #expect(try PhotoLibraryJournal.read(for: recovered)?.assetIdentifier == "already-created")
        let ready = try await processor.prepareForSaving(recovered)
        #expect(ready.renderStyle == PhotoStyle.film.adjustment)
        #expect(try PhotoLibraryJournal.read(for: ready)?.phase == .creating)
        try Data("invalid".utf8).write(to: PhotoLibraryJournal.url(for: photo), options: .atomic)
        #expect(throws: DecodingError.self) { try PhotoLibraryJournal.read(for: photo) }
    }
}
