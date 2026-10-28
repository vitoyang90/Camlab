import SwiftUI

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
