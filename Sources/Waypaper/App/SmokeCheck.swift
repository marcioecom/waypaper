import AppKit
import AVFoundation
import AVKit

@MainActor
enum SmokeCheck {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NSError(domain: "WaypaperSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    static func waitUntil(_ message: String, timeout: Double = 15, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            try require(Date() < deadline, message)
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    static func run(app: AppDelegate, source: URL) async throws {
        if Bundle.main.bundleURL.pathExtension == "app" {
            let path = L10n.bundle.bundleURL.standardizedFileURL.path
            try require(
                path.contains("/Contents/Resources/Waypaper_Waypaper.bundle"),
                "O bundle de localização resolveu para \(path). O app empacotado precisa carregar Contents/Resources/Waypaper_Waypaper.bundle; Bundle.module aponta para a pasta .build da máquina que compilou e o app fecha ao abrir em qualquer outro Mac."
            )
            if Locale.preferredLanguages.first?.hasPrefix("pt") == true {
                try require(L10n.string("Quit Waypaper") == "Encerrar Waypaper", "O app empacotado não carregou a tradução pt-BR")
                print("PASS: tradução pt-BR carregada")
            }
            print("PASS: localização carregada de Contents/Resources")
        }
        let library = app.library
        let displays = app.displays
        guard let root = app.smokeRoot, let screen = displays.displays.first else {
            throw NSError(domain: "WaypaperSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: "O smoke test requer uma sessão gráfica com monitor."])
        }
        let wallpaper = try await library.importVideo(source)
        try require(library.url(for: wallpaper) != source, "Importação deve guardar uma cópia, não o original")
        try require(FileManager.default.contentsEqual(atPath: source.path, andPath: library.url(for: wallpaper).path), "Importação alterou o vídeo")
        try require(NSImage(contentsOf: library.thumbnailURL(for: wallpaper)) != nil, "Miniatura não pode ser decodificada")
        let reloaded = WallpaperLibrary(root: root)
        try require(reloaded.wallpapers == library.wallpapers, "Biblioteca não sobreviveu à reabertura")
        print("PASS: importação preservou o original, miniatura válida e biblioteca persistida")

        let invalid = root.appendingPathComponent("invalid.mp4")
        try Data("not a video".utf8).write(to: invalid)
        var rejected = false
        do { _ = try await library.importVideo(invalid) } catch { rejected = true }
        try require(rejected && library.wallpapers == reloaded.wallpapers, "Arquivo inválido alterou a biblioteca")
        print("PASS: arquivo inválido rejeitado sem alterar a biblioteca")

        let corruptRoot = root.appendingPathComponent("corrupt-library")
        try FileManager.default.createDirectory(at: corruptRoot, withIntermediateDirectories: true)
        let manifest = corruptRoot.appendingPathComponent(WallpaperPersistence.manifestFileName)
        let corruptData = Data("{invalid".utf8)
        try corruptData.write(to: manifest)
        let corruptLibrary = WallpaperLibrary(root: corruptRoot)
        rejected = false
        do { _ = try await corruptLibrary.importVideo(source) } catch { rejected = true }
        let afterRejection = try Data(contentsOf: manifest)
        try require(rejected && afterRejection == corruptData, "Importação sobrescreveu manifesto corrompido")
        print("PASS: manifesto corrompido preservado, sem perda silenciosa de dados")

        let traversal = try JSONSerialization.data(withJSONObject: ["wallpapers": [[
            "id": UUID().uuidString, "title": "Invalid path", "fileName": "../outside.mp4",
            "width": 10, "height": 10, "duration": 1
        ]]])
        try traversal.write(to: manifest)
        let unsafeLibrary = WallpaperLibrary(root: corruptRoot)
        try require(unsafeLibrary.wallpapers.isEmpty && unsafeLibrary.errorMessage != nil, "Manifesto aceitou caminho fora da biblioteca")
        let cancelledImport = Task { try await library.importVideo(source) }
        cancelledImport.cancel()
        rejected = false
        do { _ = try await cancelledImport.value } catch is CancellationError { rejected = true }
        try require(rejected && WallpaperLibrary(root: root).wallpapers == library.wallpapers && library.wallpapers.count == 1, "Importação cancelada publicou um wallpaper")
        print("PASS: caminho inseguro rejeitado e importação cancelada sem publicação")

        try await displays.apply(wallpaper, to: screen.id)
        var settings = displays.assignments[screen.id] ?? DisplaySettings()
        settings.paused = false
        try await displays.updateSettings(settings, for: screen.id)
        try await waitUntil("Vídeo não apresentou frames") {
            guard let session = displays.sessions[screen.id] else { return false }
            return session.videoView?.videoLayer.isReadyForDisplay == true && session.player.currentTime().seconds > 0.5
        }
        guard let session = displays.sessions[screen.id], let window = session.window else {
            throw NSError(domain: "WaypaperSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: "Sessão desapareceu durante a reprodução"])
        }
        try require(window.ignoresMouseEvents, "Wallpaper intercepta cliques")
        try require(window.level.rawValue < Int(CGWindowLevelForKey(.desktopIconWindow)), "Wallpaper cobre os ícones")
        print("PASS: vídeo decodificado na janela do desktop")

        settings.paused = true
        try await displays.updateSettings(settings, for: screen.id)
        let pausedTime = session.player.currentTime().seconds
        try await Task.sleep(nanoseconds: 300_000_000)
        try require(session.player.rate == 0 && abs(session.player.currentTime().seconds - pausedTime) < 0.1, "Pausa não interrompeu o vídeo")
        settings.paused = false
        displays.suspendForWorkspace()
        displays.resumeForWorkspace()
        try require(session.player.rate == 0, "Acordar a sessão desfez a pausa manual")
        if let physicalScreen = NSScreen.screens.first {
            let peer = WallpaperSession(displayID: "smoke-independent-session", library: library)
            defer { peer.stop() }
            peer.attach(screen: physicalScreen)
            try await peer.apply(settings: DisplaySettings(wallpaperID: wallpaper.id), workspaceSuspended: false)
            try await waitUntil("Segunda sessão não reproduziu") { peer.player.currentTime().seconds > 0.3 }
            try require(session.player !== peer.player && session.player.rate == 0 && peer.player.rate > 0, "Pausar uma sessão afetou a outra")
        }
        let offlineID = "smoke-disconnected-display"
        let offlineSettings = DisplaySettings(wallpaperID: wallpaper.id, fit: .fill, sharpness: 0.7, paused: true)
        try await displays.updateSettings(offlineSettings, for: offlineID)
        try require(displays.sessions[offlineID] == nil && displays.assignments[screen.id] != offlineSettings, "Configuração offline alterou outra tela")
        print("PASS: sessões independentes, configuração offline e pausa manual preservada ao acordar")
        settings.fit = .fit
        settings.sharpness = 0.35
        let originalBytesBeforeSharpen = try Data(contentsOf: library.url(for: wallpaper))
        try await displays.updateSettings(settings, for: screen.id)
        try await waitUntil("Nitidez não apresentou frames", timeout: 60) {
            guard let updated = displays.sessions[screen.id] else { return false }
            return updated.videoView?.videoLayer.isReadyForDisplay == true && updated.player.currentTime().seconds > 0.5
        }
        // Sharpening is now baked once into a derived file instead of composited in real time,
        // so playback must be plain hardware decode: no AVVideoComposition at play time.
        try require(displays.sessions[screen.id]?.player.currentItem?.videoComposition == nil, "Reprodução com nitidez não deveria usar composição em tempo real")
        let sharpenedURL = try await library.ensureSharpenedVariant(for: wallpaper, sharpness: 0.35)
        try require(sharpenedURL != library.url(for: wallpaper), "Nitidez deveria reproduzir um arquivo derivado, não o original")
        try require(FileManager.default.fileExists(atPath: sharpenedURL.path), "Variante com nitidez não foi gravada em disco")
        let originalBytesAfterSharpen = try Data(contentsOf: library.url(for: wallpaper))
        try require(originalBytesAfterSharpen == originalBytesBeforeSharpen, "Aplicar nitidez alterou o arquivo original")
        // A second request for the same (wallpaper, level) must reuse the cached file rather
        // than re-exporting it.
        let variantModifiedAt = try FileManager.default.attributesOfItem(atPath: sharpenedURL.path)[.modificationDate] as? Date
        let reusedURL = try await library.ensureSharpenedVariant(for: wallpaper, sharpness: 0.37)
        try require(reusedURL == sharpenedURL, "Níveis de nitidez próximos deveriam reutilizar o mesmo bucket")
        let variantModifiedAfterReuse = try FileManager.default.attributesOfItem(atPath: sharpenedURL.path)[.modificationDate] as? Date
        try require(variantModifiedAt == variantModifiedAfterReuse, "Variante em cache foi regravada em vez de reutilizada")
        print("PASS: nitidez pré-processada uma única vez, original intacto e cache reutilizado")
        displays.suspendForSessionInactivity()
        displays.suspendForWorkspace()
        displays.resumeForWorkspace()
        try require(displays.sessions[screen.id]?.player.rate == 0, "Acordar a tela reativou uma sessão ainda inativa")
        displays.resumeForSessionActivity()
        print("PASS: pausa, retomada, ajuste de enquadramento e nitidez com frames reais")
        try await waitUntil("Loop não foi concluído", timeout: 90) {
            (displays.sessions[screen.id]?.looper?.loopCount ?? 0) > 0
        }
        print("PASS: loop completo com nitidez ativada")

        let assignmentsBeforeDisconnect = displays.assignments
        displays.reconcile(screens: [])
        try require(displays.sessions.isEmpty && displays.assignments == assignmentsBeforeDisconnect, "Desconectar perdeu configurações ou manteve players")
        displays.reconcile(screens: NSScreen.screens)
        displays.reconcile(screens: NSScreen.screens)
        try await waitUntil("Reconectar não restaurou o wallpaper", timeout: 25) {
            displays.sessions[screen.id]?.videoView?.videoLayer.isReadyForDisplay == true
        }
        let restored = DisplayCoordinator(library: library, settingsURL: root.appendingPathComponent("displays.json"))
        try require(restored.assignments == displays.assignments, "Configurações dos monitores não persistiram")
        restored.stop()
        try displays.clear(displayID: offlineID)
        print("PASS: desconexão/reconexão simulada e persistência por monitor")
        app.showLibrary()
        try await Task.sleep(nanoseconds: 400_000_000)
        if let view = app.window?.contentView {
            view.layoutSubtreeIfNeeded()
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let path = FileManager.default.temporaryDirectory.appendingPathComponent("waypaper-library-smoke.png")
                if let data = bitmap.representation(using: .png, properties: [:]) {
                    try data.write(to: path)
                    print("UI snapshot: \(path.path)")
                }
            }
            let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: app.window?.windowNumber ?? 0, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
            try require(app.window?.performKeyEquivalent(with: key) == true, "Atalho de prévia não foi tratado pela janela")
            try await waitUntil("Prévia não reproduziu pelo atalho") {
                (previewPlayer(in: view)?.player?.currentTime().seconds ?? 0) > 0.3
            }
            app.window?.orderOut(nil)
            try await waitUntil("Prévia continuou ativa com janela oculta") { previewPlayer(in: view)?.player?.rate == 0 }
            print("PASS: atalho SwiftUI iniciou a prévia e ocultar a janela pausou o vídeo")
        }
        try displays.clear(displayID: screen.id)
        try require(displays.sessions[screen.id] == nil, "Restaurar fundo não liberou o player")
        try library.remove(wallpaper)
        try require(FileManager.default.fileExists(atPath: source.path), "Remoção apagou o original")
        try require(!FileManager.default.fileExists(atPath: library.url(for: wallpaper).path), "Remoção deixou mídia órfã")
        try require(WallpaperLibrary(root: root).wallpapers.isEmpty, "Remoção não persistiu")
        displays.stop()
        try require(displays.sessions.isEmpty, "Encerramento deixou sessões ativas")
        print("PASS: restaurar fundo e remover da biblioteca preservaram o original")
    }


    private static func previewPlayer(in view: NSView) -> AVPlayerView? {
        if let player = view as? AVPlayerView { return player }
        return view.subviews.lazy.compactMap { previewPlayer(in: $0) }.first
    }
}
