import CoreImage
import Foundation
import Testing
import UIKit
@testable import Camlab

@MainActor struct ShootingStyleTests {
    @Test func builtInsPersistWithoutReplacingCustomRecipes() throws {
        let suite = "ShootingStyleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RecipeStore(defaults: defaults)
        store.draft[.exposure] = 15
        let custom = try store.saveNew(name: "我的風格")
        #expect(ShootingStyle.allCases.count >= 10)
        #expect(Set(ShootingStyle.allCases.map(\.id)).count == ShootingStyle.allCases.count)
        for preset in ShootingStyle.allCases {
            try store.select(preset.id)
            #expect(try store.draft.validated() == preset.adjustment)
            #expect(!store.canUpdate && !store.isModified)
            store.draft[.exposure] = 90
            #expect(store.isModified)
            #expect(throws: CameraFailure.self) { try store.update() }
            #expect(throws: CameraFailure.self) { try store.delete(preset.id) }
            #expect(throws: CameraFailure.self) { try store.rename(preset.id, name: "改名") }
            let restored = RecipeStore(defaults: defaults)
            #expect(restored.selectedID == preset.id)
            #expect(restored.draft == preset.adjustment)
            #expect(restored.recipes == [custom])
        }
        try store.select(ShootingStyle.vintage.id)
        store.draft[.exposure] = 10
        let copy = try store.saveNew(name: "我的復古")
        #expect(store.canUpdate && copy.adjustment[.exposure] == 10)
        try store.select(nil)
        #expect(store.draft == RecipeAdjustment())
        try store.select(ShootingStyle.vintage.id)
        #expect(store.draft == ShootingStyle.vintage.adjustment)
    }

    @Test func choosingStyleEnablesMatchingLiveAndCaptureEffects() throws {
        let suite = "ShootingStyleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = CameraModel(defaults: defaults)
        for preset in ShootingStyle.allCases {
            model.nativePhotosWorkflow = true
            model.selectShootingRecipe(preset.id)
            #expect(!model.nativePhotosWorkflow)
            #expect(model.previewStyle == model.captureStyle)
            #expect(model.captureStyle.recipe == preset.adjustment)
            #expect(model.captureStyle.name == preset.name)
        }
        let restored = CameraModel(defaults: defaults)
        #expect(!restored.nativePhotosWorkflow)
        #expect(restored.previewStyle == model.previewStyle)
        model.selectShootingRecipe(nil)
        #expect(model.previewStyle.recipe == RecipeAdjustment())
    }

    @Test func stylesProduceDistinctPixelsAndMonochromeHasNoColor() throws {
        let source = CIImage(color: CIColor(red: 0.52, green: 0.34, blue: 0.21))
            .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        let context = CIContext(options: [.useSoftwareRenderer: true])
        func pixel(_ image: CIImage) -> [Float] {
            var values = [Float](repeating: 0, count: 4)
            values.withUnsafeMutableBytes {
                context.render(image, toBitmap: $0.baseAddress!, rowBytes: 16,
                               bounds: CGRect(x: 32, y: 32, width: 1, height: 1), format: .RGBAf,
                               colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            }
            return values
        }
        let original = pixel(source)
        var outputs: [[Float]] = []
        for preset in ShootingStyle.allCases {
            let image = preset.adjustment.applying(to: source)
            #expect(image.extent == source.extent)
            let output = pixel(image)
            #expect(output.allSatisfy { $0.isFinite })
            #expect(zip(original, output).contains { abs($0 - $1) > 0.005 }, "\(preset.name) must change pixels")
            for previous in outputs {
                #expect(zip(previous, output).contains { abs($0 - $1) > 0.002 }, "\(preset.name) needs a distinct effect")
            }
            outputs.append(output)
        }
        let mono = pixel(ShootingStyle.mono.adjustment.applying(to: source))
        #expect(abs(mono[0] - mono[1]) < 0.005 && abs(mono[1] - mono[2]) < 0.005)
    }

    @Test func capturedStyleRetainsRecipeAndOriginalForReediting() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = CIImage(color: CIColor(red: 0.7, green: 0.4, blue: 0.2))
            .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 96))
        let bitmap = try #require(CIContext().createCGImage(source, from: source.extent))
        let original = try #require(UIImage(cgImage: bitmap).jpegData(compressionQuality: 1))
        let processor = PhotoProcessor(storageDirectory: folder)
        for preset in ShootingStyle.allCases {
            let style = StyleAdjustment(recipe: preset.adjustment, recipeName: preset.name)
            let saved = try await processor.process(original, style: style)
            #expect(saved.styleName == preset.name && saved.adjustment == preset.adjustment)
            #expect(saved.width == 64 && saved.height == 96)
            #expect(saved.nativePhotosWorkflow == false)
            #expect(try Data(contentsOf: saved.originalURL) == original)
            let expected = try processor.render(original, style: style).data
            #expect(try Data(contentsOf: saved.fileURL) == expected)
        }
    }
}
