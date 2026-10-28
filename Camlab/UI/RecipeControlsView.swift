import SwiftUI

struct RecipeControlsView: View {
    @Bindable var store: RecipeStore
    @Binding var parameter: AdjustmentParameter
    @Binding var numericText: String?
    var error: (String) -> Void
    var compact = false
    @State private var naming = false
    @State private var name = ""
    private let accent = Color(red: 0.98, green: 0.81, blue: 0.30)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if compact {
                ScrollViewReader { scroll in
                    ScrollView {
                        VStack(spacing: 3) {
                            ForEach(AdjustmentParameter.allCases) { item in
                                Button { parameter = item } label: {
                                    HStack {
                                        Text(item.title)
                                        Spacer(minLength: 0)
                                        Text(String(store.draft[item])).monospacedDigit()
                                    }.font(.caption).padding(.horizontal, 8).frame(minHeight: 30)
                                        .foregroundStyle(parameter == item ? accent : .white.opacity(0.65))
                                        .background(parameter == item ? accent.opacity(0.12) : .clear,
                                                    in: RoundedRectangle(cornerRadius: 8))
                                        .contentShape(Rectangle())
                                        .animation(InterfaceMotion.fade, value: parameter == item)
                                }.buttonStyle(.plain).id(item)
                                    .accessibilityIdentifier("parameter-\(item.rawValue)")
                            }
                        }
                    }.onAppear { scroll.scrollTo(parameter, anchor: .center) }
                }.frame(minHeight: 55)
                    .accessibilityIdentifier("recipeParameterList")
                HStack(spacing: 4) {
                    Text(parameter.title).font(.caption.weight(.medium)).lineLimit(1).minimumScaleFactor(0.75)
                    Spacer(minLength: 0)
                    numericButton
                }
            } else {
                HStack(spacing: 4) { parameterPicker; Spacer(minLength: 0); numericButton }
            }
            Slider(value: Binding(get: { Double(store.draft[parameter]) }, set: { store.draft[parameter] = Int($0.rounded()) }),
                   in: Double(parameter.range.lowerBound)...Double(parameter.range.upperBound), step: 1)
                .tint(accent).accessibilityLabel(parameter.title)
                .accessibilityIdentifier("recipeSlider")
            HStack {
                Text(parameter.range.lowerBound < 0 ? "−100" : "0")
                Spacer()
                if parameter.range.lowerBound < 0 { Text("0"); Spacer() }
                Text("100")
            }.font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 6) { saveButtons }.padding(.top, 4)
        }
        .alert("另存新配方", isPresented: $naming) {
            TextField("配方名稱", text: $name)
            Button("取消", role: .cancel) { }
            Button("儲存") {
                do { try store.saveNew(name: name) }
                catch { self.error(error.localizedDescription) }
            }
        }
    }

    private var parameterPicker: some View {
        Picker("調色參數", selection: $parameter) {
            ForEach(AdjustmentParameter.allCases) { Text($0.title).tag($0) }
        }.labelsHidden().tint(.white).font(.subheadline.weight(.medium))
            .accessibilityIdentifier("recipeParameter")
    }

    private var numericButton: some View {
        Button { numericText = String(store.draft[parameter]) } label: {
            Text(String(store.draft[parameter])).font(.system(size: 20, weight: .medium)).monospacedDigit()
                .foregroundStyle(accent).frame(minWidth: 46, minHeight: 38)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        }.accessibilityLabel("輸入\(parameter.title)數值")
            .accessibilityValue(String(store.draft[parameter]))
    }

    @ViewBuilder private var saveButtons: some View {
        Button(compact ? "更新" : "更新配方") {
            do { try store.update() }
            catch { self.error(error.localizedDescription) }
        }.disabled(!store.canUpdate || !store.isModified)
            .buttonStyle(.bordered).font(.caption)
            .accessibilityLabel("更新配方")
        Button(compact ? "另存" : "另存新配方") { name = ""; naming = true }
            .foregroundStyle(accent).buttonStyle(.bordered).font(.caption)
            .accessibilityLabel("另存新配方")
    }
}

