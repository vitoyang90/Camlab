import CoreImage
import Foundation
import Testing
import UIKit
@testable import Camlab

@MainActor struct RecipeWorkflowTests {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "CamlabTests.\(UUID().uuidString)")! }

    @Test func relaunchAndSwitchingDiscardUnsavedValues() throws {
        let defaults = defaults()
        let store = RecipeStore(defaults: defaults)
        store.draft[.saturation] = 20
        let saved = try store.saveNew(name: "暖色人像")
        store.draft[.saturation] = 30
        #expect(store.isModified)
        let restored = RecipeStore(defaults: defaults)
        #expect(restored.selectedID == saved.id)
        #expect(restored.draft[.saturation] == 20)
        try store.select(nil)
        try store.select(saved.id)
        #expect(store.draft[.saturation] == 20)
        store.draft[.saturation] = 30
        try store.update()
        #expect(RecipeStore(defaults: defaults).draft[.saturation] == 30)
    }

    @Test func saveAsRenameDeleteAndNaturalSelectionPersist() throws {
        let defaults = defaults()
        let store = RecipeStore(defaults: defaults)
        store.draft[.saturation] = 20
        let first = try store.saveNew(name: "配方 A")
        store.draft[.saturation] = 30
        let second = try store.saveNew(name: "配方 B")
        #expect(first.id != second.id)
        #expect(store.recipes.first?.adjustment[.saturation] == 20)
        try store.rename(second.id, name: "陰天")
        #expect(store.name == "陰天")
        #expect(throws: CameraFailure.self) { try store.rename(second.id, name: "配方 A") }
        #expect(throws: CameraFailure.self) { try store.saveNew(name: "原色") }
        try store.delete(second.id)
        #expect(store.selectedID == nil && store.draft == RecipeAdjustment())
        #expect(RecipeStore(defaults: defaults).selectedID == nil)
        #expect(throws: CameraFailure.self) { try store.update() }
    }

    @Test func acceptsOnlyIntegersAndSupportedRanges() throws {
        #expect(try RecipeAdjustment.integer(" -20 ", parameter: .exposure) == -20)
        for input in ["20.5", "20.0", "nan", "inf", "101", "-101", ""] {
            #expect(throws: CameraFailure.self) { try RecipeAdjustment.integer(input, parameter: .saturation) }
        }
        let malformed = Data("{\"values\":{\"saturation\":200}}".utf8)
        let adjustment = try JSONDecoder().decode(RecipeAdjustment.self, from: malformed)
        #expect(throws: CameraFailure.self) { try adjustment.validated() }
    }

    @Test func colorParametersChangePixelsAndZeroIsIdentity() {
        let source = CIImage(color: CIColor(red: 0.42, green: 0.32, blue: 0.18))
            .cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16))
        #expect(RecipeAdjustment().applying(to: source) === source)
        let context = CIContext(options: [.useSoftwareRenderer: true])
        func pixels(_ image: CIImage) -> [Float] {
            var result = [Float](repeating: 0, count: 4)
            result.withUnsafeMutableBytes { buffer in
                context.render(image, toBitmap: buffer.baseAddress!, rowBytes: 16,
                               bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf,
                               colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            }
            return result
        }
        let original = pixels(source)
        // Spatial detail controls need textured fixtures, covered separately.
        for parameter in AdjustmentParameter.allCases where ![.sharpness, .definition, .noiseReduction].contains(parameter) {
            var adjustment = RecipeAdjustment()
            adjustment[parameter] = 60
            let output = pixels(adjustment.applying(to: source))
            #expect(zip(original, output).contains { abs($0 - $1) > 0.001 }, "\(parameter.title) must affect the preview and export pipeline")
            #expect(output.allSatisfy { $0.isFinite })
        }
    }

    @Test func pendingJournalRetainsAssetAndCleanupPreservesOtherCaptures() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let processor = PhotoProcessor(storageDirectory: folder)
        let source = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 48))
        let bitmap = try #require(CIContext().createCGImage(source, from: source.extent))
        let data = try #require(UIImage(cgImage: bitmap).jpegData(compressionQuality: 0.9))
        var adjustment = RecipeAdjustment(); adjustment[.saturation] = 20
        let first = try await processor.process(data, style: StyleAdjustment(recipe: adjustment, recipeName: "測試"))
        let journaled = try await processor.recordAsset(first, identifier: "test-asset")
        adjustment[.saturation] = 30
        let revised = try await processor.revise(journaled, style: StyleAdjustment(recipe: adjustment))
        #expect(revised.id == first.id && revised.assetIdentifier == "test-asset")
        #expect(try Data(contentsOf: revised.originalURL) == data)
        let other = try await processor.process(data, style: StyleAdjustment(recipe: RecipeAdjustment()))
        #expect(await processor.pending().count == 2)
        try await processor.complete(revised)
        #expect(!FileManager.default.fileExists(atPath: revised.originalURL.path))
        #expect(FileManager.default.fileExists(atPath: other.originalURL.path))
        #expect(await processor.latest()?.id == other.id)
        #expect(await processor.pending().count == 1)
    }

    @Test func horizonWorksAcrossOrientationsAndRejectsFlatPhone() {
        #expect(HorizonGeometry.degrees(x: 0, y: -1) == 0)
        #expect(HorizonGeometry.degrees(x: 1, y: 0) == 0)
        #expect(HorizonGeometry.degrees(x: -1, y: 0) == 0)
        #expect(HorizonGeometry.degrees(x: 0, y: 1) == 0)
        #expect(HorizonGeometry.degrees(x: 0, y: 0) == nil)
        #expect(HorizonGeometry.degrees(x: .nan, y: -1) == nil)
        let angled = HorizonGeometry.degrees(x: sin(10 * .pi / 180), y: -cos(10 * .pi / 180))!
        #expect(abs(angled - 10) < 0.001)
    }

    @Test func tapFocusAccountsForRotationMirrorAndLetterboxing() throws {
        let source = CGRect(x: 0, y: 0, width: 400, height: 300)
        let topRight = try #require(PreviewGeometry.sensorPoint(sourceExtent: source, clockwiseDegrees: 90, mirrored: false,
                                                               viewport: CGSize(width: 300, height: 400), touch: CGPoint(x: 300, y: 0)))
        #expect(abs(topRight.x) < 0.001 && abs(topRight.y) < 0.001)
        let mirrored = try #require(PreviewGeometry.sensorPoint(sourceExtent: source, clockwiseDegrees: 90, mirrored: true,
                                                               viewport: CGSize(width: 300, height: 400), touch: CGPoint(x: 300, y: 0)))
        #expect(abs(mirrored.x) < 0.001 && abs(mirrored.y - 1) < 0.001)
        #expect(PreviewGeometry.sensorPoint(sourceExtent: source, clockwiseDegrees: 0, mirrored: false,
                                           viewport: CGSize(width: 400, height: 600), touch: CGPoint(x: 20, y: 10)) == nil)
    }
}
