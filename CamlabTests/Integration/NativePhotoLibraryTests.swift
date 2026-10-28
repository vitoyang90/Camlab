import Photos
import UIKit
import XCTest
@testable import Camlab

final class NativePhotoLibraryTests: XCTestCase {
    @MainActor func testOriginalIsUnmodifiedAndCurrentReadSeesExternalEdit() async throws {
        #if targetEnvironment(simulator)
        let permission = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard permission == .authorized || permission == .limited else { throw XCTSkip("需要模擬器相簿權限") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 60), format: format)
        let original = renderer.pngData { context in UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 80, height: 60)) }
        let processor = PhotoProcessor(storageDirectory: folder)
        var recipe = RecipeAdjustment(); recipe[.saturation] = -100
        let staged = try await processor.process(original, style: StyleAdjustment(recipe: recipe), nativePhotosWorkflow: true)
        let saved = try await PhotoLibrarySaver.save(staged, processor: processor)
        let id = try XCTUnwrap(saved.assetIdentifier)
        let current = try await PhotoLibrarySaver.loadCurrent(id)
        XCTAssertFalse(current.data.isEmpty) // Photos can update metadata in its current representation.
        let asset = try XCTUnwrap(PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject)
        let resource = try XCTUnwrap(PHAssetResource.assetResources(for: asset).first { $0.type == .photo })
        let originalCopy = folder.appendingPathComponent("asset-original.png")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: originalCopy, options: nil) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        XCTAssertEqual(try Data(contentsOf: originalCopy), original)
        let input: PHContentEditingInput = try await withCheckedThrowingContinuation { continuation in
            asset.requestContentEditingInput(with: nil) { input, _ in
                if let input { continuation.resume(returning: input) }
                else { continuation.resume(throwing: CameraFailure("無法讀取測試 asset")) }
            }
        }
        XCTAssertNil(input.adjustmentData)
        let edited = renderer.jpegData(withCompressionQuality: 0.96) { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 80, height: 60))
        }
        let output = PHContentEditingOutput(contentEditingInput: input)
        try edited.write(to: output.renderedContentURL)
        output.adjustmentData = PHAdjustmentData(formatIdentifier: "CamlabTest.externalEdit", formatVersion: "1", data: Data("test".utf8))
        try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest(for: asset).contentEditingOutput = output }
        let refreshed = try await PhotoLibrarySaver.loadCurrent(id)
        XCTAssertNotEqual(refreshed.data, original)
        // PhotoKit may update container metadata; verify the expected rendered pixels.
        let image = try XCTUnwrap(UIImage(data: refreshed.data)?.cgImage)
        var rgba = [UInt8](repeating: 0, count: 4)
        try rgba.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                                 space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        XCTAssertGreaterThan(rgba[2], 220)
        XCTAssertLessThan(rgba[0], 30)
        let share = try refreshed.writeShareCopy(in: folder)
        XCTAssertEqual(try Data(contentsOf: share), refreshed.data)
        try await processor.complete(saved)
        // Leave this generated solid-color fixture in the simulator for UI testing.
        // This test never deletes or touches any existing library asset.
        #else
        throw XCTSkip("不向真機相簿寫入測試圖片")
        #endif
    }
}
