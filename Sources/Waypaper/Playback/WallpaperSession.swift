import AppKit
import AVFoundation

@MainActor
final class WallpaperSession {
    let displayID: String
    private(set) var window: NSWindow?
    private(set) var videoView: VideoView?
    let player = AVQueuePlayer()
    private(set) var looper: AVPlayerLooper?

    private weak var library: WallpaperLibrary?
    private var screen: NSScreen?
    private var settings = DisplaySettings()
    private var loadGeneration = 0
    private var loadTask: Task<Void, Error>?
    private var failureObserver: NSObjectProtocol?
    private var workspaceSuspended = false
    private var playbackBlockedByFailure = false
    private var fullyOccluded = false
    private var occlusionObserver: NSObjectProtocol?
    private var loadedURL: URL?
    var onFailure: ((String) -> Void)?

    /// True when playback is stopped due to load/runtime failure; distinct from `DisplaySettings.paused`.
    var isPlaybackBlockedByFailure: Bool { playbackBlockedByFailure }

    init(displayID: String, library: WallpaperLibrary) {
        self.displayID = displayID
        self.library = library
        player.isMuted = true
        player.actionAtItemEnd = .advance
        failureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self,
                      let item = notification.object as? AVPlayerItem,
                      self.player.items().contains(where: { $0 === item })
                else { return }
                self.playbackBlockedByFailure = true
                self.syncPlayback()
                self.onFailure?(item.error?.localizedDescription ?? L10n.string("Could not continue playback."))
            }
        }
    }

    deinit {
        if let failureObserver {
            NotificationCenter.default.removeObserver(failureObserver)
        }
    }

    func attach(screen: NSScreen) {
        self.screen = screen
        ensureWindow(on: screen)
        updateGeometry(for: screen)
    }

    func detachScreen() {
        invalidateLoads()
        screen = nil
        teardownWindowAndPlayer()
    }

    /// Fully occluded (e.g. another app covers the whole screen in full-screen/Spaces) stops
    /// decode+composite work entirely; the wallpaper isn't visible, so there's nothing to save for.
    private func updateOcclusion(for window: NSWindow) {
        fullyOccluded = !window.occlusionState.contains(.visible)
        syncPlayback()
    }

    func updateGeometry(for screen: NSScreen) {
        self.screen = screen
        guard let window else { return }
        window.setFrame(screen.frame, display: true)
        videoView?.applyContentsScale(screen.backingScaleFactor)
    }

    func apply(settings newSettings: DisplaySettings, workspaceSuspended: Bool) async throws {
        settings = newSettings
        settings.normalize()
        self.workspaceSuspended = workspaceSuspended

        guard settings.wallpaperID != nil else {
            clearPlayback()
            return
        }

        guard let library else {
            playbackBlockedByFailure = true
            syncPlayback()
            throw WaypaperPlaybackError.wallpaperMissing
        }
        guard let wallpaperID = settings.wallpaperID,
              let wallpaper = library.wallpapers.first(where: { $0.id == wallpaperID })
        else {
            playbackBlockedByFailure = true
            syncPlayback()
            throw WaypaperPlaybackError.wallpaperMissing
        }

        guard screen != nil else { return }

        // Resolve the content URL up front: sharpness > 0 plays a one-time baked variant
        // (see WallpaperLibrary.ensureSharpenedVariant / WallpaperVariantRenderer) instead of a
        // live CIFilter composition, so `loadedURL` alone already captures the sharpness level.
        let generation = invalidateLoads()
        let fit = settings.fit
        let sharpness = settings.sharpness

        let task = Task<URL, Error> { @MainActor in
            let url = try await library.ensureSharpenedVariant(for: wallpaper, sharpness: sharpness)
            try self.ensureLoadStillValid(generation: generation)
            if self.loadedURL == url, self.looper != nil, !self.playbackBlockedByFailure {
                self.videoView?.apply(fit: fit)
                return url
            }
            try await self.performLoad(url: url, generation: generation, fit: fit)
            return url
        }
        loadTask = Task<Void, Error> { try await withTaskCancellationHandler {
            _ = try await task.value
        } onCancel: {
            task.cancel()
        } }

        let resolvedURL: URL
        do {
            resolvedURL = try await task.value
        } catch is CancellationError {
            return
        } catch {
            guard generation == loadGeneration else { return }
            playbackBlockedByFailure = true
            syncPlayback()
            throw error
        }

        guard generation == loadGeneration else { return }
        guard screen != nil else { return }

        loadedURL = resolvedURL
        playbackBlockedByFailure = false
        videoView?.apply(fit: fit)
        syncPlayback()
    }

    func clearPlayback() {
        invalidateLoads()
        loadedURL = nil
        playbackBlockedByFailure = false
        teardownWindowAndPlayer()
    }

    func setWorkspaceSuspended(_ suspended: Bool) {
        workspaceSuspended = suspended
        syncPlayback()
    }

    func syncPlayback() {
        let shouldPlay = settings.wallpaperID != nil
            && screen != nil
            && looper != nil
            && !settings.paused
            && !workspaceSuspended
            && !playbackBlockedByFailure
            && !fullyOccluded
        if shouldPlay {
            player.play()
        } else {
            player.pause()
        }
    }

    func stop() {
        invalidateLoads()
        teardownWindowAndPlayer()
        if let failureObserver {
            NotificationCenter.default.removeObserver(failureObserver)
            self.failureObserver = nil
        }
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
            self.occlusionObserver = nil
        }
    }

    @discardableResult
    private func invalidateLoads() -> Int {
        loadTask?.cancel()
        loadTask = nil
        loadGeneration &+= 1
        return loadGeneration
    }

    private func ensureWindow(on screen: NSScreen) {
        guard window == nil else { return }
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.backgroundColor = .black
        let view = VideoView(player: player, fit: settings.fit, contentsScale: screen.backingScaleFactor)
        window.contentView = view
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
        self.window = window
        self.videoView = view
        fullyOccluded = !window.occlusionState.contains(.visible)
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                guard let self, let window else { return }
                self.updateOcclusion(for: window)
            }
        }
    }

    private func teardownWindowAndPlayer() {
        player.pause()
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
        loadedURL = nil
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
            self.occlusionObserver = nil
        }
        fullyOccluded = false
        window?.close()
        window = nil
        videoView = nil
    }

    private func performLoad(url: URL, generation: Int, fit: WallpaperFit) async throws {
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw WaypaperPlaybackError.unreadableVideo(url.path)
        }
        let asset = AVURLAsset(url: url)
        let playable = try await asset.load(.isPlayable)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let duration = try await asset.load(.duration).seconds
        guard playable, !tracks.isEmpty, duration.isFinite, duration > 0 else {
            throw WaypaperPlaybackError.invalidVideo(
                L10n.string("Select a playable video with a finite duration greater than zero.")
            )
        }
        try Task.checkCancellation()
        try ensureLoadStillValid(generation: generation)

        guard let screen else { throw CancellationError() }

        ensureWindow(on: screen)
        updateGeometry(for: screen)
        guard let videoView else { throw CancellationError() }

        try ensureLoadStillValid(generation: generation)

        // No videoComposition here: sharpness is baked into the file ahead of time (see
        // WallpaperLibrary.ensureSharpenedVariant), so playback is plain hardware decode
        // regardless of the sharpness setting.
        let template = AVPlayerItem(asset: asset)
        try ensureLoadStillValid(generation: generation)
        player.pause()
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
        looper = AVPlayerLooper(player: player, templateItem: template)
        videoView.apply(fit: fit)

        try ensureLoadStillValid(generation: generation)
    }

    private func ensureLoadStillValid(generation: Int) throws {
        try Task.checkCancellation()
        guard generation == loadGeneration else { throw CancellationError() }
        guard screen != nil else { throw CancellationError() }
    }
}
