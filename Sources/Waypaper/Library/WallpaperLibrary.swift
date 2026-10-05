import AppKit
import AVFoundation
import Combine
import Foundation

@MainActor
final class WallpaperLibrary: ObservableObject {
    @Published private(set) var wallpapers: [Wallpaper] = []
    @Published private(set) var isImporting = false
    @Published var errorMessage: String?

    private let root: URL
    private var persistenceBlocked = false

    init(root: URL?) {
        if let root {
            self.root = root
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.root = support.appendingPathComponent("Waypaper", isDirectory: true)
        }
        do {
            try prepareLibraryRoot()
            wallpapers = try WallpaperPersistence.load(from: self.root)
        } catch {
            persistenceBlocked = true
            errorMessage = error.localizedDescription
        }
    }

    /// Number of discrete sharpness buckets (0 = original, 1...levelCount = baked variants).
    /// Quantizing avoids baking a near-infinite number of near-identical files as the user
    /// drags the slider; `SharpnessControl` already steps in 0.05 increments and only commits
    /// on drag end, so 10 buckets (10% increments) comfortably covers the meaningful range.
    private static let sharpnessLevelCount = 10

    /// In-flight bake tasks, deduplicated by destination URL so concurrent requests for the
    /// same (wallpaper, level) share one export instead of racing to write the same file.
    private var variantTasks: [URL: Task<URL, Error>] = [:]

    func url(for wallpaper: Wallpaper) -> URL {
        root.appendingPathComponent(WallpaperPersistence.mediaDirectoryName, isDirectory: true)
            .appendingPathComponent(wallpaper.fileName)
    }

    func thumbnailURL(for wallpaper: Wallpaper) -> URL {
        root.appendingPathComponent(WallpaperPersistence.thumbnailsDirectoryName, isDirectory: true)
            .appendingPathComponent("\(wallpaper.id.uuidString).jpg")
    }

    func importVideo(_ source: URL) async throws -> Wallpaper {
        try Task.checkCancellation()
        guard !persistenceBlocked else { throw WallpaperLibraryError.persistenceBlocked }
        guard !isImporting else { throw WallpaperLibraryError.importInProgress }
        isImporting = true
        defer { isImporting = false }

        let libraryRoot = root
        let worker = Task.detached(priority: .userInitiated) {
            try await WallpaperImportWorker.importVideo(from: source, into: libraryRoot)
        }
        let imported = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }

        do {
            try Task.checkCancellation()
            var next = wallpapers
            next.append(imported.wallpaper)
            try WallpaperPersistence.save(next, to: root)
            wallpapers = next
            return imported.wallpaper
        } catch {
            WallpaperImportWorker.rollback(files: [imported.mediaURL, imported.thumbnailURL])
            throw error
        }
    }

    /// Resolves the URL to play for a given sharpness (0 = original file, untouched). For
    /// sharpness > 0, bakes (or reuses a cached) sharpened copy once via
    /// `WallpaperVariantRenderer` instead of compositing in real time during playback — see
    /// that type's doc comment for why. The original imported file is only ever read here.
    func ensureSharpenedVariant(for wallpaper: Wallpaper, sharpness: Double) async throws -> URL {
        let clamped = DisplaySettings.clampSharpness(sharpness)
        guard clamped > 0 else { return url(for: wallpaper) }
        guard !persistenceBlocked else { throw WallpaperLibraryError.persistenceBlocked }

        let level = max(1, min(Self.sharpnessLevelCount, Int((clamped * Double(Self.sharpnessLevelCount)).rounded())))
        let ext = (wallpaper.fileName as NSString).pathExtension
        let directory = try WallpaperPersistence.ownedVariantsDirectory(for: wallpaper, root: root)
        let destination = directory.appendingPathComponent(
            WallpaperPersistence.variantFileName(level: level, originalExtension: ext),
            isDirectory: false
        )

        if FileManager.default.fileExists(atPath: destination.path) {
            return destination
        }

        if let existing = variantTasks[destination] {
            return try await existing.value
        }

        let source = url(for: wallpaper)
        let normalizedLevel = Double(level) / Double(Self.sharpnessLevelCount)
        let task = Task<URL, Error> {
            try await WallpaperVariantRenderer.render(source: source, sharpness: normalizedLevel, to: destination)
            return destination
        }
        variantTasks[destination] = task
        defer { variantTasks[destination] = nil }
        return try await task.value
    }

    func remove(_ wallpaper: Wallpaper) throws {
        guard !persistenceBlocked else { throw WallpaperLibraryError.persistenceBlocked }
        guard !isImporting else { throw WallpaperLibraryError.importInProgress }
        guard let index = wallpapers.firstIndex(where: { $0.id == wallpaper.id }) else { return }

        let removed = wallpapers[index]
        let mediaURL = try WallpaperPersistence.ownedMediaURL(for: removed, root: root)
        let thumbURL = try WallpaperPersistence.ownedThumbnailURL(for: removed, root: root)
        let variantsDirectory = try? WallpaperPersistence.ownedVariantsDirectory(for: removed, root: root)

        var next = wallpapers
        next.remove(at: index)
        try WallpaperPersistence.save(next, to: root)
        wallpapers = next

        var deletionErrors: [String] = []
        do {
            try deleteOwnedFile(at: mediaURL)
        } catch {
            deletionErrors.append(error.localizedDescription)
        }
        do {
            try deleteOwnedFile(at: thumbURL)
        } catch {
            deletionErrors.append(error.localizedDescription)
        }
        if let variantsDirectory {
            for (destination, task) in variantTasks where destination.deletingLastPathComponent() == variantsDirectory {
                task.cancel()
                variantTasks[destination] = nil
            }
            do {
                try deleteOwnedDirectory(at: variantsDirectory)
            } catch {
                deletionErrors.append(error.localizedDescription)
            }
        }
        if !deletionErrors.isEmpty {
            throw WallpaperLibraryError.deletionFailed(
                "O wallpaper foi removido da biblioteca, mas alguns arquivos não puderam ser apagados: \(deletionErrors.joined(separator: "; "))"
            )
        }
    }

    private func deleteOwnedFile(at url: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        try fm.removeItem(at: url)
    }

    private func deleteOwnedDirectory(at url: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        try fm.removeItem(at: url)
    }

    private func prepareLibraryRoot() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent(WallpaperPersistence.mediaDirectoryName, isDirectory: true), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent(WallpaperPersistence.thumbnailsDirectoryName, isDirectory: true), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent(WallpaperPersistence.variantsDirectoryName, isDirectory: true), withIntermediateDirectories: true)
    }
}

