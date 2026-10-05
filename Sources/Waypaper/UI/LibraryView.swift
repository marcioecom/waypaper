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
        .onAppear { synchronizeSelection() }
        .onChange(of: library.wallpapers.map(\.id)) { _ in synchronizeSelection() }
        .onChange(of: displays.displays.map(\.id)) { _ in synchronizeSelection() }
        .onChange(of: library.errorMessage) { if let message = $0 { errorMessage = message; library.errorMessage = nil } }
        .onChange(of: displays.errorMessage) { if let message = $0 { errorMessage = message; displays.errorMessage = nil } }
        .alert("Não foi possível concluir", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .confirmationDialog("Remover da biblioteca?", isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }), titleVisibility: .visible) {
            Button("Remover wallpaper", role: .destructive) {
                guard let wallpaper = pendingRemoval else { return }
                perform {
                    for (id, assignment) in displays.assignments where assignment.wallpaperID == wallpaper.id {
                        try displays.clear(displayID: id)
                    }
                    try library.remove(wallpaper)
                }
                pendingRemoval = nil
            }
            Button("Cancelar", role: .cancel) { pendingRemoval = nil }
        } message: { Text("A cópia da biblioteca será removida e deixará de ser usada nos monitores. O arquivo original não será apagado.") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 10) {
                Image(nsImage: AppIdentity.menuIcon).resizable().frame(width: 26, height: 26)
                Text("Waypaper").font(.title3.weight(.semibold))
            }
            .padding(.top, 12)
            VStack(alignment: .leading, spacing: 10) {
                Text("Monitores").font(.headline).foregroundStyle(.secondary)
                ForEach(displays.displays) { display in
                    Button { displayID = display.id } label: {
                        HStack(spacing: 9) {
                            Image(systemName: "display")
                            Text(display.name).lineLimit(2)
                            Spacer(minLength: 0)
                            if displays.assignments[display.id]?.wallpaperID != nil {
                                Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                                    .accessibilityLabel("Wallpaper configurado")
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
                    Text("Nenhum monitor disponível.").font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text("Seu desktop, em movimento.").font(.callout.weight(.medium))
            Text("Vídeos locais. Sem conta, sem nuvem.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Biblioteca").font(.title2.weight(.semibold))
                Text("Escolha um vídeo e aplique ao monitor selecionado.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if library.isImporting { ProgressView().controlSize(.small).accessibilityLabel("Importando vídeo") }
            Button(action: chooseVideos) { Label("Importar vídeos", systemImage: "plus") }
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
                    Text("Um novo fundo começa aqui").font(.title3.weight(.semibold))
                    Text("Arraste vídeos para esta janela ou importe do Mac. Guardamos uma cópia na biblioteca; seus originais não são alterados.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 330)
                    Button("Escolher vídeos", action: chooseVideos).buttonStyle(.borderedProminent).disabled(library.isImporting)
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
                                    if current?.id == wallpaper.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor).accessibilityLabel("Aplicado neste monitor") }
                                }.font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(3).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(wallpaper.title), \(wallpaper.width) por \(wallpaper.height)")
                        .accessibilityAddTraits(selectedID == wallpaper.id ? .isSelected : [])
                        .contextMenu { Button("Remover da biblioteca…", role: .destructive) { pendingRemoval = wallpaper } }
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
                    Text("Prévia").font(.headline)
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
                        Text(current?.id == wallpaper.id ? "Reaplicar ao monitor" : "Aplicar ao monitor")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(displayID.isEmpty || working)
                    Button("Remover da biblioteca…", role: .destructive) { pendingRemoval = wallpaper }
                        .disabled(working)
                } else {
                    Text("Selecione um wallpaper").font(.headline)
                    Text("A prévia e os detalhes aparecem aqui.").foregroundStyle(.secondary)
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text("Neste monitor").font(.headline)
                    Text(current?.title ?? "Fundo original do macOS")
                        .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    Picker("Enquadramento", selection: Binding(get: { settings.fit }, set: { value in
                        var updated = settings; updated.fit = value; save(updated)
                    })) {
                        Text("Preencher").tag(WallpaperFit.fill)
                        Text("Ajustar").tag(WallpaperFit.fit)
                    }
                    .pickerStyle(.segmented)
                    .help("Preencher recorta as bordas; Ajustar mantém todo o vídeo com barras quando necessário.")
                    .disabled(current == nil || working)
                    SharpnessControl(value: settings.sharpness, enabled: current != nil && !working && !isPreparing) { value in
                        var updated = settings; updated.sharpness = value; save(updated)
                    }
                    Text("Nitidez realça contornos; não é super-resolução por IA. A primeira vez que você liga um nível de nitidez, o vídeo é processado uma única vez em segundo plano; depois disso a reprodução é tão leve quanto o vídeo original.")
                        .font(.caption).foregroundStyle(.secondary)
                    if isPreparing {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Preparando nitidez…").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Button(settings.paused ? "Retomar" : "Pausar") {
                            var updated = settings; updated.paused.toggle(); save(updated)
                        }
                        Button("Restaurar fundo") { perform { try displays.clear(displayID: displayID) } }
                    }.disabled(current == nil || working)
                    if working { ProgressView().controlSize(.small).accessibilityLabel("Aplicando configuração") }
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
            HStack { Text("Nitidez"); Spacer(); Text(draft == 0 ? "Original" : "\(Int(draft * 100))%").foregroundStyle(.secondary) }
            Slider(value: $draft, in: 0...1, step: 0.05, onEditingChanged: { editing in if !editing { commit(draft) } })
                .accessibilityLabel("Intensidade da nitidez")
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
