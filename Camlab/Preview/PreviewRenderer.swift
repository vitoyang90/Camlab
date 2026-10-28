@preconcurrency import MetalKit
import CoreImage
import OSLog
import QuartzCore

/// UI hands over one immutable frame and its drawable. All Core Image setup
/// and encoding runs on queue; GPU completion releases the frame reservation.
nonisolated final class PreviewRenderer: @unchecked Sendable {
    private nonisolated struct Frame: @unchecked Sendable {
        let source: CIImage
        let drawable: CAMetalDrawable
        let size: CGSize
        let style: StyleAdjustment
        let rotation: CGFloat
        let mirrored: Bool
        let startupID: UUID?
        let startupBegan: TimeInterval?
        let drawBegan: TimeInterval
        let acquiredAt: TimeInterval
    }

    private nonisolated struct Resources {
        let context: CIContext
        let commands: MTLCommandQueue
    }

    private let device: MTLDevice
    private let service: CameraService
    private let queue = DispatchQueue(label: "Camlab.previewRendering", qos: .userInitiated)
    private let inFlight = DispatchSemaphore(value: 1)
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let logger = Logger(subsystem: "Camlab", category: "CameraStartup")
    private var storedResources: Resources?
    private var submittedStartupID: UUID?
    private let presentation = PreviewPresentationTracker()

    init(device: MTLDevice, service: CameraService) {
        self.device = device
        self.service = service
        queue.async { _ = self.resources() }
    }

    private func resources() -> Resources? {
        dispatchPrecondition(condition: .onQueue(queue))
        if let storedResources { return storedResources }
        let began = ProcessInfo.processInfo.systemUptime
        guard let commands = device.makeCommandQueue() else {
            logger.error("Unable to create preview command queue")
            return nil
        }
        let context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        let created = Resources(context: context, commands: commands)
        storedResources = created
        logger.info("Preview renderer setup took \(ProcessInfo.processInfo.systemUptime - began, privacy: .public) seconds")
        return created
    }

    func reserveFrame() -> Bool { inFlight.wait(timeout: .now()) == .success }
    func releaseFrame() { inFlight.signal() }

    func submit(source: CIImage, drawable: CAMetalDrawable,
                style: StyleAdjustment, rotation: CGFloat, mirrored: Bool,
                startupID: UUID?, startupBegan: TimeInterval?, drawBegan: TimeInterval) {
        // During rotation MTKView.drawableSize can already describe the next
        // surface while currentDrawable still owns a texture of the old size.
        let size = CGSize(width: drawable.texture.width, height: drawable.texture.height)
        let frame = Frame(source: source, drawable: drawable, size: size, style: style,
                          rotation: rotation, mirrored: mirrored, startupID: startupID,
                          startupBegan: startupBegan, drawBegan: drawBegan, acquiredAt: ProcessInfo.processInfo.systemUptime)
        queue.async {
            autoreleasepool { self.render(frame) }
        }
    }

    private func render(_ frame: Frame) {
        let began = ProcessInfo.processInfo.systemUptime
        guard let resources = resources(), let command = resources.commands.makeCommandBuffer() else {
            releaseFrame()
            return
        }
        let oriented = PreviewGeometry.oriented(frame.source, clockwiseDegrees: frame.rotation, mirrored: frame.mirrored)
        let filtered = frame.style.applying(to: oriented)
        let scale = min(frame.size.width / filtered.extent.width, frame.size.height / filtered.extent.height)
        let scaled = filtered.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let positioned = scaled.transformed(by: CGAffineTransform(
            translationX: (frame.size.width - scaled.extent.width) / 2 - scaled.extent.minX,
            y: (frame.size.height - scaled.extent.height) / 2 - scaled.extent.minY
        ))
        let bounds = CGRect(origin: .zero, size: frame.size)
        let background = CIImage(color: .black).cropped(to: bounds)
        resources.context.render(positioned.composited(over: background), to: frame.drawable.texture,
                                 commandBuffer: command, bounds: bounds, colorSpace: colorSpace)
        let encodedAt = ProcessInfo.processInfo.systemUptime
        let first = frame.startupID != nil && frame.startupID != submittedStartupID
        let semaphore = inFlight
        let logger = logger
        command.addCompletedHandler { completed in
            semaphore.signal()
            if first {
                logger.info("Preview first GPU completion after encode took \(ProcessInfo.processInfo.systemUptime - encodedAt, privacy: .public) seconds; status \(completed.status.rawValue, privacy: .public)")
            }
            if let error = completed.error { logger.error("Preview GPU error: \(error.localizedDescription, privacy: .public)") }
        }
        if first, let startupID = frame.startupID {
            submittedStartupID = startupID
            presentation.begin(startupID)
            if let startupBegan = frame.startupBegan {
                logger.info("Preview first draw began after \(frame.drawBegan - startupBegan, privacy: .public) seconds; command ready after \(encodedAt - startupBegan, privacy: .public) seconds")
            }
            logger.info("Preview first drawable acquisition took \(frame.acquiredAt - frame.drawBegan, privacy: .public) seconds; render queue wait \(began - frame.acquiredAt, privacy: .public) seconds; encoding \(encodedAt - began, privacy: .public) seconds")
        }
        if let startupID = frame.startupID, presentation.shouldObserve(startupID) {
            #if !targetEnvironment(simulator)
            let camera = service
            let tracker = presentation
            frame.drawable.addPresentedHandler { drawable in
                let callbackAt = ProcessInfo.processInfo.systemUptime
                let hostNow = CACurrentMediaTime()
                let hostPresented = drawable.presentedTime
                // Metal reports 0 for skipped/unpresented frames. Keep observing
                // subsequent drawables instead of declaring startup complete.
                guard hostPresented <= hostNow,
                      tracker.record(startupID, presentedTime: hostPresented) else { return }
                let presentedAt = callbackAt - (hostNow - hostPresented)
                camera.previewDidPresent(startupID: startupID, at: presentedAt, callbackAt: callbackAt)
            }
            #endif
        }
        command.present(frame.drawable)
        command.commit()
    }
}