private struct WallpaperImportResult: Sendable {
    let wallpaper: Wallpaper
    let mediaURL: URL
    let thumbnailURL: URL
}


private enum WallpaperImportWorker {
    static func importVideo(from source: URL, into root: URL) async throws -> WallpaperImportResult {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw WallpaperLibraryError.invalidSource("Selecione um arquivo de vídeo, não uma pasta.")
        }
        guard fm.isReadableFile(atPath: source.path) else {
            throw WallpaperLibraryError.unreadableSource(source.path)
        }

        let metadata = try await measureVideo(at: source)
        try Task.checkCancellation()

        let id = UUID()
        let ext = source.pathExtension.isEmpty ? "mov" : source.pathExtension
        let fileName = "\(id.uuidString).\(ext)"
        let mediaURL = root.appendingPathComponent(WallpaperPersistence.mediaDirectoryName, isDirectory: true).appendingPathComponent(fileName)
        let thumbnailURL = root.appendingPathComponent(WallpaperPersistence.thumbnailsDirectoryName, isDirectory: true)
            .appendingPathComponent("\(id.uuidString).jpg")

        var created: [URL] = []
        do {
            try fm.createDirectory(at: mediaURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createDirectory(at: thumbnailURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Task.checkCancellation()
            try fm.copyItem(at: source, to: mediaURL)
            created.append(mediaURL)
            try await writeThumbnail(for: mediaURL, to: thumbnailURL)
            created.append(thumbnailURL)
            try Task.checkCancellation()
        } catch {
            rollback(files: created)
            throw error
        }

        let title = source.deletingPathExtension().lastPathComponent
        let wallpaper = Wallpaper(
            id: id,
            title: title,
            fileName: fileName,
            width: metadata.width,
            height: metadata.height,
            duration: metadata.duration
        )
        return WallpaperImportResult(wallpaper: wallpaper, mediaURL: mediaURL, thumbnailURL: thumbnailURL)
    }

    static func rollback(files: [URL]) {
        for url in files {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private struct VideoMetadata: Sendable {
        let width: Int
        let height: Int
        let duration: Double
    }

    private static func measureVideo(at url: URL) async throws -> VideoMetadata {
        let asset = AVURLAsset(url: url)
        let readable = try await asset.load(.isReadable)
        let playable = try await asset.load(.isPlayable)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let duration = try await asset.load(.duration).seconds
        guard readable, playable, !tracks.isEmpty, duration.isFinite, duration > 0 else {
            throw WallpaperLibraryError.invalidVideo(
                "Selecione um vídeo reproduzível, com faixa de vídeo, duração finita e maior que zero."
            )
        }
        let track = tracks[0]
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let rect = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let width = max(1, Int(abs(rect.width).rounded()))
        let height = max(1, Int(abs(rect.height).rounded()))
        return VideoMetadata(width: width, height: height, duration: duration)
    }

    private static func writeThumbnail(for videoURL: URL, to destination: URL) async throws {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        let image = try generator.copyCGImage(at: .zero, actualTime: nil)
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
            throw WallpaperLibraryError.invalidVideo("Não foi possível gerar a miniatura do vídeo.")
        }
        try data.write(to: destination, options: .atomic)
    }
}
