import AppKit

@MainActor
enum AppIdentity {
    static var menuIcon: NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 22), flipped: false) { _ in
            NSColor.labelColor.setStroke()
            let wave = NSBezierPath()
            wave.lineWidth = 2
            wave.lineCapStyle = .round
            wave.lineJoinStyle = .round
            wave.move(to: NSPoint(x: 2, y: 15))
            wave.curve(to: NSPoint(x: 7, y: 7), controlPoint1: NSPoint(x: 4, y: 15), controlPoint2: NSPoint(x: 4, y: 7))
            wave.curve(to: NSPoint(x: 11, y: 13), controlPoint1: NSPoint(x: 10, y: 7), controlPoint2: NSPoint(x: 8, y: 13))
            wave.curve(to: NSPoint(x: 15, y: 7), controlPoint1: NSPoint(x: 14, y: 13), controlPoint2: NSPoint(x: 12, y: 7))
            wave.curve(to: NSPoint(x: 20, y: 15), controlPoint1: NSPoint(x: 18, y: 7), controlPoint2: NSPoint(x: 18, y: 15))
            wave.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let displays: DisplayCoordinator
    private let showLibrary: () -> Void
    private let importVideos: () -> Void
    private let togglePlayback: () -> Void
    let pauseItem = NSMenuItem(title: "Pausar todos", action: #selector(toggle), keyEquivalent: "p")

    init(displays: DisplayCoordinator, showLibrary: @escaping () -> Void, importVideos: @escaping () -> Void, togglePlayback: @escaping () -> Void) {
        self.displays = displays
        self.showLibrary = showLibrary
        self.importVideos = importVideos
        self.togglePlayback = togglePlayback
        super.init()
        item.button?.image = AppIdentity.menuIcon
        item.button?.toolTip = "Waypaper"
        item.button?.setAccessibilityLabel("Waypaper — wallpapers por monitor")
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        for entry in [
            NSMenuItem(title: "Abrir biblioteca…", action: #selector(open), keyEquivalent: "b"),
            NSMenuItem(title: "Importar vídeos…", action: #selector(importFiles), keyEquivalent: "o"),
            .separator(), pauseItem, .separator(),
            NSMenuItem(title: "Encerrar Waypaper", action: #selector(quit), keyEquivalent: "q")
        ] {
            entry.target = self
            menu.addItem(entry)
        }
        item.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let active = displays.displays.compactMap { displays.assignments[$0.id] }.filter { $0.wallpaperID != nil }
        pauseItem.isEnabled = !active.isEmpty
        pauseItem.title = !active.isEmpty && active.allSatisfy(\.paused) ? "Retomar todos" : "Pausar todos"
    }

    @objc private func open() { showLibrary() }
    @objc private func importFiles() { importVideos() }
    @objc private func toggle() { togglePlayback() }
    @objc private func quit() { NSApp.terminate(nil) }

    func stop() { NSStatusBar.system.removeStatusItem(item) }
}
