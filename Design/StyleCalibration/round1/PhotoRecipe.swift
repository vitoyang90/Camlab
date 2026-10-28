import CoreImage
import Foundation
import Observation

nonisolated enum AdjustmentParameter: String, CaseIterable, Identifiable, Codable, Sendable {
    case exposure, brilliance, highlights, shadows, contrast, brightness, blackPoint
    case saturation, vibrance, warmth, tint
    case sharpness, definition, noiseReduction, vignette
    var id: String { rawValue }
    var title: String {
        switch self {
        case .exposure: "曝光"
        case .brilliance: "增艷"
        case .highlights: "亮部"
        case .shadows: "陰影"
        case .contrast: "對比"
        case .brightness: "亮度"
        case .blackPoint: "黑點"
        case .saturation: "飽和度"
        case .vibrance: "自然飽和度"
        case .warmth: "色溫"
        case .tint: "色調"
        case .sharpness: "銳利度"
        case .definition: "清晰度"
        case .noiseReduction: "降低雜點"
        case .vignette: "暈邊"
        }
    }
    var range: ClosedRange<Int> {
        switch self {
        case .sharpness, .definition, .noiseReduction: 0...100
        default: -100...100
        }
    }
}

/// Tutorial-style integer values. Core Image mapping is Camlab's approximation,
/// not a reproduction of Apple's private Photos processing algorithm.
nonisolated struct RecipeAdjustment: Codable, Equatable, Sendable {
    private(set) var values: [String: Int] = [:]

    subscript(_ parameter: AdjustmentParameter) -> Int {
        get { values[parameter.rawValue] ?? 0 }
        set {
            let value = min(parameter.range.upperBound, max(parameter.range.lowerBound, newValue))
            if value == 0 { values.removeValue(forKey: parameter.rawValue) }
            else { values[parameter.rawValue] = value }
        }
    }

    func validated() throws -> Self {
        for (key, value) in values {
            guard let parameter = AdjustmentParameter(rawValue: key), parameter.range.contains(value) else {
                throw CameraFailure("配方包含不支援或超出範圍的調色數值。")
            }
        }
        return self
    }

    static func integer(_ text: String, parameter: AdjustmentParameter) throws -> Int {
        guard let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              parameter.range.contains(value) else {
            throw CameraFailure("\(parameter.title)請輸入 \(parameter.range.lowerBound) 至 \(parameter.range.upperBound) 的整數。")
        }
        return value
    }

    func applying(to source: CIImage) -> CIImage {
        guard AdjustmentParameter.allCases.contains(where: { self[$0] != 0 }) else { return source }
        var image = RecipeColorPipeline.applying(self, to: source)
        // Spatial filters use extended edge pixels to avoid dark/transparent
        // borders. Scale detail radii with image size for preview/export parity.
        let extent = source.extent
        let detailScale = max(0.1, min(extent.width, extent.height) / 1080)
        if self[.noiseReduction] > 0 {
            image = image.clampedToExtent().applyingFilter("CINoiseReduction", parameters: [
                "inputNoiseLevel": Double(self[.noiseReduction]) / 100 * 0.08,
                "inputSharpness": 0
            ]).cropped(to: extent)
        }
        if self[.definition] > 0 {
            // Broad local contrast gives structure without duplicating the
            // fine-edge sharpening control.
            image = image.clampedToExtent().applyingFilter("CIUnsharpMask", parameters: [
                kCIInputRadiusKey: 10 * detailScale,
                kCIInputIntensityKey: Double(self[.definition]) / 100 * 0.7
            ]).cropped(to: extent)
        }
        if self[.sharpness] > 0 {
            image = image.clampedToExtent().applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: Double(self[.sharpness]) / 100 * 1.5,
                kCIInputRadiusKey: 1.5 * detailScale
            ]).cropped(to: extent)
        }
        if self[.vignette] != 0 {
            // An explicit radial mask supports both dark and light vignettes,
            // including images whose Core Image extent has a nonzero origin.
            let amount = Double(self[.vignette]) / 100
            let mask = CIFilter(name: "CIRadialGradient", parameters: [
                kCIInputCenterKey: CIVector(x: extent.midX, y: extent.midY),
                "inputRadius0": min(extent.width, extent.height) * 0.3,
                "inputRadius1": hypot(extent.width, extent.height) * 0.5,
                "inputColor0": CIColor(red: 0, green: 0, blue: 0),
                "inputColor1": CIColor(red: abs(amount) * 0.85, green: abs(amount) * 0.85, blue: abs(amount) * 0.85)
            ])!.outputImage!.cropped(to: extent)
            let edgeColor = CIImage(color: amount > 0 ? .black : .white).cropped(to: extent)
            image = edgeColor.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: image,
                kCIInputMaskImageKey: mask
            ])
        }
        return image.cropped(to: extent)
    }
}

