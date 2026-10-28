import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The current representation supplied by Photos. Export must not render it.
nonisolated struct NativePhotoContent: Sendable {
    let data: Data
    let fileExtension: String

    init(data: Data) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let identifier = CGImageSourceGetType(source),
              let type = UTType(identifier as String), type.conforms(to: .image),
              let suffix = type.preferredFilenameExtension else {
            throw CameraFailure("無法讀取相簿影像，請重新選擇照片。")
        }
        self.data = data
        fileExtension = suffix
    }

    func writeShareCopy(in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Photos-\(UUID().uuidString).\(fileExtension)")
        try data.write(to: url, options: .atomic)
        return url
    }
}
