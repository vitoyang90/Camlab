import AVFoundation

/// Values read during capture startup must still satisfy AVFoundation's
/// preconditions: Objective-C range exceptions are not Swift errors.
nonisolated enum CameraOutputValidation {
    static func whiteBalanceGains(
        _ gains: AVCaptureDevice.WhiteBalanceGains, maximum: Float
    ) -> AVCaptureDevice.WhiteBalanceGains? {
        guard maximum.isFinite, maximum >= 1 else { return nil }
        func bounded(_ value: Float) -> Float {
            value.isFinite ? min(maximum, max(1, value)) : 1
        }
        return .init(redGain: bounded(gains.redGain), greenGain: bounded(gains.greenGain),
                     blueGain: bounded(gains.blueGain))
    }

    static func photoDimensions(from supported: [CMVideoDimensions]) -> CMVideoDimensions? {
        let valid = supported.filter { $0.width > 0 && $0.height > 0 }
        func pixels(_ size: CMVideoDimensions) -> Int64 { Int64(size.width) * Int64(size.height) }
        // Prefer the largest supported size up to 24 MP; if none fits, use the
        // smallest supported size rather than relying on the array's order.
        return valid.filter { pixels($0) <= 25_000_000 }.max { pixels($0) < pixels($1) }
            ?? valid.min { pixels($0) < pixels($1) }
    }
}
