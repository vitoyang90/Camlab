import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import UIKit

nonisolated struct SavedPhoto: Identifiable, Codable, Sendable {
    let id: UUID
    let fileURL: URL
    let originalURL: URL
    let thumbnailURL: URL
    let width: Int
    let height: Int
    let styleName: String
    let createdAt: Date
    var adjustment: RecipeAdjustment? = nil
    var assetIdentifier: String? = nil
    var nativePhotosWorkflow: Bool? = nil
    var renderStyle: StyleAdjustment? = nil
}

nonisolated struct RenderedPhoto: Sendable {
    let data: Data
    let thumbnail: Data
    let width: Int
    let height: Int
}

nonisolated final class PhotoProcessor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Camlab.photoProcessing", qos: .userInitiated)
    private let stagingQueue = DispatchQueue(label: "Camlab.photoStaging", qos: .userInitiated)
    private let contextLock = NSLock()
    private var renderContext: CIContext?
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let storageDirectory: URL?

    init(storageDirectory: URL? = nil) {
        self.storageDirectory = storageDirectory
    }

    private func context() -> CIContext {
        contextLock.lock()
        defer { contextLock.unlock() }
        if let renderContext { return renderContext }
        // Photo processing is not needed to open the camera or restore its archive.
        let created = CIContext(options: [.cacheIntermediates: false])
        renderContext = created
        return created
    }

    private func archiveDirectory() throws -> URL {
        if let storageDirectory { return storageDirectory }
        return try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                          appropriateFor: nil, create: true).appendingPathComponent("Captures")
    }

    func process(_ original: Data, style: StyleAdjustment, assetIdentifier: String? = nil, nativePhotosWorkflow: Bool = false) async throws -> SavedPhoto {
        let staged = try await stage(original, style: style, assetIdentifier: assetIdentifier, nativePhotosWorkflow: nativePhotosWorkflow)
        return try await processStaged(staged, style: style)
    }

    /// Persist each untouched original as soon as it is delivered. This queue
    /// stays independent of full-resolution rendering and Photos delivery.
    func stage(_ original: Data, style: StyleAdjustment, assetIdentifier: String? = nil, nativePhotosWorkflow: Bool = false, id: UUID = UUID(), createdAt: Date = Date()) async throws -> SavedPhoto {
        try await perform(on: stagingQueue) {
            let root = try self.archiveDirectory()
            let folder = root.appendingPathComponent(id.uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let raw = SavedPhoto(id: id, fileURL: folder.appendingPathComponent("Camlab.jpg"),
                                 originalURL: folder.appendingPathComponent("Original.jpg"),
                                 thumbnailURL: folder.appendingPathComponent("Preview.jpg"),
                                 width: 0, height: 0, styleName: style.name, createdAt: createdAt,
                                 adjustment: style.recipe, assetIdentifier: assetIdentifier, nativePhotosWorkflow: nativePhotosWorkflow,
                                 renderStyle: style)
            // Publish the journal first: any fully written original is then
            // discoverable after termination between these two atomic writes.
            try JSONEncoder().encode(raw).write(to: folder.appendingPathComponent("Capture.json"), options: .atomic)
            try original.write(to: raw.originalURL, options: .atomic)
            return raw
        }
    }

    func processStaged(_ raw: SavedPhoto, style: StyleAdjustment) async throws -> SavedPhoto {
        try await perform {
            try autoreleasepool {
                let original = try Data(contentsOf: raw.originalURL)
                let folder = raw.originalURL.deletingLastPathComponent()
                let root = folder.deletingLastPathComponent()
                let nativePhotosWorkflow = raw.nativePhotosWorkflow == true
                let rendered: RenderedPhoto
                if nativePhotosWorkflow {
                    guard let source = CGImageSourceCreateWithData(original as CFData, nil),
                          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
                          let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
                          let height = properties[kCGImagePropertyPixelHeight as String] as? Int else {
                        throw CameraFailure("無法讀取拍攝原圖。")
                    }
                    rendered = RenderedPhoto(data: original, thumbnail: try Self.thumbnail(data: original), width: width, height: height)
                } else { rendered = try self.render(original, style: style) }
                let photo = SavedPhoto(id: raw.id, fileURL: raw.fileURL, originalURL: raw.originalURL, thumbnailURL: raw.thumbnailURL,
                                       width: rendered.width, height: rendered.height, styleName: raw.styleName, createdAt: raw.createdAt,
                                       adjustment: raw.adjustment, assetIdentifier: raw.assetIdentifier, nativePhotosWorkflow: raw.nativePhotosWorkflow,
                                       renderStyle: style)
                try rendered.data.write(to: photo.fileURL, options: .atomic)
                try rendered.thumbnail.write(to: photo.thumbnailURL, options: .atomic)
                try JSONEncoder().encode(photo).write(to: folder.appendingPathComponent("Capture.json"), options: .atomic)
                try JSONEncoder().encode(photo).write(to: root.appendingPathComponent("Latest.json"), options: .atomic)
                return photo
            }
        }
    }

    func thumbnail(for photo: SavedPhoto) async -> UIImage? {
        // Decode once at the size of the 48-point library button, off the main actor.
        try? await perform {
            guard let source = CGImageSourceCreateWithURL(photo.thumbnailURL as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: 144
                  ] as CFDictionary) else { return nil }
            return UIImage(cgImage: image)
        }
    }

    func prepareForSaving(_ photo: SavedPhoto) async throws -> SavedPhoto {
        guard let current = await pending().first(where: { $0.id == photo.id }) else {
            throw CameraFailure("找不到待儲存原圖，請重新開啟照片確認。")
        }
        let hasRenderedFile = try await perform {
            current.width > 0 && current.height > 0 && FileManager.default.fileExists(atPath: current.fileURL.path)
        }
        if hasRenderedFile { return current }
        let style: StyleAdjustment
        if let stored = current.renderStyle { style = stored }
        else if let recipe = current.adjustment { style = StyleAdjustment(recipe: recipe, recipeName: current.styleName) }
        else if let preset = PhotoStyle(rawValue: current.styleName) { style = preset.adjustment }
        else { throw CameraFailure("這張舊照片缺少完整調色紀錄，原圖已保留，請開啟照片確認後儲存。") }
        return try await processStaged(current, style: style)
    }

    func latest() async -> SavedPhoto? {
        try? await perform {
            let root = try self.archiveDirectory()
            let stored = try JSONDecoder().decode(SavedPhoto.self, from: Data(contentsOf: root.appendingPathComponent("Latest.json")))
            // App container URLs can change after a reinstall or restoration.
            let folder = root.appendingPathComponent(stored.id.uuidString)
            let photo = SavedPhoto(id: stored.id, fileURL: folder.appendingPathComponent("Camlab.jpg"),
                                   originalURL: folder.appendingPathComponent("Original.jpg"),
                                   thumbnailURL: folder.appendingPathComponent("Preview.jpg"),
                                   width: stored.width, height: stored.height, styleName: stored.styleName, createdAt: stored.createdAt,
                                   adjustment: stored.adjustment, assetIdentifier: stored.assetIdentifier, nativePhotosWorkflow: stored.nativePhotosWorkflow, renderStyle: stored.renderStyle)
            guard FileManager.default.fileExists(atPath: photo.fileURL.path) else {
                throw CameraFailure("找不到上次拍攝的照片。")
            }
            return photo
        }
    }

    func revise(_ photo: SavedPhoto, style: StyleAdjustment) async throws -> SavedPhoto {
        guard photo.nativePhotosWorkflow != true else { throw CameraFailure("這張原圖請使用原生照片流程儲存。") }
        return try await perform {
            if var journal = try PhotoLibraryJournal.read(for: photo), journal.phase == .finished {
                journal.phase = .created
                try journal.write(for: photo)
            }
            let original = try Data(contentsOf: photo.originalURL)
            let rendered = try self.render(original, style: style)
            let updated = SavedPhoto(id: photo.id, fileURL: photo.fileURL, originalURL: photo.originalURL,
                                     thumbnailURL: photo.thumbnailURL, width: rendered.width, height: rendered.height,
                                     styleName: style.name, createdAt: photo.createdAt, adjustment: style.recipe,
                                     assetIdentifier: photo.assetIdentifier, renderStyle: style)
            try rendered.data.write(to: photo.fileURL, options: .atomic)
            try rendered.thumbnail.write(to: photo.thumbnailURL, options: .atomic)
            let metadata = try JSONEncoder().encode(updated)
            try metadata.write(to: photo.originalURL.deletingLastPathComponent().appendingPathComponent("Capture.json"), options: .atomic)
            try metadata.write(to: self.archiveDirectory().appendingPathComponent("Latest.json"), options: .atomic)
            return updated
        }
    }

    func recordAsset(_ photo: SavedPhoto, identifier: String) async throws -> SavedPhoto {
        try await perform {
            var updated = photo
            updated.assetIdentifier = identifier
            let data = try JSONEncoder().encode(updated)
            try data.write(to: photo.originalURL.deletingLastPathComponent().appendingPathComponent("Capture.json"), options: .atomic)
            try data.write(to: self.archiveDirectory().appendingPathComponent("Latest.json"), options: .atomic)
            return updated
        }
    }

    func pending() async -> [SavedPhoto] {
        (try? await perform {
            let root = try self.archiveDirectory()
            let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            return folders.compactMap { folder -> SavedPhoto? in
                guard UUID(uuidString: folder.lastPathComponent) != nil,
                      FileManager.default.fileExists(atPath: folder.appendingPathComponent("Original.jpg").path),
                      let data = try? Data(contentsOf: folder.appendingPathComponent("Capture.json")),
                      let photo = try? JSONDecoder().decode(SavedPhoto.self, from: data) else { return nil }
                return SavedPhoto(id: photo.id, fileURL: folder.appendingPathComponent("Camlab.jpg"),
                                  originalURL: folder.appendingPathComponent("Original.jpg"), thumbnailURL: folder.appendingPathComponent("Preview.jpg"),
                                  width: photo.width, height: photo.height, styleName: photo.styleName, createdAt: photo.createdAt,
                                  adjustment: photo.adjustment, assetIdentifier: photo.assetIdentifier, nativePhotosWorkflow: photo.nativePhotosWorkflow, renderStyle: photo.renderStyle)
            }.sorted { $0.createdAt > $1.createdAt }
        }) ?? []
    }

    /// Call only after Photos confirms both the original and rendered edit.
    func complete(_ photo: SavedPhoto) async throws {
        try await removeLocalCopy(photo)
    }

    func removeLocalCopy(_ photo: SavedPhoto) async throws {
        try await perform {
            let root = try self.archiveDirectory()
            let folder = root.appendingPathComponent(photo.id.uuidString, isDirectory: true)
            if FileManager.default.fileExists(atPath: folder.path) {
                // Withdraw the entire job from recovery before removing its files.
                let trash = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.moveItem(at: folder, to: trash)
                try? FileManager.default.removeItem(at: trash)
            }
            let latest = root.appendingPathComponent("Latest.json")
            if let data = try? Data(contentsOf: latest),
               let stored = try? JSONDecoder().decode(SavedPhoto.self, from: data), stored.id == photo.id {
                try FileManager.default.removeItem(at: latest)
            }
            UserDefaults.standard.removeObject(forKey: "Camlab.PendingAsset.\(photo.id.uuidString)")
        }
    }

    /// Normalize EXIF orientation, preserve full pixel dimensions and useful metadata.
    func render(_ data: Data, style: StyleAdjustment) throws -> RenderedPhoto {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let input = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            throw CameraFailure("無法讀取照片，請重新拍攝。")
        }
        let normalized = input.transformed(by: CGAffineTransform(translationX: -input.extent.minX, y: -input.extent.minY))
        let styled = style.applying(to: normalized)
        guard let image = context().createCGImage(styled, from: normalized.extent, format: .RGBA8, colorSpace: colorSpace) else {
            throw CameraFailure("照片處理失敗，請重新拍攝。")
        }
        var metadata = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]) ?? [:]
        metadata[kCGImagePropertyOrientation as String] = 1
        metadata[kCGImagePropertyPixelWidth as String] = image.width
        metadata[kCGImagePropertyPixelHeight as String] = image.height
        metadata.removeValue(forKey: kCGImagePropertyProfileName as String)
        var exif = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        exif[kCGImagePropertyExifPixelXDimension as String] = image.width
        exif[kCGImagePropertyExifPixelYDimension as String] = image.height
        metadata[kCGImagePropertyExifDictionary as String] = exif
        var tiff = metadata[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        tiff[kCGImagePropertyTIFFOrientation as String] = 1
        tiff[kCGImagePropertyTIFFSoftware as String] = "Camlab"
        metadata[kCGImagePropertyTIFFDictionary as String] = tiff
        let encoded = try Self.encode(image, quality: 0.96, metadata: metadata)
        let thumb = try Self.thumbnail(data: encoded)
        return RenderedPhoto(data: encoded, thumbnail: thumb, width: image.width, height: image.height)
    }

    static func thumbnail(data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1200
              ] as CFDictionary) else { throw CameraFailure("無法顯示照片預覽。") }
        return try encode(image, quality: 0.88, metadata: [:])
    }

    private static func encode(_ image: CGImage, quality: Double, metadata: [String: Any]) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CameraFailure("無法建立照片檔案。")
        }
        var properties = metadata
        properties[kCGImageDestinationLossyCompressionQuality as String] = quality
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CameraFailure("照片編碼失敗。") }
        return data as Data
    }

    private func perform<T: Sendable>(on target: DispatchQueue? = nil, _ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            (target ?? queue).async { continuation.resume(with: Result { try operation() }) }
        }
    }
}
