import Foundation
import Testing
import UIKit
@testable import Camlab

@MainActor struct PhotoCaptureBufferTests {
    private func shot() -> PhotoCaptureBuffer.Shot {
        .init(previewID: UUID(), burstID: UUID(), style: StyleAdjustment(), nativeWorkflow: false,
              backgroundTask: PhotoBackgroundTask(name: "test", begin: { _, _ in .invalid }, end: { _ in }))
    }

    @Test func responsiveCameraCanAcceptTheNextRequestBeforeExposureFeedback() {
        var buffer = PhotoCaptureBuffer()
        let first = shot(), second = shot()
        buffer.append(first)
        #expect(!buffer.hasRoom(responsive: true, saveSlots: 16))
        buffer.markSubmitted(first.id)
        #expect(buffer.hasRoom(responsive: true, saveSlots: 16))
        #expect(!buffer.hasRoom(responsive: false, saveSlots: 16))
        #expect(buffer.recordExposure(first.id) != nil)
        #expect(buffer.recordExposure(first.id) == nil)
        #expect(buffer.hasRoom(responsive: true, saveSlots: 16))
        #expect(!buffer.hasRoom(responsive: false, saveSlots: 16))
        #expect(!buffer.hasRoom(responsive: true, saveSlots: 1))
        _ = buffer.beginStaging(first.id)
        #expect(buffer.hasRoom(responsive: false, saveSlots: 2))
        buffer.append(second)
        _ = buffer.recordExposure(second.id)
        #expect(!buffer.hasRoom(responsive: true, saveSlots: 16))
    }

    @Test func errorsAndReversedDeliveryDrainInShutterOrder() throws {
        var buffer = PhotoCaptureBuffer()
        let first = shot(), second = shot()
        buffer.append(first)
        buffer.append(second)
        let path = URL(fileURLWithPath: "/unused")
        let staged = SavedPhoto(id: second.id, fileURL: path, originalURL: path, thumbnailURL: path,
                                width: 1, height: 1, styleName: "test", createdAt: second.createdAt)
        #expect(buffer.beginStaging(second.id) != nil)
        let early = buffer.finishStaging(.success(staged), id: second.id)
        #expect(early.isEmpty)
        #expect(buffer.beginStaging(first.id) != nil)
        let ready = buffer.finishStaging(.failure(CameraFailure("interrupted")), id: first.id)
        #expect(ready.map(\.id) == [first.id, second.id])
        #expect(try ready.last?.result?.get().id == second.id)
        let duplicate = buffer.finishStaging(.success(staged), id: second.id)
        #expect(duplicate.isEmpty)
        #expect(!buffer.hasRoom(responsive: true, saveSlots: 0))
        #expect(buffer.hasRoom(responsive: true, saveSlots: 1))
        #expect(buffer.recordExposure(first.id) == nil)
    }
}
