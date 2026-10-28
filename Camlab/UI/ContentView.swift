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
    @State private var recipeMenu = false
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
                    if expanded {
                        controls(compact: landscape)
                            .frame(width: landscape ? (numericText == nil
                                   ? min(164, max(140, geometry.size.width * 0.19))
                                   : min(184, max(164, geometry.size.width * 0.21))) : nil)
                            .frame(maxHeight: landscape ? .infinity : nil)
                            .transition(InterfaceMotion.reveal(reduceMotion: reduceMotion, horizontal: landscape))
                    } else if !landscape { recipeShortcuts.transition(.opacity) }
                    actions(landscape: landscape).frame(width: landscape ? 72 : nil)
                }
                .padding(landscape ? 0 : 14)
                .background(landscape ? Color.clear : Color(white: 0.075), in: RoundedRectangle(cornerRadius: 24))
                .overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(landscape ? 0 : 0.08)))
                .padding(.horizontal, landscape ? 0 : 10).padding(.bottom, landscape ? 0 : 6)
            }
            .padding(.horizontal, landscape ? 8 : 0).padding(.vertical, landscape ? 8 : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Animate structural UI changes only, not frame delivery or slider values.
            .animation(InterfaceMotion.layout(reduceMotion: reduceMotion), value: expanded)
            .animation(InterfaceMotion.layout(reduceMotion: reduceMotion), value: numericText == nil)
            .animation(InterfaceMotion.layout(reduceMotion: reduceMotion), value: colorControls)
            .animation(InterfaceMotion.layout(reduceMotion: reduceMotion), value: recipeMenu)
        }
        .background(Color.black.ignoresSafeArea()).foregroundStyle(.white)
        .tint(accent).preferredColorScheme(.dark)
        .statusBarHidden()
        .task { await camera.restoreLastPhoto() }
        .task {
            await camera.resume()
            if showLevel { level.start() }
            if let error = camera.recipes.loadError { camera.errorMessage = error }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
                await camera.refresh()
            }
        }
        .onChange(of: showLevel) { _, value in if value { level.start() } else { level.stop() } }
        .onChange(of: camera.recipes.draft) { _, _ in compareOriginal = false }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { level.stop(); Task { await camera.deactivate() } }
            else if phase == .active {
                if showLevel { level.start() }
                if camera.photoToEdit == nil { Task { await camera.resume() } }
            }
        }
        .onChange(of: camera.photoToEdit?.id) { _, id in
            Task {
                if id != nil { await camera.deactivate() }
                else { await camera.restoreLastPhoto(); await camera.resume() }
            }
        }
        .onDisappear { level.stop(); Task { await camera.deactivate() } }
        .sheet(isPresented: $showPhotoPicker, onDismiss: {
            photoPickerDismissed = true
            presentImportedPhoto()
        }) {
            PhotoImportPicker { result in
                showPhotoPicker = false
                if let result { Task { await importPhoto(result) } }
            }.ignoresSafeArea()
        }
        .fullScreenCover(item: $camera.photoToEdit) { source in
            if source.pending?.nativePhotosWorkflow == true || (source.pending == nil && camera.nativePhotosWorkflow) {
                NativePhotoReviewView(source: source, recipe: source.pending?.adjustment ?? camera.recipes.draft)
            } else { PhotoReviewView(source: source, recipes: camera.recipes) }
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
        .sheet(isPresented: $recipeMenu) {
            NavigationStack {
                ScrollView {
                    RecipePickerView(store: camera.recipes, onSelect: {
                        camera.activateSelectedShootingStyle()
                        recipeMenu = false
                        numericText = nil
                        compareOriginal = false
                    }, onError: { camera.errorMessage = $0 })
                    .padding(20)
                }.accessibilityIdentifier("shootingStyleList")
                .navigationTitle("拍攝風格")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { recipeMenu = false } } }
            }.preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showPreferences) {
            NavigationStack {
                Form {
                    Toggle("九宮格", isOn: $showGrid)
                    Toggle("水平線", isOn: $showLevel)
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

    private func viewfinder(landscape: Bool) -> some View {
        GeometryReader { geometry in
            let ratio: CGFloat = landscape ? 4 / 3 : 3 / 4
            let width = min(geometry.size.width, geometry.size.height * ratio)
            ZStack {
                Color(white: 0.06)
                CameraPreview(service: camera.service, device: camera.snapshot?.rotationDevice,
                              startupID: camera.snapshot?.previewID, startupBegan: camera.snapshot?.previewBegan,
                              style: compareOriginal ? StyleAdjustment() : camera.previewStyle, running: camera.canPreview,
                              onFocus: { point in Task { await camera.focus(at: point) } })
                if showGrid { GridOverlay().allowsHitTesting(false).transition(.opacity) }
                if showLevel && level.available { LevelOverlay(angle: level.angle).allowsHitTesting(false).transition(.opacity) }
                if !camera.previewReady || !camera.canPreview { connection.transition(.opacity) }
            }
            .animation(InterfaceMotion.fade, value: showGrid)
            .animation(InterfaceMotion.fade, value: showLevel && level.available)
            .animation(InterfaceMotion.fade, value: !camera.previewReady || !camera.canPreview)
            .frame(width: max(0, width), height: max(0, width / ratio))
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(alignment: .top) { if landscape { topControls } }
            .overlay(alignment: .bottom) { bottomControls(width: width) }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("cameraViewfinder")
    }

    private var topControls: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 4) {
                Button { recipeMenu.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "camera.filters")
                        Text("風格 · \(camera.recipes.name)").lineLimit(1)
                        if camera.recipes.isModified { Text("•").foregroundStyle(accent) }
                        Image(systemName: "chevron.down")
                            .rotationEffect(.degrees(recipeMenu ? 180 : 0))
                            .animation(InterfaceMotion.layout(reduceMotion: reduceMotion), value: recipeMenu)
                    }.font(.subheadline.weight(.medium)).padding(.horizontal, 12).frame(minHeight: 40)
                        .background(.white.opacity(0.07), in: Capsule())
                }.accessibilityLabel("選擇配方").accessibilityIdentifier("openRecipes")
                    .accessibilityValue(camera.recipes.name)
            }
            .animation(reduceMotion ? InterfaceMotion.fade : nil, value: recipeMenu)
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                Button { showLevel.toggle() } label: {
                    Text("水平").font(.caption2).foregroundStyle(showLevel ? accent : .white).frame(width: 44, height: 40)
                }
                    .accessibilityLabel(showLevel ? "關閉水平線" : "開啟水平線")
                Button { showGrid.toggle() } label: { Image(systemName: "grid").foregroundStyle(showGrid ? accent : .white).frame(width: 38, height: 40) }
                    .accessibilityLabel(showGrid ? "關閉九宮格" : "開啟九宮格")
                Button { showPreferences = true } label: {
                    Image(systemName: "gearshape").frame(width: 36, height: 40)
                }.accessibilityLabel("相機設定")
            }.background(.white.opacity(0.07), in: Capsule())
        }.padding(8)
    }

    private var recipeShortcuts: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(camera.recipes.selectedStyle?.detail ?? "選擇風格，即時預覽並直接拍照")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                Button("全部風格") { recipeMenu = true }
                    .font(.caption2).accessibilityIdentifier("allShootingStyles")
            }
            ScrollViewReader { scroll in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        recipeShortcut("原色", id: nil).id("original")
                        ForEach(ShootingStyle.allCases) { style in
                            recipeShortcut(style.name, id: style.id, symbol: style.symbol).id(style.id.uuidString)
                        }
                        ForEach(camera.recipes.recipes) { recipe in
                            recipeShortcut(recipe.name, id: recipe.id).id(recipe.id.uuidString)
                        }
                        Button { expanded = true; colorControls = true } label: {
                            Label("新配方", systemImage: "plus").font(.caption)
                                .padding(.horizontal, 12).frame(height: 44)
                                .background(.white.opacity(0.05), in: Capsule())
                        }.accessibilityLabel("調整新配方")
                    }
                }.accessibilityIdentifier("recipeShortcuts")
                    .onAppear { scroll.scrollTo(camera.recipes.selectedID?.uuidString ?? "original", anchor: .center) }
                    .onChange(of: camera.recipes.selectedID) { _, id in
                        withAnimation(InterfaceMotion.fade) { scroll.scrollTo(id?.uuidString ?? "original", anchor: .center) }
                    }
            }
        }
    }

    private func recipeShortcut(_ name: String, id: UUID?, symbol: String = "camera.filters") -> some View {
        let selected = camera.recipes.selectedID == id
        return Button {
            camera.selectShootingRecipe(id)
            compareOriginal = false
        } label: {
            Label(name, systemImage: symbol).font(.caption.weight(.medium)).lineLimit(1)
                .padding(.horizontal, 14).frame(height: 44)
                .foregroundStyle(selected ? accent : .white.opacity(0.7))
                .background(selected ? accent.opacity(0.12) : .white.opacity(0.05), in: Capsule())
                .animation(InterfaceMotion.fade, value: selected)
        }.accessibilityLabel("套用\(name)")
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func bottomControls(width: CGFloat) -> some View {
        VStack(spacing: 6) {
            if camera.isCapturing {
                Text(camera.status).font(.caption).padding(8)
                    .background(.black.opacity(0.8), in: Capsule())
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
            HStack {
                Button(camera.nativePhotosWorkflow ? "原色預覽 · 原生調整" : (compareOriginal ? "返回效果" : "原圖比較")) { compareOriginal.toggle() }
                    .font(.caption2).padding(.horizontal, 12).frame(minHeight: 44)
                    .foregroundStyle(compareOriginal ? accent : .white)
                    .background(.black.opacity(0.8), in: Capsule())
                    .disabled(camera.nativePhotosWorkflow).accessibilityIdentifier("comparePreview")
                Spacer(minLength: 0)
                Button { expanded.toggle(); numericText = nil } label: {
                    Label("調整", systemImage: "slider.horizontal.3")
                        .font(.caption.weight(.medium)).foregroundStyle(accent)
                        .padding(.horizontal, 12).frame(minHeight: 44)
                        .background(.black.opacity(0.8), in: Capsule())
                }.accessibilityLabel("調整參數").accessibilityIdentifier("adjustControls")
            }
            zoomSelector(width: width)
        }.padding(8)
    }

    private func zoomSelector(width: CGFloat) -> some View {
        let values = camera.snapshot?.capabilities.zoomPresets ?? [1, 2]
        let current = Double(camera.draft.zoom) ?? 1
        return ViewThatFits(in: .horizontal) {
            zoomButtons(values: values, current: current)
            ScrollView(.horizontal, showsIndicators: false) {
                zoomButtons(values: values, current: current)
            }.frame(width: max(44, width - 16), height: 48)
        }
    }

    private func zoomButtons(values: [Double], current: Double) -> some View {
        HStack(spacing: 4) {
            ForEach(values, id: \.self) { value in
                let selected = abs(current - value) < 0.01
                Button { camera.adjustLive(.zoom(value)) } label: {
                    Text("\(CameraSettings.format(value))×")
                        .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(selected ? accent : .white)
                        .frame(width: 44, height: 44)
                        .background(selected ? .white.opacity(0.16) : .clear, in: Circle())
                }
                .accessibilityLabel("變焦 \(CameraSettings.format(value)) 倍")
                .accessibilityAddTraits(selected ? .isSelected : [])
                .disabled(!camera.canAdjust)
            }
            Button {
                colorControls = false; shootingControl = .zoom; expanded = true; numericText = nil
            } label: {
                Group {
                    if values.contains(where: { abs(current - $0) < 0.01 }) {
                        Image(systemName: "chevron.down")
                    } else {
                        Text("\(CameraSettings.format(current))×").monospacedDigit()
                    }
                }.font(.caption.weight(.semibold)).foregroundStyle(accent)
                    .frame(minWidth: 44, minHeight: 44)
            }.accessibilityLabel("調整變焦倍率").accessibilityIdentifier("openZoom")
        }.padding(2).background(.black.opacity(0.8), in: Capsule())
    }

    private var connection: some View {
        VStack(spacing: 8) {
            Text(camera.status).font(.subheadline).accessibilityIdentifier("cameraStatus")
            if camera.isBusy { ProgressView() }
            if let error = camera.errorMessage {
                Text(error).font(.caption).multilineTextAlignment(.center).accessibilityIdentifier("cameraError")
            }
            if camera.needsPermission {
                Button("開啟設定") { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } }
            } else if !camera.isBusy && !camera.isCapturing {
                Button("重新連線") { Task { await camera.activate() } }
            }
        }
        .padding(14).frame(maxWidth: 290)
        .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
    }

    private func importPhoto(_ result: PHPickerResult) async {
        do {
            if camera.nativePhotosWorkflow {
                if let id = result.assetIdentifier, let current = try? await PhotoLibrarySaver.loadCurrent(id) {
                    importedPhoto = PhotoEditorSource(original: current.data, assetIdentifier: id)
                } else {
                    importedPhoto = PhotoEditorSource(original: try await PhotoImportPicker.imageData(from: result))
                }
                presentImportedPhoto()
                return
            }
            if let id = result.assetIdentifier, let source = try? await PhotoLibrarySaver.load(id) {
                importedPhoto = PhotoEditorSource(original: source.original, adjustment: source.adjustment,
                                                 assetIdentifier: source.editableAssetIdentifier)
            } else {
                // The picker can deliver an image even with limited library access.
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
                        Button { expanded = false } label: { Image(systemName: "chevron.down") }
                            .accessibilityLabel("收起調整")
                    }.font(.caption)
                    if colorControls {
                        RecipeControlsView(store: camera.recipes, parameter: $parameter, numericText: $numericText,
                                           error: { camera.errorMessage = $0 }, compact: compact)
                            .transition(.opacity)
                    } else { shootingControls(compact: compact).transition(.opacity) }
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
            Text(title).font(.caption.weight(.semibold))
                .foregroundStyle(selected ? accent : .white.opacity(0.5))
                .padding(.horizontal, 10).frame(height: 30)
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
            Button { Task { await camera.capture() } } label: {
                Circle().fill(camera.isCapturing ? .gray : .white).padding(5)
                    .overlay(Circle().stroke(.white, lineWidth: 2)).frame(width: landscape ? 60 : 68, height: landscape ? 60 : 68)
            }.disabled(!camera.canControl).accessibilityLabel("拍照").accessibilityIdentifier("capturePhoto")
            Spacer(minLength: 0)
            Button { Task { await camera.flipCamera() } } label: {
                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 23, weight: .medium))
                    .frame(width: 50, height: 50).background(.white.opacity(0.12), in: Circle())
                    .frame(width: 64, height: 68)
            }
            .disabled(!camera.canControl || camera.flipCameraTarget == nil)
            .accessibilityLabel(camera.flipCameraTarget?.isFront == true ? "切換前置相機" : "切換後置相機")
            .accessibilityIdentifier("cameraLens")
        }
        .frame(maxHeight: landscape ? .infinity : nil)
    }

    private var libraryButton: some View {
        Button {
            importedPhoto = nil
            photoPickerDismissed = false
            showPhotoPicker = true
        } label: {
            VStack(spacing: 3) {
                Group {
                    if let data = camera.lastThumbnail, let thumbnail = UIImage(data: data) {
                        Image(uiImage: thumbnail).resizable().scaledToFill()
                    } else {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 24, weight: .medium))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color(white: 0.18))
                    }
                }
                .frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.75), lineWidth: 1.5))
                Text("圖庫").font(.system(size: 11, weight: .medium))
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
