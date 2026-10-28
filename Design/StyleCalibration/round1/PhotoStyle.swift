import CoreImage
import Foundation

nonisolated enum PhotoStyle: String, CaseIterable, Identifiable, Sendable {
    case natural = "自然", vivid = "鮮明", warm = "暖色", cool = "冷色", mono = "黑白"
    case soft = "柔光人像", film = "暖調底片", cinema = "冷調電影"
    var id: String { rawValue }
    var adjustment: StyleAdjustment {
        switch self {
        case .natural: StyleAdjustment()
        case .vivid: StyleAdjustment(contrast: 1.18, saturation: 1.3)
        case .warm: StyleAdjustment(warmth: 45)
        case .cool: StyleAdjustment(warmth: -45)
        case .mono: StyleAdjustment(contrast: 1.12, saturation: 0)
        case .soft: StyleAdjustment(contrast: 0.96, saturation: 0.95, warmth: 8, highlightSoftness: 0.45, shadowLift: 0.25)
        case .film: StyleAdjustment(contrast: 1.04, saturation: 0.9, warmth: 22, highlightSoftness: 0.5, shadowLift: 0.55, vignette: 0.12)
        case .cinema: StyleAdjustment(contrast: 1.1, saturation: 0.85, warmth: -16, highlightSoftness: 0.35, shadowLift: 0.2, vignette: 0.18)
        }
    }

    var detail: String {
        switch self {
        case .natural: "保留原色，適合日常紀錄"
        case .vivid: "提升色彩與對比，適合風景、美食"
        case .warm: "溫暖色調，適合餐桌與室內光線"
        case .cool: "清爽冷色，適合城市與建築"
        case .mono: "黑白層次，適合街拍與光影"
        case .soft: "柔和亮部與淡雅色彩，適合人像"
        case .film: "暖調、淡黑位與輕微暗角，適合生活片段"
        case .cinema: "偏冷低彩度與較深對比，適合城市夜景"
        }
    }
}

nonisolated enum ShootingScene: String, CaseIterable, Identifiable, Sendable {
    case everyday = "日常", portrait = "人像", food = "美食", landscape = "風景", night = "夜景", all = "全部"
    var id: String { rawValue }
    var styles: [PhotoStyle] {
        switch self {
        case .everyday: [.natural, .film, .warm]
        case .portrait: [.soft, .warm, .mono]
        case .food: [.warm, .vivid, .film]
        case .landscape: [.natural, .vivid, .cool, .cinema]
        case .night: [.cinema, .mono, .film]
        case .all: PhotoStyle.allCases
        }
    }
    var tip: String {
        switch self {
        case .everyday: "選定主角，讓背景簡潔；窗邊光線適合日常紀錄。"
        case .portrait: "讓人物面向柔和光源，避免頂光；用主鏡頭保留細節。"
        case .food: "靠近窗邊拍攝，讓光線從側面照入，呈現食物層次。"
        case .landscape: "打開九宮格安排地平線，讓天空和地景各有空間。"
        case .night: "保持手機穩定；若招牌或路燈太亮，可試著降低曝光。"
        case .all: "切換風格觀察光影與色彩，再用強度調到喜歡的程度。"
        }
    }
}

nonisolated struct StyleAdjustment: Equatable, Sendable {
    var contrast = 1.0
    var saturation = 1.0
    var warmth = 0.0
    var highlightSoftness = 0.0
    var shadowLift = 0.0
    var vignette = 0.0
    var intensity = 1.0
    var recipe: RecipeAdjustment?
    var recipeName: String?

    var name: String {
        if let recipeName { return recipeName }
        var base = self
        base.intensity = 1
        return PhotoStyle.allCases.first { $0.adjustment == base }?.rawValue ?? "自訂"
    }

    func applying(to source: CIImage) -> CIImage {
        if let recipe { return recipe.applying(to: source) }
        guard intensity > 0 else { return source }
        if contrast == 1, saturation == 1, warmth == 0,
           highlightSoftness == 0, shadowLift == 0, vignette == 0 { return source }
        let colored = source.applyingFilter("CIColorControls", parameters: [
            kCIInputContrastKey: contrast, kCIInputSaturationKey: saturation
        ])
        let strength = warmth / 100
        var styled = colored.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1 + 0.16 * strength, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 1 + 0.03 * strength, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 1 - 0.16 * strength, w: 0)
        ])
        if highlightSoftness > 0 || shadowLift > 0 {
            styled = styled.applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0, y: shadowLift * 0.06),
                "inputPoint1": CIVector(x: 0.25, y: 0.25 + shadowLift * 0.025),
                "inputPoint2": CIVector(x: 0.5, y: 0.5),
                "inputPoint3": CIVector(x: 0.75, y: 0.75 - highlightSoftness * 0.045),
                "inputPoint4": CIVector(x: 1, y: 1 - highlightSoftness * 0.075)
            ])
        }
        if vignette > 0 {
            styled = styled.applyingFilter("CIVignetteEffect", parameters: [
                kCIInputCenterKey: CIVector(x: source.extent.midX, y: source.extent.midY),
                kCIInputRadiusKey: min(source.extent.width, source.extent.height) * 0.7,
                kCIInputIntensityKey: vignette
            ])
        }
        if intensity < 1 {
            styled = source.applyingFilter("CIDissolveTransition", parameters: [
                kCIInputTargetImageKey: styled, kCIInputTimeKey: intensity
            ])
        }
        return styled.cropped(to: source.extent)
    }
}

nonisolated struct StyleDraft: Sendable {
    var contrast = "1"
    var saturation = "1"
    var warmth = "0"
    var highlightSoftness = 0.0
    var shadowLift = 0.0
    var vignette = 0.0
    var intensity = 1.0

    init(_ adjustment: StyleAdjustment = StyleAdjustment()) {
        contrast = CameraSettings.format(adjustment.contrast)
        saturation = CameraSettings.format(adjustment.saturation)
        warmth = CameraSettings.format(adjustment.warmth)
        highlightSoftness = adjustment.highlightSoftness
        shadowLift = adjustment.shadowLift
        vignette = adjustment.vignette
        intensity = adjustment.intensity
    }

    func validated() throws -> StyleAdjustment {
        try StyleAdjustment(
            contrast: CameraSettings.number(contrast, name: "對比", range: 0.5...2),
            saturation: CameraSettings.number(saturation, name: "飽和度", range: 0...2),
            warmth: CameraSettings.number(warmth, name: "冷暖", range: -100...100),
            highlightSoftness: CameraSettings.number(String(highlightSoftness), name: "亮部柔化", range: 0...1),
            shadowLift: CameraSettings.number(String(shadowLift), name: "暗部層次", range: 0...1),
            vignette: CameraSettings.number(String(vignette), name: "暗角", range: 0...1),
            intensity: CameraSettings.number(String(intensity), name: "風格強度", range: 0...1)
        )
    }
}
