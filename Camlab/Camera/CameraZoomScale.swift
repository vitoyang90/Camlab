import Foundation

/// UI and draft values use display magnification; only the service uses hardware factors.
nonisolated struct CameraZoomScale {
    let hardwareRange: ClosedRange<Double>
    let displayMultiplier: Double

    // Product limit for the requested iPhone 17 photo experience, not the sensor's maximum.
    static let maximumMagnification = 10.0

    var displayRange: ClosedRange<Double> {
        let lower = hardwareRange.lowerBound * displayMultiplier
        let upper = min(hardwareRange.upperBound * displayMultiplier, Self.maximumMagnification)
        return lower...max(lower, upper)
    }

    func displayed(_ hardwareFactor: Double) -> Double {
        hardwareFactor * displayMultiplier
    }

    func presets(switchOverFactors: [Double]) -> [Double] {
        let candidates = [displayRange.lowerBound, 1, 2] + switchOverFactors.map(displayed)
        return Array(Set(candidates.filter { $0.isFinite && displayRange.contains($0) })).sorted()
    }

    func hardwareFactor(for magnification: Double) -> Double {
        let bounded = min(displayRange.upperBound, max(displayRange.lowerBound, magnification))
        return min(hardwareRange.upperBound, max(hardwareRange.lowerBound, bounded / displayMultiplier))
    }
}
