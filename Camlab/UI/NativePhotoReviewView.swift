import SwiftUI
import PhotosUI
import Observation

@MainActor @Observable
final class NativePhotoReviewModel {
    private let loadCurrent: (String) async throws -> NativePhotoContent
    private let processor = PhotoProcessor()
    private(set) var content: NativePhotoContent?
    private(set) var assetIdentifier: String?
    private(set) var pending: SavedPhoto?
    var image: UIImage?
    var busy = false
    var errorMessage: String?
    var notice: String?
    var shareURL: URL?
    var canShare: Bool { content != nil && !busy && errorMessage == nil }

    init(loadCurrent: @escaping (String) async throws -> NativePhotoContent = { try await PhotoLibrarySaver.loadCurrent($0) }) {
        self.loadCurrent = loadCurrent
    }

    func load(_ source: PhotoEditorSource) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            if let staged = source.pending {
                pending = staged
                assetIdentifier = staged.assetIdentifier
                let data = try await Task.detached { try Data(contentsOf: staged.originalURL) }.value
                try accept(NativePhotoContent(data: data))
                notice = "原圖尚未完成儲存，請先儲存到相簿。"
            } else if let identifier = source.assetIdentifier {
                assetIdentifier = identifier
                try accept(await loadCurrent(identifier))
            } else if let data = source.original {
                try accept(NativePhotoContent(data: data))
                notice = "已讀取選取的版本。修改後請重新選擇同一張照片。"
            } else { throw CameraFailure("請選擇要在「照片」中調整的影像。") }
        } catch { errorMessage = error.localizedDescription }
    }

    func refresh() async {
        guard !busy, pending == nil, let identifier = assetIdentifier else { return }
        busy = true
        defer { busy = false }
        // Failed refreshes block sharing the stale version until a successful retry.
        do {
            try accept(await loadCurrent(identifier))
            notice = "已重新讀取相簿目前版本"
        } catch { errorMessage = error.localizedDescription }
    }

    func select(_ result: PHPickerResult) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            if let identifier = result.assetIdentifier, let current = try? await loadCurrent(identifier) {
                try accept(current)
                assetIdentifier = identifier
                notice = "返回 Camlab 時會重新讀取這張照片。"
            } else {
                // Picker-only access still supplies the current representation.
                let data = try await PhotoImportPicker.imageData(from: result)
                try accept(NativePhotoContent(data: data))
                assetIdentifier = nil
                notice = "已讀取選取的版本。修改後請重新選擇同一張照片。"
            }
            pending = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func savePending() async {
        guard !busy, let pending, pending.nativePhotosWorkflow == true else { return }
        busy = true
        defer { busy = false }
        do {
            let staged = await processor.pending().first { $0.id == pending.id } ?? pending
            let saved = try await PhotoLibrarySaver.save(staged, processor: processor)
            assetIdentifier = saved.assetIdentifier
            try await processor.complete(saved)
            self.pending = nil
            errorMessage = nil
            notice = "原圖已儲存，請切換到「照片」完成調整。"
        } catch { errorMessage = error.localizedDescription }
    }

    private func accept(_ value: NativePhotoContent) throws {
        guard let image = UIImage(data: value.data) else { throw CameraFailure("無法顯示這張相簿影像。") }
        clearExport()
        content = value
        self.image = image
        errorMessage = nil
        notice = nil
    }

    func export(in directory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("CamlabNativeShares")) throws {
        guard canShare, let content else { throw CameraFailure("請先成功讀取相簿目前版本再分享。") }
        clearExport()
        shareURL = try content.writeShareCopy(in: directory)
    }

    func clearExport() {
        if let shareURL { try? FileManager.default.removeItem(at: shareURL) }
        shareURL = nil
    }
}

