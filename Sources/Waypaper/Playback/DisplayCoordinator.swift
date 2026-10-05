import AppKit
import Combine
import Foundation

@MainActor
final class DisplayCoordinator: NSObject, ObservableObject {
    @Published private(set) var displays: [DisplayDescriptor] = []
    @Published private(set) var assignments: [String: DisplaySettings] = [:]
    @Published var errorMessage: String?
    /// Displays currently baking a sharpened variant (or otherwise mid `session.apply`), so the
    /// UI can show a "preparando" indicator instead of looking frozen during the one-time export.
    @Published private(set) var preparingDisplays: Set<String> = []
    private(set) var sessions: [String: WallpaperSession] = [:]

    private let library: WallpaperLibrary
    private let settingsURL: URL
    private var screenByID: [String: NSScreen] = [:]
    private var workspaceSleeping = false
    private var sessionInactive = false
    private var persistenceBlocked = false
    private var started = false

    init(library: WallpaperLibrary, settingsURL: URL?) {
        self.library = library
        if let settingsURL {
            self.settingsURL = settingsURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.settingsURL = support.appendingPathComponent("Waypaper/displays.json")
        }
        super.init()
        do {
            assignments = try DisplayPersistence.load(from: self.settingsURL)
            for key in assignments.keys {
                assignments[key]?.normalize()
            }
        } catch {
            persistenceBlocked = true
            assignments = [:]
            errorMessage = error.localizedDescription
        }
        start()
    }

    func session(for displayID: String) -> WallpaperSession? {
        sessions[displayID]
    }

    func apply(_ wallpaper: Wallpaper, to displayID: String) async throws {
        var settings = assignments[displayID] ?? DisplaySettings()
        if assignments[displayID] == nil,
           NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            settings.paused = true
        }
        settings.wallpaperID = wallpaper.id
        settings.normalize()
        try await updateSettings(settings, for: displayID)
    }

    func updateSettings(_ settings: DisplaySettings, for displayID: String) async throws {
        var normalized = settings
        normalized.normalize()
        var candidate = assignments
        candidate[displayID] = normalized
        try persistAssignments(candidate)
        assignments = candidate
        guard let screen = screenByID[displayID] else { return }
        let session = sessions[displayID] ?? makeSession(for: displayID)
        session.attach(screen: screen)
        sessions[displayID] = session
        preparingDisplays.insert(displayID)
        defer { preparingDisplays.remove(displayID) }
        try await session.apply(settings: normalized, workspaceSuspended: isPlaybackSuspended)
    }

    func clear(displayID: String) throws {
        var settings = assignments[displayID] ?? DisplaySettings()
        settings.wallpaperID = nil
        settings.normalize()
        var candidate = assignments
        candidate[displayID] = settings
        try persistAssignments(candidate)
        assignments = candidate
        if let session = sessions.removeValue(forKey: displayID) {
            session.stop()
        }
    }

    /// Suspends playback for display sleep without clearing session lock.
    func suspendForWorkspace() {
        workspaceSleeping = true
        propagatePlaybackGate()
    }

    /// Resumes after display sleep; does not resume while the login session is inactive or manually paused.
    func resumeForWorkspace() {
        workspaceSleeping = false
        propagatePlaybackGate()
    }

    /// Suspends playback when the login session resigns active (screen lock / fast user switch).
    func suspendForSessionInactivity() {
        sessionInactive = true
        propagatePlaybackGate()
    }

    /// Resumes after the login session becomes active again; manual per-display pause still applies.
    func resumeForSessionActivity() {
        sessionInactive = false
        propagatePlaybackGate()
    }

    /// Smoke / test hook: pass `[]` to simulate all displays disconnected, then real screens to restore.
    func reconcile(screens: [NSScreen]) {
        reconcileScreens(screens)
    }

    func stop() {
        guard started else { return }
        started = false
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        sessions.values.forEach { $0.stop() }
        sessions.removeAll()
        screenByID.removeAll()
        displays = []
    }

    private var isPlaybackSuspended: Bool {
        workspaceSleeping || sessionInactive
    }

    private func start() {
        guard !started else { return }
        started = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(workspaceWillSleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(workspaceWillSleep), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(workspaceDidWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        center.addObserver(self, selector: #selector(sessionDidResignActive), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(sessionDidBecomeActive), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        reconcile(screens: NSScreen.screens)
    }

    @objc private func screenParametersChanged() {
        reconcile(screens: NSScreen.screens)
    }

    @objc private func workspaceWillSleep() {
        workspaceSleeping = true
        propagatePlaybackGate()
    }

    @objc private func workspaceDidWake() {
        workspaceSleeping = false
        propagatePlaybackGate()
    }

    @objc private func sessionDidResignActive() {
        sessionInactive = true
        propagatePlaybackGate()
    }

    @objc private func sessionDidBecomeActive() {
        sessionInactive = false
        propagatePlaybackGate()
    }

    private func propagatePlaybackGate() {
        let suspended = isPlaybackSuspended
        sessions.values.forEach { $0.setWorkspaceSuspended(suspended) }
    }

    private func reconcileScreens(_ screens: [NSScreen]) {
        let independent = DisplayIdentity.independentScreens(from: screens)
        var nextScreenByID: [String: NSScreen] = [:]
        var nextDisplays: [DisplayDescriptor] = []
        for (screen, cgID) in independent {
            let id = DisplayIdentity.persistentID(for: cgID)
            nextScreenByID[id] = screen
            nextDisplays.append(DisplayDescriptor(id: id, name: DisplayIdentity.localizedName(for: screen)))
        }
        nextDisplays.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let connected = Set(nextScreenByID.keys)
        let previousConnected = Set(screenByID.keys)

        for id in previousConnected.subtracting(connected) {
            sessions[id]?.detachScreen()
            sessions.removeValue(forKey: id)
        }

        screenByID = nextScreenByID
        displays = nextDisplays

        for (id, screen) in nextScreenByID {
            let settings = assignments[id] ?? DisplaySettings()
            guard settings.wallpaperID != nil else { continue }
            if let session = sessions[id] {
                session.attach(screen: screen)
                session.updateGeometry(for: screen)
                continue
            }
            let session = makeSession(for: id)
            session.attach(screen: screen)
            sessions[id] = session
            Task { @MainActor in
                guard self.sessions[id] === session else { return }
                let current = self.assignments[id] ?? DisplaySettings()
                guard current.wallpaperID != nil else { return }
                do {
                    try await session.apply(settings: current, workspaceSuspended: self.isPlaybackSuspended)
                } catch is CancellationError {
                    return
                } catch {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func makeSession(for displayID: String) -> WallpaperSession {
        let session = WallpaperSession(displayID: displayID, library: library)
        session.onFailure = { [weak self] message in
            self?.errorMessage = message
        }
        return session
    }

    private func persistAssignments(_ snapshot: [String: DisplaySettings]) throws {
        guard !persistenceBlocked else {
            throw WaypaperPlaybackError.persistenceBlocked
        }
        do {
            try DisplayPersistence.save(snapshot, to: settingsURL)
        } catch {
            persistenceBlocked = true
            errorMessage = error.localizedDescription
            throw error
        }
    }
}
