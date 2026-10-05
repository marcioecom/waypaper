import AVFoundation
import CoreImage
import Foundation

/// Bakes a sharpened copy of a video file once, so playback can use ordinary hardware
/// decoding afterwards instead of running a `CIUnsharpMask` composition on every frame.
///
/// This is the fix for the CPU/RAM regression measured with real-time compositing: profiling
/// showed the cost was `CIContext.render` blocking synchronously once per frame inside
/// `AVMutableVideoComposition`'s CI-filter closure at 60 fps / 4K (~76% of the compositor
/// queue's samples, matching 66% CPU / 1.5GB with sharpness at 100% vs 3.5% / 79MB with it off).
/// Capping the composition's frame rate did not help and broke 60 fps smoothness, so instead
/// the filter now runs exactly once per sharpness level, producing a derived file that plays
/// back identically to any other plain video.
/// Thin `Sendable` box around an `AVAssetExportSession` so its lifetime can cross the
/// `@Sendable` cancellation-handler boundary; `cancelExport()` itself is safe to call from any
/// thread per Apple's documentation.
private final class ExportSessionBox: @unchecked Sendable {
    private let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
    func cancel() { session.cancelExport() }
}

enum WallpaperVariantRenderer {
    enum RenderError: LocalizedError {
        case noVideoTrack
        case exportFailed(String)

        var errorDescription: String? {
            switch self {
            case .noVideoTrack:
                return "O vídeo original não possui uma trilha de vídeo válida."
            case .exportFailed(let detail):
                return "Não foi possível preparar a nitidez do vídeo: \(detail)"
            }
        }
    }

    /// Renders `source` with `CIUnsharpMask` applied at `sharpness` (0...1) into `destination`,
    /// writing atomically (via a temp file renamed into place) so partial/cancelled exports never
    /// leave a corrupt file at `destination`. `source` is only ever read, never mutated.
    static func render(source: URL, sharpness: Double, to destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard tracks.first != nil else { throw RenderError.noVideoTrack }

        let amount = DisplaySettings.clampSharpness(sharpness) * 1.5
        let composition = AVMutableVideoComposition(asset: asset, applyingCIFiltersWithHandler: { request in
            let source = request.sourceImage.clampedToExtent()
            guard let filter = CIFilter(name: "CIUnsharpMask") else {
                request.finish(with: source, context: nil)
                return
            }
            filter.setValue(source, forKey: kCIInputImageKey)
            filter.setValue(amount, forKey: kCIInputIntensityKey)
            filter.setValue(1.5, forKey: kCIInputRadiusKey)
            let output = filter.outputImage?.cropped(to: request.sourceImage.extent) ?? source
            request.finish(with: output, context: nil)
        })

        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw RenderError.exportFailed("Não foi possível criar a sessão de exportação.")
        }
        exportSession.videoComposition = composition
        exportSession.outputFileType = .mp4

        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tempURL = destination.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString + ".tmp.mp4")
        if fm.fileExists(atPath: tempURL.path) {
            try fm.removeItem(at: tempURL)
        }

        // AVAssetExportSession is NS_SWIFT_NONSENDABLE but only ever touched here, serially,
        // from this async context and the cancellation handler below; box it to satisfy the
        // @Sendable closure requirement without unsafely sharing mutable state across threads.
        let box = ExportSessionBox(exportSession)
        do {
            try await withTaskCancellationHandler {
                try await exportSession.export(to: tempURL, as: .mp4)
            } onCancel: {
                box.cancel()
            }
        } catch {
            try? fm.removeItem(at: tempURL)
            throw RenderError.exportFailed(error.localizedDescription)
        }
        try Task.checkCancellation()

        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: tempURL, to: destination)
    }
}
