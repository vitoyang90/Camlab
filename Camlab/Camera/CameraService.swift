@preconcurrency import AVFoundation
import Foundation
import OSLog

nonisolated struct CameraChoice: Identifiable, Sendable {
    let id: String
    let name: String
    let isFront: Bool

    static func flipTarget(in cameras: [Self], currentID: String) -> Self? {
        guard let current = cameras.first(where: { $0.id == currentID }) else { return nil }
        return cameras.first { $0.isFront != current.isFront }
    }
}

nonisolated struct CameraSnapshot: Sendable {
    let deviceID: String
    let rotationDevice: AVCaptureDevice
    let photoOutput: AVCapturePhotoOutput
    let responsiveCapture: Bool
    let previewID: UUID
    let previewBegan: TimeInterval
    let capabilities: CameraCapabilities
    let settings: CameraSettings
    let running: Bool
    let interrupted: Bool
    let previewPresented: Bool
}

/// Device mutations and session lifecycle operations are confined to queue.
nonisolated final class CameraService: @unchecked Sendable {
    private nonisolated struct CaptureResources {
        let session = AVCaptureSession()
        let videoOutput = AVCaptureVideoDataOutput()
        let photoOutput = AVCapturePhotoOutput()
    }
    // First accessed on queue: constructing capture resources can block too.
    private var storedResources: CaptureResources?
    private var session: AVCaptureSession { resources().session }
    let frames = VideoFrameStore()
    private var videoOutput: AVCaptureVideoDataOutput { resources().videoOutput }
    private var photoOutput: AVCapturePhotoOutput { resources().photoOutput }
    private let logger = Logger(subsystem: "Camlab", category: "CameraStartup")
    private var discoveredDevices: [AVCaptureDevice] = []
    // A timeout ends the caller's wait, not AVFoundation's capture. Keep each
    // delegate alive until the system's final callback, even after a timeout.
    private var retainedPhotos: [Int64: PhotoCaptureDelegate] = [:]
    private var captureRotation: CGFloat = 90
    private let frameQueue = DispatchQueue(label: "Camlab.frames", qos: .userInteractive)
    private let queue = DispatchQueue(label: "Camlab.camera", qos: .userInitiated)
    private var device: AVCaptureDevice?
    private var nominalTiming: (format: AVCaptureDevice.Format, min: CMTime, max: CMTime)?
    private var configuredFormat: AVCaptureDevice.Format?
    private var visibilityID: UUID?
    private var previewID = UUID()
    private var previewBegan: TimeInterval?
    private var reportedPreview = false
    private var previewPresentationHandler: (@Sendable (UUID) -> Void)?

    func setPreviewPresentationHandler(_ handler: @escaping @Sendable (UUID) -> Void) {
        queue.async { self.previewPresentationHandler = handler }
    }

    private func resources() -> CaptureResources {
        dispatchPrecondition(condition: .onQueue(queue))
        if let storedResources { return storedResources }
        let created = CaptureResources()
        storedResources = created
        return created
    }

    static func devices() -> [AVCaptureDevice] {
        // The virtual rear camera keeps optical zoom transitions available.
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera
        ]
        let discovered = AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .video, position: .unspecified
        ).devices
        return [AVCaptureDevice.Position.back, .front].compactMap { position in
            types.lazy.compactMap { type in
                discovered.first { $0.position == position && $0.deviceType == type }
            }.first
        }
    }

    func cameras() async throws -> [CameraChoice] {
        try await perform {
            let began = ProcessInfo.processInfo.systemUptime
            if self.discoveredDevices.isEmpty { self.discoveredDevices = Self.devices() }
            self.logger.info("Camera discovery took \(ProcessInfo.processInfo.systemUptime - began, privacy: .public) seconds")
            return self.discoveredDevices.map {
                CameraChoice(id: $0.uniqueID, name: $0.position == .front ? "前置相機" : "後置相機",
                             isFront: $0.position == .front)
            }
        }
    }

    func start(deviceID: String? = nil, visibilityID: UUID, restart: Bool = false) async throws -> CameraSnapshot {
        try await perform {
            guard self.visibilityID == visibilityID else { throw CancellationError() }
            let began = ProcessInfo.processInfo.systemUptime
            if self.discoveredDevices.isEmpty { self.discoveredDevices = Self.devices() }
            let devices = self.discoveredDevices
            let selected = deviceID.flatMap { id in devices.first { $0.uniqueID == id } }
                ?? self.device
                ?? devices.first { $0.position == .back }
                ?? devices.first
            guard let selected else {
                throw CameraFailure("找不到可用的內建相機。請使用實體 iPhone 或 iPad；模擬器無法提供相機畫面。")
            }
            let changingCamera = self.device?.uniqueID != selected.uniqueID
            guard !changingCamera || self.retainedPhotos.isEmpty else {
                throw CameraFailure("系統仍在完成上一張拍攝，請稍後再切換鏡頭。")
            }
            if restart, self.session.isRunning { self.session.stopRunning() }
            if !restart, self.previewBegan != nil, !changingCamera, self.configuredFormat == selected.activeFormat,
               self.session.isRunning, !self.session.isInterrupted {
                // A duplicate foreground request must not discard the current
                // frame or make a ready camera go through startup again.
                return try self.snapshot()
            }
            self.previewID = UUID()
            self.previewBegan = began
            self.reportedPreview = false
            if changingCamera {
                self.configuredFormat = nil
                let input = try AVCaptureDeviceInput(device: selected)
                // Finish the old pipeline before changing its input and photo
                // dimensions. All stop/configure/start calls stay on queue.
                if self.session.isRunning { self.session.stopRunning() }
                self.session.beginConfiguration()
                let previousInputs = self.session.inputs
                previousInputs.forEach { self.session.removeInput($0) }
                if self.session.canSetSessionPreset(.photo) { self.session.sessionPreset = .photo }
                guard self.session.canAddInput(input) else {
                    previousInputs.forEach { if self.session.canAddInput($0) { self.session.addInput($0) } }
                    self.session.commitConfiguration()
                    throw CameraFailure("無法開啟這個鏡頭，請重試。")
                }
                self.session.addInput(input)
                if !self.session.outputs.contains(self.videoOutput) {
                    self.videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                    self.videoOutput.alwaysDiscardsLateVideoFrames = true
                    self.videoOutput.automaticallyConfiguresOutputBufferDimensions = false
                    self.videoOutput.deliversPreviewSizedOutputBuffers = true
                    self.videoOutput.setSampleBufferDelegate(self.frames, queue: self.frameQueue)
                    guard self.session.canAddOutput(self.videoOutput) else {
                        self.session.removeInput(input)
                        previousInputs.forEach { if self.session.canAddInput($0) { self.session.addInput($0) } }
                        self.session.commitConfiguration()
                        throw CameraFailure("無法啟動風格預覽，請重試開啟相機。")
                    }
                    self.session.addOutput(self.videoOutput)
                }
                if !self.session.outputs.contains(self.photoOutput) {
                    guard self.session.canAddOutput(self.photoOutput) else {
                        self.session.removeInput(input)
                        previousInputs.forEach { if self.session.canAddInput($0) { self.session.addInput($0) } }
                        self.session.commitConfiguration()
                        throw CameraFailure("無法啟動拍照功能，請重試開啟相機。")
                    }
                    self.session.addOutput(self.photoOutput)
                }
                // Keep preview immediate. Start photo preparation as soon as
                // startRunning returns, in parallel with the Metal preview.
                self.videoOutput.isDeferredStartEnabled = false
                if self.photoOutput.isDeferredStartSupported {
                    self.photoOutput.isDeferredStartEnabled = true
                }
                self.session.automaticallyRunsDeferredStart = !self.session.isManualDeferredStartSupported
                self.photoOutput.maxPhotoQualityPrioritization = .quality
                self.captureRotation = 90
                if let connection = self.videoOutput.connection(with: .video) {
                    // Rotate/mirror on the GPU instead of rebuilding the video
                    // output's hardware rotation pipeline when preview appears.
                    if connection.isVideoRotationAngleSupported(0) { connection.videoRotationAngle = 0 }
                    if connection.isVideoMirroringSupported {
                        connection.automaticallyAdjustsVideoMirroring = false
                        connection.isVideoMirrored = false
                    }
                }
                self.frames.clear()
                self.session.commitConfiguration()
                self.device = selected
            }
            // The photo preset can change activeFormat when the input graph is
            // committed. Only choose dimensions from that committed format,
            // including on retries after a configuration lock failure.
            if self.configuredFormat != selected.activeFormat {
                try selected.lockForConfiguration()
                defer { selected.unlockForConfiguration() }
                guard let photoSize = CameraOutputValidation.photoDimensions(
                    from: selected.activeFormat.supportedMaxPhotoDimensions
                ) else { throw CameraFailure("這個鏡頭尚未提供可用的照片尺寸，請重試開啟相機。") }
                if self.photoOutput.maxPhotoDimensions.width != photoSize.width ||
                    self.photoOutput.maxPhotoDimensions.height != photoSize.height {
                    self.session.beginConfiguration()
                    self.photoOutput.maxPhotoDimensions = photoSize
                    self.session.commitConfiguration()
                }
                self.nominalTiming = (selected.activeFormat, selected.activeVideoMinFrameDuration, selected.activeVideoMaxFrameDuration)
                self.setAutomaticModes(selected)
            }
            if self.photoOutput.isResponsiveCaptureSupported && !self.photoOutput.isResponsiveCaptureEnabled {
                self.session.beginConfiguration()
                self.photoOutput.isResponsiveCaptureEnabled = true
                self.session.commitConfiguration()
            }
            // Reconnects and lens changes must also respect the app's zoom limit.
            let zoomScale = self.zoomScale(selected)
            let magnification = changingCamera ? 1 : zoomScale.displayed(Double(selected.videoZoomFactor))
            let hardwareZoom = CGFloat(zoomScale.hardwareFactor(for: magnification))
            let restrictSwitching = selected.position == .back &&
                selected.activePrimaryConstituentDeviceSwitchingBehavior != .unsupported &&
                (selected.primaryConstituentDeviceSwitchingBehavior != .restricted ||
                 selected.primaryConstituentDeviceRestrictedSwitchingBehaviorConditions != .videoZoomChanged)
            if restrictSwitching || selected.videoZoomFactor != hardwareZoom {
                try selected.lockForConfiguration()
                defer { selected.unlockForConfiguration() }
                if restrictSwitching {
                    selected.setPrimaryConstituentDeviceSwitchingBehavior(.restricted, restrictedSwitchingBehaviorConditions: .videoZoomChanged)
                }
                if selected.videoZoomFactor != hardwareZoom { selected.videoZoomFactor = hardwareZoom }
            }
            self.configuredFormat = selected.activeFormat
            self.logger.info("Camera configuration took \(ProcessInfo.processInfo.systemUptime - began, privacy: .public) seconds")
            self.frames.beginPreview(at: began)
            let startBegan = ProcessInfo.processInfo.systemUptime
            if !self.session.isRunning { self.session.startRunning() }
            self.logger.info("Camera startRunning took \(ProcessInfo.processInfo.systemUptime - startBegan, privacy: .public) seconds")
            guard self.session.isRunning || self.session.isInterrupted else {
                throw CameraFailure("系統未能啟動相機，請重試開啟相機。")
            }
            if !self.session.automaticallyRunsDeferredStart {
                self.session.runDeferredStartWhenNeeded()
            }
            if self.session.isRunning, !self.session.isInterrupted, self.supportsPhotoSettings(for: selected) {
                self.photoOutput.setPreparedPhotoSettingsArray([self.photoSettings(for: selected)], completionHandler: nil)
            }
            let readBegan = ProcessInfo.processInfo.systemUptime
            let result = try self.snapshot()
            self.logger.info("Camera initial readback took \(ProcessInfo.processInfo.systemUptime - readBegan, privacy: .public) seconds")
            return result
        }
    }

    /// Enqueue directly in the order the main actor received visibility changes.
    /// An async start that reaches this queue late must present the current ID.
    func setVisibility(_ id: UUID?) {
        queue.async {
            self.visibilityID = id
            guard id == nil else { return }
            self.storedResources?.session.stopRunning()
            self.previewBegan = nil
            self.reportedPreview = false
            self.frames.clear()
        }
    }

    func previewDidPresent(startupID: UUID, at presentedAt: TimeInterval, callbackAt: TimeInterval) {
        queue.async {
            guard startupID == self.previewID, !self.reportedPreview,
                  let began = self.previewBegan, self.session.isRunning else { return }
            self.reportedPreview = true
            self.logger.info("Camera first preview presented after \(presentedAt - began, privacy: .public) seconds; presentation callback delay \(callbackAt - presentedAt, privacy: .public) seconds; reporting queue delay \(ProcessInfo.processInfo.systemUptime - callbackAt, privacy: .public) seconds")
            self.previewPresentationHandler?(startupID)
        }
    }

    func rotateCapture(to angle: CGFloat, deviceID: String) {
        queue.async {
            if self.device?.uniqueID == deviceID { self.captureRotation = angle }
        }
    }

    private func supportsPhotoSettings(for device: AVCaptureDevice) -> Bool {
        let dimensions = photoOutput.maxPhotoDimensions
        return photoOutput.availablePhotoCodecTypes.contains(.jpeg) &&
            device.activeFormat.supportedMaxPhotoDimensions.contains {
                $0.width == dimensions.width && $0.height == dimensions.height
            }
    }

    private func photoSettings(for device: AVCaptureDevice) -> AVCapturePhotoSettings {
        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        settings.isShutterSoundSuppressionEnabled = photoOutput.isShutterSoundSuppressionSupported
        settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
        settings.photoQualityPrioritization = device.exposureMode == .custom ? .speed : .quality
        return settings
    }

    func capturePhoto(previewID: UUID, requestedAt: TimeInterval,
                      submitted: @escaping @Sendable (Bool) -> Void,
                      didCapture: @escaping @Sendable () -> Void,
                      completion: @escaping @Sendable (Result<Data, Error>) -> Void) {
        queue.async {
            var accepted = false
            defer { submitted(accepted) }
            guard let device = self.device, self.session.isRunning, !self.session.isInterrupted,
                  self.visibilityID != nil, self.previewID == previewID,
                  self.retainedPhotos.count < (self.photoOutput.isResponsiveCaptureEnabled ? 2 : 1),
                  let connection = self.photoOutput.connection(with: .video) else {
                completion(.failure(CameraFailure("相機目前無法拍照，請等待恢復後再試。")))
                return
            }
            guard self.supportsPhotoSettings(for: device) else {
                // Let the existing stopped-session recovery rebuild the
                // configuration instead of submitting invalid settings.
                self.configuredFormat = nil
                self.session.stopRunning()
                completion(.failure(CameraFailure("相機格式已變更，正在重新準備，請稍後再拍攝。")))
                return
            }
            if connection.videoRotationAngle != self.captureRotation, connection.isVideoRotationAngleSupported(self.captureRotation) {
                connection.videoRotationAngle = self.captureRotation
            }
            if connection.isVideoMirroringSupported {
                if connection.automaticallyAdjustsVideoMirroring { connection.automaticallyAdjustsVideoMirroring = false }
                let mirror = device.position == .front
                if connection.isVideoMirrored != mirror { connection.isVideoMirrored = mirror }
            }
            let settings = self.photoSettings(for: device)
            let captureID = settings.uniqueID
            let delegate = PhotoCaptureDelegate(didCapture: didCapture, completion: completion, captureFinished: { [weak self] in
                self?.queue.async { [weak self] in self?.retainedPhotos[captureID] = nil }
            })
            self.retainedPhotos[captureID] = delegate
            let captureBegan = ProcessInfo.processInfo.systemUptime
            self.logger.info("Camera shutter request reached output after \(captureBegan - requestedAt, privacy: .public) seconds")
            if let began = self.previewBegan {
                self.logger.info("Camera capture submitted after \(captureBegan - began, privacy: .public) seconds from session startup")
            }
            self.photoOutput.capturePhoto(with: settings, delegate: delegate)
            accepted = true
            self.queue.asyncAfter(deadline: .now() + 30) { [weak delegate] in
                guard let delegate, self.retainedPhotos[captureID] === delegate else { return }
                delegate.finish(.failure(CameraFailure("拍攝逾時，請重試開啟相機後再拍攝。")))
            }
        }
    }

    func read() async throws -> CameraSnapshot {
        try await perform { try self.snapshot() }
    }

    func adjustLive(_ adjustment: CameraLiveAdjustment) async throws -> CameraSnapshot {
        try await perform {
            guard let device = self.device, self.session.isRunning, !self.session.isInterrupted else {
                throw CameraFailure("相機目前無法使用，請等待恢復。")
            }
            try adjustment.validate(for: self.capabilities(device))
            var gains: AVCaptureDevice.WhiteBalanceGains?
            if case .temperature(let value) = adjustment {
                let tint = self.whiteBalanceReadback(device).tint
                let converted = device.deviceWhiteBalanceGains(for: .init(temperature: Float(value), tint: tint))
                guard [converted.redGain, converted.greenGain, converted.blueGain].allSatisfy({
                    $0.isFinite && $0 >= 1 && $0 <= device.maxWhiteBalanceGain
                }) else { throw CameraFailure("這個冷暖值超出鏡頭可用範圍，請稍微往回調。") }
                gains = converted
            }
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            switch adjustment {
            case .brightness(let value):
                self.restoreFrameTiming(device)
                self.setAutomaticExposure(device)
                device.setExposureTargetBias(Float(value), completionHandler: nil)
            case .iso(let value):
                device.setExposureModeCustom(duration: AVCaptureDevice.currentExposureDuration, iso: Float(value), completionHandler: nil)
            case .shutter(let value):
                self.restoreFrameTiming(device)
                let duration = CMTimeMaximum(device.activeFormat.minExposureDuration,
                    CMTimeMinimum(CMTime(seconds: value, preferredTimescale: 1_000_000_000), device.activeFormat.maxExposureDuration))
                device.setExposureModeCustom(duration: duration, iso: AVCaptureDevice.currentISO, completionHandler: nil)
            case .focus(let value): device.setFocusModeLocked(lensPosition: Float(value), completionHandler: nil)
            case .temperature:
                if let gains { device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil) }
            case .zoom(let value): self.applyZoom(value, to: device)
            case .automaticExposure:
                self.restoreFrameTiming(device)
                self.setAutomaticExposure(device)
            case .automaticFocus: self.setAutomaticFocus(device)
            case .automaticWhiteBalance: self.setAutomaticWhiteBalance(device)
            }
            return try self.snapshot()
        }
    }

    func focus(at point: CGPoint) async throws -> CameraSnapshot {
        try await perform {
            guard let device = self.device, self.session.isRunning, !self.session.isInterrupted else {
                throw CameraFailure("相機目前無法使用。")
            }
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = point
                if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus }
                else { self.setAutomaticFocus(device) }
            }
            if device.exposureMode != .custom, device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = point
            }
            return try self.snapshot()
        }
    }

    func setZoom(_ factor: Double) async throws -> CameraSnapshot {
        try await perform {
            guard let device = self.device, self.session.isRunning, !self.session.isInterrupted else {
                throw CameraFailure("相機目前無法使用，請等待恢復或重試開啟相機。")
            }
            let value = try CameraSettings.number(String(factor), name: "變焦倍率",
                                                  range: self.capabilities(device).zoom)
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            self.applyZoom(value, to: device)
            return try self.snapshot()
        }
    }

    func apply(_ settings: CameraSettings) async throws -> CameraSnapshot {
        try await perform {
            guard let device = self.device, self.session.isRunning, !self.session.isInterrupted else {
                throw CameraFailure("相機目前無法使用，請等待恢復或重試開啟相機。")
            }
            // Validate the entire request against the active format before mutating hardware.
            let values = try settings.validated(for: self.capabilities(device))
            var gains: AVCaptureDevice.WhiteBalanceGains?
            if let temperature = values.temperature, let tint = values.tint {
                let converted = device.deviceWhiteBalanceGains(for: .init(temperature: Float(temperature), tint: Float(tint)))
                guard [converted.redGain, converted.greenGain, converted.blueGain].allSatisfy({
                    $0.isFinite && $0 >= 1 && $0 <= device.maxWhiteBalanceGain
                }) else {
                    throw CameraFailure("這個鏡頭無法套用此色溫與色調組合，請改用較接近目前回報的數值。")
                }
                gains = converted
            }
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            self.restoreFrameTiming(device)
            if let iso = values.iso, let shutter = values.shutter {
                var duration = CMTime(seconds: shutter, preferredTimescale: 1_000_000_000)
                // Keep CMTime rounding from stepping outside the sensor's limits.
                duration = CMTimeMaximum(device.activeFormat.minExposureDuration,
                                         CMTimeMinimum(duration, device.activeFormat.maxExposureDuration))
                device.setExposureModeCustom(duration: duration, iso: Float(iso), completionHandler: nil)
            } else {
                self.setAutomaticExposure(device)
                if let bias = values.exposureBias {
                    device.setExposureTargetBias(Float(bias), completionHandler: nil)
                }
            }
            if let focus = values.focus {
                device.setFocusModeLocked(lensPosition: Float(focus), completionHandler: nil)
            } else {
                self.setAutomaticFocus(device)
            }
            if let gains {
                device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
            } else {
                self.setAutomaticWhiteBalance(device)
            }
            self.applyZoom(values.zoom, to: device)
            // Hardware settles asynchronously; the UI polls actual values separately.
            return try self.snapshot()
        }
    }

    func restoreAutomatic() async throws -> CameraSnapshot {
        try await perform {
            guard let device = self.device, self.session.isRunning, !self.session.isInterrupted else {
                throw CameraFailure("相機目前無法使用。")
            }
            try device.lockForConfiguration()
            self.setAutomaticModes(device)
            device.setExposureTargetBias(0, completionHandler: nil)
            self.restoreFrameTiming(device)
            device.unlockForConfiguration()
            return try self.snapshot()
        }
    }

    private func applyZoom(_ magnification: Double, to device: AVCaptureDevice) {
        let factor = CGFloat(zoomScale(device).hardwareFactor(for: magnification))
        if device.videoZoomFactor != factor { device.videoZoomFactor = factor }
    }

    private func setAutomaticModes(_ device: AVCaptureDevice) {
        setAutomaticExposure(device)
        setAutomaticFocus(device)
        setAutomaticWhiteBalance(device)
    }

    private func restoreFrameTiming(_ device: AVCaptureDevice) {
        // Long manual exposures extend the frame duration. Restore it before the
        // next exposure so a shorter shutter can return to normal preview speed.
        guard let timing = nominalTiming, timing.format == device.activeFormat,
              !device.isAutoVideoFrameRateEnabled else { return }
        device.activeVideoMinFrameDuration = timing.min
        device.activeVideoMaxFrameDuration = timing.max
    }

    private func setAutomaticExposure(_ device: AVCaptureDevice) {
        if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
        else if device.isExposureModeSupported(.autoExpose) { device.exposureMode = .autoExpose }
    }

    private func setAutomaticFocus(_ device: AVCaptureDevice) {
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        else if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus }
    }

    private func setAutomaticWhiteBalance(_ device: AVCaptureDevice) {
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
        else if device.isWhiteBalanceModeSupported(.autoWhiteBalance) { device.whiteBalanceMode = .autoWhiteBalance }
    }

    private func zoomScale(_ device: AVCaptureDevice) -> CameraZoomScale {
        CameraZoomScale(
            hardwareRange: Double(device.minAvailableVideoZoomFactor)...Double(device.maxAvailableVideoZoomFactor),
            displayMultiplier: Double(device.displayVideoZoomFactorMultiplier)
        )
    }

    private func capabilities(_ device: AVCaptureDevice) -> CameraCapabilities {
        CameraCapabilities(
            iso: Double(device.activeFormat.minISO)...Double(device.activeFormat.maxISO),
            shutter: device.activeFormat.minExposureDuration.seconds...device.activeFormat.maxExposureDuration.seconds,
            zoom: zoomScale(device).displayRange,
            manualExposure: device.isExposureModeSupported(.custom),
            manualFocus: device.isFocusModeSupported(.locked) && device.isLockingFocusWithCustomLensPositionSupported,
            manualWhiteBalance: device.isWhiteBalanceModeSupported(.locked) && device.isLockingWhiteBalanceWithCustomDeviceGainsSupported,
            exposureBias: Double(device.minExposureTargetBias)...Double(device.maxExposureTargetBias),
            automaticExposure: device.isExposureModeSupported(.continuousAutoExposure) || device.isExposureModeSupported(.autoExpose),
            zoomPresets: zoomScale(device).presets(
                switchOverFactors: device.virtualDeviceSwitchOverVideoZoomFactors.map(\.doubleValue)
            )
        )
    }

    private func whiteBalanceReadback(_ device: AVCaptureDevice) -> AVCaptureDevice.WhiteBalanceTemperatureAndTintValues {
        // A newly started/reconnected device can report unsettled gains. The
        // conversion API raises NSRangeException for invalid input, even when
        // that input came directly from deviceWhiteBalanceGains.
        guard let gains = CameraOutputValidation.whiteBalanceGains(
            device.deviceWhiteBalanceGains, maximum: device.maxWhiteBalanceGain
        ) else { return .init(temperature: 5000, tint: 0) }
        return device.temperatureAndTintValues(for: gains)
    }

    private func snapshot() throws -> CameraSnapshot {
        guard let device else { throw CameraFailure("相機尚未就緒。") }
        let whiteBalance = whiteBalanceReadback(device)
        // Preserve enough digits for values at device boundaries to round-trip.
        let settings = CameraSettings(
            automaticExposure: device.exposureMode != .custom,
            automaticFocus: device.focusMode != .locked,
            automaticWhiteBalance: device.whiteBalanceMode != .locked,
            iso: String(Double(device.iso)), shutter: String(device.exposureDuration.seconds),
            focus: String(Double(device.lensPosition)),
            temperature: String(Double(whiteBalance.temperature)), tint: String(Double(whiteBalance.tint)),
            zoom: String(zoomScale(device).displayed(Double(device.videoZoomFactor))), exposureBias: String(Double(device.exposureTargetBias))
        )
        return CameraSnapshot(deviceID: device.uniqueID, rotationDevice: device, photoOutput: photoOutput, responsiveCapture: photoOutput.isResponsiveCaptureEnabled, previewID: previewID, previewBegan: previewBegan ?? ProcessInfo.processInfo.systemUptime, capabilities: capabilities(device), settings: settings,
                              running: session.isRunning, interrupted: session.isInterrupted,
                              previewPresented: reportedPreview)
    }

    private func perform<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try operation() }) }
        }
    }
}
