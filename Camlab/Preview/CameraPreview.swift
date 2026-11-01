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
    let zoom: Double
    let zoomRange: ClosedRange<Double>?
    let onZoom: (Double) -> Void
    var onFocus: ((CGPoint) -> Void)?

    func makeUIView(context: Context) -> PreviewView {
        PreviewView(service: service)
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        view.configureRotation(device: device)
        view.configurePresentation(startupID: startupID, began: startupBegan)
        view.style = style
        view.focusHandler = onFocus
        view.configureZoom(zoom, range: running ? zoomRange : nil, onZoom: onZoom)
        view.startDrawing(running: running)
    }

    static func dismantleUIView(_ view: PreviewView, coordinator: ()) {
        view.tearDown()
    }
}

final class PreviewView: MTKView, MTKViewDelegate {
    var style = StyleAdjustment()
    var focusHandler: ((CGPoint) -> Void)?
    private lazy var pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinchZoom(_:)))
    private var currentZoom = 1.0
    private var pinchStartZoom: Double?
    private var zoomScale: PinchZoomRange?
    private var zoomHandler: ((Double) -> Void)?
    private let focusBox = CAShapeLayer()
    private let service: CameraService
    private var renderer: PreviewRenderer?
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
        super.init(frame: .zero, device: gpu)
        framebufferOnly = false
        colorPixelFormat = .bgra8Unorm
        if let gpu, let metalLayer = layer as? CAMetalLayer {
            metalLayer.colorspace = colorSpace
            renderer = PreviewRenderer(device: gpu, layer: metalLayer, service: service)
        }
        preferredFramesPerSecond = 30
        isPaused = true
        delegate = self
        backgroundColor = .black
        isMultipleTouchEnabled = true
        addGestureRecognizer(pinch)
        let focusTap = UITapGestureRecognizer(target: self, action: #selector(tapFocus(_:)))
        focusTap.require(toFail: pinch)
        addGestureRecognizer(focusTap)
        focusBox.strokeColor = UIColor.systemYellow.cgColor
        focusBox.fillColor = UIColor.clear.cgColor
        focusBox.lineWidth = 1
        layer.addSublayer(focusBox)
    }

    required init(coder: NSCoder) { fatalError("Use init(service:)") }

    func configureZoom(_ value: Double, range: ClosedRange<Double>?, onZoom: @escaping (Double) -> Void) {
        currentZoom = value
        zoomScale = range.flatMap(PinchZoomRange.init)
        zoomHandler = onZoom
        let enabled = zoomScale != nil
        if pinch.isEnabled != enabled { pinch.isEnabled = enabled }
    }

    @objc private func pinchZoom(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            pinchStartZoom = currentZoom
        case .changed, .ended:
            break
        default:
            pinchStartZoom = nil
            return
        }
        defer { if gesture.state == .ended { pinchStartZoom = nil } }
        guard let start = pinchStartZoom, let zoomScale, !isPaused,
              gesture.scale.isFinite, gesture.scale > 0 else { return }
        // The recognizer reports cumulative scale from the start of this pinch.
        let next = zoomScale.magnification(clamping: start * Double(gesture.scale))
        if next != currentZoom {
            currentZoom = next
            zoomHandler?(next)
        }
    }

    @objc private func tapFocus(_ gesture: UITapGestureRecognizer) {
        let location = gesture.location(in: self)
        guard !isPaused, let source = service.frames.image(),
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
        pinchStartZoom = nil
        pinch.isEnabled = false
        currentStartupID = startupID
        startupBegan = began
        needsFirstDraw = startupID != nil
        if let began {
            logger.info("Preview UI updated after \(ProcessInfo.processInfo.systemUptime - began, privacy: .public) seconds")
        }
    }

    func startDrawing(running: Bool) {
        renderer?.setActivePreview(running ? currentStartupID : nil)
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
        guard !isPaused, window?.windowScene?.activationState == .foregroundActive,
              let id = currentStartupID,
              let source = service.frames.image(), let renderer,
              drawableSize.width > 0, drawableSize.height > 0,
              renderer.reserveFrame() else { return }
        let began = ProcessInfo.processInfo.systemUptime
        renderer.submit(source: source,
                        style: style, rotation: previewRotation, mirrored: mirrorPreview,
                        startupID: id, startupBegan: startupBegan, drawBegan: began)
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
        renderer?.setActivePreview(nil)
        isPaused = true
        delegate = nil
        currentStartupID = nil
        needsFirstDraw = false
        focusHandler = nil
        pinch.isEnabled = false
        zoomHandler = nil
        pinchStartZoom = nil
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
