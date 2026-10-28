import CoreImage
import Foundation
import Testing
@testable import Camlab

@MainActor struct RecipeRegionalTests {
    private let context = CIContext(options: [.useSoftwareRenderer: true])
    private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    @Test func shadowLiftKeepsBlackAndSeparatesUsefulDarkSteps() {
        #expect(RecipeColorPipeline.shadowToeKernel != nil)
        let source = grayRamp(height: 32)
        for amount in [20, 60, 100] {
            var recipe = RecipeAdjustment(); recipe[.shadows] = amount; recipe[.brilliance] = amount
            let output = recipe.applying(to: source)
            #expect(abs(pixel(output, x: 0, y: 16)[0]) < 0.001)
            #expect(pixel(output, x: 32, y: 16)[0] > pixel(source, x: 32, y: 16)[0])
            #expect(pixel(output, x: 48, y: 16)[0] > pixel(output, x: 32, y: 16)[0])
            var previous: Float = 0
            for x in 0..<256 {
                let current = pixel(output, x: x, y: 16)[0]
                #expect(current.isFinite && current >= previous - 0.0002)
                previous = current
            }
        }
    }

    @Test func protectionKernelsCompileAndWarmColorsKeepMoreOfTheirOriginalHue() throws {
        #expect(RecipeColorPipeline.skinMaskKernel != nil)
        #expect(RecipeColorPipeline.shoulderKernel != nil)
        // Synthetic warm patches at several brightnesses, not a skin dataset.
        for color: [UInt8] in [[68, 43, 31], [140, 94, 69], [220, 168, 135]] {
            let source = patch(color)
            var warm = RecipeAdjustment(); warm[.warmth] = 50
            let before = pixel(source, x: 0), after = pixel(warm.applying(to: source), x: 0)
            // Unprotected +50 adds .04 red and subtracts .04 blue in sRGB.
            #expect(after[0] > before[0])
            #expect(after[0] - before[0] < 0.035)
            #expect(before[2] - after[2] < 0.035)
        }
        var warm = RecipeAdjustment(); warm[.warmth] = 50
        let blue = patch([60, 110, 180])
        #expect(abs(pixel(warm.applying(to: blue), x: 0)[0] - pixel(blue, x: 0)[0] - 0.04) < 0.003)
    }

    @Test func highlightCompressionNeverReversesTheGrayRamp() {
        let source = grayRamp(height: 32)
        for highlights in [-20, -60, -100] { for brilliance in [0, 100] {
            var recipe = RecipeAdjustment()
            recipe[.highlights] = highlights; recipe[.brilliance] = brilliance
            let result = recipe.applying(to: source)
            var previous: Float = -1
            for x in 0..<256 {
                let value = pixel(result, x: x, y: 16)
                #expect(value.allSatisfy { $0.isFinite })
                #expect(value[0] >= previous - 0.0001)
                #expect(abs(value[0] - value[1]) < 0.002 && abs(value[1] - value[2]) < 0.002)
                previous = value[0]
            }
            #expect(pixel(result, x: 250, y: 16)[0] > pixel(result, x: 240, y: 16)[0])
        }}
    }

    @Test func shoulderHasNoKneeJumpPreservesColorRatiosAndAlpha() throws {
        let kernel = try #require(RecipeColorPipeline.shoulderKernel)
        let source = grayRamp().applyingFilter("CILinearToSRGBToneCurve")
        let result = try #require(kernel.apply(extent: source.extent, arguments: [source, 0.8, 5.0, 1.0]))
            .applyingFilter("CISRGBToneCurveToLinear")
        for x in 198...210 {
            let delta = pixel(result, x: x)[0] - pixel(result, x: x-1)[0]
            #expect(delta > 0 && delta < 0.0042)
        }
        let color = patch([250, 220, 170]).applyingFilter("CILinearToSRGBToneCurve")
        let compressed = try #require(kernel.apply(extent: color.extent, arguments: [color, 0.8, 5.0, 1.0]))
            .applyingFilter("CISRGBToneCurveToLinear")
        let rgb = pixel(compressed, x: 0)
        #expect(rgb[0] < 250.0 / 255)
        #expect(abs(rgb[0] / rgb[1] - 250.0 / 220) < 0.003)
        #expect(abs(rgb[1] / rgb[2] - 220.0 / 170) < 0.003)
        #expect(abs(rgb[3] - 1) < 0.001)
    }

