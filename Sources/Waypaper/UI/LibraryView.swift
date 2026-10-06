import AppKit
import AVKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct LibraryView: View {
    @ObservedObject var library: WallpaperLibrary
    @ObservedObject var displays: DisplayCoordinator
    let importVideos: ([URL]) -> Void
    let chooseVideos: () -> Void
    @State private var selectedID: UUID?
    @State private var displayID = ""
    @State private var pendingRemoval: Wallpaper?
    @State private var errorMessage: String?
    @State private var working = false
    @State private var dropTargeted = false
    @State private var openAtLogin = false

    private var selected: Wallpaper? { library.wallpapers.first { $0.id == selectedID } }
    private var settings: DisplaySettings { displays.assignments[displayID] ?? DisplaySettings() }
    private var current: Wallpaper? { library.wallpapers.first { $0.id == settings.wallpaperID } }
    private var isPreparing: Bool { displays.preparingDisplays.contains(displayID) }

    var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 185, idealWidth: 205, maxWidth: 240)
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()
                HSplitView {
                    collection.frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
                    inspector.frame(minWidth: 285, idealWidth: 310, maxWidth: 370, maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            synchronizeSelection()
            openAtLogin = LoginItem.isEnabled
        }
        .onChange(of: library.wallpapers.map(\.id)) { _ in synchronizeSelection() }
        .onChange(of: displays.displays.map(\.id)) { _ in synchronizeSelection() }
        .onChange(of: library.errorMessage) { if let message = $0 { errorMessage = message; library.errorMessage = nil } }
        .onChange(of: displays.errorMessage) { if let message = $0 { errorMessage = message; displays.errorMessage = nil } }
        .alert(L10n.string("Could not finish"), isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button(L10n.string("OK"), role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .confirmationDialog(L10n.string("Remove from library?"), isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }), titleVisibility: .visible) {
            Button(L10n.string("Remove wallpaper"), role: .destructive) {
                guard let wallpaper = pendingRemoval else { return }
                perform {
                    for (id, assignment) in displays.assignments where assignment.wallpaperID == wallpaper.id {
                        try displays.clear(displayID: id)
                    }
                    try library.remove(wallpaper)
                }
                pendingRemoval = nil
            }
            Button(L10n.string("Cancel"), role: .cancel) { pendingRemoval = nil }
        } message: { Text(l10n: "The library copy will be removed and will no longer be used on your displays. The original file will not be deleted.") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 10) {
                Image(nsImage: AppIdentity.menuIcon).resizable().frame(width: 26, height: 26)
                Text("Waypaper").font(.title3.weight(.semibold))
            }
            .padding(.top, 12)
            VStack(alignment: .leading, spacing: 10) {
                Text(l10n: "Displays").font(.headline).foregroundStyle(.secondary)
                ForEach(displays.displays) { display in
                    Button { displayID = display.id } label: {
                        HStack(spacing: 9) {
                            Image(systemName: "display")
                            Text(display.name).lineLimit(2)
                            Spacer(minLength: 0)
                            if displays.assignments[display.id]?.wallpaperID != nil {
                                Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                                    .accessibilityLabel(L10n.string("Wallpaper assigned"))
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(displayID == display.id ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(displayID == display.id ? .isSelected : [])
                }
                if displays.displays.isEmpty {
                    Text(l10n: "No displays available.").font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle(isOn: Binding(get: { openAtLogin }, set: { newValue in
                do { try LoginItem.setEnabled(newValue) }
                catch { errorMessage = error.localizedDescription }
                openAtLogin = LoginItem.isEnabled
            })) {
                Text(l10n: "Open at login")
            }
            .help(L10n.string("Launch Waypaper when you log in to this Mac."))
            Text(l10n: "Your desktop, in motion.").font(.callout.weight(.medium))
            Text(l10n: "Local videos. No account, no cloud.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(l10n: "Library").font(.title2.weight(.semibold))
                Text(l10n: "Choose a video and apply it to the selected display.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if library.isImporting { ProgressView().controlSize(.small).accessibilityLabel(L10n.string("Importing video")) }
            Button(action: chooseVideos) {
                Label { Text(l10n: "Import videos") } icon: { Image(systemName: "plus") }
            }
                .disabled(library.isImporting)
                .keyboardShortcut("o", modifiers: .command)
        }
        .padding(20)
    }

    private var collection: some View {
        ScrollView {
            if library.wallpapers.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "rectangle.stack.badge.play").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text(l10n: "A new background starts here").font(.title3.weight(.semibold))
                    Text(l10n: "Drag videos into this window or import them from your Mac. We keep a library copy; your originals are not changed.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 330)
                    Button(L10n.string("Choose videos"), action: chooseVideos).buttonStyle(.borderedProminent).disabled(library.isImporting)
                }
                .padding(32).frame(maxWidth: .infinity, minHeight: 340)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 16)], spacing: 20) {
                    ForEach(library.wallpapers) { wallpaper in
                        Button { selectedID = wallpaper.id } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                ThumbnailView(url: library.thumbnailURL(for: wallpaper))
                                    .aspectRatio(16 / 9, contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(selectedID == wallpaper.id ? Color.accentColor : Color.clear, lineWidth: 3))
                                Text(wallpaper.title).font(.callout.weight(.medium)).lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                HStack {
                                    Text("\(wallpaper.width) × \(wallpaper.height)")
                                    Spacer()
                                    if current?.id == wallpaper.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor).accessibilityLabel(L10n.string("Applied on this display")) }
                                }.font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(3).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.format("%1$@, %2$lld by %3$lld", wallpaper.title, Int64(wallpaper.width), Int64(wallpaper.height)))
                        .accessibilityAddTraits(selectedID == wallpaper.id ? .isSelected : [])
                        .contextMenu { Button(L10n.string("Remove from library…"), role: .destructive) { pendingRemoval = wallpaper } }
                    }
                }.padding(20)
            }
        }
        .background(dropTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dropTargeted) { providers in
            guard !library.isImporting else { return false }
            Task {
                var urls: [URL] = []
                for provider in providers {
                    let url: URL? = await withCheckedContinuation { continuation in
                        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                            if let url = item as? URL { continuation.resume(returning: url) }
                            else if let data = item as? Data { continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil)) }
                            else { continuation.resume(returning: nil) }
                        }
                    }
                    if let url { urls.append(url) }
                }
                importVideos(urls)
            }
            return true
        }
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let wallpaper = selected {
                    Text(l10n: "Preview").font(.headline)
                    WallpaperPreview(url: library.url(for: wallpaper), thumbnailURL: library.thumbnailURL(for: wallpaper))
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .id(wallpaper.id)
                    Text(wallpaper.title).font(.title3.weight(.semibold)).textSelection(.enabled)
                    Text("\(wallpaper.width) × \(wallpaper.height) · \(Int(wallpaper.duration)) s")
                        .font(.callout).foregroundStyle(.secondary)
                    Button {
                        perform { try await displays.apply(wallpaper, to: displayID) }
                    } label: {
                        Text(l10n: current?.id == wallpaper.id ? "Reapply to display" : "Apply to display")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(displayID.isEmpty || working)
                    Button(L10n.string("Remove from library…"), role: .destructive) { pendingRemoval = wallpaper }
                        .disabled(working)
                } else {
                    Text(l10n: "Select a wallpaper").font(.headline)
                    Text(l10n: "The preview and details appear here.").foregroundStyle(.secondary)
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text(l10n: "On this display").font(.headline)
                    Text(current?.title ?? L10n.string("macOS wallpaper"))
                        .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    Picker(L10n.string("Framing"), selection: Binding(get: { settings.fit }, set: { value in
                        var updated = settings; updated.fit = value; save(updated)
                    })) {
                        Text(l10n: "Fill").tag(WallpaperFit.fill)
                        Text(l10n: "Fit").tag(WallpaperFit.fit)
                    }
                    .pickerStyle(.segmented)
                    .help(L10n.string("Fill crops the edges; Fit keeps the whole video and may add bars."))
                    .disabled(current == nil || working)
                    SharpnessControl(value: settings.sharpness, enabled: current != nil && !working && !isPreparing) { value in
                        var updated = settings; updated.sharpness = value; save(updated)
                    }
                    Text(l10n: "Sharpness emphasizes edges; it is not AI super-resolution. The first time you choose a sharpness level, the video is processed once in the background; after that, playback is as light as the original video.")
                        .font(.caption).foregroundStyle(.secondary)
                    if isPreparing {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(l10n: "Preparing sharpness…").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Button(L10n.string(settings.paused ? "Resume" : "Pause")) {
                            var updated = settings; updated.paused.toggle(); save(updated)
                        }
                        Button(L10n.string("Restore background")) { perform { try displays.clear(displayID: displayID) } }
                    }.disabled(current == nil || working)
                    if working { ProgressView().controlSize(.small).accessibilityLabel(L10n.string("Applying setting")) }
                }
            }.padding(20)
        }
    }

    private func synchronizeSelection() {
        if !displays.displays.contains(where: { $0.id == displayID }) { displayID = displays.displays.first?.id ?? "" }
        if !library.wallpapers.contains(where: { $0.id == selectedID }) { selectedID = library.wallpapers.first?.id }
        if let message = library.errorMessage ?? displays.errorMessage { errorMessage = message }
    }

    private func save(_ settings: DisplaySettings) {
        let target = displayID
        perform { try await displays.updateSettings(settings, for: target) }
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        working = true
        Task { @MainActor in
            defer { working = false }
            do { try await operation() } catch { errorMessage = error.localizedDescription }
        }
    }
}

private struct SharpnessControl: View {
    let value: Double
    let enabled: Bool
    let commit: (Double) -> Void
    @State private var draft = 0.0

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack { Text(l10n: "Sharpness"); Spacer(); Text(draft == 0 ? L10n.string("Original") : "\(Int(draft * 100))%").foregroundStyle(.secondary) }
            Slider(value: $draft, in: 0...1, step: 0.05, onEditingChanged: { editing in if !editing { commit(draft) } })
                .accessibilityLabel(L10n.string("Sharpness amount"))
                .disabled(!enabled)
        }
        .onAppear { draft = value }
        .onChange(of: value) { draft = $0 }
    }
}

private struct ThumbnailView: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color(nsColor: .controlBackgroundColor)
            if let image { Image(nsImage: image).resizable().scaledToFill() }
            else { Image(systemName: "film").foregroundStyle(.secondary) }
        }
        .clipped()
        .task(id: url) {
            let data = await Task.detached(priority: .utility) { try? Data(contentsOf: url) }.value
            guard !Task.isCancelled else { return }
            image = data.flatMap(NSImage.init(data:))
        }
    }
}
