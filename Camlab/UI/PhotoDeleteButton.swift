import SwiftUI

enum PhotoDeletionTarget {
    case library(String)
    case pending(SavedPhoto)

    var title: String {
        switch self {
        case .library: "從相簿刪除照片"
        case .pending: "捨棄待儲存照片"
        }
    }
}

struct PhotoDeleteButton: View {
    let target: PhotoDeletionTarget
    @Binding var deleting: Bool
    @Binding var errorMessage: String?
    let delete: (PhotoDeletionTarget) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirming = false

    var body: some View {
        Button {
            switch target {
            case .library: performDeletion()
            case .pending: confirming = true
            }
        } label: {
            Image(systemName: "trash").frame(width: 44, height: 44)
        }
        .accessibilityLabel(target.title).accessibilityIdentifier("deleteCurrentPhoto")
        .alert(target.title, isPresented: $confirming) {
            Button(target.title, role: .destructive) { performDeletion() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("將移除 Camlab 內的原圖與續存紀錄。若相簿已有這張照片，相簿版本會保留。")
        }
    }

    private func performDeletion() {
        guard !deleting else { return }
        deleting = true
        Task {
            defer { deleting = false }
            do { try await delete(target); dismiss() }
            catch is CancellationError { }
            catch { errorMessage = error.localizedDescription }
        }
    }
}
