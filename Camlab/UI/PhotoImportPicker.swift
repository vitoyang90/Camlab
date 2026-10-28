import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// A sheet-owned picker gives the caller an actual onDismiss boundary before
/// presenting the full-screen editor, including when an image loads immediately.
struct PhotoImportPicker: UIViewControllerRepresentable {
    var onSelect: (PHPickerResult?) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = 1
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {
        context.coordinator.onSelect = onSelect
    }

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        var onSelect: (PHPickerResult?) -> Void
        init(onSelect: @escaping (PHPickerResult?) -> Void) { self.onSelect = onSelect }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            onSelect(results.first)
        }
    }

    static func imageData(from result: PHPickerResult) async throws -> Data {
        let provider = result.itemProvider
        guard let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) else {
            throw CameraFailure("無法讀取這張照片。")
        }
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? CameraFailure("無法讀取這張照片。")) }
            }
        }
    }
}
