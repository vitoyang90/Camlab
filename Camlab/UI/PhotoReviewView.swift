import SwiftUI
import Observation

struct PhotoEditorSource: Identifiable {
    let id = UUID()
    var original: Data?
    var adjustment: RecipeAdjustment?
    var assetIdentifier: String?
    var pending: SavedPhoto?
}

@MainActor @Observable
final class PhotoEditorModel {
    let source: PhotoEditorSource
    private let processor = PhotoProcessor()
    private var original: Data?
    private var previewSource: Data?
    private var assetIdentifier: String?
    private var staged: SavedPhoto?
    private var savedAdjustment: RecipeAdjustment?
    private var previewGeneration = 0
    var image: UIImage?
    var originalImage: UIImage?
    var isLoading = true
    var isSaving = false
    var errorMessage: String?
    var notice: String?
    var shareURL: URL?

    init(source: PhotoEditorSource) { self.source = source }

    func load(recipes: RecipeStore) async {
        do {
            if let pending = source.pending {
                original = try await Task.detached { try Data(contentsOf: pending.originalURL) }.value
                staged = pending
                assetIdentifier = pending.assetIdentifier
                recipes.draft = pending.adjustment ?? RecipeAdjustment()
            } else if let data = source.original {
                original = data
                assetIdentifier = source.assetIdentifier
                if let adjustment = source.adjustment { recipes.draft = adjustment }
                if assetIdentifier != nil { savedAdjustment = recipes.draft }
            } else if let id = source.assetIdentifier {
                let loaded = try await PhotoLibrarySaver.load(id)
                original = loaded.original
                assetIdentifier = loaded.editableAssetIdentifier
                recipes.draft = loaded.adjustment
                if assetIdentifier != nil { savedAdjustment = loaded.adjustment }
            }
            guard let original else { throw CameraFailure("找不到照片原圖。") }
            previewSource = try await Task.detached { try PhotoProcessor.thumbnail(data: original) }.value
            originalImage = previewSource.flatMap(UIImage.init(data:))
            isLoading = false
            await refresh(recipes.draft)
        } catch { errorMessage = error.localizedDescription; isLoading = false }
    }

    func refresh(_ adjustment: RecipeAdjustment) async {
        guard let data = previewSource else { return }
        previewGeneration += 1
        let generation = previewGeneration
        do {
            try await Task.sleep(for: .milliseconds(60))
            let processor = self.processor
            let rendered = try await Task.detached(priority: .userInitiated) {
                try processor.render(data, style: StyleAdjustment(recipe: adjustment))
            }.value
            guard !Task.isCancelled, generation == previewGeneration else { return }
            image = UIImage(data: rendered.thumbnail)
        } catch is CancellationError { }
        catch { if !Task.isCancelled { errorMessage = error.localizedDescription } }
    }

    func canSave(_ adjustment: RecipeAdjustment) -> Bool {
        original != nil && !isSaving && (staged != nil || savedAdjustment != adjustment)
    }

    func save(recipes: RecipeStore) async {
        guard let original, canSave(recipes.draft) else { return }
        isSaving = true
        errorMessage = nil
        let adjustment = recipes.draft
        let style = StyleAdjustment(recipe: adjustment, recipeName: recipes.name)
        defer { isSaving = false }
        do {
            if let pending = staged {
                let current = await processor.pending().first { $0.id == pending.id } ?? pending
                staged = try await processor.revise(current, style: style)
            } else {
                staged = try await processor.process(original, style: style, assetIdentifier: assetIdentifier)
            }
            guard let pending = staged else { return }
            let saved = try await PhotoLibrarySaver.save(pending, processor: processor)
            // State changes only after the original and edited image are committed.
            assetIdentifier = saved.assetIdentifier
            savedAdjustment = adjustment
            try await processor.complete(saved)
            staged = nil
            notice = "已儲存至相簿"
        } catch {
            if let pending = staged {
                staged = await processor.pending().first { $0.id == pending.id } ?? pending
            }
            errorMessage = "\(error.localizedDescription)\n照片已暫留，可重試儲存。"
        }
    }

