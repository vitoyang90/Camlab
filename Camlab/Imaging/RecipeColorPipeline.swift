import CoreImage
import Foundation

/// Camlab's measured approximation. These coefficients are not Apple's slider
/// definitions. Regional tone masks depend on both pixel and neighborhood luma.
nonisolated enum RecipeColorPipeline {
    struct Mapping {
        var exposureEV = 1.8
        var contrast = 0.25
        var shadowEV = 1.0
        var brillianceShadowEV = 0.9
        var brillianceHighlightEV = 0.4
        var saturation = 0.6
        var warmthGain = 0.0
        var warmthOffset = 0.08
    }
    static let mapping = Mapping()

    static func applying(_ recipe: RecipeAdjustment, to source: CIImage, mapping: Mapping = mapping) -> CIImage {
        var image = source
        if recipe[.exposure] != 0 {
            image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: Double(recipe[.exposure]) / 100 * mapping.exposureEV])
        }
        let brilliance = Double(recipe[.brilliance]) / 100
        let shadows = Double(recipe[.shadows]) / 100
        let highlights = Double(recipe[.highlights]) / 100
        if brilliance != 0 || shadows != 0 || highlights != 0 {
            image = regionalTone(image, brilliance: brilliance, shadows: shadows, highlights: highlights, mapping: mapping)
        }
        let black = Double(recipe[.blackPoint]) / 100
        if black != 0 {
            image = image.applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0, y: max(0, -black * 0.12)),
                "inputPoint1": CIVector(x: 0.25, y: 0.25 - max(0, black) * 0.1),
                "inputPoint2": CIVector(x: 0.5, y: 0.5),
                "inputPoint3": CIVector(x: 0.75, y: 0.75),
                "inputPoint4": CIVector(x: 1, y: 1)
            ])
        }
        if recipe[.contrast] != 0 {
            let value = Double(recipe[.contrast]) / 100
            // Strengthen ordinary settings without extrapolating the curve
            // past monotonic endpoints at +/-100.
            let response = mapping.contrast / 0.15
            let amount = value * response / (1 + (response - 1) * abs(value))
            image = image.applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0, y: 0),
                "inputPoint1": CIVector(x: 0.25, y: 0.25 - amount * 0.15),
                "inputPoint2": CIVector(x: 0.5, y: 0.5),
                "inputPoint3": CIVector(x: 0.75, y: 0.75 + amount * 0.15),
                "inputPoint4": CIVector(x: 1, y: 1)
            ])
        }
        if recipe[.brightness] != 0 || recipe[.saturation] != 0 {
            // Keep -100 saturation a complete desaturation, with a gentler
            // positive range. Brilliance never silently adds saturation.
            let saturation = Double(recipe[.saturation]) / 100
            image = image.applyingFilter("CILinearToSRGBToneCurve").applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: 1,
                kCIInputBrightnessKey: Double(recipe[.brightness]) / 400,
                kCIInputSaturationKey: 1 + saturation * (saturation > 0 ? mapping.saturation : 1)
            ]).applyingFilter("CISRGBToneCurveToLinear")
        }
        if recipe[.vibrance] != 0 {
            image = image.applyingFilter("CIVibrance", parameters: ["inputAmount": Double(recipe[.vibrance]) / 100])
        }
        if recipe[.warmth] != 0 || recipe[.tint] != 0 {
            let warmth = Double(recipe[.warmth]) / 100
            let tint = Double(recipe[.tint]) / 100
            let perceptual = image.applyingFilter("CILinearToSRGBToneCurve")
            let balanced = perceptual.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1 + warmth * mapping.warmthGain, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 1 - tint * 0.1, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1 - warmth * mapping.warmthGain, w: 0),
                "inputBiasVector": CIVector(x: warmth * mapping.warmthOffset + tint * 0.025,
                                             y: warmth * mapping.warmthOffset * 0.2 - tint * 0.025,
                                             z: -warmth * mapping.warmthOffset + tint * 0.025, w: 0)
            ])
            // Fade chromatic offsets out at black; a color-temperature change
            // must not paint a blue/red floor over true black pixels.
            let protection = luma(perceptual).applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 64, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 64, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 64, w: 0)
            ]).applyingFilter("CIColorClamp")
            image = blend(balanced, over: perceptual, mask: protection).applyingFilter("CISRGBToneCurveToLinear")
        }
        return image.cropped(to: source.extent)
    }

    static func regionalTone(_ source: CIImage, brilliance: Double, shadows: Double, highlights: Double, mapping: Mapping = mapping) -> CIImage {
        let extent = source.extent
        let perceptual = source.applyingFilter("CILinearToSRGBToneCurve")
        let luminance = luma(perceptual).applyingFilter("CIColorClamp")
        let surround = luminance.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [
            kCIInputRadiusKey: max(0.5, min(extent.width, extent.height) * 0.015)
        ]).cropped(to: extent)
        // Most weight remains at the current pixel, limiting halos across edges.
        let regional = luminance.applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: surround, kCIInputTimeKey: 0.2
        ])
        let shadowMask = polynomial(regional, coefficients: CIVector(x: 1, y: -2, z: 1, w: 0))
        let highlightMask = polynomial(regional, coefficients: CIVector(x: 0, y: 0, z: 1, w: 0))
        let shadowGain = pow(2, shadows * mapping.shadowEV + brilliance * mapping.brillianceShadowEV)
        let highlightGain = pow(2, highlights * 0.8 - brilliance * mapping.brillianceHighlightEV)
        var image = blend(gain(perceptual, shadowGain), over: perceptual, mask: shadowMask)
        image = blend(gain(image, highlightGain), over: image, mask: highlightMask)
        return image.applyingFilter("CISRGBToneCurveToLinear").cropped(to: extent)
    }

    private static func luma(_ image: CIImage) -> CIImage {
        let weights = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": weights, "inputGVector": weights, "inputBVector": weights
        ])
    }
    private static func gain(_ image: CIImage, _ value: Double) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: value, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: value, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: value, w: 0)
        ])
    }
    private static func polynomial(_ image: CIImage, coefficients: CIVector) -> CIImage {
        image.applyingFilter("CIColorPolynomial", parameters: [
            "inputRedCoefficients": coefficients, "inputGreenCoefficients": coefficients,
            "inputBlueCoefficients": coefficients
        ]).applyingFilter("CIColorClamp")
    }
    private static func blend(_ image: CIImage, over background: CIImage, mask: CIImage) -> CIImage {
        image.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: background, kCIInputMaskImageKey: mask])
    }
}
