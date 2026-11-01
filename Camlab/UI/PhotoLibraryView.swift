import PhotosUI
import SwiftUI
import Observation

@MainActor @Observable
private final class PhotoLibraryModel: NSObject, PHPhotoLibraryChangeObserver {
    var assets: [PHAsset] = []
    var permission = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    private var observing = false
    let images = PHCachingImageManager()

    func start() async {
        if !observing {
            PHPhotoLibrary.shared().register(self)
            observing = true
        }
        if permission == .notDetermined {
            permission = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        reload()
    }

    func stop() {
        if observing {
            PHPhotoLibrary.shared().unregisterChangeObserver(self)
            observing = false
        }
    }

    func reload() {
        permission = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard permission == .authorized || permission == .limited else {
            assets = []
            return
        }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(with: .image, options: options)
        assets = (0..<result.count).map { result.object(at: $0) }
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in self?.reload() }
    }
}

struct PhotoLibraryView: View {
    let openPhoto: (String) -> Void
    let importPhoto: (PHPickerResult) -> Void
    let delete: (Set<String>) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var library = PhotoLibraryModel()
    @State private var selecting = false
    @State private var selected: Set<String> = []
    @State private var deleting = false
    @State private var errorMessage: String?
    @State private var showImport = false
    @State private var imported: PHPickerResult?
    @State private var dragStart: String?
    @State private var dragBaseline: Set<String> = []
    @State private var dragLocation: CGPoint?
    @State private var photoFrames: [String: CGRect] = [:]
    @State private var scrollPosition = ScrollPosition(edge: .top)
    @State private var scrollGeometry = LibraryScrollGeometry()
    @State private var autoScrollTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ScrollView {
                if library.permission == .limited {
                    Text("目前顯示已允許存取的照片").font(.footnote).foregroundStyle(.secondary).padding(.top)
                    Button("調整相簿權限") { openSettings() }
                }
                if library.permission == .denied || library.permission == .restricted {
                    ContentUnavailableView {
                        Label("需要相簿存取權限", systemImage: "photo.on.rectangle")
                    } description: {
                        Text("允許存取照片後，即可瀏覽與多選刪除。")
                    } actions: {
                        Button("開啟設定") { openSettings() }
                        Button("選擇照片以編輯") { showImport = true }
                    }
                } else if library.assets.isEmpty {
                    ContentUnavailableView("沒有可顯示的照片", systemImage: "photo")
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 3)], spacing: 3) {
                        ForEach(library.assets, id: \.localIdentifier) { asset in
                            LibraryPhotoCell(asset: asset, manager: library.images, selecting: selecting,
                                             selected: selected.contains(asset.localIdentifier))
                                .contentShape(Rectangle())
                                .background {
                                    GeometryReader { geometry in
                                        Color.clear.preference(key: LibraryPhotoFrames.self,
                                            value: [asset.localIdentifier: geometry.frame(in: .named("libraryViewport"))])
                                    }
                                }
                                .onTapGesture { tap(asset.localIdentifier) }
                                .contextMenu {
                                    if !selecting {
                                        Button("開啟照片") { openPhoto(asset.localIdentifier) }
                                        Button("刪除照片", systemImage: "trash", role: .destructive) {
                                            deletePhotos([asset.localIdentifier])
                                        }.accessibilityIdentifier("deletePreviewPhoto")
                                    }
                                } preview: {
                                    LibraryPhotoPreview(asset: asset, manager: library.images)
                                }
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(asset.creationDate?.formatted() ?? "照片")
                                .accessibilityValue(selected.contains(asset.localIdentifier) ? "已選取" : "未選取")
                                .accessibilityAddTraits(.isButton)
                                .accessibilityIdentifier("libraryPhoto-\(asset.localIdentifier)")
                                .accessibilityAction { tap(asset.localIdentifier) }
                                .accessibilityAction(named: selecting ? "選取照片" : "開啟照片") {
                                    if selecting { selected.insert(asset.localIdentifier) }
                                    else { openPhoto(asset.localIdentifier) }
                                }
                        }
                    }.padding(3)
                }
            }
            .accessibilityIdentifier("photoLibraryScroll")
            .coordinateSpace(name: "libraryViewport")
            .gesture(LibrarySelectionGesture(enabled: selecting) { state, location, start in
                switch state {
                case .began:
                    guard let photo = photoFrames.first(where: { $0.value.contains(start) }) else { return }
                    dragStart = photo.key
                    dragBaseline = selected
                    dragLocation = location
                    updateRange(through: photo.key)
                    startAutoScroll()
                case .changed:
                    guard dragStart != nil else { return }
                    dragLocation = location
                    updateDrag(at: location)
                case .ended, .cancelled, .failed: finishDrag()
                default: break
                }
            })
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: LibraryScrollGeometry.self) { geometry in
                LibraryScrollGeometry(offset: geometry.contentOffset.y,
                                      maximum: max(-geometry.contentInsets.top, geometry.contentSize.height - geometry.containerSize.height + geometry.contentInsets.bottom),
                                      minimum: -geometry.contentInsets.top,
                                      height: geometry.containerSize.height)
            } action: { _, geometry in scrollGeometry = geometry }
            .onPreferenceChange(LibraryPhotoFrames.self) { frames in
                photoFrames = frames
                if let dragLocation { updateDrag(at: dragLocation) }
            }
            .navigationTitle(selecting ? "已選取 \(selected.count) 張" : "相簿")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button(selecting ? "取消多選" : "多選") {
                        finishDrag()
                        selecting.toggle()
                        selected.removeAll()
                    }.accessibilityIdentifier("selectLibraryPhotos")
                }
                if selecting {
                    ToolbarItem(placement: .bottomBar) {
                        Button("刪除 \(selected.count) 張照片", role: .destructive) { deletePhotos(selected) }
                            .disabled(selected.isEmpty)
                            .accessibilityIdentifier("deleteSelectedPhotos")
                    }
                } else if library.permission == .limited {
                    ToolbarItem(placement: .bottomBar) {
                        Button("選擇其他照片以編輯") { showImport = true }
                    }
                }
            }
        }
        .disabled(deleting)
        .interactiveDismissDisabled(deleting)
        .task { await library.start() }
        .onDisappear { finishDrag(); library.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { library.reload() } else { finishDrag() }
        }
        .onChange(of: library.assets.map(\.localIdentifier)) { _, identifiers in
            finishDrag()
            if !deleting { selected.formIntersection(identifiers) }
        }
        .sheet(isPresented: $showImport, onDismiss: {
            if let imported {
                self.imported = nil
                importPhoto(imported)
            }
        }) {
            PhotoImportPicker { result in
                imported = result
                showImport = false
            }.ignoresSafeArea()
        }
        .alert("無法刪除照片", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func updateRange(through identifier: String) {
        guard let dragStart,
              let first = library.assets.firstIndex(where: { $0.localIdentifier == dragStart }),
              let last = library.assets.firstIndex(where: { $0.localIdentifier == identifier }) else { return }
        let range = library.assets[min(first, last)...max(first, last)].map(\.localIdentifier)
        var updated = dragBaseline
        if dragBaseline.contains(dragStart) { updated.subtract(range) }
        else { updated.formUnion(range) }
        if selected != updated { selected = updated }
    }

    private func updateDrag(at location: CGPoint) {
        let visible = photoFrames.filter { $0.value.maxY > 0 && $0.value.minY < scrollGeometry.height }
        let closest = visible.min { left, right in
            distance(to: left.value, from: location) < distance(to: right.value, from: location)
        }
        if let closest { updateRange(through: closest.key) }
    }

    private func distance(to frame: CGRect, from point: CGPoint) -> CGFloat {
        let x = max(frame.minX - point.x, 0, point.x - frame.maxX)
        let y = max(frame.minY - point.y, 0, point.y - frame.maxY)
        return x * x + y * y
    }

    private func startAutoScroll() {
        autoScrollTask?.cancel()
        autoScrollTask = Task { @MainActor in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(33)) } catch { return }
                guard let dragLocation, dragStart != nil, scrollGeometry.height > 0 else { continue }
                let edge: CGFloat = 64
                let velocity: CGFloat
                if dragLocation.y < edge {
                    velocity = -min(1, max(0, (edge - dragLocation.y) / edge)) * 14
                } else {
                    velocity = min(1, max(0, (dragLocation.y - scrollGeometry.height + edge) / edge)) * 14
                }
                guard velocity != 0 else { continue }
                let offset = min(scrollGeometry.maximum, max(scrollGeometry.minimum, scrollGeometry.offset + velocity))
                guard abs(offset - scrollGeometry.offset) > 0.5 else { continue }
                scrollPosition.scrollTo(y: offset - scrollGeometry.minimum)
            }
        }
    }

    private func finishDrag() {
        autoScrollTask?.cancel()
        autoScrollTask = nil
        dragStart = nil
        dragLocation = nil
        dragBaseline = []
    }

    private func tap(_ identifier: String) {
        if selecting {
            if !selected.insert(identifier).inserted { selected.remove(identifier) }
        } else {
            openPhoto(identifier)
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    }

    private func deletePhotos(_ identifiers: Set<String>) {
        guard !deleting, !identifiers.isEmpty else { return }
        deleting = true
        Task {
            defer {
                deleting = false
                library.reload()
                selected.formIntersection(library.assets.map(\.localIdentifier))
            }
            do {
                try await delete(identifiers)
                selected.removeAll()
                selecting = false
            } catch is CancellationError {
            } catch { errorMessage = error.localizedDescription }
        }
    }
}

