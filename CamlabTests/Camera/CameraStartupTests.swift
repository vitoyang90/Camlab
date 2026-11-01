import Foundation
import Testing
@testable import Camlab

struct CameraStartupTests {
    @Test func obsoleteStartsCannotReopenCameraAfterRapidVisibilityChanges() async {
        let service = CameraService()
        let first = UUID(), second = UUID()
        service.setVisibility(first)
        service.setVisibility(nil)
        service.setVisibility(second)
        await #expect(throws: CancellationError.self) { try await service.start(visibilityID: first) }
        service.setVisibility(nil)
        await #expect(throws: CancellationError.self) { try await service.start(visibilityID: second) }
    }

    @Test func firstFrameTimeoutStartsFreshAfterInterruptionOrNewPreview() {
        let first = UUID(), second = UUID()
        var wait = FirstFrameWait()
        let firstWindow = [wait.expired(for: first, now: 1), wait.expired(for: first, now: 6)]
        #expect(firstWindow == [false, true])
        wait.reset()
        let nextWindow = [wait.expired(for: first, now: 100), wait.expired(for: second, now: 110),
                          wait.expired(for: second, now: 114), wait.expired(for: second, now: 115)]
        #expect(nextWindow == [false, false, false, true])
    }
    private enum Failure: Error { case temporary }
    private actor Attempts {
        var count = 0
        func next() -> Int { count += 1; return count }
    }

    @Test func successfulStartupDoesNotStartTheSessionTwice() async throws {
        let attempts = Attempts()
        let result = try await CameraStartupRetry.run(delay: .zero) { await attempts.next() }
        #expect(result == 1)
        #expect(await attempts.count == 1)
    }

    @Test func transientFailureRecoversWithoutUserAction() async throws {
        let attempts = Attempts()
        let result = try await CameraStartupRetry.run(delay: .zero) {
            let attempt = await attempts.next()
            if attempt == 1 { throw Failure.temporary }
            return attempt
        }
        #expect(result == 2)
    }

    @Test func persistentFailureStopsAfterOneRetry() async {
        let attempts = Attempts()
        do {
            let _: Int = try await CameraStartupRetry.run(delay: .zero) {
                _ = await attempts.next()
                throw Failure.temporary
            }
            Issue.record("Persistent startup failure should reach the UI")
        } catch { #expect(error is Failure) }
        #expect(await attempts.count == 2)
    }

    @Test func obsoleteStartupDoesNotRetry() async {
        let attempts = Attempts()
        do {
            let _: Int = try await CameraStartupRetry.run(delay: .zero) {
                _ = await attempts.next()
                throw CancellationError()
            }
            Issue.record("An obsolete startup must remain cancelled")
        } catch { #expect(error is CancellationError) }
        #expect(await attempts.count == 1)
    }

    @Test func leavingDuringBackoffCancelsThePendingRetry() async {
        let attempts = Attempts()
        let task = Task {
            try await CameraStartupRetry.run(delay: .seconds(30)) { () async throws -> Int in
                _ = await attempts.next()
                throw Failure.temporary
            }
        }
        while await attempts.count == 0 { await Task.yield() }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Leaving the camera must cancel its retry")
        } catch { #expect(error is CancellationError) }
        #expect(await attempts.count == 1)
    }

    @Test func waitingForPreviewNeverAsksTheUserToReconnect() {
        for state: CameraStartupState in [.starting, .waitingForPreview, .ready, .interrupted,
                                         .paused, .permissionRequired, .unavailable] {
            #expect(!state.canRetry)
        }
        #expect(CameraStartupState.failed.canRetry)
    }
}
