import SwiftUI

/// "Get More Soundpacks": pick a classic sound scheme and download it as a
/// user soundpack. Nothing here changes which pack is in use.
struct SoundCatalogSheet: View {
    var library: SoundpackLibrary
    /// Called with the new pack's folder name after a download.
    var onInstalled: (String) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var installer = SoundCatalogInstaller()
    @State private var selection: String?
    @State private var search = ""
    @State private var message: String?
    @State private var errorMessage: String?

    private let catalog = SoundCatalog.bundled

    /// Catalog id → user pack folder, refreshed when the pack list changes.
    @State private var installed: [String: String] = [:]

    private var groups: [(name: String, packs: [SoundCatalog.Pack])] {
        let all = catalog?.groups ?? []
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return all }
        return all.compactMap { group in
            let packs = group.packs.filter {
                $0.name.localizedCaseInsensitiveContains(query) || group.name.localizedCaseInsensitiveContains(query)
            }
            return packs.isEmpty ? nil : (group.name, packs)
        }
    }

    private var selectedPack: SoundCatalog.Pack? {
        guard let selection else { return nil }
        return catalog?.packs.first { $0.id == selection }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Get More Soundpacks").font(.headline)
            Text("Classic sound schemes from Windows, Mac OS, Android and the iPhone. When you choose one, MaccessHub downloads its sounds from the public archive where they already live and turns them into a soundpack. MaccessHub doesn't include or host these sounds. Most belong to Microsoft or Apple and are for your own use; the Android sounds are open source.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if catalog == nil {
                Text("The soundpack list is missing from this copy of MaccessHub.").foregroundStyle(.red)
            }
            TextField("Search", text: $search)
                .accessibilityLabel("Search soundpacks")
            List(selection: $selection) {
                ForEach(groups, id: \.name) { group in
                    Section(group.name) {
                        ForEach(group.packs) { pack in
                            row(pack).tag(pack.id)
                        }
                    }
                }
            }
            .frame(minHeight: 220)
            .accessibilityLabel("Soundpacks you can download")
            if let pack = selectedPack { detail(pack) }
            if let active = installer.activePack {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: installer.fraction)
                        .accessibilityLabel("Downloading \(active.name)")
                        .accessibilityValue("\(Int(installer.fraction * 100)) percent")
                    Text(installer.status).font(.caption)
                }
            }
            if let message {
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isStaticText)
            }
            HStack {
                if installer.isBusy {
                    Button("Cancel Download") { installer.cancel() }
                }
                Spacer()
                Button("Close") { installer.cancel(); dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(downloadTitle) { download() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedPack == nil || installer.isBusy || isInstalled(selectedPack))
                    .accessibilityLabel(downloadLabel)
            }
        }
        .padding()
        .frame(width: 560, height: 600)
        .alert("Download", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .onAppear {
            installed = SoundCatalog.installed(in: library)
            if selection == nil { selection = catalog?.packs.first?.id }
        }
        .onChange(of: library.packs.map(\.id)) { installed = SoundCatalog.installed(in: library) }
    }

    private func isInstalled(_ pack: SoundCatalog.Pack?) -> Bool {
        guard let pack, let folder = installed[pack.id] else { return false }
        return library.pack(id: folder) != nil
    }

    private var downloadTitle: String { isInstalled(selectedPack) ? "Already Downloaded" : "Download" }

    private var downloadLabel: String {
        guard let pack = selectedPack else { return "Download" }
        return isInstalled(pack) ? "\(pack.name) is already downloaded" : "Download \(pack.name)"
    }

    @ViewBuilder
    private func row(_ pack: SoundCatalog.Pack) -> some View {
        VStack(alignment: .leading) {
            Text(pack.name)
            Text(pack.summary + (isInstalled(pack) ? ", downloaded" : ""))
                .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func detail(_ pack: SoundCatalog.Pack) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("Sounds", value: pack.summary)
            LabeledContent("Downloaded from", value: pack.hosts.joined(separator: ", "))
            Text(pack.license).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("Events it covers") {
                Text(pack.files.compactMap { SoundEvent.byID[$0.event]?.title }.joined(separator: ", "))
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func download() {
        guard let pack = selectedPack, !installer.isBusy else { return }
        message = nil
        installer.install(pack, into: library) { result in
            switch result {
            case .success(let outcome):
                var text = "\(outcome.folderName) is ready, with \(outcome.soundCount) sound\(outcome.soundCount == 1 ? "" : "s"). It's in your soundpacks list. To hear it, choose it as the soundpack for event sounds."
                if !outcome.skipped.isEmpty {
                    text += " \(outcome.skipped.count) sound\(outcome.skipped.count == 1 ? "" : "s") couldn't be downloaded and \(outcome.skipped.count == 1 ? "was" : "were") left out: \(outcome.skipped.joined(separator: ", "))."
                }
                message = text
                AppController.shared.speaker.speak(text)
                onInstalled(outcome.folderName)
            case .failure(let error):
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    message = "Download cancelled. Nothing was saved."
                    announce("Download cancelled")
                } else {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

/// The button that opens the catalog, for the Soundpacks and Event Sounds pages.
struct GetMoreSoundpacksButton: View {
    var library: SoundpackLibrary
    var onInstalled: (String) -> Void = { _ in }
    @State private var showing = false

    var body: some View {
        Button("Get More Soundpacks…") { showing = true }
            .help("Download classic Windows, Mac OS, Android and iPhone sound schemes as soundpacks.")
            .disabled(SoundCatalog.bundled == nil)
            .sheet(isPresented: $showing) {
                SoundCatalogSheet(library: library, onInstalled: onInstalled)
            }
    }
}