private struct LibraryPhotoCell: View {
    let asset: PHAsset
    let manager: PHImageManager
    let selecting: Bool
    let selected: Bool
    @Environment(\.displayScale) private var scale
    @State private var thumbnail: UIImage?
    @State private var request: PHImageRequestID?
    @State private var generation: UUID?

    var body: some View {
        Color(white: 0.15)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let thumbnail { Image(uiImage: thumbnail).resizable().scaledToFill() }
            }
            .clipped()
            .overlay(alignment: .bottomTrailing) {
                if selecting {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 17, weight: .semibold)).foregroundStyle(selected ? .yellow : .white)
                        .shadow(radius: 1).padding(5)
                }
            }
            .onAppear {
                guard request == nil else { return }
                let token = UUID()
                generation = token
                let options = PHImageRequestOptions()
                options.deliveryMode = .opportunistic
                options.resizeMode = .fast
                options.isNetworkAccessAllowed = true
                request = manager.requestImage(for: asset, targetSize: CGSize(width: 160 * scale, height: 160 * scale),
                                               contentMode: .aspectFill, options: options) { image, _ in
                    Task { @MainActor in
                        if generation == token { thumbnail = image }
                    }
                }
            }
            .onDisappear {
                generation = nil
                if let request { manager.cancelImageRequest(request) }
                request = nil
                thumbnail = nil
            }
    }
}

