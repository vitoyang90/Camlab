import Foundation

/// Stable identifiers keep the selected built-in style across launches.
/// Recipes share the same processing path as the viewfinder and saved photo.
nonisolated enum ShootingStyle: Int, CaseIterable, Identifiable, Sendable {
    case vintage = 1, film = 2, japanese = 3, cinema = 4, mono = 5, portrait = 6
    case sunset = 7, cool = 8, vivid = 9, faded = 10, street = 11, cafe = 12

    var id: UUID {
        UUID(uuidString: String(format: "CAAB0000-0000-4000-8000-%012d", rawValue))!
    }

    var name: String {
        switch self {
        case .vintage: "復古"
        case .film: "暖調底片"
        case .japanese: "日系清透"
        case .cinema: "電影"
        case .mono: "經典黑白"
        case .portrait: "柔光人像"
        case .sunset: "夕陽"
        case .cool: "冷調"
        case .vivid: "鮮明"
        case .faded: "霧感"
        case .street: "城市街拍"
        case .cafe: "咖啡暖棕"
        }
    }

    var detail: String {
        switch self {
        case .vintage: "褪色暖調與淡黑位，留下懷舊日常"
        case .film: "琥珀暖色與柔和亮部，適合生活紀錄"
        case .japanese: "明亮低對比，適合晴天與清新小物"
        case .cinema: "冷色低彩度與深邃暗部，營造電影感"
        case .mono: "純粹黑白與鮮明層次，突出光影輪廓"
        case .portrait: "柔和反差與微暖膚色，適合窗邊人像"
        case .sunset: "金色暖光與豐富色彩，留住黃昏氣氛"
        case .cool: "乾淨偏藍色調，適合海邊與建築"
        case .vivid: "飽滿色彩與清楚層次，適合風景美食"
        case .faded: "低彩度與輕盈灰階，呈現安靜霧感"
        case .street: "俐落反差與沉穩色彩，適合都市街景"
        case .cafe: "濃暖棕調與深色邊緣，適合咖啡與木質空間"
        }
    }

    var symbol: String {
        switch self {
        case .vintage: "camera"
        case .film: "film"
        case .japanese: "leaf"
        case .cinema: "film.stack"
        case .mono: "circle.lefthalf.filled"
        case .portrait: "person.crop.square"
        case .sunset: "sun.horizon"
        case .cool: "snowflake"
        case .vivid: "paintpalette"
        case .faded: "cloud.fog"
        case .street: "building.2"
        case .cafe: "cup.and.saucer"
        }
    }

    // First multi-scene review: Design/StyleCalibration/comparison.html.
    // Keep values in the existing recipe format so saved custom recipes are unchanged.
    var adjustment: RecipeAdjustment {
        let values: [AdjustmentParameter: Int]
        switch self {
        case .vintage:
            values = [.warmth: 28, .tint: 4, .saturation: -22, .blackPoint: -24, .highlights: -18, .contrast: 8, .shadows: 8, .vignette: 12]
        case .film:
            values = [.warmth: 18, .tint: 4, .saturation: -10, .blackPoint: -12, .highlights: -22, .contrast: 12, .shadows: 6]
        case .japanese:
            values = [.exposure: 4, .brightness: 4, .contrast: -14, .shadows: 12, .saturation: -10, .warmth: -4, .highlights: -20]
        case .cinema:
            values = [.warmth: -18, .tint: -4, .saturation: -18, .contrast: 22, .blackPoint: 10, .highlights: -24, .shadows: 14, .vignette: 16]
        case .mono:
            values = [.saturation: -100, .contrast: 22, .blackPoint: 6, .highlights: -18, .shadows: 18]
        case .portrait:
            values = [.warmth: 6, .tint: 4, .contrast: -12, .highlights: -18, .shadows: 16, .saturation: -4, .brightness: 3]
        case .sunset:
            values = [.warmth: 32, .tint: 6, .vibrance: 12, .saturation: 4, .highlights: -24, .contrast: 8, .shadows: 6]
        case .cool:
            values = [.warmth: -26, .contrast: 6, .brightness: 2, .vibrance: 6, .highlights: -14, .shadows: 6]
        case .vivid:
            values = [.saturation: 18, .vibrance: 16, .contrast: 14, .blackPoint: 4, .highlights: -22, .shadows: 8]
        case .faded:
            values = [.saturation: -24, .contrast: -16, .blackPoint: -26, .highlights: -16, .warmth: -4, .brightness: 2, .shadows: 4]
        case .street:
            values = [.contrast: 28, .blackPoint: 14, .saturation: -14, .warmth: -6, .highlights: -20, .shadows: 12]
        case .cafe:
            values = [.warmth: 30, .tint: 4, .saturation: -16, .contrast: 16, .blackPoint: 6, .highlights: -22, .shadows: 10, .vignette: 18]
        }
        var result = RecipeAdjustment()
        for (parameter, value) in values { result[parameter] = value }
        return result
    }

    var recipe: PhotoRecipe { PhotoRecipe(id: id, name: name, adjustment: adjustment) }
    static let recipes = allCases.map(\.recipe)
}
