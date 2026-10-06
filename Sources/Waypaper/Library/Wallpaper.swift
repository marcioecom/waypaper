import Foundation

struct Wallpaper: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    /// File name inside the library `media` directory.
    let fileName: String
    let width: Int
    let height: Int
    let duration: Double
}

private struct WallpaperManifest: Codable {
    var wallpapers: [Wallpaper]
}

enum WallpaperLibraryError: LocalizedError {
    case corruptedManifest(String)
    case persistenceBlocked
    case importInProgress
    case invalidSource(String)
    case invalidVideo(String)
    case unreadableSource(String)
    case deletionFailed(String)

    var errorDescription: String? {
        switch self {
        case .corruptedManifest(let detail):
            return L10n.format("Corrupted library; the file was not changed. (%@)", detail)
        case .persistenceBlocked:
            return L10n.string("The library cannot be changed until the corrupted manifest is fixed.")
        case .importInProgress:
            return L10n.string("Wait for the current import to finish.")
        case .invalidSource(let message):
            return message
        case .invalidVideo(let message):
            return message
        case .unreadableSource(let path):
            return L10n.format("The file is not accessible: %@", path)
        case .deletionFailed(let message):
            return message
        }
    }
}

enum WallpaperPersistence {
    static let manifestFileName = "manifest.json"
    static let mediaDirectoryName = "media"
    static let thumbnailsDirectoryName = "thumbnails"
    /// Per-wallpaper derived copies with sharpening baked in, keyed by quantized level.
    /// Never contains anything derived from an untrusted/unowned wallpaper id.
    static let variantsDirectoryName = "variants"

    static func load(from root: URL) throws -> [Wallpaper] {
        let url = root.appendingPathComponent(manifestFileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            let manifest = try JSONDecoder().decode(WallpaperManifest.self, from: data)
            return try validatedWallpapers(manifest.wallpapers)
        } catch let error as WallpaperLibraryError {
            throw error
        } catch {
            throw WallpaperLibraryError.corruptedManifest(error.localizedDescription)
        }
    }

    static func save(_ wallpapers: [Wallpaper], to root: URL) throws {
        _ = try validatedWallpapers(wallpapers)
        let url = root.appendingPathComponent(manifestFileName)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let payload = WallpaperManifest(wallpapers: wallpapers)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        try data.write(to: url, options: .atomic)
    }

    static func validatedWallpapers(_ wallpapers: [Wallpaper]) throws -> [Wallpaper] {
        var seenIDs = Set<UUID>()
        for wallpaper in wallpapers {
            try validateWallpaper(wallpaper, seenIDs: &seenIDs)
        }
        return wallpapers
    }

    static func validateWallpaper(_ wallpaper: Wallpaper, seenIDs: inout Set<UUID>) throws {
        guard seenIDs.insert(wallpaper.id).inserted else {
            throw WallpaperLibraryError.corruptedManifest(L10n.format("Duplicate id: %@", wallpaper.id.uuidString))
        }
        guard wallpaper.width > 0, wallpaper.height > 0 else {
            throw WallpaperLibraryError.corruptedManifest(L10n.format("Invalid dimensions for %@", wallpaper.id.uuidString))
        }
        guard wallpaper.duration.isFinite, wallpaper.duration > 0 else {
            throw WallpaperLibraryError.corruptedManifest(L10n.format("Invalid duration for %@", wallpaper.id.uuidString))
        }
        guard isOwnedMediaFileName(wallpaper.fileName, wallpaperID: wallpaper.id) else {
            throw WallpaperLibraryError.corruptedManifest(L10n.format("Invalid file name for %@", wallpaper.id.uuidString))
        }
    }

    /// Basename only, owned layout: `{uuid}.{ext}` with uuid matching the entry id.
    static func isOwnedMediaFileName(_ fileName: String, wallpaperID: UUID) -> Bool {
        guard !fileName.isEmpty else { return false }
        guard fileName == (fileName as NSString).lastPathComponent else { return false }
        guard !fileName.contains("/"), !fileName.contains("\\") else { return false }
        guard fileName != ".", fileName != ".." else { return false }
        if fileName.contains("..") { return false }
        let requiredPrefix = wallpaperID.uuidString + "."
        guard fileName.hasPrefix(requiredPrefix) else { return false }
        let ext = String(fileName.dropFirst(requiredPrefix.count))
        guard !ext.isEmpty, !ext.contains(".") else { return false }
        return true
    }

    static func ownedMediaURL(for wallpaper: Wallpaper, root: URL) throws -> URL {
        var seen = Set<UUID>()
        try validateWallpaper(wallpaper, seenIDs: &seen)
        let mediaDirectory = root
            .appendingPathComponent(mediaDirectoryName, isDirectory: true)
            .standardizedFileURL
        let candidate = mediaDirectory
            .appendingPathComponent(wallpaper.fileName, isDirectory: false)
            .standardizedFileURL
        guard isContained(candidate, in: mediaDirectory) else {
            throw WallpaperLibraryError.corruptedManifest(L10n.string("Media path is outside the library"))
        }
        return candidate
    }

    static func ownedThumbnailURL(for wallpaper: Wallpaper, root: URL) throws -> URL {
        var seen = Set<UUID>()
        try validateWallpaper(wallpaper, seenIDs: &seen)
        let thumbnailsDirectory = root
            .appendingPathComponent(thumbnailsDirectoryName, isDirectory: true)
            .standardizedFileURL
        let fileName = "\(wallpaper.id.uuidString).jpg"
        let candidate = thumbnailsDirectory
            .appendingPathComponent(fileName, isDirectory: false)
            .standardizedFileURL
        guard isContained(candidate, in: thumbnailsDirectory) else {
            throw WallpaperLibraryError.corruptedManifest(L10n.string("Thumbnail path is outside the library"))
        }
        return candidate
    }

    /// Directory holding baked sharpened variants for a single wallpaper. Named after the
    /// wallpaper's own UUID (not user-controlled), so no extra traversal validation is needed
    /// beyond containment inside `variants/`.
    static func ownedVariantsDirectory(for wallpaper: Wallpaper, root: URL) throws -> URL {
        var seen = Set<UUID>()
        try validateWallpaper(wallpaper, seenIDs: &seen)
        let variantsRoot = root
            .appendingPathComponent(variantsDirectoryName, isDirectory: true)
            .standardizedFileURL
        let candidate = variantsRoot
            .appendingPathComponent(wallpaper.id.uuidString, isDirectory: true)
            .standardizedFileURL
        guard isContained(candidate, in: variantsRoot) else {
            throw WallpaperLibraryError.corruptedManifest(L10n.string("Variant path is outside the library"))
        }
        return candidate
    }

    /// File name for a baked sharpened variant at a given quantized level (1...levelCount).
    static func variantFileName(level: Int, originalExtension: String) -> String {
        "sharp-\(level).\(originalExtension)"
    }

    private static func isContained(_ file: URL, in directory: URL) -> Bool {
        let filePath = file.path
        let directoryPath = directory.path
        guard filePath.hasPrefix(directoryPath) else { return false }
        let remainder = filePath.dropFirst(directoryPath.count)
        guard remainder.first == "/" || remainder.isEmpty else { return false }
        return true
    }
}
