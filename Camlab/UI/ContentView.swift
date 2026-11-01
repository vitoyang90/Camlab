import SwiftUI
import PhotosUI

private enum ShootingControl: String, CaseIterable, Identifiable {
    case brightness, iso, shutter, focus, whiteBalance, zoom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .brightness: "拍攝亮度"
        case .iso: "感光度"
        case .shutter: "快門"
        case .focus: "對焦"
        case .whiteBalance: "白平衡"
        case .zoom: "變焦"
        }
    }
}

struct ContentView: View {
    @State private var camera = CameraModel()
    @State private var level = HorizonLevel()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("Camlab.ShowGrid") private var showGrid = false
    @AppStorage("Camlab.ShowLevel") private var showLevel = true
    @State private var expanded = false
    @State private var showStyleWheel = false
    @State private var lensTurns = 0.0
    @State private var lensFlipID: UUID?
    @State private var outgoingPreview: CameraSnapshot?
    @State private var cameraPageVisible = false
    @State private var colorControls = true
    @State private var parameter = AdjustmentParameter.saturation
    @State private var shootingControl = ShootingControl.brightness
    @State private var numericText: String?
    @State private var showPhotoPicker = false
    @State private var photoPickerDismissed = true
    @State private var importedPhoto: PhotoEditorSource?
    @State private var showPending = false
    @State private var showPreferences = false
    @State private var compareOriginal = false
    private let accent = Color(red: 0.98, green: 0.81, blue: 0.30)

    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            let layout = landscape ? AnyLayout(HStackLayout(spacing: 12)) : AnyLayout(VStackLayout(spacing: 8))
            // Keep the Metal view and its rotation coordinator alive while the
            // layout changes, including before the first frame is presented.
            layout {
                if !landscape { topControls.padding(.horizontal, 4) }
                viewfinder(landscape: landscape)
                    .aspectRatio(landscape ? 4 / 3 : 3 / 4, contentMode: .fit)
                let panelLayout = landscape ? AnyLayout(HStackLayout(spacing: 12)) : AnyLayout(VStackLayout(spacing: 12))
                panelLayout {
                    if expanded && camera.photoToEdit == nil {
                        controls(compact: landscape)
                            .frame(width: landscape ? (numericText == nil
                                   ? min(164, max(140, geometry.size.width * 0.19))
                                   : min(184, max(164, geometry.size.width * 0.21))) : nil)
                            .frame(maxHeight: landscape ? .infinity : nil)
                            .transition(InterfaceMotion.reveal(reduceMotion: reduceMotion, horizontal: landscape))
                    }
                    actions(landscape: landscape).frame(width: landscape ? 72 : nil)
                }
                .padding(landscape ? 0 : 16)
                .background(landscape || !expanded ? Color.clear : Color(white: 0.075), in: RoundedRectangle(cornerRadius: 24))
                .padding(.horizontal, landscape ? 0 : 10).padding(.bottom, landscape ? 0 : 6)
            }
            .padding(.horizontal, landscape ? 8 : 0).padding(.vertical, landscape ? 8 : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { dismissStyleBackdrop }
            .accessibilityHidden(camera.photoToEdit != nil)
            // Animate structural UI changes only, not frame delivery or slider values.
            .onChange(of: expanded) { _, isExpanded in
                if !isExpanded { compareOriginal = false }
            }
            .animation(InterfaceMotion.layout(reduceMotion: reduceMotion), value: expanded)
            .animation(InterfaceMotion.layout(reduceMotion: reduceMotion), value: numericText == nil)
            .animation(InterfaceMotion.layout(reduceMotion: reduceMotion), value: colorControls)
            .animation(InterfaceMotion.layout(reduceMotion: reduceMotion), value: showStyleWheel)
        }
        .background(Color.black.ignoresSafeArea()).foregroundStyle(.white)
        .tint(accent).preferredColorScheme(.dark)
        .statusBarHidden()
        .onAppear {
            cameraPageVisible = true
            camera.setSceneActive(scenePhase == .active)
            updateCameraVisibility()
            if showLevel && scenePhase == .active { level.start() }
        }
        .task {
            if let error = camera.recipes.loadError { camera.errorMessage = error }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
                await camera.refresh()
            }
        }
        .onChange(of: showLevel) { _, value in if value { level.start() } else { level.stop() } }
        .onChange(of: colorControls) { _, _ in compareOriginal = false }
        .onChange(of: numericText != nil) { _, _ in compareOriginal = false }
        .onChange(of: camera.recipes.draft) { _, _ in compareOriginal = false }
        .onChange(of: scenePhase) { _, phase in
            camera.setSceneActive(phase == .active)
            updateCameraVisibility()
            if phase == .background { level.stop() }
            else if phase == .active {
                if showLevel { level.start() }
            }
        }
        .onChange(of: camera.photoToEdit?.id) { _, id in
            updateCameraVisibility()
            if id == nil { Task { await camera.restoreLastPhoto() } }
        }
        .onDisappear {
            cameraPageVisible = false
            level.stop()
            updateCameraVisibility()
        }
        .sheet(isPresented: $showPhotoPicker, onDismiss: {
            photoPickerDismissed = true
            presentImportedPhoto()
        }) {
            PhotoLibraryView(openPhoto: { identifier in
                showPhotoPicker = false
                Task {
                    do {
                        importedPhoto = try await libraryPhotoSource(identifier)
                        presentImportedPhoto()
                    } catch { camera.errorMessage = error.localizedDescription }
                }
            }, importPhoto: { result in
                showPhotoPicker = false
                Task { await importPhoto(result) }
            }, delete: camera.deleteLibraryPhotos)
        }
        .fullScreenCover(item: $camera.photoToEdit) { source in
            if source.pending?.nativePhotosWorkflow == true || (source.pending == nil && camera.nativePhotosWorkflow) {
                NativePhotoReviewView(source: source, recipe: source.pending?.adjustment ?? camera.recipes.draft, deletePhoto: camera.deletePhoto)
            } else { PhotoReviewView(source: source, recipes: camera.recipes, deletePhoto: camera.deletePhoto) }
        }
        .sheet(isPresented: $showPending) {
            NavigationStack {
                List(camera.pendingPhotos) { photo in
                    Button {
                        showPending = false
                        camera.photoToEdit = PhotoEditorSource(pending: photo)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(photo.styleName)
                            Text(photo.createdAt.formatted()).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .navigationTitle("待儲存照片")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showPending = false } } }
            }.preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showPreferences) {
            NavigationStack {
                Form {
                    NavigationLink("管理配方") {
                        ScrollView {
                            RecipePickerView(store: camera.recipes, onSelect: {
                                camera.activateSelectedShootingStyle()
                                compareOriginal = false
                                numericText = nil
                                showPreferences = false
                            }, onError: { camera.errorMessage = $0 })
                            .padding(20)
                        }.navigationTitle("管理配方")
                    }
                    Section("構圖輔助") {
                        Toggle("九宮格", isOn: $showGrid).accessibilityIdentifier("gridToggle")
                        Toggle("水平線", isOn: $showLevel).accessibilityIdentifier("levelToggle")
                    }
                    Text("照片由系統相簿管理。儲存失敗時會暫留照片，供你重試。")
                    Toggle("使用原生照片調整流程", isOn: $camera.nativePhotosWorkflow)
                        .accessibilityIdentifier("nativePhotosWorkflow")
                    Text("開啟後拍攝保留原圖，配方作為手動輸入清單；請在「照片」完成調整，再回來讀取與分享。關閉則使用 Camlab 近似調色與即時預覽。")
                    Button("恢復相機自動設定") { Task { await camera.restoreAutomatic() } }
                        .disabled(!camera.canControl)
                    Button("開啟系統設定") { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } }
                }.navigationTitle("相機設定")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showPreferences = false } } }
            }.preferredColorScheme(.dark)
        }
    }

    private func updateCameraVisibility() {
        if !cameraPageVisible || camera.photoToEdit != nil || scenePhase == .background {
            camera.setCameraVisible(false)
            if lensFlipID != nil {
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    lensFlipID = nil
                    outgoingPreview = nil
                    lensTurns = 0
                }
            }
        } else if scenePhase == .active {
            camera.setCameraVisible(true)
        }
    }

    private func viewfinder(landscape: Bool) -> some View {
        GeometryReader { geometry in
            let ratio: CGFloat = landscape ? 4 / 3 : 3 / 4
            let width = min(geometry.size.width, geometry.size.height * ratio)
            let loading = camera.startupState == .starting || camera.startupState == .waitingForPreview
            let showChrome = !loading || lensFlipID != nil
            let displayed = outgoingPreview ?? camera.snapshot
            ZStack {
                Color.black
                if let id = camera.visibilityID {
                    CameraPreview(service: camera.service, device: displayed?.rotationDevice,
                                  startupID: displayed?.previewID, startupBegan: displayed?.previewBegan,
                                  style: compareOriginal ? StyleAdjustment() : camera.previewStyle,
                                  running: scenePhase == .active && outgoingPreview == nil && camera.canPreview,
                                  zoom: Double(camera.draft.zoom) ?? 1,
                                  zoomRange: camera.canAdjust ? camera.snapshot?.capabilities.zoom : nil,
                                  onZoom: { camera.adjustLive(.zoom($0)) },
                                  onFocus: { point in Task { await camera.focus(at: point) } })
                        .id(id)
                        .id(displayed?.rotationDevice.position == .front)
                }
                if outgoingPreview == nil && (!camera.previewReady || !camera.canPreview) {
                    cameraAvailability.transition(.identity)
                }
            }
            .modifier(ViewfinderFlip(turns: lensTurns, reduceMotion: reduceMotion))
            .background(.black)
            .frame(width: max(0, width), height: max(0, width / ratio))
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay {
                if showChrome {
                    ZStack {
                        if showGrid { GridOverlay().transition(.opacity) }
                        if showLevel && level.available { LevelOverlay(angle: level.angle).transition(.opacity) }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .allowsHitTesting(false)
                    .animation(InterfaceMotion.fade, value: showGrid)
                    .animation(InterfaceMotion.fade, value: showLevel && level.available)
                }
            }
            .overlay {
                if scenePhase == .active && camera.canPreview {
                    Color.black
                        .keyframeAnimator(initialValue: 0.0, trigger: camera.singleShotFlashCount) { color, opacity in
                            color.opacity(opacity)
                        } keyframes: { _ in
                            MoveKeyframe(reduceMotion ? 0.65 : 1.0)
                            LinearKeyframe(reduceMotion ? 0.65 : 1.0, duration: 0.05)
                            CubicKeyframe(0.0, duration: 0.13)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .overlay { dismissStyleBackdrop }
            .overlay(alignment: .top) { if landscape && showChrome { topControls } }
            .overlay(alignment: .leading) {
                if showChrome {
                    styleSelector(width: width, height: width / ratio, landscape: landscape)
                        .padding(.leading, 4)
                }
            }
            .overlay(alignment: .bottom) { if showChrome { bottomControls(width: width) } }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("cameraViewfinder")
    }

    @ViewBuilder private var dismissStyleBackdrop: some View {
        if showStyleWheel {
            Color.clear.contentShape(Rectangle())
                .onTapGesture { showStyleWheel = false }
                .accessibilityHidden(true)
        }
    }

    private func styleSelector(width: CGFloat, height: CGFloat, landscape: Bool) -> some View {
        HStack(spacing: 2) {
            Button {
                showStyleWheel.toggle()
            } label: {
                Image(systemName: showStyleWheel ? "chevron.left" : "camera.filters")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 34, height: 34)
                    .background(.black.opacity(0.72), in: Circle())
                    .overlay(alignment: .topTrailing) {
                        if camera.recipes.isModified {
                            Circle().fill(accent).frame(width: 6, height: 6)
                        }
                    }
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showStyleWheel ? "收合拍攝風格" : "選擇配方")
            .accessibilityValue(camera.recipes.name)
            .accessibilityIdentifier("openRecipes")
            if showStyleWheel {
                ShootingStylePicker(options:
                    [.init(id: nil, name: "原色", scene: "日常紀錄")]
                    + camera.recipes.recipes.map { .init(id: $0.id, name: $0.name, scene: "同系列續拍") }
                    + ShootingStyle.allCases.map { .init(id: $0.id, name: $0.name, scene: $0.suggestedScene) },
                    selection: Binding(get: { camera.recipes.selectedID }, set: { id in
                        camera.selectShootingRecipe(id)
                        compareOriginal = false
                        numericText = nil
                    }))
                .frame(width: min(208, max(60, width - 60)),
                       height: min(224, max(44, height - (landscape ? 128 : 96))))
                .clipped()
                .contentShape(Rectangle())
                .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 16))
                .accessibilityIdentifier("shootingStyleWheel")
                .transition(InterfaceMotion.reveal(reduceMotion: reduceMotion, horizontal: true))
            }
        }
    }

    private var topControls: some View {
        HStack(spacing: 4) {
            guideButton("九宮格", symbol: "grid", enabled: $showGrid, id: "quickGrid")
            guideButton("水平線", symbol: "level", enabled: $showLevel, id: "quickLevel")
            Text(camera.recipes.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("currentStyleName")
            Button { showStyleWheel = false; expanded.toggle(); numericText = nil } label: {
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(expanded ? accent : .white)
                    .frame(width: 44, height: 44)
                    .background(expanded ? .white.opacity(0.1) : .clear, in: Circle())
                    .contentShape(Circle())
            }
            .accessibilityLabel("調整參數").accessibilityIdentifier("adjustControls")
            .accessibilityValue(expanded ? "已展開" : "已收合")
            Button { showStyleWheel = false; showPreferences = true } label: {
                Image(systemName: "gearshape").foregroundStyle(.white.opacity(0.7))
                    .frame(width: 44, height: 44).contentShape(Circle())
            }.accessibilityLabel("相機設定").accessibilityIdentifier("cameraPreferences")
        }
        .padding(8)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 20))
    }

    private func guideButton(_ label: String, symbol: String, enabled: Binding<Bool>, id: String) -> some View {
        Button {
            showStyleWheel = false
            enabled.wrappedValue.toggle()
        } label: {
            Image(systemName: symbol)
                .foregroundStyle(enabled.wrappedValue ? accent : .white.opacity(0.7))
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .accessibilityLabel(label).accessibilityIdentifier(id)
        .accessibilityValue(enabled.wrappedValue ? "已開啟" : "已關閉")
        .accessibilityAddTraits(enabled.wrappedValue ? .isSelected : [])
    }

    private func compareButton(iconOnly: Bool) -> some View {
        let title = camera.nativePhotosWorkflow ? "原色預覽 · 原生調整" : (compareOriginal ? "返回效果" : "原圖比較")
        return Button { compareOriginal.toggle() } label: {
            Group {
                if iconOnly { Image(systemName: "circle.lefthalf.filled") }
                else { Text(title) }
            }
            .font(.caption).foregroundStyle(compareOriginal ? accent : .secondary)
            .frame(minWidth: 44, maxWidth: iconOnly ? nil : .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(title)
        .disabled(camera.nativePhotosWorkflow).accessibilityIdentifier("comparePreview")
    }

    private func bottomControls(width: CGFloat) -> some View {
        VStack(spacing: 6) {
            if camera.lastBurstID != nil {
                Text("連拍 \(camera.burstCount) 張")
                    .font(.headline.monospacedDigit()).padding(.horizontal, 12).padding(.vertical, 5)
                    .background(.black.opacity(0.8), in: Capsule())
                    .accessibilityIdentifier("burstCount")
            } else if camera.isCapturing {
                Text(camera.status).font(.caption).padding(8)
                    .background(.black.opacity(0.8), in: Capsule())
            } else if camera.processingPhotoCount > 0 {
                Text(camera.photoQueueIsFull ? "正在處理照片，請稍候…" : "正在儲存 \(camera.processingPhotoCount) 張 · 可繼續拍攝")
                    .font(.caption).padding(8)
                    .background(.black.opacity(0.8), in: Capsule())
                    .accessibilityIdentifier("photoSaveProgress")
            }
            if let error = camera.errorMessage, camera.previewReady {
                Text(error).font(.caption).lineLimit(2).padding(8)
                    .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 8))
            }
            if !camera.pendingPhotos.isEmpty {
                Button { showPending = true } label: {
                    Label("\(camera.pendingPhotos.count) 張待儲存", systemImage: "exclamationmark.circle")
                }.font(.caption).padding(8).background(.black.opacity(0.8), in: Capsule())
            }
            zoomSelector(width: width)
        }.padding(8)
    }

    private func zoomSelector(width: CGFloat) -> some View {
        ViewfinderZoomControl(
            presets: camera.snapshot?.capabilities.zoomPresets ?? [1, 2],
            current: Double(camera.draft.zoom) ?? 1,
            availableWidth: max(88, width - 16), canAdjust: camera.canAdjust
        ) { camera.adjustLive(.zoom($0)) }
        .id(camera.snapshot?.deviceID)
    }

    @ViewBuilder private var cameraAvailability: some View {
        switch camera.startupState {
        case .starting:
            Color.black.allowsHitTesting(false).accessibilityHidden(true)
        case .waitingForPreview:
            // The fresh Metal surface is black until it presents its first frame.
            // Keep it visible so its presentation callback can finish startup.
            EmptyView()
        case .interrupted:
            Text("相機暫時被系統暫停，恢復後會自動開啟")
                .font(.caption).multilineTextAlignment(.center).padding(14)
                .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
        case .permissionRequired, .unavailable, .failed:
            VStack(spacing: 8) {
                Text(camera.status).font(.subheadline).accessibilityIdentifier("cameraStatus")
                if let error = camera.errorMessage {
                    Text(error).font(.caption).multilineTextAlignment(.center).accessibilityIdentifier("cameraError")
                }
                if camera.startupState == .permissionRequired {
                    Button("允許使用相機") { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } }
                } else if camera.startupState.canRetry {
                    Button("重試開啟相機") { Task { await camera.activate() } }
                        .accessibilityIdentifier("retryCamera")
                }
            }
            .padding(14).frame(maxWidth: 290)
            .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
        case .ready, .paused:
            EmptyView()
        }
    }

    private func libraryPhotoSource(_ identifier: String) async throws -> PhotoEditorSource {
        if camera.nativePhotosWorkflow {
            let current = try await PhotoLibrarySaver.loadCurrent(identifier)
            return PhotoEditorSource(original: current.data, assetIdentifier: identifier)
        }
        let source = try await PhotoLibrarySaver.load(identifier)
        return PhotoEditorSource(original: source.original, adjustment: source.adjustment,
                                 assetIdentifier: source.editableAssetIdentifier, importedLibraryIdentifier: identifier)
    }

    private func importPhoto(_ result: PHPickerResult) async {
        do {
            if let id = result.assetIdentifier, let source = try? await libraryPhotoSource(id) {
                importedPhoto = source
            } else {
                importedPhoto = PhotoEditorSource(original: try await PhotoImportPicker.imageData(from: result))
            }
            presentImportedPhoto()
        } catch { camera.errorMessage = error.localizedDescription }
    }

    private func presentImportedPhoto() {
        guard photoPickerDismissed, let source = importedPhoto else { return }
        importedPhoto = nil
        camera.photoToEdit = source
    }

    private func controls(compact: Bool) -> some View {
        VStack(spacing: 5) {
            if numericText == nil {
                VStack(spacing: 5) {
                    HStack(spacing: 4) {
                        controlTab(camera.nativePhotosWorkflow ? "配方清單" : "調色", selected: colorControls) { colorControls = true }
                        controlTab("拍攝", selected: !colorControls) { colorControls = false }
                        Spacer(minLength: 0)
                        if colorControls && !compact { compareButton(iconOnly: true) }
                        if !compact {
                            Button { expanded = false } label: {
                                Image(systemName: "chevron.down").frame(width: 44, height: 44)
                            }.accessibilityLabel("收起調整")
                        }
                    }.font(.caption)
                    if colorControls {
                        RecipeControlsView(store: camera.recipes, parameter: $parameter, numericText: $numericText,
                                           error: { camera.errorMessage = $0 }, compact: compact)
                            .transition(.opacity)
                    } else { shootingControls(compact: compact).transition(.opacity) }
                    if colorControls && compact { compareButton(iconOnly: false) }
                }
                .transition(.opacity)
            } else {
                ParameterKeypad(title: colorControls ? parameter.title : shootingControl.title,
                                text: Binding(get: { numericText ?? "" }, set: { numericText = $0 }), fractional: !colorControls,
                                fillHeight: compact,
                                allowsNegative: !colorControls || parameter.range.lowerBound < 0,
                                onChange: { applyNumeric($0, reportError: false) },
                                onDone: {
                                    if applyNumeric(numericText ?? "", reportError: true) { numericText = nil }
                                }, onCancel: { numericText = nil })
                    .transition(InterfaceMotion.reveal(reduceMotion: reduceMotion, horizontal: compact))
            }
        }
        .animation(InterfaceMotion.fade, value: colorControls)
        .animation(reduceMotion ? InterfaceMotion.fade : InterfaceMotion.layout(reduceMotion: false), value: numericText == nil)
        .font(.caption).padding(compact ? 12 : 0)
        .frame(maxHeight: compact ? .infinity : nil)
        .background(compact ? Color(white: 0.075) : .clear, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(compact ? 0.08 : 0)))
        .accessibilityElement(children: .contain).accessibilityIdentifier("inlineCameraControls")
    }

    private func controlTab(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.caption.weight(.semibold)).lineLimit(1)
                .foregroundStyle(selected ? accent : .white.opacity(0.5))
                .padding(.horizontal, 10).frame(height: 44)
                .background(selected ? accent.opacity(0.12) : .clear, in: Capsule())
                .animation(InterfaceMotion.fade, value: selected)
        }
    }

    private func shootingControls(compact: Bool) -> some View {
        VStack(spacing: 6) {
            if compact {
                ScrollView {
                    VStack(spacing: 3) {
                        ForEach(ShootingControl.allCases) { item in
                            Button { shootingControl = item } label: {
                                HStack {
                                    Text(item.title); Spacer(minLength: 0)
                                    if shootingControl == item { Image(systemName: "checkmark") }
                                }.font(.caption).padding(.horizontal, 8).frame(minHeight: 30)
                                    .foregroundStyle(shootingControl == item ? accent : .white.opacity(0.65))
                                    .background(shootingControl == item ? accent.opacity(0.12) : .clear,
                                                in: RoundedRectangle(cornerRadius: 8))
                                    .contentShape(Rectangle())
                                    .animation(InterfaceMotion.fade, value: shootingControl == item)
                            }.buttonStyle(.plain)
                        }
                    }
                }.frame(minHeight: 55)
            } else {
                HStack {
                    Picker("拍攝參數", selection: $shootingControl) {
                        ForEach(ShootingControl.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().tint(.white)
                    Spacer(minLength: 0)
                }
            }
            HStack {
                Button { numericText = shootingValue } label: {
                    Text(shootingValue).monospacedDigit().foregroundStyle(accent)
                        .padding(8).background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }.accessibilityLabel("輸入\(shootingControl.title)數值").disabled(!camera.canAdjust)
                Spacer(minLength: 0)
                if shootingControl != .zoom {
                    Button("自動") {
                        camera.adjustLive(shootingControl == .focus ? .automaticFocus : shootingControl == .whiteBalance ? .automaticWhiteBalance : .automaticExposure)
                    }.disabled(!camera.canAdjust)
                }
            }
            let range = sliderRange
            if range.upperBound > range.lowerBound {
                Slider(value: Binding(get: { sliderValue }, set: { value in
                    let amount = shootingControl == .shutter || shootingControl == .iso ? exp(value) : value
                    camera.adjustLive(adjustment(amount))
                }), in: range)
                .accessibilityLabel(shootingControl.title).disabled(!camera.canAdjust || !controlSupported)
            }
            HStack { Text(sliderLowerLabel); Spacer(); Text(sliderUpperLabel) }
                .font(.caption2).foregroundStyle(.secondary)
            if shootingControl == .zoom, let range = camera.snapshot?.capabilities.zoom {
                zoomShortcuts(range: range, columns: compact ? 3 : 5).disabled(!camera.canAdjust)
            }
            if !controlSupported { Text("此鏡頭不支援這項調整").font(.caption2).foregroundStyle(.secondary) }
        }
    }

    private func zoomShortcuts(range: ClosedRange<Double>, columns: Int) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: columns), spacing: 4) {
            ForEach([0.5, 1, 2, 5, 10].filter { range.contains($0) }, id: \.self) { value in
                Button("\(CameraSettings.format(value))×") { camera.adjustLive(.zoom(value)) }
                    .font(.caption2).lineLimit(1).fixedSize().frame(minHeight: 28)
            }
        }
    }

    private func actions(landscape: Bool) -> some View {
        let layout = landscape ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            libraryButton
            Spacer(minLength: 0)
            ShutterButton(diameter: landscape ? 60 : 68,
                          available: shutterVisible && camera.canPreview,
                          burstCount: camera.burstCount,
                          canCapture: { shutterVisible && camera.canCapture }) { burstID, requested in
                showStyleWheel = false
                return await camera.capture(burstID: burstID, whileRequested: requested)
            }
            Spacer(minLength: 0)
            Button { Task { await flipLens() } } label: {
                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 23, weight: .medium))
                    .frame(width: 50, height: 50).background(.white.opacity(0.12), in: Circle())
                    .frame(width: 64, height: 68)
            }
            .disabled(lensFlipID != nil || !camera.canAdjust || camera.flipCameraTarget == nil)
            .accessibilityLabel(camera.flipCameraTarget?.isFront == true ? "切換前置相機" : "切換後置相機")
            .accessibilityIdentifier("cameraLens")
        }
        .frame(maxHeight: landscape ? .infinity : nil)
    }

    private var shutterVisible: Bool {
        cameraPageVisible && lensFlipID == nil && camera.photoToEdit == nil && !showPhotoPicker && !showPending && !showPreferences
    }

    @MainActor private func flipLens() async {
        guard lensFlipID == nil, camera.canAdjust, camera.flipCameraTarget != nil else { return }
        let id = UUID()
        lensFlipID = id
        outgoingPreview = camera.snapshot
        showStyleWheel = false
        async let switched: Void = camera.flipCamera()
        withAnimation(.easeIn(duration: 0.16)) { lensTurns = 0.5 }
        try? await Task.sleep(for: .milliseconds(160))
        await switched
        guard lensFlipID == id else { return }
        outgoingPreview = nil
        withAnimation(.easeOut(duration: 0.20), completionCriteria: .logicallyComplete) {
            lensTurns = 1
        } completion: {
            if lensFlipID == id {
                lensFlipID = nil
                lensTurns = 0
            }
        }
    }

    private var libraryButton: some View {
        Button {
            importedPhoto = nil
            photoPickerDismissed = false
            showPhotoPicker = true
        } label: {
            Group {
                Group {
                    if let thumbnail = camera.lastThumbnail {
                        Image(uiImage: thumbnail).resizable().scaledToFill()
                    } else {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 24, weight: .medium))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color(white: 0.18))
                    }
                }
                .frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.2), lineWidth: 1))
            }.foregroundStyle(.white).frame(width: 64, height: 68)
        }.accessibilityLabel("匯入相簿照片").accessibilityIdentifier("photoLibrary")
            .contextMenu {
                if camera.lastThumbnail != nil || PhotoLibrarySaver.lastAssetIdentifier != nil || !camera.pendingPhotos.isEmpty {
                    Button("開啟最近照片") { Task { await camera.openLastPhoto() } }
                }
            }
    }

    private var shootingValue: String {
        let settings = camera.draft
        switch shootingControl {
        case .brightness: return settings.exposureBias
        case .iso: return settings.iso
        case .shutter: return settings.shutter
        case .focus: return settings.focus
        case .whiteBalance: return settings.temperature
        case .zoom: return settings.zoom
        }
    }
    private var actualRange: ClosedRange<Double> {
        let cap = camera.snapshot?.capabilities
        switch shootingControl {
        case .brightness: return cap?.exposureBias ?? -3...3
        case .iso: return cap?.iso ?? 25...1600
        case .shutter: return cap?.shutter ?? (1.0 / 8000)...1
        case .focus: return 0...1
        case .whiteBalance: return 2000...10000
        case .zoom: return cap?.zoom ?? 1...10
        }
    }
    private var sliderRange: ClosedRange<Double> {
        if shootingControl == .shutter || shootingControl == .iso { return log(actualRange.lowerBound)...log(actualRange.upperBound) }
        return actualRange
    }
    private var sliderValue: Double {
        let value = shootingControl == .shutter ? (try? CameraSettings.exposureSeconds(shootingValue, range: actualRange)) : Double(shootingValue)
        let bounded = min(actualRange.upperBound, max(actualRange.lowerBound, value ?? actualRange.lowerBound))
        return shootingControl == .shutter || shootingControl == .iso ? log(bounded) : bounded
    }
    private var sliderLowerLabel: String { CameraSettings.format(actualRange.lowerBound) + (shootingControl == .zoom ? "×" : "") }
    private var sliderUpperLabel: String { CameraSettings.format(actualRange.upperBound) + (shootingControl == .zoom ? "×" : "") }
    private var controlSupported: Bool {
        guard let cap = camera.snapshot?.capabilities else { return false }
        switch shootingControl {
        case .brightness: return cap.automaticExposure
        case .iso, .shutter: return cap.manualExposure
        case .focus: return cap.manualFocus
        case .whiteBalance: return cap.manualWhiteBalance
        case .zoom: return true
        }
    }
    private func adjustment(_ value: Double) -> CameraLiveAdjustment {
        switch shootingControl {
        case .brightness: .brightness(value)
        case .iso: .iso(value)
        case .shutter: .shutter(value)
        case .focus: .focus(value)
        case .whiteBalance: .temperature(value)
        case .zoom: .zoom(value)
        }
    }
    @discardableResult private func applyNumeric(_ text: String, reportError: Bool) -> Bool {
        do {
            if colorControls { camera.recipes.draft[parameter] = try RecipeAdjustment.integer(text, parameter: parameter) }
            else {
                let value = try shootingControl == .shutter ? CameraSettings.exposureSeconds(text, range: actualRange)
                    : CameraSettings.number(text, name: shootingControl.title, range: actualRange)
                guard let cap = camera.snapshot?.capabilities else { throw CameraFailure("相機尚未就緒。") }
                let request = adjustment(value)
                try request.validate(for: cap)
                camera.adjustLive(request)
            }
            camera.errorMessage = nil
            return true
        } catch { if reportError { camera.errorMessage = error.localizedDescription }; return false }
    }
}

