import AVFoundation
import Photos
import Observation
import OSLog
import UIKit

@MainActor @Observable
final class CameraModel {
    let service = CameraService()
    let recipes: RecipeStore
    private let defaults: UserDefaults
    var nativePhotosWorkflow: Bool {
        didSet { defaults.set(nativePhotosWorkflow, forKey: PhotoWorkflowPreferences.nativeKey) }
    }
    var previewStyle: StyleAdjustment { nativePhotosWorkflow ? StyleAdjustment() : recipes.style }
    var captureStyle: StyleAdjustment {
        nativePhotosWorkflow ? StyleAdjustment(recipe: recipes.draft, recipeName: "原圖 · 待原生調整") : recipes.style
    }
    var cameras: [CameraChoice] = []
    var selectedCameraID = ""
    var draft = CameraSettings()
    var styleDraft = StyleDraft()
    var appliedStyle = StyleAdjustment()
    var selectedScene = ShootingScene.everyday
    private var captures = PhotoCaptureBuffer()
    var isCapturing: Bool { !captures.isEmpty }
    private(set) var lastBurstID: UUID?
    private(set) var burstCount = 0
    private var failedBurstID: UUID?
    private(set) var singleShotFlashCount = 0
    var lastPhoto: SavedPhoto?
    var reviewPhoto: SavedPhoto?
    var pendingPhotos: [SavedPhoto] = []
    var lastThumbnail: UIImage?
    private var thumbnailPhotoID: UUID?
    private var thumbnailAssetID: String?
    var photoToEdit: PhotoEditorSource?
    private let photoProcessor: PhotoProcessor
    private let savePhoto: @MainActor (SavedPhoto, PhotoProcessor) async throws -> SavedPhoto
    private let canRecoverPhotos: @MainActor () -> Bool
    private var sceneActive = false
    private var attemptedRecovery: Set<UUID> = []
    private let photoSaveQueue: PhotoSaveQueue
    private var pendingRevision = 0
    var processingPhotoCount: Int { photoSaveQueue.count }
    var photoQueueIsFull: Bool { photoSaveQueue.count + captures.shots.count >= photoSaveQueue.capacity }
    private let photoReadiness = PhotoCaptureReadiness()
    var snapshot: CameraSnapshot?
    var previewReady = false
    var startupState = CameraStartupState.starting
    var isBusy = false
    var needsPermission = false
    var errorMessage: String?
    var status = "正在準備相機…"
    private var active = false
    private(set) var visibilityID: UUID?
    private var resumeTask: Task<Void, Never>?
    private var firstFrameWait = FirstFrameWait()
    private var generation = 0
    private var automaticRecoveryAttempted = false
    private var activationBegan: TimeInterval?
    var isAdjusting = false
    private var adjustmentBuffer = CameraAdjustmentBuffer()
    private var adjustmentTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "Camlab", category: "CameraStartup")

    init(defaults: UserDefaults = .standard, photoSaveQueue: PhotoSaveQueue? = nil,
         photoProcessor: PhotoProcessor = PhotoProcessor(),
         savePhoto: @escaping @MainActor (SavedPhoto, PhotoProcessor) async throws -> SavedPhoto = {
             try await PhotoLibrarySaver.save($0, processor: $1)
         }, canRecoverPhotos: @escaping @MainActor () -> Bool = {
             let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
             return status == .authorized || status == .limited
         }) {
        self.defaults = defaults
        self.photoSaveQueue = photoSaveQueue ?? PhotoSaveQueue()
        self.photoProcessor = photoProcessor
        self.savePhoto = savePhoto
        self.canRecoverPhotos = canRecoverPhotos
        recipes = RecipeStore(defaults: defaults)
        nativePhotosWorkflow = PhotoWorkflowPreferences.nativePhotosEnabled(defaults: defaults)
        service.setPreviewPresentationHandler { [weak self] id in
            Task { @MainActor [weak self] in
                guard let self, self.active,
                      self.snapshot?.previewID == id,
                      self.snapshot?.running == true, self.snapshot?.interrupted == false else { return }
                self.markPreviewReady()
                if let began = self.snapshot?.previewBegan {
                    self.logger.info("Camera preview confirmed in UI after \(ProcessInfo.processInfo.systemUptime - began, privacy: .public) seconds")
                }
            }
        }
    }

    var canControl: Bool {
        canAdjust && !isAdjusting
    }

    var canAdjust: Bool {
        canPreview && previewReady && !isBusy && !isCapturing
    }

    var canPreview: Bool {
        sceneActive && active && snapshot?.running == true && snapshot?.interrupted == false
    }

    var canCapture: Bool {
        canPreview && photoReadiness.isReady && !isBusy &&
            captures.hasRoom(responsive: snapshot?.responsiveCapture == true, saveSlots: photoSaveQueue.capacity - photoSaveQueue.count)
    }

    func selectShootingRecipe(_ id: UUID?) {
        do {
            try recipes.select(id)
            activateSelectedShootingStyle()
        } catch { errorMessage = error.localizedDescription }
    }

    func activateSelectedShootingStyle() {
        // A built-in shooting mode always previews and saves its effect, even
        // when the previous session used the optional native Photos workflow.
        if recipes.selectedStyle != nil { nativePhotosWorkflow = false }
    }

    func chooseStyle(_ preset: PhotoStyle) {
        let amount = styleDraft.intensity
        var style = preset.adjustment
        style.intensity = amount
        appliedStyle = style
        styleDraft = StyleDraft(style)
    }

    func setStyleIntensity(_ amount: Double) {
        let value = min(1, max(0, amount))
        styleDraft.intensity = value
        appliedStyle.intensity = value
    }

    private func refreshPendingPhotos() async {
        pendingRevision += 1
        let request = pendingRevision
        let photos = await photoProcessor.pending()
        guard request == pendingRevision else { return }
        // In-flight files belong to the save worker, not the editor/retry UI.
        pendingPhotos = photos.filter { !photoSaveQueue.photoIDs.contains($0.id) && !captures.contains($0.id) }
        lastPhoto = pendingPhotos.first
    }

    func restoreLastPhoto() async {
        await refreshPendingPhotos()
        resumePendingPhotos()
        guard processingPhotoCount == 0, let photo = lastPhoto else { return }
        let thumbnail = await photoProcessor.thumbnail(for: photo)
        if processingPhotoCount == 0, lastPhoto?.id == photo.id {
            lastThumbnail = thumbnail
            thumbnailPhotoID = photo.id
            thumbnailAssetID = photo.assetIdentifier
        }
    }

    private func resumePendingPhotos() {
        guard sceneActive, !isCapturing, photoToEdit == nil, canRecoverPhotos() else { return }
        // Refill the bounded queue as each job finishes. Failures are attempted
        // only once per process, then remain visible for an explicit retry.
        for photo in pendingPhotos.reversed() {
            guard photoSaveQueue.hasCapacity else { break }
            guard !attemptedRecovery.contains(photo.id) else { continue }
            enqueuePhoto(photo, style: nil)
        }
    }

    func capture(burstID: UUID?, whileRequested requested: @MainActor () -> Bool) async -> Bool {
        guard requested(), canCapture, burstID == nil || burstID != failedBurstID else { return false }
        let requestedAt = ProcessInfo.processInfo.systemUptime
        guard await finishLiveAdjustments(), requested(), canCapture, let snapshot else { return false }
        do {
            // The usual automatic shot needs no device lock, exposure reset or
            // hardware readback before capture. Still validate pending edits.
            if try draft.requiresApplication(comparedTo: snapshot.settings, capabilities: snapshot.capabilities) {
                guard await execute(replaceDraft: false, operation: { try await self.service.apply(self.draft) }) else { return false }
            }
        } catch { errorMessage = error.localizedDescription; return false }
        guard requested(), canCapture, !isAdjusting, self.snapshot?.previewID == snapshot.previewID else { return false }
        let shot = PhotoCaptureBuffer.Shot(previewID: snapshot.previewID, burstID: burstID, style: captureStyle,
                                           nativeWorkflow: nativePhotosWorkflow,
                                           backgroundTask: PhotoBackgroundTask(name: "Preserve captured original"))
        if lastBurstID != burstID {
            lastBurstID = burstID
            burstCount = 0
        }
        captures.append(shot)
        status = "正在拍攝…"
        errorMessage = nil
        let id = shot.id
        let accepted = await withCheckedContinuation { continuation in
            service.capturePhoto(previewID: shot.previewID, requestedAt: requestedAt, submitted: { accepted in
                continuation.resume(returning: accepted)
            }, didCapture: { [weak self] in
                Task { @MainActor [weak self] in self?.recordExposure(id) }
            }, completion: { [self] result in
                Task { @MainActor in await finishCapture(result, id: id) }
            })
        }
        if accepted {
            photoReadiness.updateReadiness()
            captures.markSubmitted(id)
        }
        return accepted
    }

    private func recordExposure(_ id: UUID) {
        guard let shot = captures.recordExposure(id), active, snapshot?.previewID == shot.previewID else { return }
        if let burstID = shot.burstID {
            if lastBurstID == burstID { burstCount += 1 }
        } else {
            singleShotFlashCount += 1
        }
    }

    private func finishCapture(_ result: Result<Data, Error>, id: UUID) async {
        if case .success = result { recordExposure(id) }
        guard let shot = captures.beginStaging(id) else { return }
        let staged: Result<SavedPhoto, Error>
        do {
            let photo = try await photoProcessor.stage(result.get(), style: shot.style, nativePhotosWorkflow: shot.nativeWorkflow,
                                                       id: shot.id, createdAt: shot.createdAt)
            staged = .success(photo)
        } catch {
            staged = .failure(error)
            failedBurstID = shot.burstID
            errorMessage = error.localizedDescription
            status = "拍攝未完成，請重試"
        }
        var needsRecoveryScan = false
        for finished in captures.finishStaging(staged, id: id) {
            if case .success(let photo) = finished.result { enqueuePhoto(photo, style: finished.style) }
            else { needsRecoveryScan = true }
            finished.backgroundTask.finish()
        }
        if needsRecoveryScan { await refreshPendingPhotos() }
        resumePendingPhotos()
    }

    private func enqueuePhoto(_ photo: SavedPhoto, style: StyleAdjustment?) {
        let accepted = photoSaveQueue.enqueue(id: photo.id, operation: { [self] in
            let rendered: SavedPhoto
            if let style { rendered = try await photoProcessor.processStaged(photo, style: style) }
            else { rendered = try await photoProcessor.prepareForSaving(photo) }
            if let thumbnail = await photoProcessor.thumbnail(for: rendered) {
                lastThumbnail = thumbnail
                thumbnailPhotoID = rendered.id
                thumbnailAssetID = rendered.assetIdentifier
            }
            let saved = try await savePhoto(rendered, photoProcessor)
            if thumbnailPhotoID == saved.id { thumbnailAssetID = saved.assetIdentifier }
            try await photoProcessor.complete(saved)
            // Stay in the camera for subsequent shots, including native Photos mode.
        }, completion: { [self] result in
            if case .failure(let error) = result {
                errorMessage = error.localizedDescription
                await refreshPendingPhotos()
            }
            resumePendingPhotos()
            if !isCapturing, active {
                status = pendingPhotos.isEmpty ? "已儲存至相簿" : "照片尚未儲存，可開啟待儲存照片重試"
            }
        })
        if accepted {
            attemptedRecovery.insert(photo.id)
            pendingPhotos.removeAll { $0.id == photo.id }
            lastPhoto = pendingPhotos.first
        } else {
            // A staged original is never discarded if a caller loses its slot.
            errorMessage = "待處理照片已滿，原圖已保留，可稍後重試儲存。"
        }
    }

    func openLastPhoto() async {
        if let pending = pendingPhotos.first { photoToEdit = PhotoEditorSource(pending: pending); return }
        guard let id = PhotoLibrarySaver.lastAssetIdentifier else { return }
        photoToEdit = PhotoEditorSource(assetIdentifier: id)
    }

    func deletePhoto(_ target: PhotoDeletionTarget) async throws {
        switch target {
        case .library(let identifier):
            try await deleteLibraryPhotos([identifier])
        case .pending(let photo):
            guard !photoSaveQueue.photoIDs.contains(photo.id), !captures.contains(photo.id) else {
                throw CameraFailure("這張照片正在儲存，請稍後再試。")
            }
            try await photoProcessor.removeLocalCopy(photo)
            if thumbnailPhotoID == photo.id { clearThumbnail() }
            pendingRevision += 1
            pendingPhotos.removeAll { $0.id == photo.id }
            lastPhoto = pendingPhotos.first
        }
    }

    func deleteLibraryPhotos(_ identifiers: Set<String>) async throws {
        try await PhotoLibrarySaver.deleteAssets(identifiers)
        if let thumbnailAssetID, identifiers.contains(thumbnailAssetID) { clearThumbnail() }
    }

    private func clearThumbnail() {
        lastThumbnail = nil
        thumbnailPhotoID = nil
        thumbnailAssetID = nil
    }

    func retryPending(_ photo: SavedPhoto) async {
        guard !isCapturing, photoSaveQueue.hasCapacity, !photoSaveQueue.photoIDs.contains(photo.id) else { return }
        enqueuePhoto(photo, style: nil)
        await refreshPendingPhotos()
    }

    func setCameraVisible(_ visible: Bool) {
        if !visible {
            if visibilityID != nil { deactivate() }
            return
        }
        if visibilityID == nil {
            let id = UUID()
            visibilityID = id
            service.setVisibility(id)
        } else if startupState != .permissionRequired && startupState != .failed && startupState != .paused { return }
        resumeTask?.cancel()
        resumeTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            await self?.activate()
        }
    }

    func setSceneActive(_ active: Bool) {
        // Photo work follows the app's scene, independently of camera/editor visibility.
        photoSaveQueue.setForeground(active)
        sceneActive = active
        if !active { firstFrameWait.reset() }
        if active { Task { await restoreLastPhoto() } }
    }

    func activate(isAutomaticRecovery: Bool = false) async {
        guard visibilityID != nil, !isBusy, !Task.isCancelled else { return }
        let restart = isAutomaticRecovery || startupState == .failed
        if restart {
            let id = UUID()
            visibilityID = id
            service.setVisibility(id)
        }
        firstFrameWait.reset()
        activationBegan = ProcessInfo.processInfo.systemUptime
        cancelLiveAdjustments()
        generation += 1
        let request = generation
        active = true
        automaticRecoveryAttempted = isAutomaticRecovery
        startupState = .starting
        previewReady = false
        snapshot = nil
        isBusy = true
        errorMessage = nil
        needsPermission = false
        status = "正在尋找內建相機…"
        defer {
            if request == generation {
                isBusy = false
                if Task.isCancelled {
                    active = false
                    startupState = .paused
                }
            }
        }
        do {
            cameras = try await service.cameras()
            guard request == generation, active, !Task.isCancelled else { return }
            guard !cameras.isEmpty else {
                startupState = .unavailable
                throw CameraFailure("找不到可用的內建相機。請使用實體 iPhone 或 iPad；模擬器無法提供相機畫面。")
            }
            let authorized: Bool
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: authorized = true
            case .notDetermined:
                status = "請允許使用相機…"
                authorized = await AVCaptureDevice.requestAccess(for: .video)
            default: authorized = false
            }
            guard request == generation, active, !Task.isCancelled else { return }
            needsPermission = !authorized
            guard authorized else {
                isBusy = false
                startupState = .permissionRequired
                status = "尚未取得相機權限"
                errorMessage = "請到「設定」允許 Camlab 使用相機，再返回 App。"
                return
            }
            status = "正在啟動相機預覽…"
            let slowStartHint = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(8)) } catch { return }
                guard request == self.generation, self.active, self.isBusy else { return }
                self.status = "相機啟動較久，正在等待系統…"
            }
            defer { slowStartHint.cancel() }
            let id = selectedCameraID.isEmpty ? nil : selectedCameraID
            let result = try await CameraStartupRetry.run {
                try await self.startCamera(deviceID: id, request: request, restart: restart)
            }
            guard request == generation, active, !Task.isCancelled else { return }
            accept(result, replaceDraft: true)
            logger.info("Camera ready published after \(ProcessInfo.processInfo.systemUptime - result.previewBegan, privacy: .public) seconds")
        } catch {
            guard request == generation, active, !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
            if startupState != .unavailable { startupState = .failed }
            status = startupState == .unavailable ? "此裝置無法使用相機" : "相機暫時無法使用"
        }
    }

    func deactivate() {
        lastBurstID = nil
        burstCount = 0
        visibilityID = nil
        resumeTask?.cancel()
        resumeTask = nil
        firstFrameWait.reset()
        cancelLiveAdjustments()
        active = false
        startupState = .paused
        previewReady = false
        snapshot = nil
        generation += 1
        isBusy = false
        status = "相機已暫停"
        service.setVisibility(nil)
    }

    func selectCamera(_ id: String) async {
        guard canAdjust, await finishLiveAdjustments(), canControl, let visibilityID else { return }
        lastBurstID = nil
        burstCount = 0
        activationBegan = ProcessInfo.processInfo.systemUptime
        previewReady = false
        startupState = .starting
        let request = generation + 1
        let succeeded = await execute(replaceDraft: true) { try await self.service.start(deviceID: id, visibilityID: visibilityID) }
        if !succeeded, active, request == generation {
            startupState = .failed
        }
    }

    var flipCameraTarget: CameraChoice? {
        CameraChoice.flipTarget(in: cameras, currentID: selectedCameraID)
    }

    func flipCamera() async {
        guard let target = flipCameraTarget else { return }
        await selectCamera(target.id)
    }

    func focus(at point: CGPoint) async {
        guard canControl else { return }
        if await execute(replaceDraft: false, operation: { try await self.service.focus(at: point) }), let settings = snapshot?.settings {
            draft.automaticFocus = settings.automaticFocus
            draft.focus = settings.focus
        }
    }

    func setZoom(_ factor: Double) async {
        guard canControl else { return }
        if await execute(replaceDraft: false, operation: { try await self.service.setZoom(factor) }) {
            draft.zoom = String(factor)
        }
    }

    func adjustLive(_ adjustment: CameraLiveAdjustment) {
        guard canAdjust, let snapshot else { return }
        do { try adjustment.validate(for: snapshot.capabilities) }
        catch { errorMessage = error.localizedDescription; return }
        adjustment.updateDraft(&draft, readback: snapshot.settings)
        adjustmentBuffer.enqueue(adjustment)
        guard adjustmentTask == nil else { return }
        isAdjusting = true
        let request = generation
        adjustmentTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if request == self.generation {
                    self.adjustmentTask = nil
                    self.adjustmentBuffer.removeAll()
                    self.isAdjusting = false
                }
            }
            while !Task.isCancelled, !self.adjustmentBuffer.isEmpty {
                do { try await Task.sleep(for: .milliseconds(60)) } catch { break }
                guard request == self.generation, self.canAdjust,
                      let next = self.adjustmentBuffer.next() else { break }
                do {
                    let result = try await self.service.adjustLive(next)
                    guard request == self.generation, !Task.isCancelled else { break }
                    self.snapshot = result
                    self.errorMessage = nil
                } catch {
                    guard request == self.generation, !Task.isCancelled else { break }
                    if !self.adjustmentBuffer.contains(control: next.control), let settings = self.snapshot?.settings {
                        next.restoreDraft(&self.draft, readback: settings)
                    }
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    // Keep the controls available while zoom settles, but submit the next camera
    // operation only after the pending device writes finish on the same session.
    private func finishLiveAdjustments() async -> Bool {
        let request = generation
        await adjustmentTask?.value
        return request == generation && !isAdjusting
    }

    private func cancelLiveAdjustments() {
        adjustmentTask?.cancel()
        adjustmentTask = nil
        adjustmentBuffer.removeAll()
        isAdjusting = false
    }

    func apply() async {
        guard canControl else { return }
        let style: StyleAdjustment
        do { style = try styleDraft.validated() }
        catch { errorMessage = error.localizedDescription; return }
        let settings = draft
        let succeeded = await execute(replaceDraft: false) { try await self.service.apply(settings) }
        if succeeded {
            appliedStyle = style
            status = "已套用\(style.name)風格；曝光回報值持續更新"
        }
    }

    func restoreAutomatic() async {
        guard canControl else { return }
        if await execute(replaceDraft: true, operation: { try await self.service.restoreAutomatic() }) {
            appliedStyle = StyleAdjustment()
            styleDraft = StyleDraft()
        }
    }

    func refresh() async {
        guard sceneActive, active, !isBusy, !isAdjusting, snapshot != nil else { return }
        let request = generation
        do {
            let result = try await service.read()
            guard request == generation, sceneActive, active, !isBusy else { return }
            let wasUnavailable = snapshot?.interrupted == true || snapshot?.running == false
            snapshot = result
            if result.interrupted {
                firstFrameWait.reset()
                previewReady = false
                startupState = .interrupted
                status = "相機暫時被系統暫停，恢復後會自動開啟"
            } else if !result.running || (!result.previewPresented && firstFrameWait.expired(for: result.previewID)) {
                guard !isCapturing else { return }
                if !automaticRecoveryAttempted {
                    await activate(isAutomaticRecovery: true)
                } else {
                    startupState = .failed
                    snapshot = nil
                    previewReady = false
                    errorMessage = "相機未恢復取景畫面，請重試開啟相機。"
                    status = "相機暫時無法使用"
                }
            } else if result.previewPresented {
                if !previewReady || startupState != .ready { markPreviewReady() }
            } else if wasUnavailable {
                startupState = .waitingForPreview
                status = "正在開啟相機…"
            }
        } catch {
            if request == generation { errorMessage = error.localizedDescription }
        }
    }

    @discardableResult
    private func execute(replaceDraft: Bool, operation: () async throws -> CameraSnapshot) async -> Bool {
        generation += 1
        let request = generation
        isBusy = true
        errorMessage = nil
        do {
            let result = try await operation()
            guard request == generation, active else { return false }
            accept(result, replaceDraft: replaceDraft)
            isBusy = false
            return true
        } catch {
            if request == generation { errorMessage = error.localizedDescription }
        }
        if request == generation { isBusy = false }
        return false
    }

    private func accept(_ result: CameraSnapshot, replaceDraft: Bool) {
        previewReady = result.previewPresented || (snapshot?.previewID == result.previewID && previewReady)
        snapshot = result
        photoReadiness.observe(result.photoOutput, startupID: result.previewID, began: activationBegan ?? result.previewBegan)
        selectedCameraID = result.deviceID
        if replaceDraft { draft = result.settings }
        startupState = result.interrupted ? .interrupted : result.running ? (previewReady ? .ready : .waitingForPreview) : .failed
        status = result.interrupted ? "相機暫時被系統暫停，恢復後會自動開啟" : result.running ? (previewReady ? "相機已就緒" : "正在開啟相機…") : "相機暫時無法使用"
    }

    private func markPreviewReady() {
        firstFrameWait.reset()
        previewReady = true
        startupState = .ready
        automaticRecoveryAttempted = false
        if !isCapturing { status = "相機已就緒" }
    }

    private func startCamera(deviceID: String?, request: Int, restart: Bool) async throws -> CameraSnapshot {
        // A background/editor transition can happen during the retry delay.
        // Do not restart a camera that the user has already left.
        guard let visibilityID, active, request == generation else { throw CancellationError() }
        return try await service.start(deviceID: deviceID, visibilityID: visibilityID, restart: restart)
    }
}
