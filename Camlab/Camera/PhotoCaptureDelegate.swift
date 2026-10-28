@preconcurrency import AVFoundation
import Foundation

/// A capture owns this delegate until didFinishCapture, including error paths.
nonisolated final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var processingError: Error?
    private var completed = false
    private let completion: @Sendable (Result<Data, Error>) -> Void

    init(completion: @escaping @Sendable (Result<Data, Error>) -> Void) {
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        lock.lock()
        data = photo.fileDataRepresentation()
        processingError = error
        lock.unlock()
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        lock.lock()
        let result: Result<Data, Error>
        if let error = error ?? processingError { result = .failure(error) }
        else if let data { result = .success(data) }
        else { result = .failure(CameraFailure("相機未回傳照片，請重新拍攝。")) }
        lock.unlock()
        finish(result)
    }

    func finish(_ result: Result<Data, Error>) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        lock.unlock()
        completion(result)
    }
}
