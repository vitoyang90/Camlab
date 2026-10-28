import Foundation

nonisolated enum CameraLiveAdjustment: Sendable, Equatable {
    case brightness(Double), iso(Double), shutter(Double), focus(Double), temperature(Double), zoom(Double)
    case automaticExposure, automaticFocus, automaticWhiteBalance

    var control: Int {
        switch self {
        case .brightness: 0
        case .iso: 1
        case .shutter: 2
        case .focus, .automaticFocus: 3
        case .temperature, .automaticWhiteBalance: 4
        case .zoom: 5
        case .automaticExposure: 6
        }
    }

    func validate(for capabilities: CameraCapabilities) throws {
        func number(_ value: Double, _ name: String, _ range: ClosedRange<Double>) throws {
            _ = try CameraSettings.number(String(value), name: name, range: range)
        }
        switch self {
        case .brightness(let value):
            guard capabilities.automaticExposure else { throw CameraFailure("此鏡頭不支援自動亮度。") }
            try number(value, "亮度", capabilities.exposureBias)
        case .iso(let value):
            guard capabilities.manualExposure else { throw CameraFailure("此鏡頭不支援手動感光度。") }
            try number(value, "感光度", capabilities.iso)
        case .shutter(let value):
            guard capabilities.manualExposure else { throw CameraFailure("此鏡頭不支援手動快門。") }
            try number(value, "快門", capabilities.shutter)
        case .focus(let value):
            guard capabilities.manualFocus else { throw CameraFailure("此鏡頭不支援手動對焦。") }
            try number(value, "對焦", 0...1)
        case .temperature(let value):
            guard capabilities.manualWhiteBalance else { throw CameraFailure("此鏡頭不支援手動冷暖。") }
            try number(value, "冷暖", 2000...10000)
        case .zoom(let value): try number(value, "變焦", capabilities.zoom)
        case .automaticExposure:
            guard capabilities.automaticExposure else { throw CameraFailure("此鏡頭不支援自動亮度。") }
        case .automaticFocus, .automaticWhiteBalance: break
        }
    }

    func updateDraft(_ draft: inout CameraSettings, readback: CameraSettings) {
        switch self {
        case .brightness(let value): draft.automaticExposure = true; draft.exposureBias = String(value)
        case .iso(let value):
            if draft.automaticExposure { draft.shutter = readback.shutter }
            draft.automaticExposure = false; draft.iso = String(value)
        case .shutter(let value):
            if draft.automaticExposure { draft.iso = readback.iso }
            draft.automaticExposure = false; draft.shutter = String(value)
        case .focus(let value): draft.automaticFocus = false; draft.focus = String(value)
        case .temperature(let value):
            if draft.automaticWhiteBalance { draft.tint = readback.tint }
            draft.automaticWhiteBalance = false; draft.temperature = String(value)
        case .zoom(let value): draft.zoom = String(value)
        case .automaticExposure: draft.automaticExposure = true
        case .automaticFocus: draft.automaticFocus = true
        case .automaticWhiteBalance: draft.automaticWhiteBalance = true
        }
    }

    func restoreDraft(_ draft: inout CameraSettings, readback: CameraSettings) {
        switch self {
        case .brightness: draft.exposureBias = readback.exposureBias; draft.automaticExposure = readback.automaticExposure
        case .iso, .shutter, .automaticExposure:
            draft.iso = readback.iso; draft.shutter = readback.shutter; draft.automaticExposure = readback.automaticExposure
        case .focus, .automaticFocus:
            draft.focus = readback.focus; draft.automaticFocus = readback.automaticFocus
        case .temperature, .automaticWhiteBalance:
            draft.temperature = readback.temperature; draft.tint = readback.tint; draft.automaticWhiteBalance = readback.automaticWhiteBalance
        case .zoom: draft.zoom = readback.zoom
        }
    }
}

nonisolated struct CameraAdjustmentBuffer {
    private var pending: [CameraLiveAdjustment] = []
    mutating func enqueue(_ adjustment: CameraLiveAdjustment) {
        // Keep each control's latest value in chronological order. Switching
        // controls must not lose another control's final slider position.
        pending.removeAll { $0.control == adjustment.control }
        pending.append(adjustment)
    }
    mutating func next() -> CameraLiveAdjustment? {
        pending.isEmpty ? nil : pending.removeFirst()
    }
    func contains(control: Int) -> Bool { pending.contains { $0.control == control } }
    mutating func removeAll() { pending.removeAll() }
}
