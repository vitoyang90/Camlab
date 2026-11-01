import Foundation
import Synchronization
import Testing
@testable import Camlab

struct PhotoCaptureDelegateTests {
    @Test func shutterFeedbackFiresOnceForACaptureAndIgnoresLateCallbacks() {
        let events = Mutex(0)
        let captured = PhotoCaptureDelegate(didCapture: { events.withLock { $0 += 1 } },
                                            completion: { _ in }, captureFinished: {})
        captured.reportCapture()
        captured.reportCapture()
        let timedOut = PhotoCaptureDelegate(didCapture: { events.withLock { $0 += 1 } },
                                            completion: { _ in }, captureFinished: {})
        timedOut.finish(.failure(Failure.timeout))
        timedOut.reportCapture()
        #expect(events.withLock { $0 } == 1)
    }

    private enum Failure: Error { case timeout, system }

    @Test func stoppingAfterJPEGDeliveryPreservesTheDeliveredPhoto() {
        let original = Data([1, 2, 3])
        let responses = Mutex(0)
        let delegate = PhotoCaptureDelegate(completion: { result in
            #expect((try? result.get()) == original)
            responses.withLock { $0 += 1 }
        }, captureFinished: {})
        delegate.didProcessPhoto(data: original, error: nil)
        delegate.didFinishCapture(error: Failure.system)
        delegate.didFinishCapture(error: nil)
        #expect(responses.withLock { $0 } == 1)
    }

    @Test func interruptedCaptureWithoutAValidPhotoReportsFailure() {
        let failures = Mutex(0)
        for processingFailed in [false, true] {
            let delegate = PhotoCaptureDelegate(completion: { result in
                if case .failure = result { failures.withLock { $0 += 1 } }
            }, captureFinished: {})
            if processingFailed { delegate.didProcessPhoto(data: Data([1]), error: Failure.system) }
            delegate.didFinishCapture(error: Failure.system)
        }
        #expect(failures.withLock { $0 } == 2)
    }

    @Test func timeoutDoesNotReleaseCaptureBeforeTheSystemFinishes() {
        let counts = Mutex((responses: 0, finished: 0))
        let delegate = PhotoCaptureDelegate(completion: { result in
            #expect(throws: Failure.self) { try result.get() }
            counts.withLock { $0.responses += 1 }
        }, captureFinished: { counts.withLock { $0.finished += 1 } })

        delegate.finish(.failure(Failure.timeout))
        #expect(counts.withLock { $0.responses == 1 && $0.finished == 0 })
        delegate.didFinishCapture(error: Failure.system)
        delegate.didFinishCapture(error: nil)
        #expect(counts.withLock { $0.responses == 1 && $0.finished == 1 })
    }

    @Test func systemCompletionAndTimeoutRacingRespondOnlyOnce() {
        let counts = Mutex((responses: 0, finished: 0))
        let delegate = PhotoCaptureDelegate(completion: { _ in
            counts.withLock { $0.responses += 1 }
        }, captureFinished: { counts.withLock { $0.finished += 1 } })

        DispatchQueue.concurrentPerform(iterations: 100) { index in
            if index.isMultiple(of: 2) { delegate.finish(.failure(Failure.timeout)) }
            else { delegate.didFinishCapture(error: Failure.system) }
        }
        #expect(counts.withLock { $0.responses == 1 && $0.finished == 1 })
    }

    @Test func completedCaptureIgnoresLateTimeout() {
        let responses = Mutex(0)
        let delegate = PhotoCaptureDelegate(completion: { result in
            #expect((try? result.get()) == Data([1, 2, 3]))
            responses.withLock { $0 += 1 }
        }, captureFinished: {})
        delegate.finish(.success(Data([1, 2, 3])))
        delegate.finish(.failure(Failure.timeout))
        delegate.didFinishCapture(error: nil)
        #expect(responses.withLock { $0 } == 1)
    }
}