    @Test func protectedColorsStillFullyDesaturateAndNeutralRecipeIsIdentity() {
        let source = patch([180, 125, 93])
        #expect(RecipeAdjustment().applying(to: source) === source)
        var recipe = RecipeAdjustment(); recipe[.saturation] = -100
        let rgb = pixel(recipe.applying(to: source), x: 0)
        #expect(abs(rgb[0] - rgb[1]) < 0.002 && abs(rgb[1] - rgb[2]) < 0.002)
    }

    @Test func newColorProcessingMatchesSoftwareAndDefaultRenderers() {
        let colors: [[UInt8]] = [[70, 43, 31], [180, 125, 93], [238, 203, 180],
                                 [255, 250, 245], [128, 128, 128], [30, 100, 240]]
        let bytes: [UInt8] = colors.flatMap { $0 + [UInt8(255)] }
        let source = CIImage(bitmapData: Data(bytes), bytesPerRow: bytes.count,
                             size: CGSize(width: colors.count, height: 1), format: .RGBA8, colorSpace: srgb)
            .transformed(by: CGAffineTransform(translationX: 17, y: 23))
        var recipe = RecipeAdjustment()
        recipe[.warmth] = 40; recipe[.saturation] = 30; recipe[.highlights] = -40
        recipe[.shadows] = 20; recipe[.noiseReduction] = 35
        let result = recipe.applying(to: source)
        #expect(result.extent == source.extent)
        let defaultContext = CIContext()
        for x in 17..<(17 + colors.count) {
            let software = pixel(result, x: x, y: 23)
            var hardware = [Float](repeating: 0, count: 4)
            defaultContext.render(result, toBitmap: &hardware, rowBytes: 16,
                                  bounds: CGRect(x: x, y: 23, width: 1, height: 1), format: .RGBAf, colorSpace: srgb)
            #expect(hardware.allSatisfy { $0.isFinite })
            #expect(zip(software, hardware).allSatisfy { abs($0 - $1) < 0.004 })
            #expect(abs(hardware[3] - 1) < 0.001)
        }
    }

    private func patch(_ color: [UInt8]) -> CIImage {
        CIImage(bitmapData: Data(color + [255]), bytesPerRow: 4,
                size: CGSize(width: 1, height: 1), format: .RGBA8, colorSpace: srgb)
    }

    @Test func sameGrayRespondsToItsNeighborhood() {
        // Two identical small patches embedded in very different surroundings.
        var data = [UInt8](repeating: 255, count: 256 * 128 * 4)
        for y in 0..<128 { for x in 0..<256 {
            let patch = abs(x - 64) <= 2 || abs(x - 192) <= 2
            let value: UInt8 = patch ? 90 : (x < 128 ? 20 : 210)
            let i = (y * 256 + x) * 4
            data[i] = value; data[i+1] = value; data[i+2] = value
        }}
        let source = CIImage(bitmapData: Data(data), bytesPerRow: 256 * 4, size: CGSize(width: 256, height: 128), format: .RGBA8, colorSpace: srgb)
        var recipe = RecipeAdjustment(); recipe[.shadows] = 80
        let result = recipe.applying(to: source)
        let darkSurround = pixel(result, x: 64, y: 64)
        let lightSurround = pixel(result, x: 192, y: 64)
        #expect(darkSurround[0] > lightSurround[0] + 0.002)
    }

    @Test func brillianceLiftsDarkRegionsAndProtectsBrightOnesWithoutColorCast() {
        let source = grayRamp()
        var recipe = RecipeAdjustment(); recipe[.brilliance] = 60
        let result = recipe.applying(to: source)
        #expect(pixel(result, x: 64)[0] > pixel(source, x: 64)[0])
        #expect(pixel(result, x: 220)[0] < pixel(source, x: 220)[0])
        for x in [0, 32, 64, 128, 220, 255] {
            let rgb = pixel(result, x: x)
            #expect(abs(rgb[0] - rgb[1]) < 0.002 && abs(rgb[1] - rgb[2]) < 0.002)
        }
    }

