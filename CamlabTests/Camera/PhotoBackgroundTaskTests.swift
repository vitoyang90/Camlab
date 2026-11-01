import Testing
import UIKit
@testable import Camlab

@MainActor struct PhotoBackgroundTaskTests {
    @Test func expirationAndCompletionEndTheAssertionOnlyOnce() throws {
        var callback: (@MainActor @Sendable () -> Void)?
        var ends = 0, expirations = 0
        let task = PhotoBackgroundTask(name: "test", begin: { _, expiration in
            callback = expiration
            return UIBackgroundTaskIdentifier(rawValue: 10)
        }, end: { _ in ends += 1 }, expiration: { expirations += 1 })
        let expire = try #require(callback)
        expire(); task.finish(); expire()
        #expect(ends == 1 && expirations == 1)
    }

    @Test func completionIgnoresLateExpiration() throws {
        var callback: (@MainActor @Sendable () -> Void)?
        var ends = 0, expirations = 0
        let task = PhotoBackgroundTask(name: "test", begin: { _, expiration in
            callback = expiration
            return UIBackgroundTaskIdentifier(rawValue: 11)
        }, end: { _ in ends += 1 }, expiration: { expirations += 1 })
        task.finish()
        let expire = try #require(callback)
        expire()
        #expect(ends == 1 && expirations == 0)
    }

    @Test func deniedOrImmediatelyExpiredAssertionsDoNotLeak() {
        var ends = 0, expirations = 0
        let denied = PhotoBackgroundTask(name: "denied", begin: { _, _ in .invalid },
            end: { _ in ends += 1 }, expiration: { expirations += 1 })
        denied.finish()
        #expect(ends == 0 && expirations == 1)
        let expired = PhotoBackgroundTask(name: "expired", begin: { _, expiration in
            expiration()
            return UIBackgroundTaskIdentifier(rawValue: 12)
        }, end: { _ in ends += 1 }, expiration: { expirations += 1 })
        expired.finish()
        #expect(ends == 1 && expirations == 2)
    }
}
