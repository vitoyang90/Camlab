import Foundation

/// Separate from render metadata, so rerendering cannot erase a Photos commit.
nonisolated struct PhotoLibraryJournal: Codable, Sendable {
    enum Phase: String, Codable, Sendable { case creating, retryable, created, finished }
    var phase: Phase
    var assetIdentifier: String?

    static func url(for photo: SavedPhoto) -> URL {
        photo.originalURL.deletingLastPathComponent().appendingPathComponent("LibrarySave.json")
    }

    static func read(for photo: SavedPhoto) throws -> Self? {
        let url = url(for: photo)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        // A corrupt journal is an error, never permission to create a duplicate.
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    func write(for photo: SavedPhoto) throws {
        try JSONEncoder().encode(self).write(to: Self.url(for: photo), options: .atomic)
    }
}
