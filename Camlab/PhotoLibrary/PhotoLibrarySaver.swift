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
    var journalError: Error?
}

@MainActor enum PhotoLibrarySaver {
    nonisolated static let formatIdentifier = "order.Camlab.recipe"
    nonisolated static let formatVersion = "1"
    private static var saves: [UUID: Task<SavedPhoto, Error>] = [:]
    static var lastAssetIdentifier: String? {
        get { UserDefaults.standard.string(forKey: "Camlab.LastAsset") }
        set { UserDefaults.standard.set(newValue, forKey: "Camlab.LastAsset") }
    }

    static func authorize(deniedMessage: String = "請允許相簿存取，以保存原圖、成品並重新調色。尚未儲存的照片會保留供重試。") async throws {
        var permission = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if permission == .notDetermined { permission = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
        guard permission == .authorized || permission == .limited else {
            throw CameraFailure(deniedMessage)
        }
    }

    static func deleteAssets(_ identifiers: Set<String>) async throws {
        guard !identifiers.isEmpty else { return }
        try await authorize(deniedMessage: "請在設定中允許 Camlab 存取要刪除的照片。")
        let matches = PHAsset.fetchAssets(withLocalIdentifiers: Array(identifiers), options: nil)
        guard matches.count == identifiers.count,
              (0..<matches.count).allSatisfy({ matches.object(at: $0).canPerform(.delete) }) else {
            throw CameraFailure("部分照片無法刪除。請取消勾選無法存取的照片，或在設定中調整相簿權限後重試。")
        }
        do {
            try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(matches) }
        } catch let error as NSError where error.domain == PHPhotosErrorDomain && error.code == PHPhotosError.Code.userCancelled.rawValue {
            throw CancellationError()
        }
        if let lastAssetIdentifier, identifiers.contains(lastAssetIdentifier) { self.lastAssetIdentifier = nil }
    }

    static func save(_ photo: SavedPhoto, processor: PhotoProcessor) async throws -> SavedPhoto {
        if let existing = saves[photo.id] { return try await existing.value }
        let task = Task { try await saveOnce(photo, processor: processor) }
        saves[photo.id] = task
        defer { saves[photo.id] = nil }
        return try await task.value
    }

    private static func saveOnce(_ photo: SavedPhoto, processor: PhotoProcessor) async throws -> SavedPhoto {
        try await authorize()
        let journal = try await Task.detached { try PhotoLibraryJournal.read(for: photo) }.value
        let legacyID = UserDefaults.standard.string(forKey: "Camlab.PendingAsset.\(photo.id.uuidString)")
        var identifier = photo.assetIdentifier ?? journal?.assetIdentifier ?? legacyID
        if let id = identifier, PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject == nil {
            guard journal?.phase == .retryable, photo.assetIdentifier == nil, legacyID == nil else {
                throw CameraFailure("先前的相簿寫入尚無法確認，原圖已保留。請確認相簿權限後重試，避免新增重複照片。")
            }
            identifier = nil
        }
        if identifier == nil, journal?.phase == .creating {
            identifier = try await findCreatedOriginal(photo)
            guard identifier != nil else {
                throw CameraFailure("先前的相簿寫入尚無法確認，原圖已保留，稍後可重試儲存。")
            }
        }
        if identifier == nil {
            let created = try await createAsset(photo)
            let saved = try await processor.recordAsset(photo, identifier: created)
            lastAssetIdentifier = created
            return saved
        }
        guard let identifier else { throw CameraFailure("無法取得相簿照片識別碼。") }
        let staged = try await processor.recordAsset(photo, identifier: identifier)
        if journal?.phase == .finished {
            // Photos already confirmed the final edit before the prior process
            // exited. Only local cleanup remains; never replay an old edit.
            lastAssetIdentifier = identifier
            return staged
        }
        if staged.nativePhotosWorkflow == true {
            try await recordFinished(staged)
            lastAssetIdentifier = identifier
            return staged
        }
        let input = try await editingInput(identifier)
        let output = PHContentEditingOutput(contentEditingInput: input)
        try await Task.detached(priority: .userInitiated) {
            try populate(output, with: staged)
        }.value
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else {
            throw CameraFailure("無法讀取這張照片，請確認相簿權限或照片是否已刪除。")
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest(for: asset).contentEditingOutput = output
        }
        try await recordFinished(staged)
        lastAssetIdentifier = identifier
        return staged
    }

