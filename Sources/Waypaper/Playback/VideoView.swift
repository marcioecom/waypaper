import AppKit
import AVFoundation

final class VideoView: NSView {
    let videoLayer = AVPlayerLayer()

    init(player: AVPlayer, fit: WallpaperFit, contentsScale: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.contentsScale = contentsScale
        videoLayer.contentsScale = contentsScale
        videoLayer.player = player
        apply(fit: fit)
        layer?.addSublayer(videoLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func apply(fit: WallpaperFit) {
        videoLayer.videoGravity = fit == .fill ? .resizeAspectFill : .resizeAspect
    }

    func applyContentsScale(_ scale: CGFloat) {
        guard layer?.contentsScale != scale else { return }
        layer?.contentsScale = scale
        videoLayer.contentsScale = scale
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.frame = bounds
        CATransaction.commit()
    }
}
