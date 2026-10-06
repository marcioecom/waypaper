import Foundation

enum WallpaperFit: String, Codable, CaseIterable, Equatable {
    case fill
    case fit
}

struct DisplaySettings: Codable, Equatable {
    var wallpaperID: UUID?
    var fit: WallpaperFit = .fill
    /// Playback nitidez (CI unsharp mask); 0…1, default 0 (no filter).
    var sharpness: Double = 0
    var paused: Bool = false

    init(
        wallpaperID: UUID? = nil,
        fit: WallpaperFit = .fill,
        sharpness: Double = 0,
        paused: Bool = false
    ) {
        self.wallpaperID = wallpaperID
        self.fit = fit
        self.sharpness = Self.clampSharpness(sharpness)
        self.paused = paused
    }

    static func clampSharpness(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    mutating func normalize() {
        sharpness = Self.clampSharpness(sharpness)
    }
}

struct DisplayDescriptor: Identifiable, Equatable {
    let id: String
    let name: String
}

private struct DisplayAssignmentsStore: Codable {
    var assignments: [String: DisplaySettings]
}

enum DisplayPersistenceError: LocalizedError {
    case corruptedStore(String)

    var errorDescription: String? {
        switch self {
        case .corruptedStore(let detail):
            return L10n.format("Display settings are corrupted; the file was not changed. (%@)", detail)
        }
    }
}

enum DisplayPersistence {
    static func load(from url: URL) throws -> [String: DisplaySettings] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        do {
            let data = try Data(contentsOf: url)
            let store = try JSONDecoder().decode(DisplayAssignmentsStore.self, from: data)
            return store.assignments
        } catch {
            throw DisplayPersistenceError.corruptedStore(error.localizedDescription)
        }
    }

    static func save(_ assignments: [String: DisplaySettings], to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let payload = DisplayAssignmentsStore(assignments: assignments)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        try data.write(to: url, options: .atomic)
    }
}

enum WaypaperPlaybackError: LocalizedError {
    case wallpaperMissing
    case unreadableVideo(String)
    case invalidVideo(String)
    case persistenceBlocked

    var errorDescription: String? {
        switch self {
        case .wallpaperMissing:
            return L10n.string("The wallpaper is no longer in the library.")
        case .unreadableVideo(let path):
            return L10n.format("The file is not accessible: %@", path)
        case .invalidVideo(let message):
            return message
        case .persistenceBlocked:
            return L10n.string("Display settings cannot be saved until the corrupted file is fixed.")
        }
    }
}
