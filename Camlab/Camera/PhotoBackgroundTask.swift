import UIKit

/// A finite UIKit assertion, ended exactly once on completion or expiration.
@MainActor final class PhotoBackgroundTask {
    typealias Begin = @MainActor (String, @escaping @MainActor @Sendable () -> Void) -> UIBackgroundTaskIdentifier
    private var identifier = UIBackgroundTaskIdentifier.invalid
    private var ended = false
    private let end: @MainActor (UIBackgroundTaskIdentifier) -> Void

    init(name: String,
         begin: Begin = { UIApplication.shared.beginBackgroundTask(withName: $0, expirationHandler: $1) },
         end: @escaping @MainActor (UIBackgroundTaskIdentifier) -> Void = { UIApplication.shared.endBackgroundTask($0) },
         expiration: @escaping @MainActor () -> Void = {}) {
        self.end = end
        let identifier = begin(name) { [weak self] in
            guard let self, !self.ended else { return }
            self.finish()
            expiration()
        }
        if ended {
            if identifier != .invalid { end(identifier) }
        } else if identifier == .invalid {
            ended = true
            expiration()
        } else { self.identifier = identifier }
    }

    func finish() {
        guard !ended else { return }
        ended = true
        let identifier = identifier
        self.identifier = .invalid
        if identifier != .invalid { end(identifier) }
    }
}
