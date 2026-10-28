import Foundation

nonisolated struct CameraCapabilities: Sendable {
    var iso: ClosedRange<Double>
    var shutter: ClosedRange<Double>
    var zoom: ClosedRange<Double>
    var manualExposure: Bool
    var manualFocus: Bool
    var manualWhiteBalance: Bool
    var exposureBias: ClosedRange<Double> = -3...3
    var automaticExposure: Bool = true
    var zoomPresets: [Double] = [1, 2]
}

nonisolated struct CameraSettings: Sendable {
    var automaticExposure = true
    var automaticFocus = true
    var automaticWhiteBalance = true
    var iso = "100"
    var shutter = "1/125"
    var focus = "0.5"
    var temperature = "5000"
    var tint = "0"
    var zoom = "1"
    var exposureBias = "0"

    func validated(for capabilities: CameraCapabilities) throws -> ValidatedSettings {
        let exposure = !automaticExposure && capabilities.manualExposure
        let manualFocus = !automaticFocus && capabilities.manualFocus
        let whiteBalance = !automaticWhiteBalance && capabilities.manualWhiteBalance
        return try ValidatedSettings(
            iso: exposure ? Self.number(iso, name: "ISO", range: capabilities.iso) : nil,
            shutter: exposure ? Self.exposureSeconds(shutter, range: capabilities.shutter) : nil,
            focus: manualFocus ? Self.number(focus, name: "對焦位置", range: 0...1) : nil,
            temperature: whiteBalance ? Self.number(temperature, name: "色溫", range: 2000...10000) : nil,
            tint: whiteBalance ? Self.number(tint, name: "色調", range: -150...150) : nil,
            zoom: Self.number(zoom, name: "變焦", range: capabilities.zoom),
            exposureBias: automaticExposure && capabilities.automaticExposure
                ? Self.number(exposureBias, name: "曝光補償", range: capabilities.exposureBias) : nil
        )
    }

    static func number(_ text: String, name: String, range: ClosedRange<Double>) throws -> Double {
        guard let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)), value.isFinite else {
            throw CameraFailure("\(name)請輸入有效數字。")
        }
        guard range.contains(value) else {
            throw CameraFailure("\(name)必須介於 \(format(range.lowerBound)) 與 \(format(range.upperBound))。")
        }
        return value
    }

    static func exposureSeconds(_ text: String, range: ClosedRange<Double>) throws -> Double {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        let seconds: Double
        if parts.count == 2,
           let numerator = Double(parts[0].trimmingCharacters(in: .whitespaces)),
           let denominator = Double(parts[1].trimmingCharacters(in: .whitespaces)),
           numerator.isFinite, denominator.isFinite, numerator > 0, denominator > 0 {
            seconds = numerator / denominator
        } else if parts.count == 1, let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            seconds = value
        } else {
            throw CameraFailure("快門請輸入秒數或分數，例如 0.008 或 1/125。")
        }
        guard seconds.isFinite, seconds > 0, range.contains(seconds) else {
            throw CameraFailure("快門必須介於 \(format(range.lowerBound)) 與 \(format(range.upperBound)) 秒。")
        }
        return seconds
    }

    static func format(_ value: Double) -> String {
        String(format: "%.6g", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

nonisolated struct ValidatedSettings: Sendable {
    let iso: Double?
    let shutter: Double?
    let focus: Double?
    let temperature: Double?
    let tint: Double?
    let zoom: Double
    let exposureBias: Double?
}

nonisolated struct CameraFailure: LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
