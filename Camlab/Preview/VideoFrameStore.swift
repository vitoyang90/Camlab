@preconcurrency import AVFoundation
import CoreImage
import Foundation
import OSLog

/// Keeps only the newest frame. The capture queue never waits for the UI or GPU.
nonisolated final class VideoFrameStore: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: CVPixelBuffer?
    private var previewBegan: TimeInterval?
    private let logger = Logger(subsystem: "Camlab", category: "CameraStartup")

    func beginPreview(at began: TimeInterval) {
        lock.lock()
        buffer = nil
        previewBegan = began
        lock.unlock()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let receivedAt = ProcessInfo.processInfo.systemUptime
        lock.lock()
        self.buffer = buffer
        let began = previewBegan
        previewBegan = nil
        lock.unlock()
        if let began {
            logger.info("Camera first frame received after \(receivedAt - began, privacy: .public) seconds; dimensions \(CVPixelBufferGetWidth(buffer), privacy: .public)x\(CVPixelBufferGetHeight(buffer), privacy: .public)")
        }
    }

    func image() -> CIImage? {
        lock.lock()
        let latest = buffer
        lock.unlock()
        return latest.map { CIImage(cvPixelBuffer: $0) }
    }

    func clear() {
        lock.lock()
        buffer = nil
        previewBegan = nil
        lock.unlock()
    }
}
