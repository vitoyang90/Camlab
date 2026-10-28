import CoreMotion
import Observation

nonisolated enum HorizonGeometry {
    static func degrees(x: Double, y: Double) -> Double? {
        guard x.isFinite, y.isFinite, hypot(x, y) > 0.2 else { return nil }
        var angle = atan2(x, -y) * 180 / .pi
        angle = angle.truncatingRemainder(dividingBy: 90)
        if angle > 45 { angle -= 90 }
        if angle < -45 { angle += 90 }
        return angle
    }
}

@MainActor @Observable
final class HorizonLevel {
    private let motion = CMMotionManager()
    var angle = 0.0
    var available = false

    func start() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 15
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let gravity = data?.gravity else { return }
            let value = HorizonGeometry.degrees(x: gravity.x, y: gravity.y)
            MainActor.assumeIsolated {
                guard let self else { return }
                self.available = value != nil
                if let value { self.angle = value }
            }
        }
    }

    func stop() { motion.stopDeviceMotionUpdates(); available = false }
}