struct GridOverlay: View {
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                for fraction in [1.0 / 3, 2.0 / 3] {
                    path.move(to: CGPoint(x: geometry.size.width * fraction, y: 0)); path.addLine(to: CGPoint(x: geometry.size.width * fraction, y: geometry.size.height))
                    path.move(to: CGPoint(x: 0, y: geometry.size.height * fraction)); path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height * fraction))
                }
            }.stroke(.white.opacity(0.4), lineWidth: 0.5)
        }.accessibilityHidden(true)
    }
}

struct LevelOverlay: View {
    var angle: Double
    var body: some View {
        ZStack {
            HStack(spacing: 65) { Rectangle().frame(width: 30, height: 1); Rectangle().frame(width: 30, height: 1) }
            Rectangle().frame(width: 55, height: 2).overlay(Rectangle().frame(width: 2, height: 12))
                .rotationEffect(.degrees(-angle))
            Text("\(Int(angle.rounded()))°").font(.caption2).monospacedDigit().offset(y: 18)
        }.foregroundStyle(abs(angle) <= 1 ? Color.yellow : Color.white)
            .shadow(color: .black, radius: 2).accessibilityLabel(abs(angle) <= 1 ? "已水平" : "傾斜 \(Int(angle.rounded())) 度")
    }
}
