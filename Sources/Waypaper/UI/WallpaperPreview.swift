import AppKit
import AVKit
import SwiftUI

struct WallpaperPreview: View {
    let url: URL
    let thumbnailURL: URL
    @State private var started = false
    @State private var poster: NSImage?

    var body: some View {
        ZStack {
            Color.black
            if started {
                PreviewPlayer(url: url)
            } else {
                if let poster { Image(nsImage: poster).resizable().scaledToFit() }
                Button { started = true } label: {
                    Label("Reproduzir prévia", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Reproduzir prévia")
                .keyboardShortcut(.space, modifiers: [])
                .help("Reproduzir prévia (Espaço)")
            }
        }
        .task(id: thumbnailURL) {
            let data = await Task.detached(priority: .utility) { try? Data(contentsOf: thumbnailURL) }.value
            guard !Task.isCancelled else { return }
            poster = data.flatMap(NSImage.init(data:))
        }
    }
}

private struct PreviewPlayer: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = false
        context.coordinator.load(url, into: view)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if context.coordinator.url != url { context.coordinator.load(url, into: view) }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        coordinator.stop()
        view.player = nil
    }

    final class Coordinator {
        var url: URL?
        let player = AVQueuePlayer()
        var looper: AVPlayerLooper?
        var observers: [NSObjectProtocol] = []

        func load(_ url: URL, into view: AVPlayerView) {
            stop()
            self.url = url
            player.isMuted = true
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            view.player = player
            player.play()
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self, weak view] notification in
                    guard let window = notification.object as? NSWindow, window === view?.window else { return }
                    if name != NSWindow.didChangeOcclusionStateNotification || !window.occlusionState.contains(.visible) {
                        self?.player.pause()
                    }
                })
            }
        }

        func stop() {
            player.pause()
            looper?.disableLooping()
            looper = nil
            player.removeAllItems()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
        }

        deinit { stop() }
    }
}
