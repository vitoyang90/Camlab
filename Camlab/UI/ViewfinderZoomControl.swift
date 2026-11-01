import SwiftUI

struct ViewfinderZoomControl: View {
    let presets: [Double]
    let current: Double
    let availableWidth: CGFloat
    let canAdjust: Bool
    let select: (Double) -> Void

    @Environment(\.layoutDirection) private var direction
    private let accent = Color(red: 0.98, green: 0.81, blue: 0.30)

    var body: some View {
        let cellWidth = min(48, max(1, availableWidth - 4) / CGFloat(max(1, presets.count)))
        HStack(spacing: 0) {
            ForEach(presets, id: \.self) { value in
                let selected = abs(current - value) < 0.001
                Button { if !selected { select(value) } } label: {
                    Text("\(CameraSettings.format(value))×")
                        .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(selected ? accent : .white)
                        .frame(width: cellWidth, height: 44)
                        .background(selected ? .white.opacity(0.16) : .clear, in: Capsule())
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("變焦 \(CameraSettings.format(value)) 倍")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .buttonStyle(ZoomPresetButtonStyle())
        .contentShape(Rectangle())
        .highPriorityGesture(DragGesture(minimumDistance: 5).onChanged { drag in
            guard canAdjust, !presets.isEmpty else { return }
            let column = min(presets.count - 1, max(0, Int(floor(drag.location.x / cellWidth))))
            let index = direction == .rightToLeft ? presets.count - 1 - column : column
            if presets[index] != current { select(presets[index]) }
        })
        .disabled(!canAdjust)
        .padding(2)
        .background(.black.opacity(0.8), in: Capsule())
        .overlay(alignment: .top) {
            if !presets.contains(where: { abs(current - $0) < 0.001 }) {
                Text("\(CameraSettings.format(current))×").font(.caption2.monospacedDigit())
                    .padding(.horizontal, 5).background(.black.opacity(0.8), in: Capsule())
                    .offset(y: -16).allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("zoomPresets")
    }
}

/// The selected magnification provides feedback for both taps and drags.
private struct ZoomPresetButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}
