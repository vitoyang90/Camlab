@preconcurrency import AVFoundation
import Foundation

/// A capture owns this delegate until didFinishCapture, including error paths.
nonisolated final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var processingError: Error?
    private var completed = false
    private var completion: (@Sendable (Result<Data, Error>) -> Void)?
    private var captureFinished: (@Sendable () -> Void)?
    private var didCapture: (@Sendable () -> Void)?

    init(didCapture: @escaping @Sendable () -> Void = {}, completion: @escaping @Sendable (Result<Data, Error>) -> Void,
         captureFinished: @escaping @Sendable () -> Void) {
        self.completion = completion
        self.captureFinished = captureFinished
        self.didCapture = didCapture
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        reportCapture()
    }

    func reportCapture() {
        lock.lock()
        let feedback = completed ? nil : didCapture
        didCapture = nil
        lock.unlock()
        feedback?()
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        didProcessPhoto(data: error == nil ? photo.fileDataRepresentation() : nil, error: error)
    }

    func didProcessPhoto(data: Data?, error: Error?) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        self.data = data
        processingError = error
        lock.unlock()
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        didFinishCapture(error: error)
    }

    func didFinishCapture(error: Error?) {
        lock.lock()
        let captureFinished = self.captureFinished
        self.captureFinished = nil
        let result: Result<Data, Error>
        // This delegate requests a single JPEG. Preserve a successfully delivered
        // image even if stopping the session makes the final callback fail.
        if let processingError { result = .failure(processingError) }
        else if let data { result = .success(data) }
        else if let error { result = .failure(error) }
        else { result = .failure(CameraFailure("相機未回傳照片，請重新拍攝。")) }
        let completion = takeCompletionLocked()
        lock.unlock()
        captureFinished?()
        completion?(result)
    }

    func finish(_ result: Result<Data, Error>) {
        lock.lock()
        let completion = takeCompletionLocked()
        lock.unlock()
        completion?(result)
    }

    private func takeCompletionLocked() -> (@Sendable (Result<Data, Error>) -> Void)? {
        guard !completed else { return nil }
        completed = true
        let callback = completion
        completion = nil
        data = nil
        processingError = nil
        return callback
    }
}
