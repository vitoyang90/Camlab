import AVFoundation
import Observation
import OSLog

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
    var isCapturing = false
    var lastPhoto: SavedPhoto?
    var reviewPhoto: SavedPhoto?
    var pendingPhotos: [SavedPhoto] = []
    var lastThumbnail: Data?
    var photoToEdit: PhotoEditorSource?
    private let photoProcessor = PhotoProcessor()
    var snapshot: CameraSnapshot?
    var previewReady = false
    var isBusy = false
    var needsPermission = false
    var errorMessage: String?
    var status = "正在準備相機…"
    private var active = false
    private var generation = 0
    var isAdjusting = false
    private var adjustmentBuffer = CameraAdjustmentBuffer()
    private var adjustmentTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "Camlab", category: "CameraStartup")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        recipes = RecipeStore(defaults: defaults)
        nativePhotosWorkflow = PhotoWorkflowPreferences.nativePhotosEnabled(defaults: defaults)
        service.setPreviewPresentationHandler { [weak self] id in
            Task { @MainActor [weak self] in
                guard let self, self.active, !self.isBusy,
                      self.snapshot?.previewID == id else { return }
                self.previewReady = true
                if !self.isCapturing { self.status = "相機已就緒" }
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
        active && previewReady && !isBusy && !isCapturing && snapshot?.running == true && snapshot?.interrupted == false
    }

    var canPreview: Bool {
        active && snapshot?.running == true && snapshot?.interrupted == false
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

    func restoreLastPhoto() async {
        pendingPhotos = await photoProcessor.pending()
        if lastPhoto == nil { lastPhoto = await photoProcessor.latest() }
        if let lastPhoto, !pendingPhotos.contains(where: { $0.id == lastPhoto.id }) { pendingPhotos.append(lastPhoto) }
        if let lastPhoto { lastThumbnail = try? Data(contentsOf: lastPhoto.thumbnailURL) }
    }

    func capture() async {
        guard canControl else { return }
        // Commit valid pending numeric edits before releasing the shutter.
        _ = await execute(replaceDraft: false) { try await self.service.apply(self.draft) }
        guard canControl, errorMessage == nil else { return }
        let nativeWorkflow = nativePhotosWorkflow
        let style = captureStyle
        isCapturing = true
        errorMessage = nil
        status = "正在拍攝…"
        defer { isCapturing = false }
        do {
            let original = try await service.capturePhoto()
            status = "正在製作\(style.name)成品…"
            let photo = try await photoProcessor.process(original, style: style, nativePhotosWorkflow: nativeWorkflow)
            lastPhoto = photo
            lastThumbnail = try? Data(contentsOf: photo.thumbnailURL)
            pendingPhotos = await photoProcessor.pending()
            status = "正在儲存至相簿…"
            let saved = try await PhotoLibrarySaver.save(photo, processor: photoProcessor)
            try await photoProcessor.complete(saved)
            lastPhoto = nil
            pendingPhotos = await photoProcessor.pending()
            status = nativeWorkflow ? "原圖已儲存，請到「照片」完成調整" : "已儲存至相簿"
            if nativeWorkflow { photoToEdit = PhotoEditorSource(assetIdentifier: saved.assetIdentifier) }
        } catch {
            pendingPhotos = await photoProcessor.pending()
            if let staged = lastPhoto { lastPhoto = pendingPhotos.first { $0.id == staged.id } ?? staged }
            errorMessage = error.localizedDescription
            status = pendingPhotos.isEmpty ? "拍攝未完成，請重試" : "照片尚未儲存，可開啟待儲存照片重試"
        }
    }

    func openLastPhoto() async {
        if let pending = pendingPhotos.first { photoToEdit = PhotoEditorSource(pending: pending); return }
        guard let id = PhotoLibrarySaver.lastAssetIdentifier else { return }
        photoToEdit = PhotoEditorSource(assetIdentifier: id)
    }

    func retryPending(_ photo: SavedPhoto) async {
        guard !isCapturing else { return }
        isCapturing = true
        defer { isCapturing = false }
        do {
            // Read the journal first: a prior attempt may have saved the original.
            let current = await photoProcessor.pending().first { $0.id == photo.id } ?? photo
            let saved = try await PhotoLibrarySaver.save(current, processor: photoProcessor)
            try await photoProcessor.complete(saved)
            pendingPhotos = await photoProcessor.pending()
            errorMessage = nil
            status = "已儲存至相簿"
        } catch {
            pendingPhotos = await photoProcessor.pending()
            errorMessage = error.localizedDescription
        }
    }

    func resume() async {
        guard !active else { return }
        await activate()
    }

    func activate() async {
        cancelLiveAdjustments()
        generation += 1
        let request = generation
        active = true
        previewReady = false
        snapshot = nil
        isBusy = true
        errorMessage = nil
        needsPermission = false
        status = "正在尋找內建相機…"
        do {
            cameras = try await service.cameras()
            guard request == generation, active, !Task.isCancelled else { return }
            guard !cameras.isEmpty else {
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
            let result = try await service.start(deviceID: selectedCameraID.isEmpty ? nil : selectedCameraID)
            guard request == generation, active, !Task.isCancelled else { return }
            accept(result, replaceDraft: true)
            logger.info("Camera ready published after \(ProcessInfo.processInfo.systemUptime - result.previewBegan, privacy: .public) seconds")
        } catch {
            guard request == generation else { return }
            errorMessage = error.localizedDescription
            status = "無法連接相機"
        }
        if request == generation { isBusy = false }
    }

    func deactivate() async {
        cancelLiveAdjustments()
        active = false
        previewReady = false
        generation += 1
        isBusy = false
        status = "相機已暫停"
        await service.stop()
    }

    func selectCamera(_ id: String) async {
        guard canControl else { return }
        previewReady = false
        await execute(replaceDraft: true) { try await self.service.start(deviceID: id) }
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
            while !Task.isCancelled {
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
        guard active, !isBusy, !isAdjusting, snapshot != nil else { return }
        let request = generation
        do {
            let result = try await service.read()
            guard request == generation, active, !isBusy else { return }
            let wasUnavailable = snapshot?.interrupted == true || snapshot?.running == false
            snapshot = result
            if result.interrupted { status = "相機使用中斷，等待系統恢復…" }
            else if !result.running { status = "相機已停止，請重新連線" }
            else if wasUnavailable { status = "相機已恢復" }
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
        snapshot = result
        selectedCameraID = result.deviceID
        if replaceDraft { draft = result.settings }
        status = result.interrupted ? "相機使用中斷，等待系統恢復…" : result.running ? (previewReady ? "相機已連接" : "相機已啟動，正在顯示預覽…") : "相機已停止，請重新連線"
    }
}
