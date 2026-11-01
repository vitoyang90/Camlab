import SwiftUI

/// At the edge of the turn, reveal the new camera upright on the opposite face.
struct ViewfinderFlip: AnimatableModifier {
    var turns: Double
    let reduceMotion: Bool
    var animatableData: Double {
        get { turns }
        set { turns = newValue }
    }

    func body(content: Content) -> some View {
        let phase = turns.truncatingRemainder(dividingBy: 1)
        let angle = phase <= 0.5 ? phase * 180 : (phase - 1) * 180
        content
            .overlay {
                if phase > 0 {
                    Rectangle().fill(.regularMaterial)
                        .opacity(sin(phase * .pi))
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .overlay(Color.black.opacity(sin(phase * .pi) * (reduceMotion ? 0.55 : 0.25)).allowsHitTesting(false))
            .rotation3DEffect(.degrees(reduceMotion ? 0 : angle), axis: (x: 0, y: 1, z: 0), perspective: 0.45)
    }
}

/// Short, interruptible transitions for controls; never animate live camera values.
enum InterfaceMotion {
    static func layout(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smooth(duration: 0.28)
    }

    static let fade = Animation.easeInOut(duration: 0.18)

    static func reveal(reduceMotion: Bool, horizontal: Bool = false) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .offset(x: horizontal ? 12 : 0,
                                                                 y: horizontal ? 0 : 10))
    }
}