/// An in-place keypad leaves the preview visible even on landscape phones.
struct ParameterKeypad: View {
    let title: String
    @Binding var text: String
    var fractional = false
    var fillHeight = false
    var allowsNegative = true
    var onChange: (String) -> Void
    var onDone: () -> Void
    var onCancel: () -> Void
    @State private var replaceOnDigit = true

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 8) {
                Text(title).font(.caption).lineLimit(1)
                Spacer(minLength: 0)
                Text(text).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                    .accessibilityIdentifier("numericDraft")
                Button("完成", action: onDone).font(.caption)
                    .accessibilityIdentifier("finishNumericInput")
            }
            .frame(minHeight: 30)
            VStack(spacing: 5) {
                ForEach(0..<4) { row in
                    HStack(spacing: 5) {
                        ForEach(Array(keys[(row * columns)..<((row + 1) * columns)]), id: \.self) { key in
                            Button { press(key) } label: {
                                Text(key).font(.body).frame(maxWidth: .infinity)
                                    .frame(height: fillHeight ? nil : 32)
                                    .frame(minHeight: 32, maxHeight: fillHeight ? .infinity : nil)
                                    .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                            }.buttonStyle(.plain).accessibilityLabel(key == "⌫" ? "退格" : key == "±" ? "正負號" : key)
                                .disabled(key == "±" && !allowsNegative)
                        }
                    }
                }
            }.frame(maxHeight: fillHeight ? .infinity : nil)
            Button("取消輸入", action: onCancel).font(.caption2)
        }
    }

    private var keys: [String] {
        fractional ? ["1", "2", "3", "⌫", "4", "5", "6", "±", "7", "8", "9", "/", ".", "0", "清除", "取消"]
            : ["1", "2", "3", "4", "5", "6", "7", "8", "9", "±", "0", "⌫"]
    }
    private var columns: Int { fractional ? 4 : 3 }

    private func press(_ key: String) {
        switch key {
        case "取消": onCancel(); return
        case "清除": text = "0"; replaceOnDigit = true
        case "⌫": text = String(text.dropLast()); if text.isEmpty { text = "0" }; replaceOnDigit = false
        case "±": text = text.hasPrefix("-") ? String(text.dropFirst()) : "-" + text; replaceOnDigit = false
        default:
            if replaceOnDigit { text = key == "." ? "0." : key }
            else if text == "0", key != ".", key != "/" { text = key }
            else if text.count < 12 { text += key }
            replaceOnDigit = false
        }
        onChange(text)
    }
}

struct RecipePickerView: View {
    @Bindable var store: RecipeStore
    var onSelect: () -> Void
    var onError: (String) -> Void
    @State private var renaming: PhotoRecipe?
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            recipeButton("原色", id: nil)
            ForEach(store.recipes) { recipe in
                HStack {
                    recipeButton(recipe.name, id: recipe.id)
                    Menu {
                        Button("重新命名") { name = recipe.name; renaming = recipe }
                        Button("刪除配方", role: .destructive) {
                            do { try store.delete(recipe.id) }
                            catch { onError(error.localizedDescription) }
                        }
                    } label: { Image(systemName: "ellipsis").frame(width: 36, height: 36) }
                    .accessibilityLabel("管理\(recipe.name)")
                }
            }
            if store.recipes.isEmpty { Text("調整參數後，按「另存新配方」建立。").font(.caption).foregroundStyle(.secondary) }
            Text("內建風格 · 選好就能拍").font(.caption).foregroundStyle(.secondary).padding(.top, 12)
            ForEach(ShootingStyle.allCases) { style in
                VStack(alignment: .leading, spacing: 2) {
                    recipeButton(style.name, id: style.id, symbol: style.symbol)
                    Text(style.detail).font(.caption2).foregroundStyle(.secondary)
                }.padding(.vertical, 4)
            }
        }
        .alert("重新命名", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("配方名稱", text: $name)
            Button("取消", role: .cancel) { renaming = nil }
            Button("儲存") {
                guard let recipe = renaming else { return }
                do { try store.rename(recipe.id, name: name) }
                catch { onError(error.localizedDescription) }
                renaming = nil
            }
        }
    }

    private func recipeButton(_ name: String, id: UUID?, symbol: String = "camera.filters") -> some View {
        Button {
            do { try store.select(id); onSelect() }
            catch { onError(error.localizedDescription) }
        } label: {
            HStack {
                Image(systemName: symbol).frame(width: 28)
                Text(name).lineLimit(1)
                Spacer()
                if store.selectedID == id { Image(systemName: "checkmark") }
            }.frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("recipe-\(name)")
            .accessibilityAddTraits(store.selectedID == id ? .isSelected : [])
    }
}