nonisolated struct PhotoRecipe: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var adjustment: RecipeAdjustment
}

@MainActor @Observable
final class RecipeStore {
    private struct Archive: Codable {
        var version = 1
        var recipes: [PhotoRecipe]
        var selectedID: UUID?
    }
    private let defaults: UserDefaults
    private let key = "Camlab.Recipes.v1"
    private(set) var recipes: [PhotoRecipe] = []
    private(set) var selectedID: UUID?
    var draft = RecipeAdjustment()
    private(set) var loadError: String?
    var selected: PhotoRecipe? { (recipes + ShootingStyle.recipes).first { $0.id == selectedID } }
    var selectedStyle: ShootingStyle? { ShootingStyle.allCases.first { $0.id == selectedID } }
    var canUpdate: Bool { recipes.contains { $0.id == selectedID } }
    var name: String { selected?.name ?? "原色" }
    var isModified: Bool { draft != (selected?.adjustment ?? RecipeAdjustment()) }
    var style: StyleAdjustment { StyleAdjustment(recipe: draft, recipeName: name) }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: key) else { return }
        do {
            let archive = try JSONDecoder().decode(Archive.self, from: data)
            guard archive.version == 1, Set(archive.recipes.map(\.id)).count == archive.recipes.count else {
                throw CameraFailure("配方資料版本不符或包含重複項目。")
            }
            for recipe in archive.recipes { _ = try recipe.adjustment.validated() }
            recipes = archive.recipes
            selectedID = (recipes + ShootingStyle.recipes).contains { $0.id == archive.selectedID } ? archive.selectedID : nil
            draft = selected?.adjustment ?? RecipeAdjustment()
        } catch { loadError = "無法讀取保存的配方：\(error.localizedDescription)" }
    }

    func select(_ id: UUID?) throws {
        guard id == nil || (recipes + ShootingStyle.recipes).contains(where: { $0.id == id }) else { throw CameraFailure("找不到這份配方。") }
        selectedID = id
        draft = selected?.adjustment ?? RecipeAdjustment()
        try persist()
    }

    @discardableResult
    func saveNew(name: String) throws -> PhotoRecipe {
        let recipe = try PhotoRecipe(name: validName(name), adjustment: draft.validated())
        recipes.append(recipe)
        selectedID = recipe.id
        try persist()
        return recipe
    }

    func update() throws {
        guard let index = recipes.firstIndex(where: { $0.id == selectedID }) else {
            throw CameraFailure("內建風格與原色不能覆寫，請另存新配方。")
        }
        recipes[index].adjustment = try draft.validated()
        try persist()
    }

    func rename(_ id: UUID, name: String) throws {
        let name = try validName(name, excluding: id)
        guard let index = recipes.firstIndex(where: { $0.id == id }) else { throw CameraFailure("找不到這份配方。") }
        recipes[index].name = name
        try persist()
    }

    func delete(_ id: UUID) throws {
        guard recipes.contains(where: { $0.id == id }) else { throw CameraFailure("內建風格不能刪除。") }
        recipes.removeAll { $0.id == id }
        if selectedID == id { selectedID = nil; draft = RecipeAdjustment() }
        try persist()
    }

    private func validName(_ text: String, excluding id: UUID? = nil) throws -> String {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40, name != "原色" else {
            throw CameraFailure("配方名稱請使用 1 至 40 個字，且不能命名為原色。")
        }
        guard !(recipes + ShootingStyle.recipes).contains(where: { $0.id != id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            throw CameraFailure("已有同名配方，請使用其他名稱。")
        }
        return name
    }

    private func persist() throws {
        defaults.set(try JSONEncoder().encode(Archive(recipes: recipes, selectedID: selectedID)), forKey: key)
    }
}