    @Test func warmthMovesInBothDirectionsAndPreservesTrueBlack() {
        let source = grayRamp()
        for amount in [-100, -30, 30, 100] {
            var recipe = RecipeAdjustment(); recipe[.warmth] = amount
            let result = recipe.applying(to: source)
            let mid = pixel(result, x: 128)
            #expect(amount > 0 ? mid[0] > mid[2] : mid[0] < mid[2])
            #expect(pixel(result, x: 0).prefix(3).allSatisfy { abs($0) < 0.001 })
        }
    }

    @Test func regionalEffectsScaleAcrossPreviewAndExportAndKeepEdgesOpaque() {
        let source = grayRamp(height: 128)
        // Clamp before resampling: transparent pixels beyond the source would
        // otherwise get interpolated into the test fixture's outermost pixels.
        let largeExtent = source.extent.applying(CGAffineTransform(scaleX: 4, y: 4))
        let large = source.clampedToExtent().transformed(by: CGAffineTransform(scaleX: 4, y: 4)).cropped(to: largeExtent)
        var recipe = RecipeAdjustment(); recipe[.brilliance] = 45; recipe[.shadows] = -30
        let smallResult = recipe.applying(to: source)
        let fullResult = recipe.applying(to: large)
        for x in [0, 1023] {
            #expect(abs(pixel(fullResult, x: x, y: 256)[3] - 1) < 0.001)
        }
        let largeResult = fullResult.clampedToExtent().transformed(by: CGAffineTransform(scaleX: 0.25, y: 0.25)).cropped(to: source.extent)
        #expect(smallResult.extent == source.extent)
        for x in [0, 32, 64, 128, 192, 255] {
            let a = pixel(smallResult, x: x, y: 64), b = pixel(largeResult, x: x, y: 64)
            #expect(abs(a[0] - b[0]) < 0.015)
            #expect(abs(a[3] - 1) < 0.001 && abs(b[3] - 1) < 0.001)
        }
    }

    @Test func extremeCombinedValuesRemainFiniteOnExtendedRangeInput() {
        let source = CIImage(color: CIColor(red: 1.4, green: 0.2, blue: 0.05))
            .cropped(to: CGRect(x: 11, y: 17, width: 64, height: 64))
        for value in [-100, 100] {
            var recipe = RecipeAdjustment()
            for parameter in [AdjustmentParameter.exposure, .brilliance, .shadows, .highlights, .contrast, .saturation, .warmth, .tint] { recipe[parameter] = value }
            let result = recipe.applying(to: source)
            #expect(result.extent == source.extent)
            #expect(pixel(result, x: 35, y: 40).allSatisfy { $0.isFinite })
        }
    }

    @Test func appDefaultMigratesOnceAndKeepsLaterNativeChoice() throws {
        let name = "Camlab.RegionalTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: PhotoWorkflowPreferences.nativeKey)
        #expect(!PhotoWorkflowPreferences.nativePhotosEnabled(defaults: defaults))
        defaults.set(true, forKey: PhotoWorkflowPreferences.nativeKey)
        #expect(PhotoWorkflowPreferences.nativePhotosEnabled(defaults: defaults))
    }

    private func grayRamp(height: Int = 1) -> CIImage {
        var data = [UInt8]()
        for _ in 0..<height { for x in 0..<256 { data += [UInt8(x), UInt8(x), UInt8(x), 255] } }
        return CIImage(bitmapData: Data(data), bytesPerRow: 256 * 4, size: CGSize(width: 256, height: height), format: .RGBA8, colorSpace: srgb)
    }
    private func pixel(_ image: CIImage, x: Int, y: Int = 0) -> [Float] {
        var data = [Float](repeating: 0, count: 4)
        context.render(image, toBitmap: &data, rowBytes: 16, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf, colorSpace: srgb)
        return data
    }
}
