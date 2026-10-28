import CoreImage
import Foundation
import Testing
import UIKit
@testable import Camlab

@MainActor struct NativePhotoWorkflowTests {
    private func fixture(_ color: UIColor) throws -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 64, height: 48), format: format).pngData { context in
            color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        }
    }

    @Test func sharingPreservesEncodedBytesAndRealFileType() throws {
        let data = try fixture(.orange)
        let content = try NativePhotoContent(data: data)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try content.writeShareCopy(in: folder)
        #expect(url.pathExtension == "png")
        #expect(try Data(contentsOf: url) == data)
        #expect(throws: CameraFailure.self) { try NativePhotoContent(data: Data("invalid".utf8)) }
    }

    @Test func nativeStagingIgnoresRecipeAndRetainsModeAcrossRetry() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let data = try fixture(.purple)
        let processor = PhotoProcessor(storageDirectory: folder)
        var recipe = RecipeAdjustment(); recipe[.exposure] = 100; recipe[.saturation] = -100
        let staged = try await processor.process(data, style: StyleAdjustment(recipe: recipe), nativePhotosWorkflow: true)
        #expect(try Data(contentsOf: staged.originalURL) == data)
        #expect(try Data(contentsOf: staged.fileURL) == data)
        #expect(staged.width == 64 && staged.height == 48)
        #expect(staged.adjustment == recipe) // Stored as a checklist only.
        let saved = try await processor.recordAsset(staged, identifier: "test-native-asset")
        #expect(saved.nativePhotosWorkflow == true)
        #expect(await processor.latest()?.nativePhotosWorkflow == true)
        #expect(await processor.pending().first?.nativePhotosWorkflow == true)
        await #expect(throws: CameraFailure.self) { try await processor.revise(saved, style: StyleAdjustment(recipe: recipe)) }
        // Old archives remain legacy edits, never silently reclassified as native.
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(staged)) as? [String: Any])
        json.removeValue(forKey: "nativePhotosWorkflow")
        let old = try JSONDecoder().decode(SavedPhoto.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.nativePhotosWorkflow == nil)
    }

    @Test func refreshUsesCurrentAssetAndBlocksStaleSharingAfterFailure() async throws {
        let first = try fixture(.red), second = try fixture(.blue)
        var calls = 0
        let model = NativePhotoReviewModel { identifier in
            #expect(identifier == "same-asset")
            calls += 1
            if calls == 3 { throw CameraFailure("network unavailable") }
            return try NativePhotoContent(data: calls == 1 ? first : second)
        }
        await model.load(PhotoEditorSource(assetIdentifier: "same-asset"))
        #expect(model.content?.data == first && model.canShare)
        await model.refresh()
        #expect(model.content?.data == second && model.canShare)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try model.export(in: folder)
        let url = try #require(model.shareURL)
        #expect(try Data(contentsOf: url) == second)
        model.clearExport()
        #expect(model.shareURL == nil && !FileManager.default.fileExists(atPath: url.path))
        await model.refresh()
        #expect(!model.canShare && model.errorMessage != nil)
        #expect(throws: CameraFailure.self) { try model.export(in: folder) }
        await model.refresh()
        #expect(model.canShare && model.errorMessage == nil)
    }

    @Test func pickerOnlyDataDoesNotPretendItCanAutomaticallyRefresh() async throws {
        let data = try fixture(.green)
        let model = NativePhotoReviewModel { _ in Issue.record("Picker-only data must not reload an unrelated asset"); throw CameraFailure("unexpected") }
        await model.load(PhotoEditorSource(original: data))
        await model.refresh()
        #expect(model.assetIdentifier == nil)
        #expect(model.content?.data == data && model.canShare)
    }
}
