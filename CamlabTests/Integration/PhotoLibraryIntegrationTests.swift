import CoreImage
import Photos
import UIKit
import XCTest
@testable import Camlab

final class PhotoLibraryIntegrationTests: XCTestCase {
    @MainActor func testOriginalAndRecipeSurviveEditingTheSameLibraryAsset() async throws {
        #if targetEnvironment(simulator)
        print("Photos integration host: \(Bundle.main.bundleIdentifier ?? "unknown")")
        let permission = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard permission == .authorized || permission == .limited else {
            throw XCTSkip("此整合測試需要先授權模擬器相簿，狀態 \(permission.rawValue)；不向真機相簿加入測試照片。")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let processor = PhotoProcessor(storageDirectory: folder)
        let image = CIImage(color: CIColor(red: 0.55, green: 0.35, blue: 0.2))
            .cropped(to: CGRect(x: 0, y: 0, width: 200, height: 160))
        let bitmap = try XCTUnwrap(CIContext().createCGImage(image, from: image.extent))
        // Also verifies importing a non-JPEG source despite the staging filename.
        let original = try XCTUnwrap(UIImage(cgImage: bitmap).pngData())
        var adjustment = RecipeAdjustment(); adjustment[.saturation] = 20
        adjustment[.definition] = 35
        adjustment[.sharpness] = 20
        adjustment[.noiseReduction] = 15
        adjustment[.vignette] = -25
        let pending = try await processor.process(original, style: StyleAdjustment(recipe: adjustment, recipeName: "整合測試"))
        let saved = try await PhotoLibrarySaver.save(pending, processor: processor)
        let identifier = try XCTUnwrap(saved.assetIdentifier)
        let loaded = try await PhotoLibrarySaver.load(identifier)
        XCTAssertEqual(loaded.original, original)
        XCTAssertEqual(loaded.adjustment, adjustment)
        XCTAssertEqual(loaded.editableAssetIdentifier, identifier)
        try await processor.complete(saved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.originalURL.path))

        adjustment[.saturation] = 30
        adjustment[.definition] = 70
        adjustment[.vignette] = 40
        let edit = try await processor.process(loaded.original, style: StyleAdjustment(recipe: adjustment), assetIdentifier: identifier)
        let updated = try await PhotoLibrarySaver.save(edit, processor: processor)
        XCTAssertEqual(updated.assetIdentifier, identifier)
        let reloaded = try await PhotoLibrarySaver.load(identifier)
        XCTAssertEqual(reloaded.original, original)
        XCTAssertEqual(reloaded.adjustment[.saturation], 30)
        XCTAssertEqual(reloaded.adjustment, adjustment)
        try await processor.complete(updated)
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        XCTAssertEqual(assets.count, 1)
        try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(assets) }
        #else
        throw XCTSkip("只在模擬器執行相簿整合測試")
        #endif
    }
}