    private static func recordFinished(_ photo: SavedPhoto) async throws {
        try await Task.detached {
            try PhotoLibraryJournal(phase: .finished, assetIdentifier: photo.assetIdentifier).write(for: photo)
        }.value
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

    private static func findCreatedOriginal(_ photo: SavedPhoto) async throws -> String? {
        try await Task.detached {
            let options = PHFetchOptions()
            options.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate <= %@",
                photo.createdAt.addingTimeInterval(-1) as NSDate, photo.createdAt.addingTimeInterval(1) as NSDate)
            let assets = PHAsset.fetchAssets(with: .image, options: options)
            let prefix = "Camlab-\(photo.id.uuidString)."
            var matches: [String] = []
            assets.enumerateObjects { asset, _, _ in
                if PHAssetResource.assetResources(for: asset).contains(where: { $0.originalFilename.hasPrefix(prefix) }) {
                    matches.append(asset.localIdentifier)
                }
            }
            guard matches.count <= 1 else { throw CameraFailure("找到多筆相同拍攝紀錄，已保留原圖，請先確認相簿。") }
            return matches.first
        }.value
    }

    nonisolated private static func populate(_ output: PHContentEditingOutput, with photo: SavedPhoto) throws {
        let adjustment = try (photo.adjustment ?? RecipeAdjustment()).validated()
        output.adjustmentData = PHAdjustmentData(formatIdentifier: formatIdentifier, formatVersion: formatVersion,
                                                 data: try JSONEncoder().encode(adjustment))
        try Data(contentsOf: photo.fileURL, options: .mappedIfSafe).write(to: output.renderedContentURL, options: .atomic)
    }

    private static func createAsset(_ photo: SavedPhoto) async throws -> String {
        // Persist intent before submitting any Photos work. If the process dies,
        // an unresolved request must be reconciled, never blindly recreated.
        try await Task.detached { try PhotoLibraryJournal(phase: .creating).write(for: photo) }.value
        let box = PhotoIdentifierBox()
        let contentType = CGImageSourceCreateWithURL(photo.originalURL as CFURL, nil)
            .flatMap { CGImageSourceGetType($0) }
            .flatMap { UTType($0 as String) }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.creationDate = photo.createdAt
                let options = PHAssetResourceCreationOptions()
                options.contentType = contentType
                options.originalFilename = "Camlab-\(photo.id.uuidString).\(contentType?.preferredFilenameExtension ?? "jpg")"
                request.addResource(with: .photo, fileURL: photo.originalURL, options: options)
                guard let placeholder = request.placeholderForCreatedAsset else { return }
                box.value = placeholder.localIdentifier
                do {
                    // Write on Photos' change-block queue before the transaction
                    // can commit, not in its completion handler or UserDefaults.
                    try PhotoLibraryJournal(phase: .creating, assetIdentifier: box.value).write(for: photo)
                    if photo.nativePhotosWorkflow != true {
                        let output = PHContentEditingOutput(placeholderForCreatedAsset: placeholder)
                        try populate(output, with: photo)
                        request.contentEditingOutput = output
                    }
                } catch { box.journalError = error }
            }
        } catch {
            // A confirmed transaction failure can be retried. If this write also
            // fails, leave the conservative creating state intact.
            try? await Task.detached { try PhotoLibraryJournal(phase: .retryable).write(for: photo) }.value
            throw error
        }
        if let error = box.journalError { throw error }
        guard let identifier = box.value else { throw CameraFailure("相簿未回傳照片識別碼。") }
        try await Task.detached {
            try PhotoLibraryJournal(phase: .finished, assetIdentifier: identifier).write(for: photo)
        }.value
        return identifier
    }
}
