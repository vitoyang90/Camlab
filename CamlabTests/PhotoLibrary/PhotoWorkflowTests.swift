import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Camlab

struct PhotoWorkflowTests {
    @Test func zeroIntensityPreservesOriginalPixels() {
        let source = CIImage(color: CIColor(red: 0.6, green: 0.4, blue: 0.2)).cropped(to: CGRect(x: 0, y: 0, width: 20, height: 20))
        var style = PhotoStyle.film.adjustment
        style.intensity = 0
        #expect(style.applying(to: source) === source)
        var draft = StyleDraft()
        draft.intensity = -.infinity
        #expect(throws: CameraFailure.self) { try draft.validated() }
    }

    @Test func sceneRecommendationsAreDifferentAndReachable() {
        #expect(ShootingScene.portrait.styles.contains(.soft))
        #expect(ShootingScene.night.styles.contains(.cinema))
        #expect(ShootingScene.food.styles != ShootingScene.portrait.styles)
        #expect(ShootingScene.all.styles.count == PhotoStyle.allCases.count)
    }

    @Test func exportPreservesPhotoResolutionAndNormalizesOrientation() throws {
        let input = try sourcePhoto(width: 1920, height: 1280, orientation: 6)
        let output = try PhotoProcessor().render(input, style: PhotoStyle.film.adjustment)
        #expect(output.width == 1280 && output.height == 1920)
        let source = try #require(CGImageSourceCreateWithData(output.data as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        #expect(properties[kCGImagePropertyOrientation as String] as? Int == 1)
        #expect(properties[kCGImagePropertyPixelWidth as String] as? Int == 1280)
        #expect(properties[kCGImagePropertyPixelHeight as String] as? Int == 1920)
        let exif = try #require(properties[kCGImagePropertyExifDictionary as String] as? [String: Any])
        #expect(exif[kCGImagePropertyExifExposureTime as String] as? Double == 0.008)
        let preview = try #require(CGImageSourceCreateWithData(output.thumbnail as CFData, nil))
        let thumbnail = try #require(CGImageSourceCreateImageAtIndex(preview, 0, nil))
        #expect(max(thumbnail.width, thumbnail.height) <= 1200)
    }

    @Test func captureArchiveKeepsOriginalAndCanRestoreLastPhoto() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let processor = PhotoProcessor(storageDirectory: folder)
        let original = try sourcePhoto(width: 300, height: 200, orientation: 1)
        let saved = try await processor.process(original, style: PhotoStyle.cinema.adjustment)
        #expect(try Data(contentsOf: saved.originalURL) == original)
        #expect(saved.width == 300 && saved.height == 200)
        #expect(saved.styleName == PhotoStyle.cinema.rawValue)
        #expect(try Data(contentsOf: saved.fileURL) != original)
        let restored = await processor.latest()
        #expect(restored?.id == saved.id)
        #expect(restored?.fileURL == saved.fileURL)
    }

    @Test func invalidPhotoDataFailsCleanly() {
        #expect(throws: CameraFailure.self) {
            try PhotoProcessor().render(Data("invalid".utf8), style: StyleAdjustment())
        }
    }

    private func sourcePhoto(width: Int, height: Int, orientation: Int) throws -> Data {
        let image = CIImage(color: CIColor(red: 0.6, green: 0.4, blue: 0.2))
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        let bitmap = try #require(CIContext().createCGImage(image, from: image.extent))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, bitmap, [
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifExposureTime: 0.008]
        ] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
