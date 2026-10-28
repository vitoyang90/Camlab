import CoreImage
import Foundation
import Testing
import UIKit
@testable import Camlab

@MainActor struct RecipeDetailTests {
    private let detailParameters: [AdjustmentParameter] = [.sharpness, .definition, .noiseReduction, .vignette]

    @Test func automaticShadowDenoisingReducesColorNoiseWithoutDimmingShadows() {
        #expect(RecipeColorPipeline.shadowDenoiseKernel != nil)
        let clean = pixels(shadowFixture(noisy: false))
        let source = shadowFixture(noisy: true)
        let noisy = pixels(source)
        let filtered = pixels(RecipeColorPipeline.denoising(source, amount: 0, shadowLift: 0.4))
        func errors(_ output: [Float]) -> (Double, Double, Double) {
            var chroma = 0.0, luma = 0.0, bias = 0.0
            for y in 16..<96 { for x in 16..<112 {
                let i = (y * 256 + x) * 4
                let e = (0..<3).map { Double(output[i+$0] - clean[i+$0]) }
                let light = e[0] * 0.2126 + e[1] * 0.7152 + e[2] * 0.0722
                luma += light * light; bias += light
                chroma += pow(e[0] - e[1], 2) + pow(e[2] - e[1], 2)
            }}
            return (chroma, luma, bias / (80 * 96))
        }
        let before = errors(noisy), after = errors(filtered)
        #expect(after.0 < before.0 * 0.85)
        #expect(after.1 < before.1)
        #expect(abs(after.2) < 0.003)
        // Bright pixels are outside the automatic shadow mask.
        for y in [32, 64] { for x in [160, 200] {
            let i = (y * 256 + x) * 4
            for c in 0..<3 { #expect(abs(filtered[i+c] - noisy[i+c]) < 0.002) }
        }}
    }

    @Test func shadowDenoisingKeepsFineStructureAndEdgeContrast() {
        let source = shadowFixture(noisy: false)
        let clean = pixels(source)
        let filtered = pixels(RecipeColorPipeline.denoising(source, amount: 0, shadowLift: 0.4))
        // Low-contrast eight-pixel texture and a larger dark edge, without noise.
        func texture(_ p: [Float]) -> Float { p[(180*256+66)*4] - p[(180*256+70)*4] }
        func edge(_ p: [Float]) -> Float { p[(180*256+132)*4] - p[(180*256+124)*4] }
        #expect(texture(filtered) > texture(clean) * 0.90)
        #expect(edge(filtered) > edge(clean) * 0.95)
        #expect(filtered.allSatisfy { $0.isFinite })
        #expect(stride(from: 3, to: filtered.count, by: 4).allSatisfy { abs(filtered[$0] - 1) < 0.001 })
    }

    @Test func explicitDenoisingStillWorksWithoutShadowLiftAndZeroBypasses() {
        let source = shadowFixture(noisy: true)
        #expect(RecipeColorPipeline.denoising(source, amount: 0, shadowLift: 0) === source)
        let automatic = pixels(RecipeColorPipeline.denoising(source, amount: 0, shadowLift: 0.4))
        let manual = pixels(RecipeColorPipeline.denoising(source, amount: 1, shadowLift: 0))
        #expect(horizontalEnergy(manual) < horizontalEnergy(automatic))
    }

    private func shadowFixture(noisy: Bool) -> CIImage {
        var bytes = [UInt8]()
        for y in 0..<256 { for x in 0..<256 {
            let base = y < 112 ? (x < 128 ? 0.12 : 0.72) : (x < 128 ? 0.12 : 0.26)
            let texture = y >= 112 ? 0.02 * sin(Double(x) * .pi / 4) : 0
            for c in 0..<3 {
                let noise = noisy ? Double((x*37+y*71+x*y*13+c*43+x*c*7) % 17 - 8) / 255 : 0
                bytes.append(UInt8(min(255, max(0, (base + texture + noise) * 255))))
            }
            bytes.append(255)
        }}
        return CIImage(bitmapData: Data(bytes), bytesPerRow: 256*4,
                       size: CGSize(width: 256, height: 256), format: .RGBA8,
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }

    @Test func detailRangesRejectInvalidInputAndArchives() throws {
        for parameter in [AdjustmentParameter.sharpness, .definition, .noiseReduction] {
            #expect(try RecipeAdjustment.integer("0", parameter: parameter) == 0)
            #expect(try RecipeAdjustment.integer("100", parameter: parameter) == 100)
            for text in ["-1", "101", "1.5"] {
                #expect(throws: CameraFailure.self) { try RecipeAdjustment.integer(text, parameter: parameter) }
            }
            let invalid = Data("{\"values\":{\"\(parameter.rawValue)\":-1}}".utf8)
            let decoded = try JSONDecoder().decode(RecipeAdjustment.self, from: invalid)
            #expect(throws: CameraFailure.self) { try decoded.validated() }
        }
        #expect(try RecipeAdjustment.integer("-100", parameter: .vignette) == -100)
        #expect(try RecipeAdjustment.integer("100", parameter: .vignette) == 100)
    }

    @Test func oldRecipesDefaultToZeroAndNewValuesSurviveRelaunch() throws {
        let suite = "Camlab.DetailTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID()
        let archive = """
        {"version":1,"recipes":[{"id":"\(id)","name":"舊配方","adjustment":{"values":{"saturation":23}}}],"selectedID":"\(id)"}
        """
        defaults.set(Data(archive.utf8), forKey: "Camlab.Recipes.v1")
        let store = RecipeStore(defaults: defaults)
        #expect(store.loadError == nil)
        #expect(store.draft[.saturation] == 23)
        for parameter in detailParameters { #expect(store.draft[parameter] == 0) }
        store.draft[.sharpness] = 24
        store.draft[.definition] = 47
        store.draft[.noiseReduction] = 32
        store.draft[.vignette] = -28
        try store.update()
        let restored = RecipeStore(defaults: defaults)
        #expect(restored.draft == store.draft)
        #expect(restored.selectedID == id)
        let photoKitData = try JSONEncoder().encode(store.draft)
        #expect(try JSONDecoder().decode(RecipeAdjustment.self, from: photoKitData).validated() == store.draft)
    }

    @Test func sharpeningIncreasesDetailAndNoiseReductionSmoothsIt() {
        let source = fixture(noisy: true)
        let original = pixels(source)
        let sharp = pixels(adjust(.sharpness, 100, source))
        let smooth = pixels(adjust(.noiseReduction, 100, source))
        #expect(horizontalEnergy(sharp) > horizontalEnergy(original))
        #expect(horizontalEnergy(smooth) < horizontalEnergy(original))
        #expect(sharp.allSatisfy { $0.isFinite } && smooth.allSatisfy { $0.isFinite })
    }

    @Test func definitionEnhancesBroadStructureAndDiffersFromSharpening() {
        let source = fixture(noisy: false)
        let original = pixels(source)
        let defined = pixels(adjust(.definition, 100, source))
        let sharpened = pixels(adjust(.sharpness, 100, source))
        func contrast(_ values: [Float]) -> Float {
            values[(128 * 256 + 136) * 4] - values[(128 * 256 + 120) * 4]
        }
        #expect(contrast(defined) > contrast(original))
        #expect(zip(defined, sharpened).contains { abs($0 - $1) > 0.0001 })
    }

    @Test func vignetteChangesEdgesInBothDirectionsAndKeepsCenter() {
        let extent = CGRect(x: 37, y: 53, width: 256, height: 256)
        let source = CIImage(color: CIColor(red: 0.45, green: 0.45, blue: 0.45)).cropped(to: extent)
        let original = pixels(source)
        let dark = pixels(adjust(.vignette, 100, source))
        let light = pixels(adjust(.vignette, -100, source))
        let center = (128 * 256 + 128) * 4
        #expect(dark[0] < original[0] - 0.1)
        #expect(light[0] > original[0] + 0.1)
        #expect(abs(dark[center] - original[center]) < 0.001)
        #expect(abs(light[center] - original[center]) < 0.001)
    }

    @Test func combinedDetailsKeepExtentOpaqueEdgesAndExportDimensions() throws {
        let source = fixture(noisy: true)
        var recipe = RecipeAdjustment()
        for parameter in detailParameters { recipe[parameter] = 65 }
        let output = recipe.applying(to: source)
        #expect(output.extent == source.extent)
        let rendered = pixels(output)
        #expect(rendered.allSatisfy { $0.isFinite })
        #expect(stride(from: 3, to: rendered.count, by: 4).allSatisfy { abs(rendered[$0] - 1) < 0.001 })
        let bitmap = try #require(CIContext().createCGImage(source, from: source.extent))
        let original = try #require(UIImage(cgImage: bitmap).pngData())
        let exported = try PhotoProcessor().render(original, style: StyleAdjustment(recipe: recipe))
        #expect(exported.width == 256 && exported.height == 256)
        #expect(!exported.data.isEmpty && !exported.thumbnail.isEmpty)
    }

    @Test func zeroDetailSettingsPreserveImageIdentity() {
        let source = fixture(noisy: true)
        var recipe = RecipeAdjustment()
        for parameter in detailParameters { recipe[parameter] = 0 }
        #expect(recipe.applying(to: source) === source)
    }

    private func adjust(_ parameter: AdjustmentParameter, _ value: Int, _ image: CIImage) -> CIImage {
        var recipe = RecipeAdjustment(); recipe[parameter] = value
        return recipe.applying(to: image)
    }

    private func fixture(noisy: Bool) -> CIImage {
        var data = [UInt8](repeating: 255, count: 256 * 256 * 4)
        for y in 0..<256 {
            for x in 0..<256 {
                let noise = noisy ? Double((x * 37 + y * 71 + x * y * 13) % 17 - 8) / 255 : 0
                let value = UInt8((0.45 + 0.12 * tanh(Double(x - 128) / 8) + noise) * 255)
                let index = (y * 256 + x) * 4
                data[index] = value; data[index + 1] = value; data[index + 2] = value
            }
        }
        return CIImage(bitmapData: Data(data), bytesPerRow: 256 * 4,
                       size: CGSize(width: 256, height: 256), format: .RGBA8,
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }

    private func pixels(_ image: CIImage) -> [Float] {
        var result = [Float](repeating: 0, count: 256 * 256 * 4)
        let context = CIContext(options: [.useSoftwareRenderer: true])
        result.withUnsafeMutableBytes { buffer in
            context.render(image, toBitmap: buffer.baseAddress!, rowBytes: 256 * 16,
                           bounds: image.extent, format: .RGBAf,
                           colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        return result
    }

    private func horizontalEnergy(_ pixels: [Float]) -> Double {
        var total = 0.0
        // Flat interior region: measure fine noise/texture, not the major edge.
        for y in 16..<112 {
            for x in 16..<112 {
                let index = (y * 256 + x) * 4
                let delta = Double(pixels[index] - pixels[index + 4])
                total += delta * delta
            }
        }
        return total
    }
}
