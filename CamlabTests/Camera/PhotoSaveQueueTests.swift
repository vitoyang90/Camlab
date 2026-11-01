import Foundation
import Testing
import UIKit
@testable import Camlab

@MainActor struct PhotoSaveQueueTests {
    private final class Gate {
        private var release: CheckedContinuation<Void, Never>?
        private var entered: CheckedContinuation<Void, Never>?
        func hold() async {
            await withCheckedContinuation { continuation in
                release = continuation
                entered?.resume()
                entered = nil
            }
        }
        func waitUntilEntered() async {
            if release != nil { return }
            await withCheckedContinuation { entered = $0 }
        }
        func open() { release?.resume(); release = nil }
    }

    @Test func backgroundExpirationKeepsWaitingPhotosAndForegroundResumesExactlyOnce() async throws {
        var expiration: (@MainActor @Sendable () -> Void)?
        var assertions = 0, ends = 0
        let queue = PhotoSaveQueue { handler in
            PhotoBackgroundTask(name: "test", begin: { _, callback in
                assertions += 1
                expiration = callback
                return UIBackgroundTaskIdentifier(rawValue: assertions)
            }, end: { _ in ends += 1 }, expiration: handler)
        }
        let gate = Gate()
        let finished = AsyncStream<Int>.makeStream()
        var iterator = finished.stream.makeAsyncIterator()
        var order: [Int] = []
        for index in 0..<3 {
            queue.enqueue(id: UUID(), operation: {
                order.append(index)
                if index == 0 { await gate.hold() }
            }, completion: { _ in finished.continuation.yield(index) })
        }
        await gate.waitUntilEntered()
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let model = CameraModel(defaults: defaults, photoSaveQueue: queue)
        model.setSceneActive(false)
        model.deactivate() // Stopping the camera must not discard photo work.
        let oldExpiration = try #require(expiration)
        oldExpiration()
        #expect(ends == 1)
        gate.open()
        #expect(await iterator.next() == 0)
        // Let the worker leave the drain loop after its completion callback.
        await Task.yield()
        #expect(order == [0] && queue.count == 2)
        model.setSceneActive(true)
        oldExpiration() // A late callback must not expire the new assertion.
        #expect(ends == 1 && assertions == 2)
        #expect(await iterator.next() == 1)
        #expect(await iterator.next() == 2)
        await Task.yield()
        #expect(order == [0, 1, 2] && queue.count == 0 && ends == 2)
        finished.continuation.finish()
    }

    @Test func slowSaveAllowsMoreShotsButBoundsTheQueueAndPreservesOrder() async {
        let queue = PhotoSaveQueue()
        let gate = Gate()
        let finished = AsyncStream<Void>.makeStream()
        let ids = (0...queue.capacity).map { _ in UUID() }
        var order: [Int] = []
        let firstAccepted = queue.enqueue(id: ids[0], operation: {
            order.append(0)
            await gate.hold()
        }, completion: { _ in finished.continuation.yield(()) })
        #expect(firstAccepted)
        await gate.waitUntilEntered()
        #expect(queue.hasCapacity) // Photos is still saving the first shot.
        for index in 1..<queue.capacity {
            let accepted = queue.enqueue(id: ids[index], operation: {
                order.append(index)
            }, completion: { _ in finished.continuation.yield(()) })
            #expect(accepted)
        }
        #expect(queue.count == queue.capacity && !queue.hasCapacity)
        #expect(order == [0]) // No concurrent full-resolution renders/saves.
        let overflowAccepted = queue.enqueue(id: ids[queue.capacity], operation: {}, completion: { _ in })
        #expect(!overflowAccepted)
        gate.open()
        var completions = 0
        for await _ in finished.stream {
            completions += 1
            if completions == queue.capacity { break }
        }
        #expect(order == Array(0..<queue.capacity))
        #expect(queue.count == 0 && queue.hasCapacity)
        finished.continuation.finish()
    }

    @Test func failedSaveReleasesItsSlotAndDoesNotDiscardFollowingPhotos() async {
        let queue = PhotoSaveQueue()
        let finished = AsyncStream<Void>.makeStream()
        let failedID = UUID(), nextID = UUID()
        var failures = 0, successes = 0
        queue.enqueue(id: failedID, operation: { throw CameraFailure("Photos denied") }, completion: { result in
            if case .failure = result { failures += 1 }
            #expect(!queue.photoIDs.contains(failedID))
            finished.continuation.yield(())
        })
        let duplicateAccepted = queue.enqueue(id: failedID, operation: {}, completion: { _ in })
        #expect(!duplicateAccepted)
        queue.enqueue(id: nextID, operation: {}, completion: { result in
            if case .success = result { successes += 1 }
            finished.continuation.yield(())
        })
        var completions = 0
        for await _ in finished.stream {
            completions += 1
            if completions == 2 { break }
        }
        #expect(failures == 1 && successes == 1 && queue.count == 0)
        finished.continuation.finish()
    }
}
