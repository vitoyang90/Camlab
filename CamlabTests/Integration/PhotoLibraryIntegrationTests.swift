import CoreImage
import Photos
import UIKit
import XCTest
@testable import Camlab

final class PhotoLibraryIntegrationTests: XCTestCase {
    @MainActor func testInterruptedSaveReusesTheSameAssetAcrossRelaunchAndConcurrentRetry() async throws {
        #if targetEnvironment(simulator)
        let permission = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard permission == .authorized || permission == .limited else { throw XCTSkip("需要模擬器相簿權限") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let processor = PhotoProcessor(storageDirectory: folder)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let original = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30), format: format).pngData {
            UIColor.blue.setFill(); $0.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }
        let photo = try await processor.process(original, style: StyleAdjustment())
        async let first = PhotoLibrarySaver.save(photo, processor: processor)
        async let second = PhotoLibrarySaver.save(photo, processor: processor)
        let (saved, same) = try await (first, second)
        let identifier = try XCTUnwrap(saved.assetIdentifier)
        XCTAssertEqual(identifier, same.assetIdentifier)

        // Photos committed, but Capture.json still has no asset ID and the
        // pre-commit journal is all a newly launched process can see.
        let manifest = photo.originalURL.deletingLastPathComponent().appendingPathComponent("Capture.json")
        try JSONEncoder().encode(photo).write(to: manifest, options: .atomic)
        try PhotoLibraryJournal(phase: .creating, assetIdentifier: identifier).write(for: photo)
        let restored = PhotoProcessor(storageDirectory: folder)
        let restoredPending = await restored.pending()
        let pending = try XCTUnwrap(restoredPending.first)
        let recovered = try await PhotoLibrarySaver.save(pending, processor: restored)
        XCTAssertEqual(recovered.assetIdentifier, identifier)

        // Also reconcile the fallback marker if the identifier write itself was
        // interrupted. Never issue another creation request for this photo.
        try JSONEncoder().encode(photo).write(to: manifest, options: .atomic)
        try PhotoLibraryJournal(phase: .creating).write(for: photo)
        let reconciled = try await PhotoLibrarySaver.save(photo, processor: restored)
        XCTAssertEqual(reconciled.assetIdentifier, identifier)
        XCTAssertEqual(try PhotoLibraryJournal.read(for: photo)?.phase, .finished)
        // A finished journal must not upload local content again, even if only
        // cleanup was interrupted and that local content is now unavailable.
        try Data("must not be uploaded".utf8).write(to: photo.fileURL, options: .atomic)
        let finished = try await PhotoLibrarySaver.save(photo, processor: restored)
        XCTAssertEqual(finished.assetIdentifier, identifier)
        let library = try await PhotoLibrarySaver.load(identifier)
        XCTAssertEqual(library.original, original)

        let uncertain = try await processor.process(original, style: StyleAdjustment())
        try PhotoLibraryJournal(phase: .creating).write(for: uncertain)
        do {
            _ = try await PhotoLibrarySaver.save(uncertain, processor: processor)
            XCTFail("An unresolved creation must not be replayed")
        } catch { XCTAssertTrue(error is CameraFailure) }

        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate <= %@",
            photo.createdAt.addingTimeInterval(-1) as NSDate, uncertain.createdAt.addingTimeInterval(1) as NSDate)
        let assets = PHAsset.fetchAssets(with: .image, options: options)
        var matches = 0, uncertainMatches = 0
        assets.enumerateObjects { asset, _, _ in
            if PHAssetResource.assetResources(for: asset).contains(where: { $0.originalFilename.hasPrefix("Camlab-\(photo.id.uuidString).") }) { matches += 1 }
            if PHAssetResource.assetResources(for: asset).contains(where: { $0.originalFilename.hasPrefix("Camlab-\(uncertain.id.uuidString).") }) { uncertainMatches += 1 }
        }
        XCTAssertEqual(matches, 1)
        XCTAssertEqual(uncertainMatches, 0)
        try await restored.complete(finished)
        let remaining = await restored.pending()
        XCTAssertEqual(remaining.map(\.id), [uncertain.id])
        let created = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(created) }
        #else
        throw XCTSkip("只在模擬器執行相簿整合測試")
        #endif
    }

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
        let other = try await processor.process(original, style: StyleAdjustment())
        let savedOther = try await PhotoLibrarySaver.save(other, processor: processor)
        let otherID = try XCTUnwrap(savedOther.assetIdentifier)
        XCTAssertNotEqual(identifier, otherID)
        do {
            try await PhotoLibrarySaver.deleteAssets([identifier, UUID().uuidString])
            XCTFail("An inaccessible selection must leave the entire batch untouched")
        } catch { XCTAssertTrue(error is CameraFailure) }
        XCTAssertEqual(PHAsset.fetchAssets(withLocalIdentifiers: [identifier, otherID], options: nil).count, 2)
        try await PhotoLibrarySaver.deleteAssets([identifier, otherID])
        XCTAssertEqual(PHAsset.fetchAssets(withLocalIdentifiers: [otherID], options: nil).count, 0)
        XCTAssertEqual(PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).count, 0)
        XCTAssertNil(PhotoLibrarySaver.lastAssetIdentifier)
        #else
        throw XCTSkip("只在模擬器執行相簿整合測試")
        #endif
    }
}
