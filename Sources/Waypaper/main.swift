import AppKit
import AVFoundation
import UniformTypeIdentifiers

final class VideoView: NSView {
    let videoLayer = AVPlayerLayer()

    init(player: AVPlayer) {
        super.init(frame: .zero)
        wantsLayer = true
        videoLayer.player = player
        videoLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(videoLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.frame = bounds
        CATransaction.commit()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let player = AVQueuePlayer()
    var looper: AVPlayerLooper?
    var windows: [NSWindow] = []
    var statusItem: NSStatusItem!
    let pauseItem = NSMenuItem(title: "Pausar", action: #selector(togglePause), keyEquivalent: "p")
    let fileItem = NSMenuItem(title: "Nenhum vídeo selecionado", action: nil, keyEquivalent: "")
    var paused = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    var sleeping = false
    var sessionInactive = false
    var loadTask: Task<Void, Never>?
    var failureObserver: NSObjectProtocol?
    let smoke = CommandLine.arguments.contains("--smoke-test")
    var smokeTimer: Timer?
    var smokeStarted = Date()
    var smokePhase = 0
    var pausedTime = 0.0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        player.isMuted = true
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "Waypaper"
        statusItem.button?.setAccessibilityLabel("Waypaper — wallpaper animado")
        let menu = NSMenu()
        menu.addItem(fileItem)
        menu.addItem(.separator())
        let openItem = NSMenuItem(title: "Escolher vídeo…", action: #selector(chooseVideo), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)
        pauseItem.target = self
        menu.addItem(pauseItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Encerrar Waypaper", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
        updatePlayback()

        NotificationCenter.default.addObserver(self, selector: #selector(rebuildWindows), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(didWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        center.addObserver(self, selector: #selector(resignSession), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(activateSession), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        failureObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main) { [weak self] notification in
            guard let self, let item = notification.object as? AVPlayerItem,
                  self.player.items().contains(where: { $0 === item }) else { return }
            self.paused = true
            self.updatePlayback()
            self.showError(item.error?.localizedDescription ?? "Não foi possível continuar a reprodução.")
        }

        let arguments = CommandLine.arguments.dropFirst().filter { $0 != "--smoke-test" }
        if let path = arguments.first {
            load(URL(fileURLWithPath: path))
        } else if let path = UserDefaults.standard.string(forKey: "videoPath"), FileManager.default.fileExists(atPath: path) {
            load(URL(fileURLWithPath: path))
        } else {
            chooseVideo()
        }
    }

    @objc func chooseVideo() {
        let panel = NSOpenPanel()
        panel.title = "Escolher vídeo para o wallpaper"
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { load(url) }
    }

    func load(_ url: URL) {
        loadTask?.cancel()
        loadTask = Task { @MainActor in
            do {
                guard FileManager.default.isReadableFile(atPath: url.path) else {
                    throw NSError(domain: "Waypaper", code: 1, userInfo: [NSLocalizedDescriptionKey: "O arquivo não está acessível: \(url.path)"])
                }
                let asset = AVURLAsset(url: url)
                let playable = try await asset.load(.isPlayable)
                let tracks = try await asset.loadTracks(withMediaType: .video)
                let duration = try await asset.load(.duration).seconds
                guard playable, !tracks.isEmpty, duration.isFinite, duration > 0 else {
                    throw NSError(domain: "Waypaper", code: 2, userInfo: [NSLocalizedDescriptionKey: "Selecione um vídeo reproduzível, com duração finita e maior que zero."])
                }
                try Task.checkCancellation()
                player.pause()
                looper?.disableLooping()
                player.removeAllItems()
                looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(asset: asset))
                fileItem.title = url.lastPathComponent
                fileItem.toolTip = url.path
                if !smoke { UserDefaults.standard.set(url.path, forKey: "videoPath") }
                rebuildWindows()
                updatePlayback()
                if smoke { startSmoke() }
            } catch is CancellationError {
                // A newer file selection owns playback now.
            } catch {
                if !Task.isCancelled { showError(error.localizedDescription) }
            }
        }
    }

    @objc func rebuildWindows() {
        windows.forEach { $0.close() }
        // ponytail: primary display only; use one player per display for independent wallpapers.
        windows = NSScreen.screens.prefix(1).map { screen in
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            window.ignoresMouseEvents = true
            window.hasShadow = false
            window.backgroundColor = .black
            window.contentView = VideoView(player: player)
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            return window
        }
    }

    @objc func togglePause() { paused.toggle(); updatePlayback() }
    @objc func willSleep() { sleeping = true; updatePlayback() }
    @objc func didWake() { sleeping = false; updatePlayback() }
    @objc func resignSession() { sessionInactive = true; updatePlayback() }
    @objc func activateSession() { sessionInactive = false; updatePlayback() }

    func updatePlayback() {
        if paused || sleeping || sessionInactive { player.pause() } else { player.play() }
        pauseItem.title = paused ? "Retomar" : "Pausar"
        pauseItem.isEnabled = looper != nil
    }

    func showError(_ message: String) {
        if smoke {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
        let alert = NSAlert()
        alert.messageText = "Não foi possível reproduzir o vídeo"
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc func quit() { NSApp.terminate(nil) }

    func applicationWillTerminate(_ notification: Notification) {
        loadTask?.cancel()
        smokeTimer?.invalidate()
        player.pause()
        looper?.disableLooping()
        player.removeAllItems()
        windows.forEach { $0.close() }
        windows.removeAll()
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NSStatusBar.system.removeStatusItem(statusItem)
        if smoke { print("PASS: encerramento removeu janelas e reprodução") }
    }

    // Runnable integration check: real decoding, desktop windows, pause/resume and loop.
    func startSmoke() {
        paused = false
        updatePlayback()
        smokeStarted = Date()
        smokeTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            if Date().timeIntervalSince(self.smokeStarted) > 90 { self.showError("Timeout no smoke test") }
            if self.player.currentItem?.status == .failed || self.looper?.status == .failed {
                self.showError(self.player.currentItem?.error?.localizedDescription ?? "Falha no loop")
            }
            switch self.smokePhase {
            case 0:
                guard self.player.currentTime().seconds > 1,
                      !self.windows.isEmpty,
                      self.windows.allSatisfy({ ($0.contentView as? VideoView)?.videoLayer.isReadyForDisplay == true }) else { return }
                print("PASS: vídeo decodificado em \(self.windows.count) tela(s)")
                self.statusItem.menu?.performActionForItem(at: 3)
                self.pausedTime = self.player.currentTime().seconds
                self.smokePhase = 1
            case 1:
                guard self.player.rate == 0, abs(self.player.currentTime().seconds - self.pausedTime) < 0.1 else {
                    self.showError("A ação Pausar não interrompeu o vídeo"); return
                }
                print("PASS: pausa pelo menu")
                self.statusItem.menu?.performActionForItem(at: 3)
                self.smokePhase = 2
            default:
                guard (self.looper?.loopCount ?? 0) >= 1, self.player.currentTime().seconds > 0.5 else { return }
                print("PASS: retomada e loop completo")
                self.statusItem.menu?.performActionForItem(at: 5)
            }
        }
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
