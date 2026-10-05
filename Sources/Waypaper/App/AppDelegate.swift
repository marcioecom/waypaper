import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let library: WallpaperLibrary
    let displays: DisplayCoordinator
    let smoke: Bool
    let smokeRoot: URL?
    var window: NSWindow?
    var statusBar: StatusBarController?
    var startupTask: Task<Void, Never>?
    var importTask: Task<Void, Never>?

    override init() {
        smoke = CommandLine.arguments.contains("--smoke-test")
        smokeRoot = smoke ? FileManager.default.temporaryDirectory.appendingPathComponent("waypaper-smoke-\(UUID().uuidString)", isDirectory: true) : nil
        library = WallpaperLibrary(root: smokeRoot)
        displays = DisplayCoordinator(library: library, settingsURL: smokeRoot?.appendingPathComponent("displays.json"))
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let resources = Bundle.main.url(forResource: "Waypaper_Waypaper", withExtension: "bundle").flatMap(Bundle.init(url:)) ?? Bundle.module
        if let url = resources.url(forResource: "AppIcon", withExtension: "png") {
            NSApp.applicationIconImage = NSImage(contentsOf: url)
        }
        installMainMenu()
        statusBar = StatusBarController(displays: displays, showLibrary: { [weak self] in self?.showLibrary() }, importVideos: { [weak self] in self?.chooseVideos() }, togglePlayback: { [weak self] in self?.toggleAll() })
        showLibrary()
        startupTask = Task { @MainActor in
            do {
                let argument = CommandLine.arguments.dropFirst().first { !$0.hasPrefix("--") }
                if smoke {
                    guard let argument else { throw CocoaError(.fileNoSuchFile) }
                    try await SmokeCheck.run(app: self, source: URL(fileURLWithPath: argument))
                    NSApp.terminate(nil)
                    return
                }
                if let argument {
                    let wallpaper = try await library.importVideo(URL(fileURLWithPath: argument))
                    if let display = displays.displays.first { try await displays.apply(wallpaper, to: display.id) }
                } else if library.wallpapers.isEmpty, let path = UserDefaults.standard.string(forKey: "videoPath") {
                    let wallpaper = try await library.importVideo(URL(fileURLWithPath: path))
                    if let display = displays.displays.first { try await displays.apply(wallpaper, to: display.id) }
                    UserDefaults.standard.removeObject(forKey: "videoPath")
                }
            } catch {
                if smoke {
                    fputs("FAIL: \(error.localizedDescription)\n", stderr)
                    displays.stop()
                    if let smokeRoot { try? FileManager.default.removeItem(at: smokeRoot) }
                    exit(1)
                }
                library.errorMessage = error.localizedDescription
            }
        }
    }

    func showLibrary() {
        if window == nil {
            let view = LibraryView(library: library, displays: displays, importVideos: { [weak self] in self?.importVideos($0) }, chooseVideos: { [weak self] in self?.chooseVideos() })
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 700), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Waypaper"
            window.minSize = NSSize(width: 860, height: 560)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: view)
            window.center()
            self.window = window
        }
        // Dock icon and real minimize-to-Dock only make sense while the library window is open;
        // a pure menu-bar accessory app otherwise (matches the original "no Dock icon" design).
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    @objc func chooseVideos() {
        guard !library.isImporting, importTask == nil else { return }
        showLibrary()
        let panel = NSOpenPanel()
        panel.title = "Importar vídeos para a biblioteca"
        panel.message = "Uma cópia será guardada no Waypaper. O arquivo original não será alterado."
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            self?.importVideos(panel.urls)
        }
    }

    func importVideos(_ urls: [URL]) {
        guard importTask == nil, !library.isImporting else { return }
        importTask = Task { @MainActor in
            defer { importTask = nil }
            var errors: [String] = []
            for url in urls {
                do { _ = try await library.importVideo(url) }
                catch { errors.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
            if !errors.isEmpty { library.errorMessage = errors.joined(separator: "\n") }
        }
    }

    func toggleAll() {
        let active = displays.displays.compactMap { display -> (String, DisplaySettings)? in
            guard let settings = displays.assignments[display.id], settings.wallpaperID != nil else { return nil }
            return (display.id, settings)
        }
        let pause = !active.allSatisfy { $0.1.paused }
        Task { @MainActor in
            do {
                for (id, var settings) in active {
                    settings.paused = pause
                    try await displays.updateSettings(settings, for: id)
                }
            } catch { displays.errorMessage = error.localizedDescription }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showLibrary()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        startupTask?.cancel()
        importTask?.cancel()
        displays.stop()
        statusBar?.stop()
        window?.close()
        if let smokeRoot { try? FileManager.default.removeItem(at: smokeRoot) }
        if smoke { print("PASS: encerramento liberou sessões e biblioteca temporária") }
    }

    private func installMainMenu() {
        let main = NSMenu()
        let app = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Encerrar Waypaper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        app.submenu = appMenu
        main.addItem(app)
        let file = NSMenuItem()
        let fileMenu = NSMenu(title: "Arquivo")
        let item = NSMenuItem(title: "Importar vídeos…", action: #selector(chooseVideos), keyEquivalent: "o")
        item.target = self
        fileMenu.addItem(item)
        file.submenu = fileMenu
        main.addItem(file)
        let edit = NSMenuItem()
        let editMenu = NSMenu(title: "Editar")
        for (title, action, key) in [("Copiar", "copy:", "c"), ("Colar", "paste:", "v"), ("Selecionar tudo", "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        edit.submenu = editMenu
        main.addItem(edit)
        NSApp.mainMenu = main
    }
}
