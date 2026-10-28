import AVFoundation
import CoreImage
import MetalKit
import OSLog
import SwiftUI

struct CameraPreview: UIViewRepresentable {
    let service: CameraService
    let device: AVCaptureDevice?
    let startupID: UUID?
    let startupBegan: TimeInterval?
    let style: StyleAdjustment
    let running: Bool
    var onFocus: ((CGPoint) -> Void)?

    func makeUIView(context: Context) -> PreviewView {
        PreviewView(service: service)
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        view.configureRotation(device: device)
        view.configurePresentation(startupID: startupID, began: startupBegan)
        view.style = style
        view.focusHandler = onFocus
        view.startDrawing(running: running)
    }

    static func dismantleUIView(_ view: PreviewView, coordinator: ()) {
        view.tearDown()
    }
}

final class PreviewView: MTKView, MTKViewDelegate {
    var style = StyleAdjustment()
    var focusHandler: ((CGPoint) -> Void)?
    private let focusBox = CAShapeLayer()
    private let service: CameraService
    private let renderer: PreviewRenderer?
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private var captureRotationObservation: NSKeyValueObservation?
    private var rotationID = UUID()
    private var currentDeviceID = ""
    private var currentStartupID: UUID?
    private var startupBegan: TimeInterval?
    private var needsFirstDraw = false
    private var previewRotation: CGFloat = 90
    private var mirrorPreview = false
    private let logger = Logger(subsystem: "Camlab", category: "CameraStartup")

    init(service: CameraService) {
        self.service = service
        let gpu = MTLCreateSystemDefaultDevice()
        renderer = gpu.map { PreviewRenderer(device: $0, service: service) }
        super.init(frame: .zero, device: gpu)
        framebufferOnly = false
        colorPixelFormat = .bgra8Unorm
        (layer as? CAMetalLayer)?.colorspace = colorSpace
        preferredFramesPerSecond = 30
        isPaused = true
        delegate = self
        backgroundColor = .black
        focusBox.strokeColor = UIColor.systemYellow.cgColor
        focusBox.fillColor = UIColor.clear.cgColor
        focusBox.lineWidth = 1
        layer.addSublayer(focusBox)
    }

    required init(coder: NSCoder) { fatalError("Use init(service:)") }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard !isPaused, let location = touches.first?.location(in: self), let source = service.frames.image(),
              let point = PreviewGeometry.sensorPoint(sourceExtent: source.extent, clockwiseDegrees: previewRotation,
                                                      mirrored: mirrorPreview, viewport: bounds.size, touch: location) else { return }
        focusBox.path = UIBezierPath(rect: CGRect(x: location.x - 24, y: location.y - 24, width: 48, height: 48)).cgPath
        focusBox.removeAllAnimations()
        focusBox.opacity = 0
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1; animation.toValue = 0; animation.duration = 1.2
        focusBox.add(animation, forKey: "focus")
        focusHandler?(point)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func configurePresentation(startupID: UUID?, began: TimeInterval?) {
        guard startupID != currentStartupID else { return }
        currentStartupID = startupID
        startupBegan = began
        needsFirstDraw = startupID != nil
        if let began {
            logger.info("Preview UI updated after \(ProcessInfo.processInfo.systemUptime - began, privacy: .public) seconds")
        }
    }

    func startDrawing(running: Bool) {
        let requestDraw = running && (isPaused || needsFirstDraw)
        isPaused = !running
        guard requestDraw else { return }
        needsFirstDraw = false
        let id = currentStartupID
        // Request a first frame on the next UI turn instead of relying solely
        // on the display link restarting after a long session startup.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isPaused, self.currentStartupID == id,
                  self.window != nil else { return }
            self.draw()
        }
    }

    func draw(in view: MTKView) {
        guard let source = service.frames.image(), let renderer,
              drawableSize.width > 0, drawableSize.height > 0,
              renderer.reserveFrame() else { return }
        let began = ProcessInfo.processInfo.systemUptime
        guard let drawable = currentDrawable else {
            renderer.releaseFrame()
            return
        }
        renderer.submit(source: source, drawable: drawable,
                        style: style, rotation: previewRotation, mirrored: mirrorPreview,
                        startupID: currentStartupID, startupBegan: startupBegan, drawBegan: began)
    }

    func configureRotation(device: AVCaptureDevice?) {
        guard (device?.uniqueID ?? "") != currentDeviceID else { return }
        clearRotation()
        guard let device else { return }
        let began = ProcessInfo.processInfo.systemUptime
        let deviceID = device.uniqueID
        currentDeviceID = deviceID
        mirrorPreview = device.position == .front
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: layer)
        rotationCoordinator = coordinator
        let rotationID = rotationID
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { [weak self] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            Task { @MainActor [weak self] in
                guard let self, self.rotationID == rotationID else { return }
                self.previewRotation = angle
            }
        }
        captureRotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.initial, .new]) { [weak self] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelCapture
            Task { @MainActor [weak self] in
                guard let self, self.rotationID == rotationID else { return }
                self.service.rotateCapture(to: angle, deviceID: deviceID)
            }
        }
        logger.info("Preview rotation coordinator setup took \(ProcessInfo.processInfo.systemUptime - began, privacy: .public) seconds")
    }

    func tearDown() {
        isPaused = true
        delegate = nil
        currentStartupID = nil
        needsFirstDraw = false
        focusHandler = nil
        clearRotation()
    }

    private func clearRotation() {
        rotationID = UUID()
        rotationObservation?.invalidate()
        captureRotationObservation?.invalidate()
        rotationObservation = nil
        captureRotationObservation = nil
        rotationCoordinator = nil
        currentDeviceID = ""
        previewRotation = 90
        mirrorPreview = false
    }
}