    func export(recipes: RecipeStore) async {
        guard let original else { return }
        do {
            let style = recipes.style
            let processor = self.processor
            let rendered = try await Task.detached(priority: .userInitiated) { try processor.render(original, style: style) }.value
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Camlab-\(source.id.uuidString).jpg")
            try rendered.data.write(to: url, options: .atomic)
            shareURL = url
        } catch { errorMessage = error.localizedDescription }
    }

    func clearExport() { if let shareURL { try? FileManager.default.removeItem(at: shareURL) } }
}

struct PhotoReviewView: View {
    let source: PhotoEditorSource
    @Bindable var recipes: RecipeStore
    @State private var editor: PhotoEditorModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var parameter = AdjustmentParameter.saturation
    @State private var numericText: String?
    @State private var showOriginal = false
    @State private var showRecipes = false
    @State private var sharing = false
    private let accent = Color(red: 0.98, green: 0.81, blue: 0.30)

    init(source: PhotoEditorSource, recipes: RecipeStore) {
        self.source = source
        self.recipes = recipes
        _editor = State(initialValue: PhotoEditorModel(source: source))
    }

    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            VStack(spacing: 10) {
                toolbar(compact: landscape)
                let layout = landscape ? AnyLayout(HStackLayout(spacing: 12)) : AnyLayout(VStackLayout(spacing: 12))
                layout {
                    preview.frame(maxWidth: .infinity, maxHeight: .infinity)
                    controls(compact: landscape)
                        .frame(width: landscape ? min(260, max(224, geometry.size.width * 0.28)) : nil,
                               height: landscape ? nil : min(numericText == nil ? 290 : 340, geometry.size.height * 0.5))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }.padding(12)
                .animation(InterfaceMotion.layout(reduceMotion: reduceMotion), value: numericText == nil)
        }
        .background(Color.black.ignoresSafeArea()).foregroundStyle(.white).tint(accent).preferredColorScheme(.dark)
        .task { await editor.load(recipes: recipes) }
        .task(id: recipes.draft) { await editor.refresh(recipes.draft) }
        .onChange(of: recipes.draft) { _, _ in showOriginal = false }
        .onDisappear { editor.clearExport() }
        .interactiveDismissDisabled(editor.isSaving)
        .sheet(isPresented: $sharing) {
            if let url = editor.shareURL { PhotoShareSheet(url: url) }
        }
        .sheet(isPresented: $showRecipes) {
            NavigationStack {
                ScrollView {
                    RecipePickerView(store: recipes, onSelect: { showRecipes = false; numericText = nil },
                                     onError: { editor.errorMessage = $0 })
                        .padding(20)
                }
                .navigationTitle("選擇配方")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showRecipes = false } } }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .preferredColorScheme(.dark)
        }
    }

    private func toolbar(compact: Bool) -> some View {
        HStack(spacing: 12) {
            Button { showRecipes = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "camera.filters")
                    Text(recipes.name).lineLimit(1).truncationMode(.tail)
                    Image(systemName: "chevron.down").font(.caption2)
                }.font(.subheadline.weight(.medium))
                    .padding(.horizontal, 12).frame(minHeight: 44)
                    .background(.white.opacity(0.07), in: Capsule())
            }
            .disabled(editor.isLoading || editor.isSaving)
            .accessibilityLabel("選擇配方").accessibilityIdentifier("editorRecipes")
            Spacer(minLength: 0)
            if compact { comparisonButton }
            Button("完成") { dismiss() }
                .font(.subheadline.weight(.semibold)).frame(minWidth: 48, minHeight: 44)
                .fixedSize(horizontal: true, vertical: false)
                .disabled(editor.isSaving).accessibilityIdentifier("closePhotoEditor")
        }
    }

    private var comparisonButton: some View {
        Button(showOriginal ? "返回成品" : "原圖比較") { showOriginal.toggle() }
            .font(.caption).frame(minHeight: 36)
            .fixedSize(horizontal: true, vertical: false)
            .disabled(editor.originalImage == nil)
            .accessibilityIdentifier("compareEditedPhoto")
    }

    private var preview: some View {
        // Explicit bounds keep a large or panoramic image from pushing controls
        // outside the safe area. Both layers use the exact same fitting rectangle.
        GeometryReader { geometry in
            ZStack {
                Color(white: 0.06)
                if let original = editor.originalImage {
                    Image(uiImage: original).resizable().scaledToFit()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
                if let image = editor.image {
                    Image(uiImage: image).resizable().scaledToFit()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .opacity(showOriginal ? 0 : 1)
                        .animation(InterfaceMotion.fade, value: showOriginal)
                }
                if editor.isLoading { ProgressView() }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 20))
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("photoEditPreview")
    }

    private func controls(compact: Bool) -> some View {
        VStack(spacing: 8) {
            if !compact {
                HStack {
                    Text("調色").font(.subheadline.weight(.semibold))
                    Spacer(minLength: 4)
                    comparisonButton
                }
            }
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 8) {
                        Group {
                            if numericText == nil {
                                RecipeControlsView(store: recipes, parameter: $parameter, numericText: $numericText,
                                                   error: { editor.errorMessage = $0 }, compact: compact)
                                    .transition(.opacity)
                            } else {
                                ParameterKeypad(title: parameter.title,
                                                text: Binding(get: { numericText ?? "" }, set: { numericText = $0 }),
                                                fillHeight: compact,
                                                allowsNegative: parameter.range.lowerBound < 0,
                                                onChange: { text in
                                                    if let value = try? RecipeAdjustment.integer(text, parameter: parameter) {
                                                        recipes.draft[parameter] = value
                                                    }
                                                },
                                                onDone: {
                                                    do {
                                                        recipes.draft[parameter] = try RecipeAdjustment.integer(numericText ?? "", parameter: parameter)
                                                        numericText = nil; editor.errorMessage = nil
                                                    } catch { editor.errorMessage = error.localizedDescription }
                                                }, onCancel: { numericText = nil })
                                    .transition(InterfaceMotion.reveal(reduceMotion: reduceMotion, horizontal: compact))
                            }
                        }
                        .frame(height: compact ? max(numericText == nil ? 220 : 198, geometry.size.height - 4) : nil)
                        if let error = editor.errorMessage {
                            Text(error).font(.caption).foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("開啟設定") {
                                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                            }.font(.caption).frame(minHeight: 36)
                        } else if let notice = editor.notice {
                            Text(notice).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
                }
                .scrollBounceBehavior(.basedOnSize)
                .accessibilityIdentifier("photoEditAdjustments")
                .animation(InterfaceMotion.layout(reduceMotion: reduceMotion), value: numericText == nil)
            }
            HStack(spacing: 12) {
                Button(editor.isSaving ? "儲存中…" : "儲存成品") { Task { await editor.save(recipes: recipes) } }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(accent, in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.black).disabled(!editor.canSave(recipes.draft))
                    .opacity(editor.canSave(recipes.draft) ? 1 : 0.5)
                    .accessibilityIdentifier("saveEditedPhoto")
                Button { Task { await editor.export(recipes: recipes); sharing = editor.shareURL != nil } } label: {
                    Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44)
                        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                }.disabled(editor.isLoading || editor.isSaving).accessibilityLabel("分享成品")
                    .accessibilityIdentifier("shareEditedPhoto")
            }
        }
        .padding(12).background(Color(white: 0.075), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.08)))
        .disabled(editor.isLoading || editor.isSaving)
        .accessibilityElement(children: .contain).accessibilityIdentifier("photoEditControls")
    }

}

struct PhotoShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
}
