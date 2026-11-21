import Foundation

struct DeadlineSnapshot: Sendable {
    var data: SavedData
    var bytes: Data?
}

enum DeadlineFileError: LocalizedError {
    case changed, missingCloudFile
    var errorDescription: String? {
        switch self {
        case .changed: return "The deadline file changed on disk. Your changes were not saved, to avoid overwriting another computer’s updates. Reopen the editor after the latest data loads."
        case .missingCloudFile: return "The iCloud deadline file has not finished downloading. Let iCloud Drive download DeadlineStartup/deadlines.json, then reopen the app."
        }
    }
}

actor DeadlineFile {
    let url: URL
    let isCloud: Bool
    init(url: URL, isCloud: Bool) { self.url = url; self.isCloud = isCloud }

    /// iCloud keeps not-yet-downloaded files as hidden `.name.icloud` placeholders.
    /// Creating a new file over one would replace the shared data with an empty list.
    private var cloudPlaceholder: URL {
        url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".icloud")
    }

    private func requireDownloadedIfCloud() throws {
        guard isCloud, FileManager.default.fileExists(atPath: cloudPlaceholder.path) else { return }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        throw DeadlineFileError.missingCloudFile
    }

    /// Loads the file, creating it with empty data when it does not exist yet.
    func load() throws -> DeadlineSnapshot {
        let loaded = try read()
        guard loaded.bytes == nil else { return loaded }
        try requireDownloadedIfCloud()
        let bytes = try save(loaded.data, expected: nil)
        return DeadlineSnapshot(data: loaded.data, bytes: bytes)
    }

    private func read() throws -> DeadlineSnapshot {
        var coordinationError: NSError?
        var result: Result<DeadlineSnapshot, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinated in
            result = Result {
                guard FileManager.default.fileExists(atPath: coordinated.path) else {
                    return DeadlineSnapshot(data: SavedData(), bytes: nil)
                }
                let bytes = try Data(contentsOf: coordinated)
                return DeadlineSnapshot(data: try JSONDecoder().decode(SavedData.self, from: bytes), bytes: bytes)
            }
        }
        if let coordinationError { throw coordinationError }
        return try result!.get()
    }

    func save(_ data: SavedData, expected: Data?) throws -> Data {
        try requireDownloadedIfCloud()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var coordinationError: NSError?
        var result: Result<Data, Error>?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinated in
            result = Result {
                let exists = FileManager.default.fileExists(atPath: coordinated.path)
                let current = exists ? try Data(contentsOf: coordinated) : nil
                guard current == expected else { throw DeadlineFileError.changed }
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let bytes = try encoder.encode(data)
                try bytes.write(to: coordinated, options: .atomic)
                return bytes
            }
        }
        if let coordinationError { throw coordinationError }
        return try result!.get()
    }
}
