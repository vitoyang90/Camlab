import Foundation
import ImageIO
import UniformTypeIdentifiers
@preconcurrency import Photos

nonisolated struct LibraryPhotoSource: Sendable {
    let original: Data
    let adjustment: RecipeAdjustment
    let editableAssetIdentifier: String?
}

nonisolated final class PhotoIdentifierBox: @unchecked Sendable {
    var value: String?
}

@MainActor enum PhotoLibrarySaver {
    static let formatIdentifier = "order.Camlab.recipe"
    static let formatVersion = "1"
    static var lastAssetIdentifier: String? {
        get { UserDefaults.standard.string(forKey: "Camlab.LastAsset") }
        set { UserDefaults.standard.set(newValue, forKey: "Camlab.LastAsset") }
    }

    static func authorize() async throws {
        let permission = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard permission == .authorized || permission == .limited else {
            throw CameraFailure("請允許相簿存取，以保存原圖、成品並重新調色。尚未儲存的照片會保留供重試。")
        }
    }

    static func save(_ photo: SavedPhoto, processor: PhotoProcessor) async throws -> SavedPhoto {
        try await authorize()
        var staged = photo
        if staged.assetIdentifier == nil {
            let journalKey = "Camlab.PendingAsset.\(photo.id.uuidString)"
            let identifier: String
            if let recorded = UserDefaults.standard.string(forKey: journalKey) { identifier = recorded }
            else {
                identifier = try await createOriginal(photo.originalURL, createdAt: photo.createdAt)
                // A small second journal also covers a failure writing the
                // per-photo manifest after the original has reached Photos.
                UserDefaults.standard.set(identifier, forKey: journalKey)
            }
            staged = try await processor.recordAsset(photo, identifier: identifier)
        }
        guard let identifier = staged.assetIdentifier else { throw CameraFailure("無法取得相簿照片。") }
        if staged.nativePhotosWorkflow == true {
            // Creation used originalURL verbatim. Do not submit a rendered edit.
            lastAssetIdentifier = identifier
            return staged
        }
        let input = try await editingInput(identifier)
        let output = PHContentEditingOutput(contentEditingInput: input)
        let adjustment = try (staged.adjustment ?? RecipeAdjustment()).validated()
        output.adjustmentData = PHAdjustmentData(formatIdentifier: formatIdentifier, formatVersion: formatVersion,
                                                data: try JSONEncoder().encode(adjustment))
        let source = staged.fileURL
        let destination = output.renderedContentURL
        try await Task.detached(priority: .userInitiated) {
            try Data(contentsOf: source).write(to: destination, options: .atomic)
        }.value
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else {
            throw CameraFailure("無法讀取這張照片，請確認相簿權限或照片是否已刪除。")
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest(for: asset).contentEditingOutput = output
        }
        lastAssetIdentifier = identifier
        return staged
    }

    static func load(_ identifier: String) async throws -> LibraryPhotoSource {
        try await authorize()
        let input = try await editingInput(identifier)
        guard let url = input.fullSizeImageURL else { throw CameraFailure("無法下載照片原圖，請確認網路後重試。") }
        let data = try await Task.detached(priority: .userInitiated) { try Data(contentsOf: url) }.value
        let own = input.adjustmentData.map { $0.formatIdentifier == formatIdentifier && $0.formatVersion == formatVersion } ?? false
        let adjustment: RecipeAdjustment
        if own, let metadata = input.adjustmentData {
            adjustment = try JSONDecoder().decode(RecipeAdjustment.self, from: metadata.data).validated()
        } else { adjustment = RecipeAdjustment() }
        return LibraryPhotoSource(original: data, adjustment: adjustment, editableAssetIdentifier: own ? identifier : nil)
    }

    /// Always request the current rendered version, even for old Camlab assets.
    /// The legacy editing-input path may instead return their unedited original.
    static func loadCurrent(_ identifier: String) async throws -> NativePhotoContent {
        try await authorize()
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else {
            throw CameraFailure("無法存取這張照片，可能已刪除或不在允許範圍。請重新選擇。")
        }
        let options = PHImageRequestOptions()
        options.version = .current
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
                if let error = info?[PHImageErrorKey] as? Error { continuation.resume(throwing: error) }
                else if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: CameraFailure("無法下載相簿目前版本，請確認網路後重新讀取。")) }
            }
        }
        return try NativePhotoContent(data: data)
    }

    private static func editingInput(_ identifier: String) async throws -> PHContentEditingInput {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else {
            throw CameraFailure("這張照片目前無法存取。請確認已允許讀取，或從相簿重新選擇。")
        }
        let options = PHContentEditingInputRequestOptions()
        options.isNetworkAccessAllowed = true
        options.canHandleAdjustmentData = { data in
            data.formatIdentifier == "order.Camlab.recipe" && data.formatVersion == "1"
        }
        return try await withCheckedThrowingContinuation { continuation in
            asset.requestContentEditingInput(with: options) { input, _ in
                if let input { continuation.resume(returning: input) }
                else { continuation.resume(throwing: CameraFailure("無法讀取原圖，請確認相簿權限及網路後重試。")) }
            }
        }
    }

    private static func createOriginal(_ url: URL, createdAt: Date) async throws -> String {
        let box = PhotoIdentifierBox()
        let contentType = CGImageSourceCreateWithURL(url as CFURL, nil)
            .flatMap { CGImageSourceGetType($0) }
            .flatMap { UTType($0 as String) }
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.creationDate = createdAt
            let options = PHAssetResourceCreationOptions()
            options.contentType = contentType
            options.originalFilename = "CamlabOriginal.\(contentType?.preferredFilenameExtension ?? "jpg")"
            request.addResource(with: .photo, fileURL: url, options: options)
            box.value = request.placeholderForCreatedAsset?.localIdentifier
        }
        guard let identifier = box.value else { throw CameraFailure("相簿未回傳照片識別碼。") }
        return identifier
    }
}