private struct LibraryPhotoFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct LibraryScrollGeometry: Equatable {
    var offset: CGFloat = 0
    var maximum: CGFloat = 0
    var minimum: CGFloat = 0
    var height: CGFloat = 0
}

private struct LibrarySelectionGesture: UIGestureRecognizerRepresentable {
    let enabled: Bool
    let changed: (UIGestureRecognizer.State, CGPoint, CGPoint) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.maximumNumberOfTouches = 1
        recognizer.isEnabled = enabled
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        recognizer.isEnabled = enabled
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let location = context.converter.location(in: .named("libraryViewport"))
        let translation = recognizer.translation(in: recognizer.view)
        let start = CGPoint(x: location.x - translation.x, y: location.y - translation.y)
        changed(recognizer.state, location, start)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            otherGestureRecognizer is UIPanGestureRecognizer
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            // Accept diagonal selection strokes while leaving vertical swipes for scrolling.
            return abs(velocity.x) > abs(velocity.y) * 0.6
        }
    }
}

private struct LibraryPhotoPreview: View {
    let asset: PHAsset
    let manager: PHImageManager
    @State private var image: UIImage?
    @State private var request: PHImageRequestID?
    @State private var generation: UUID?
    @Environment(\.displayScale) private var scale

    var body: some View {
        Color.black
            .overlay {
                if let image { Image(uiImage: image).resizable().scaledToFit() }
            }
            .frame(width: 300, height: min(460, 300 * CGFloat(asset.pixelHeight) / CGFloat(max(1, asset.pixelWidth))))
            .accessibilityIdentifier("libraryPhotoPreview")
            .onAppear {
                let token = UUID()
                generation = token
                let options = PHImageRequestOptions()
                options.isNetworkAccessAllowed = true
                request = manager.requestImage(for: asset, targetSize: CGSize(width: 300 * scale, height: 460 * scale),
                                               contentMode: .aspectFit, options: options) { image, _ in
                    Task { @MainActor in if generation == token { self.image = image } }
                }
            }
            .onDisappear {
                generation = nil
                if let request { manager.cancelImageRequest(request) }
                request = nil
                image = nil
            }
    }
}
