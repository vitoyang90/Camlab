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

    @Test func queuedOriginalsSurviveRelaunchBeforeRenderingWithoutChangingQuality() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let processor = PhotoProcessor(storageDirectory: folder)
        let original = try sourcePhoto(width: 640, height: 480, orientation: 6)
        var recipe = RecipeAdjustment()
        recipe[.saturation] = -80
        let firstStyle = StyleAdjustment(recipe: recipe, recipeName: "First")
        let first = try await processor.stage(original, style: firstStyle)
        recipe[.saturation] = 60
        let secondStyle = StyleAdjustment(recipe: recipe, recipeName: "Second")
        let second = try await processor.stage(original, style: secondStyle)
        #expect(!FileManager.default.fileExists(atPath: first.fileURL.path))
        #expect(try Data(contentsOf: first.originalURL) == original)
        #expect(try Data(contentsOf: second.originalURL) == original)

        let restored = PhotoProcessor(storageDirectory: folder)
        let pending = await restored.pending()
        #expect(Set(pending.map(\.id)) == [first.id, second.id])
        #expect(pending.first { $0.id == first.id }?.adjustment == firstStyle.recipe)
        #expect(pending.first { $0.id == second.id }?.adjustment == secondStyle.recipe)
        let rendered = try await restored.processStaged(first, style: firstStyle)
        let reference = try restored.render(original, style: firstStyle)
        #expect(rendered.width == 480 && rendered.height == 640)
        #expect(try Data(contentsOf: rendered.fileURL) == reference.data)
        try await restored.complete(rendered)
        #expect(await restored.pending().map(\.id) == [second.id])
        #expect(try Data(contentsOf: second.originalURL) == original)
    }

    @Test func renderingFailureKeepsTheQueuedOriginalForRecovery() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let processor = PhotoProcessor(storageDirectory: folder)
        let original = Data("invalid capture".utf8)
        let staged = try await processor.stage(original, style: StyleAdjustment())
        await #expect(throws: CameraFailure.self) {
            try await processor.processStaged(staged, style: StyleAdjustment())
        }
        #expect(await processor.pending().map(\.id) == [staged.id])
        #expect(try Data(contentsOf: staged.originalURL) == original)
    }

    @Test func journalWithoutOriginalIsHiddenAndCompletedOriginalIsRecoverable() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let processor = PhotoProcessor(storageDirectory: folder)
        let original = try sourcePhoto(width: 80, height: 60, orientation: 1)
        let staged = try await processor.stage(original, style: StyleAdjustment())
        // Model termination after the journal, before the atomic original write.
        try FileManager.default.removeItem(at: staged.originalURL)
        #expect(await processor.pending().isEmpty)
        // Once the original is committed, the existing journal must discover it
        // even though rendering and Latest.json have never been written.
        try original.write(to: staged.originalURL, options: .atomic)
        let restored = PhotoProcessor(storageDirectory: folder)
        #expect(await restored.pending().map(\.id) == [staged.id])
        #expect(await restored.latest() == nil)
        #expect(try Data(contentsOf: staged.originalURL) == original)
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
