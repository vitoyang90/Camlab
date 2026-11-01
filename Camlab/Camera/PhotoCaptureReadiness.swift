@preconcurrency import AVFoundation
import Foundation
import Observation
import OSLog

/// The shutter follows photo-output readiness, independently of Metal preview
/// rendering. The coordinator delivers readiness changes without a polling delay.
@MainActor @Observable
final class PhotoCaptureReadiness: NSObject, AVCapturePhotoOutputReadinessCoordinatorDelegate {
    private(set) var isReady = false
    private var output: AVCapturePhotoOutput?
    private var coordinator: AVCapturePhotoOutputReadinessCoordinator?
    private var startupID: UUID?
    private var startupBegan: TimeInterval?
    private var reportedID: UUID?
    private let logger = Logger(subsystem: "Camlab", category: "CameraStartup")

    func observe(_ output: AVCapturePhotoOutput, startupID: UUID, began: TimeInterval) {
        self.startupID = startupID
        startupBegan = began
        if self.output !== output {
            coordinator?.delegate = nil
            self.output = output
            let coordinator = AVCapturePhotoOutputReadinessCoordinator(photoOutput: output)
            self.coordinator = coordinator
            coordinator.delegate = self
        }
        updateReadiness()
    }

    nonisolated func readinessCoordinator(
        _ coordinator: AVCapturePhotoOutputReadinessCoordinator,
        captureReadinessDidChange captureReadiness: AVCapturePhotoOutput.CaptureReadiness
    ) {
        Task { @MainActor [weak self] in
            guard let self, self.coordinator === coordinator else { return }
            // Read the latest state rather than replaying an older queued event.
            self.updateReadiness()
        }
    }

    func updateReadiness() {
        isReady = output?.captureReadiness == .ready
        if isReady, let startupID, startupID != reportedID, let startupBegan {
            reportedID = startupID
            logger.info("Camera shutter ready after \(ProcessInfo.processInfo.systemUptime - startupBegan, privacy: .public) seconds")
        }
    }
}
