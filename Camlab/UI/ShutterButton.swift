import SwiftUI

struct ShutterButton: View {
    let diameter: CGFloat
    let available: Bool
    let burstCount: Int
    let canCapture: @MainActor () -> Bool
    let capture: @MainActor (_ burstID: UUID?, _ requested: @MainActor () -> Bool) async -> Bool

    @GestureState private var touching = false
    @State private var pressID: UUID?
    @State private var burstID: UUID?
    @State private var requesting = false

    var body: some View {
        let ready = canCapture()
        ZStack {
            Circle().stroke(.white, lineWidth: 2)
            Circle().fill(ready || burstID != nil ? .white : .gray)
                .padding(5)
            if burstID != nil {
                Text(String(burstCount))
                    .font(.system(size: 23, weight: .semibold, design: .rounded))
                    .monospacedDigit().foregroundStyle(.black)
            }
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0)
            .updating($touching) { _, touching, _ in touching = true }
            .onChanged { _ in
                if pressID == nil, available, canCapture() { pressID = UUID() }
            }
            .onEnded { touch in
                let tap = pressID != nil && burstID == nil &&
                    CGRect(x: 0, y: 0, width: diameter, height: diameter).contains(touch.location)
                endPress()
                if tap { requestShot(for: nil) }
            })
        .disabled(!available || (!ready && pressID == nil))
        .task(id: pressID) {
            guard let id = pressID else { return }
            do { try await Task.sleep(for: .milliseconds(220)) } catch { return }
            guard pressID == id, available else { return }
            burstID = id
            requestShot(for: id)
        }
        .onChange(of: touching) { _, down in if !down { endPress() } }
        .onChange(of: available) { _, active in if !active { endPress() } }
        .onChange(of: ready) { _, ready in
            if ready, let id = burstID { requestShot(for: id) }
        }
        .onChange(of: burstCount) { _, _ in
            // The output can become ready again within a single SwiftUI frame.
            if let id = burstID { requestShot(for: id) }
        }
        .onDisappear { endPress() }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { requestShot(for: nil) }
        .accessibilityLabel("拍照")
        .accessibilityValue(burstID == nil ? "" : "連拍 \(burstCount) 張")
        .accessibilityHint("點一下拍一張，按住快門連拍，放開停止")
        .accessibilityIdentifier("capturePhoto")
    }

    private func endPress() {
        pressID = nil
        burstID = nil
    }

    private func requestShot(for id: UUID?) {
        guard !requesting, burstID == id, available, canCapture() else { return }
        requesting = true
        Task { @MainActor in
            let valid: @MainActor () -> Bool = { burstID == id && available }
            guard valid(), canCapture() else {
                requesting = false
                if let current = burstID, current != id { requestShot(for: current) }
                return
            }
            let taken = await capture(id, valid)
            requesting = false
            guard let current = burstID else { return }
            if !taken && current == id {
                if canCapture() { endPress() }
                return
            }
            requestShot(for: current)
        }
    }
}
