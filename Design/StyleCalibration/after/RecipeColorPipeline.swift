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

    // A soft color-range mask, not face detection. Warm wood and orange objects
    // can also match; attenuation is partial and never changes negative saturation.
    static let skinMaskKernel = CIColorKernel(source: """
        kernel vec4 skinMask(__sample sample) {
            vec3 c = unpremultiply(sample).rgb;
            float hi = max(c.r, max(c.g, c.b));
            float lo = min(c.r, min(c.g, c.b));
            float chroma = hi - lo;
            float saturation = chroma / max(hi, 0.0001);
            float hue = (c.g - c.b) / max(chroma, 0.0001) / 6.0;
            float redDominant = smoothstep(-0.005, 0.025,
                (c.r - max(c.g, c.b)) / max(hi, 0.0001));
            float light = dot(c, vec3(0.2126, 0.7152, 0.0722));
            float mask = redDominant * smoothstep(-0.015, 0.035, hue)
                * (1.0 - smoothstep(0.10, 0.17, hue))
                * smoothstep(0.06, 0.18, saturation)
                * (1.0 - smoothstep(0.65, 0.90, saturation))
                * smoothstep(0.025, 0.10, light)
                * (1.0 - smoothstep(0.85, 0.98, light));
            return vec4(vec3(mask), 1.0);
        }
        """)

    static let shoulderKernel = CIColorKernel(source: """
        kernel vec4 shoulder(__sample sample, float knee, float strength, float usePeak) {
            vec4 c = unpremultiply(sample);
            float light = mix(dot(c.rgb, vec3(0.2126, 0.7152, 0.0722)),
                max(c.r, max(c.g, c.b)), usePeak);
            float excess = max(light - knee, 0.0);
            float mapped = knee + excess / (1.0 + strength * excess);
            float scale = light > knee ? mapped / max(light, 0.0001) : 1.0;
            return premultiply(vec4(c.rgb * scale, c.a));
        }
        """)

    static let shadowDenoiseKernel = CIColorKernel(source: """
        kernel vec4 shadowDenoise(__sample original, __sample filtered, __sample blurred,
                                 float amount, float manual) {
            vec4 c = unpremultiply(original);
            vec3 f = unpremultiply(filtered).rgb;
            vec3 b = unpremultiply(blurred).rgb;
            vec3 weights = vec3(0.2126, 0.7152, 0.0722);
            float y = dot(c.rgb, weights);
            float fy = dot(mix(f, b, 0.25), weights);
            float by = dot(b, weights);
            float dark = 1.0 - smoothstep(0.12, 0.55, y);
            float region = mix(dark, 0.25 + 0.75 * dark, manual);
            // Limit smoothing where the candidate differs across a strong edge.
            float edge = 1.0 - smoothstep(0.025, 0.08, abs(y - by));
            vec3 chromaDelta = (b - vec3(by)) - (c.rgb - vec3(y));
            float colorEdge = 1.0 - smoothstep(0.06, 0.16, length(chromaDelta));
            float chromaMix = amount * region * edge * colorEdge;
            float lumaMix = amount * region * edge * mix(0.40, 0.80, manual);
            vec3 result = c.rgb + vec3((fy - y) * lumaMix) + chromaDelta * chromaMix;
            return premultiply(vec4(max(result, vec3(0.0)), c.a));
        }
        """)

    static let shadowToeKernel = CIColorKernel(source: """
        kernel vec4 shadowToe(__sample mask, __sample source) {
            float y = dot(unpremultiply(source).rgb, vec3(0.2126, 0.7152, 0.0722));
            float toe = 0.25 + 0.75 * smoothstep(0.0, 0.08, y);
            return vec4(mask.rgb * toe, 1.0);
        }
        """)

    // Work on the original signal before exposure and shadow gain amplify noise.
    // Automatic processing is confined to shadows; the explicit slider can also
    // reduce noise in brighter regions. A zero recipe stays an exact bypass.
    static func denoising(_ source: CIImage, amount: Double, shadowLift: Double) -> CIImage {
        let manual = min(1, max(0, amount))
        let strength = max(manual, min(0.60, max(0, shadowLift) * 3.0))
        guard strength > 0 else { return source }
        let perceptual = source.applyingFilter("CILinearToSRGBToneCurve")
        let candidate = perceptual.clampedToExtent().applyingFilter("CINoiseReduction", parameters: [
            "inputNoiseLevel": 0.012 + strength * 0.06,
            "inputSharpness": 0
        ]).cropped(to: source.extent)
        // A narrow chroma neighborhood suppresses colored speckles while the
        // reconstruction keeps most original luminance texture. Pixel-sized noise
        // uses a pixel-sized radius rather than scaling with the export resolution.
        let chroma = perceptual.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [
            kCIInputRadiusKey: 0.8
        ]).cropped(to: source.extent)
        let result = shadowDenoiseKernel?.apply(extent: source.extent, arguments: [
            perceptual, candidate, chroma, strength, manual
        ]) ?? perceptual
        return result.applyingFilter("CISRGBToneCurveToLinear").cropped(to: source.extent)
    }

    static func applying(_ recipe: RecipeAdjustment, to source: CIImage, mapping: Mapping = mapping) -> CIImage {
        let lift = max(0, Double(recipe[.shadows]) / 100 * mapping.shadowEV
            + Double(recipe[.brilliance]) / 100 * mapping.brillianceShadowEV)
        var image = denoising(source, amount: Double(recipe[.noiseReduction]) / 100, shadowLift: lift)
        let needsSkinMask = recipe[.saturation] > 0 || recipe[.vibrance] > 0
            || recipe[.warmth] != 0 || recipe[.tint] != 0
        let skinMask = needsSkinMask ? skinMaskKernel?.apply(extent: source.extent, arguments: [
            source.applyingFilter("CILinearToSRGBToneCurve")
        ]) : nil
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
        if recipe[.brightness] != 0 {
            image = image.applyingFilter("CILinearToSRGBToneCurve").applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: Double(recipe[.brightness]) / 400
            ]).applyingFilter("CISRGBToneCurveToLinear")
        }
        if recipe[.saturation] != 0 {
            // Keep -100 saturation a complete desaturation, with a gentler
            // positive range. Brilliance never silently adds saturation.
            let saturation = Double(recipe[.saturation]) / 100
            let colored = image.applyingFilter("CILinearToSRGBToneCurve").applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: 1,
                kCIInputBrightnessKey: 0,
                kCIInputSaturationKey: 1 + saturation * (saturation > 0 ? mapping.saturation : 1)
            ]).applyingFilter("CISRGBToneCurveToLinear")
            image = saturation > 0 ? protectColor(colored, original: image, mask: skinMask) : colored
        }
        if recipe[.vibrance] != 0 {
            let colored = image.applyingFilter("CIVibrance", parameters: ["inputAmount": Double(recipe[.vibrance]) / 100])
            image = recipe[.vibrance] > 0 ? protectColor(colored, original: image, mask: skinMask) : colored
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
            let protected = protectColor(balanced, original: perceptual, mask: skinMask)
            image = blend(protected, over: perceptual, mask: protection).applyingFilter("CISRGBToneCurveToLinear")
        }
        // Reserve a small, smooth shoulder after color shifts as well. Scale all
        // channels together to avoid clipping red first or tinting neutral whites.
        if highlights < 0 || brilliance > 0 {
            let knee = 0.96 - min(1, max(-highlights, brilliance)) * 0.06
            let perceptual = image.applyingFilter("CILinearToSRGBToneCurve")
            image = shoulder(perceptual, knee: knee, strength: 1 / (1 - knee), usePeak: true)
                .applyingFilter("CISRGBToneCurveToLinear")
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
        var shadowMask = polynomial(regional, coefficients: CIVector(x: 1, y: -2, z: 1, w: 0))
        let highlightMask = polynomial(regional, coefficients: CIVector(x: 0, y: 0, z: 1, w: 0))
        var shadowGain = pow(2, shadows * mapping.shadowEV + brilliance * mapping.brillianceShadowEV)
        if shadowGain > 1 {
            // More useful separation in ordinary shadows, bounded at the existing
            // combined maximum. Fade the lift near black rather than lifting noise
            // at the floor as strongly as recoverable shadow detail.
            let delta = shadowGain - 1
            shadowGain += 0.15 * delta * max(0, 1 - delta / (pow(2, 1.9) - 1))
            shadowMask = shadowToeKernel?.apply(extent: extent, arguments: [shadowMask, perceptual]) ?? shadowMask
        }
        let highlightGain = pow(2, highlights * 0.8 - brilliance * mapping.brillianceHighlightEV)
        var image = blend(gain(perceptual, shadowGain), over: perceptual, mask: shadowMask)
        if highlightGain < 1 {
            // Continuous value and slope at the knee, with a positive slope at
            // every brightness. The old quadratic gain could reverse a ramp
            // when highlights and brilliance were both pushed to their limits.
            let knee = min(0.35, highlightGain * 0.8)
            let strength = 1 / (highlightGain - knee) - 1 / (1 - knee)
            image = shoulder(image, knee: knee, strength: strength, usePeak: false)
        } else {
            image = blend(gain(image, highlightGain), over: image, mask: highlightMask)
        }
        return image.applyingFilter("CISRGBToneCurveToLinear").cropped(to: extent)
    }

    private static func shoulder(_ image: CIImage, knee: Double, strength: Double, usePeak: Bool) -> CIImage {
        shoulderKernel?.apply(extent: image.extent, arguments: [image, knee, strength, usePeak ? 1.0 : 0.0]) ?? image
    }

    private static func protectColor(_ colored: CIImage, original: CIImage, mask: CIImage?) -> CIImage {
        guard let mask else { return colored }
        // Retain 45% of the intended color change even at the center of the mask.
        let reduced = mask.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.55, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0.55, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0.55, w: 0)
        ])
        return blend(original, over: colored, mask: reduced)
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