struct NativePhotoReviewView: View {
    let source: PhotoEditorSource
    let recipe: RecipeAdjustment
    @State private var model = NativePhotoReviewModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var showPicker = false
    @State private var sharing = false
    private let accent = Color(red: 0.98, green: 0.81, blue: 0.30)

    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            VStack(spacing: 12) {
                HStack {
                    Label("原生照片流程", systemImage: "photo.on.rectangle").font(.headline)
                    Spacer()
                    Button("完成") { dismiss() }.frame(minWidth: 44, minHeight: 44)
                        .accessibilityIdentifier("closeNativePhoto")
                }
                let layout = landscape ? AnyLayout(HStackLayout(spacing: 12)) : AnyLayout(VStackLayout(spacing: 12))
                layout {
                    GeometryReader { bounds in
                        ZStack {
                            Color(white: 0.06)
                            if let image = model.image {
                                Image(uiImage: image).resizable().scaledToFit()
                                    .frame(width: bounds.size.width, height: bounds.size.height)
                            }
                            if model.busy { ProgressView() }
                        }.frame(width: bounds.size.width, height: bounds.size.height)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped().clipShape(RoundedRectangle(cornerRadius: 18))
                    .accessibilityIdentifier("nativePhotoPreview")
                    panel.frame(width: landscape ? min(320, geometry.size.width * 0.4) : nil,
                                height: landscape ? nil : geometry.size.height * 0.48)
                }
            }.padding(12)
        }
        .background(.black).foregroundStyle(.white).tint(accent).preferredColorScheme(.dark)
        .task { await model.load(source) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && !sharing && !showPicker { Task { await model.refresh() } }
        }
        .interactiveDismissDisabled(model.busy)
        .onDisappear { model.clearExport() }
        .sheet(isPresented: $showPicker) {
            PhotoImportPicker { result in
                showPicker = false
                if let result { Task { await model.select(result) } }
            }
        }
        .sheet(isPresented: $sharing, onDismiss: { model.clearExport() }) {
            if let url = model.shareURL { PhotoShareSheet(url: url) }
        }
    }

    private var panel: some View {
        VStack(spacing: 10) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.pending == nil ? "相簿目前版本" : "待儲存原圖").font(.headline)
                    Text("到「照片」依清單手動調整，完成後回來重新讀取。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("手動配方清單").font(.subheadline.weight(.semibold))
                    ForEach(AdjustmentParameter.allCases) { parameter in
                        HStack {
                            Text(parameter == .brilliance ? "增艷（鮮明度）" : parameter.title)
                            Spacer()
                            Text(recipe[parameter] > 0 ? "+\(recipe[parameter])" : "\(recipe[parameter])")
                                .monospacedDigit().foregroundStyle(accent)
                        }.font(.subheadline)
                    }
                    DisclosureGroup("操作說明") {
                        Text("切換到 iPhone「照片」，選取同一張照片並點「編輯」，輸入清單數值後點「完成」。若要從原圖重做，先回復原狀。清單不會自動套用；分享保留相簿提供的檔案，不另加調色。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.font(.caption)
                    if let error = model.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
                    if let notice = model.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                }
            }.accessibilityIdentifier("nativeRecipeChecklist")
            if model.pending != nil {
                Button("儲存原圖至相簿") { Task { await model.savePending() } }
                    .buttonStyle(.borderedProminent).disabled(model.busy)
            }
            HStack {
                Button("選擇照片") { showPicker = true }.accessibilityIdentifier("selectNativePhoto")
                Spacer()
                Button("重新讀取") { Task { await model.refresh() } }
                    .disabled(model.assetIdentifier == nil || model.pending != nil)
                    .accessibilityIdentifier("refreshNativePhoto")
            }.frame(minHeight: 44).disabled(model.busy)
            Button {
                do { try model.export(); sharing = true }
                catch { model.errorMessage = error.localizedDescription }
            } label: {
                Label("分享相簿版本", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }.buttonStyle(.borderedProminent).disabled(!model.canShare)
                .accessibilityIdentifier("shareNativePhoto")
        }.padding(12).background(Color(white: 0.075), in: RoundedRectangle(cornerRadius: 18))
    }
}
