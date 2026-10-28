import CoreImage
import Foundation
import Testing
@testable import Camlab

@MainActor struct RecipeToneTests {
    private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    @Test func modestContrastRetainsDarkGradations() {
        let source = ramp()
        var recipe = RecipeAdjustment()
        recipe[.contrast] = 15
        let output = pixels(recipe.applying(to: source))
        // Previously +15 turned all of these distinct dark grays into black.
        for value in [16, 32, 48] {
            #expect(output[value * 4] > 0.01)
            #expect(output[value * 4] > output[(value - 8) * 4])
            #expect(output[value * 4] < Float(value) / 255)
        }
        #expect(output[192 * 4] > Float(192) / 255)
    }

    @Test func contrastRangeKeepsEndpointsAndMonotonicRamp() {
        let source = ramp()
        for amount in [-100, -50, 15, 50, 100] {
            var recipe = RecipeAdjustment()
            recipe[.contrast] = amount
            let output = pixels(recipe.applying(to: source))
            #expect(output.allSatisfy { $0.isFinite })
            #expect(abs(output[0]) < 0.001)
            #expect(abs(output[255 * 4] - 1) < 0.001)
            for x in 1..<256 {
                #expect(output[x * 4] >= output[(x - 1) * 4] - 0.0001)
                #expect(abs(output[x * 4] - output[x * 4 + 1]) < 0.001)
                #expect(abs(output[x * 4 + 3] - 1) < 0.001)
            }
        }
    }

    @Test func perceptualSaturationPreservesNeutralRamp() {
        let source = ramp()
        let original = pixels(source)
        for amount in [-100, 25, 100] {
            var recipe = RecipeAdjustment()
            recipe[.saturation] = amount
            let output = pixels(recipe.applying(to: source))
            #expect(zip(original, output).allSatisfy { abs($0 - $1) < 0.002 })
        }
    }

    @Test func nightRecipeRetainsShadowSeparation() {
        var recipe = RecipeAdjustment()
        recipe[.exposure] = 15
        recipe[.brilliance] = 25
        recipe[.shadows] = -30
        recipe[.contrast] = 15
        recipe[.saturation] = 25
        recipe[.warmth] = -30
        recipe[.sharpness] = 10
        recipe[.vignette] = 10
        let output = pixels(recipe.applying(to: ramp()))
        #expect(output.allSatisfy { $0.isFinite })
        for channel in 0..<3 {
            #expect(output[32 * 4 + channel] > 0.01)
            #expect(output[48 * 4 + channel] > output[32 * 4 + channel])
        }
    }

    private func ramp() -> CIImage {
        var bytes = [UInt8]()
        for value in 0...255 { bytes += [UInt8(value), UInt8(value), UInt8(value), 255] }
        return CIImage(bitmapData: Data(bytes), bytesPerRow: 256 * 4,
                       size: CGSize(width: 256, height: 1), format: .RGBA8, colorSpace: srgb)
    }

    private func pixels(_ image: CIImage) -> [Float] {
        var result = [Float](repeating: 0, count: 256 * 4)
        result.withUnsafeMutableBytes { buffer in
            CIContext(options: [.useSoftwareRenderer: true]).render(
                image, toBitmap: buffer.baseAddress!, rowBytes: 256 * 16,
                bounds: image.extent, format: .RGBAf, colorSpace: srgb)
        }
        return result
    }
}
