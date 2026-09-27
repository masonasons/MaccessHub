import SwiftUI

struct SettingsView: View {
    @Bindable var store: SettingsStore
    var library: SoundpackLibrary

    var body: some View {
        TabView {
            GeneralSettingsView(store: store)
                .tabItem { Label("General", systemImage: "gear") }
            EventSoundsSettingsView(store: store, library: library)
                .tabItem { Label("Event Sounds", systemImage: "bell") }
            KeyClicksSettingsView(store: store, library: library)
                .tabItem { Label("Key Clicks", systemImage: "keyboard") }
            ToolsSettingsView(store: store)
                .tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }
            ShortcutsSettingsView(store: store)
                .tabItem { Label("Shortcuts", systemImage: "command") }
            SoundpacksSettingsView(store: store, library: library)
                .tabItem { Label("Soundpacks", systemImage: "folder.badge.gearshape") }
        }
        .padding(.top, 8)
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @Bindable var store: SettingsStore

    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    @State private var accessibilityTrusted = AccessibilityPermission.isTrusted
    @State private var voices = SpeechVoices.available()

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch MaccessHub at login", isOn: $store.data.general.launchAtLogin)
            }
            Section("Speech") {
                Picker("Speak messages with", selection: $store.data.general.speechOutput) {
                    ForEach(SpeechOutput.allCases) { Text($0.title).tag($0) }
                }
                Picker("System voice", selection: $store.data.general.speechVoice) {
                    Text("Default").tag(String?.none)
                    ForEach(voices, id: \.identifier) { voice in
                        Text(voice.title).tag(String?.some(voice.identifier))
                    }
                }
                Slider(value: $store.data.general.speechRate, in: 0...1) {
                    Text("System voice rate")
                } minimumValueLabel: { Text("Slow") } maximumValueLabel: { Text("Fast") }
                .accessibilityValue("\(Int(store.data.general.speechRate * 100)) percent")
                Slider(value: $store.data.general.speechVolume, in: 0...1) {
                    Text("System voice volume")
                } minimumValueLabel: { Text("Quiet") } maximumValueLabel: { Text("Loud") }
                .accessibilityValue("\(Int(store.data.general.speechVolume * 100)) percent")
                Button("Test Speech") {
                    AppController.shared.speaker.speak("This is MaccessHub.")
                }
                Text("With VoiceOver output, messages use your VoiceOver voice and can be interrupted like any other VoiceOver speech. macOS will ask you once to allow MaccessHub to control VoiceOver.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Permissions") {
                LabeledContent("Accessibility") {
                    HStack {
                        Text(accessibilityTrusted ? "Granted" : "Not granted")
                            .foregroundStyle(accessibilityTrusted ? .green : .red)
                        if !accessibilityTrusted {
                            Button("Request") {
                                AccessibilityPermission.request()
                                AccessibilityPermission.openSystemSettings()
                            }
                        }
                    }
                }
                Text("Accessibility access is needed for key clicks, position information, menu extras, and window and menu sounds. If key clicks stay silent after granting it, also allow MaccessHub under Input Monitoring.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Open Accessibility Settings") { AccessibilityPermission.openSystemSettings() }
                    Button("Open Input Monitoring Settings") { AccessibilityPermission.openInputMonitoringSettings() }
                    Button("Open Automation Settings") { AccessibilityPermission.openAutomationSettings() }
                }
            }
            Section("Updates") {
                Toggle("Check for updates automatically", isOn: Binding(
                    get: { Updater.shared.automaticallyChecks },
                    set: { Updater.shared.automaticallyChecks = $0 }))
                Toggle("Download and install updates automatically", isOn: Binding(
                    get: { Updater.shared.automaticallyDownloads },
                    set: { Updater.shared.automaticallyDownloads = $0 }))
                LabeledContent("Installed version", value: Self.versionString)
                HStack {
                    Button("Check for Updates Now") { Updater.shared.checkForUpdates() }
                    if let last = Updater.shared.lastCheck {
                        Text("Last checked \(last.formatted(date: .abbreviated, time: .shortened))")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Settings File") {
                LabeledContent("Location", value: SettingsStore.fileURL.path)
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([SettingsStore.fileURL])
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityTrusted = AccessibilityPermission.isTrusted
        }
        .onAppear { accessibilityTrusted = AccessibilityPermission.isTrusted }
    }
}

// MARK: - Shared sound controls

struct SoundpackPicker: View {
    let title: String
    @Binding var packID: String
    var library: SoundpackLibrary

    var body: some View {
        Picker(title, selection: $packID) {
            ForEach(library.packs) { pack in
                Text(pack.isBuiltIn ? "\(pack.name) (built-in)" : pack.name).tag(pack.id)
            }
            if library.pack(id: packID) == nil {
                Text("\(packID) (missing)").tag(packID)
            }
        }
    }
}

struct SoundEventRow: View {
    let event: SoundEvent
    @Bindable var store: SettingsStore
    var library: SoundpackLibrary

    private var source: SoundScheme.Source? {
        SoundScheme(settings: store.data, library: library).source(for: event)
    }

    private var isEnabled: Binding<Bool> {
        Binding(get: { store.data.isEnabled(event) }, set: { store.data.setEnabled($0, for: event) })
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Toggle(isOn: isEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title)
                    Text(statusText).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                AppController.shared.preview(event)
            } label: { Image(systemName: "play.circle") }
            .buttonStyle(.borderless)
            .accessibilityLabel("Preview \(event.title)")
            .disabled(source == nil)
            Button("Choose…") { choose() }
                .accessibilityLabel("Choose sound for \(event.title)")
            if store.data.soundOverrides[event.id] != nil {
                Button("Use Pack") { store.data.soundOverrides[event.id] = nil }
                    .accessibilityLabel("Use pack sound for \(event.title)")
            }
        }
    }

    private var statusText: String {
        var parts: [String] = []
        if let source { parts.append(source.description) } else { parts.append("No sound") }
        if let note = event.note { parts.append(note) }
        return parts.joined(separator: " · ")
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.title = "Choose a sound for \(event.title)"
        panel.allowedContentTypes = [.audio]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let current = source?.url { panel.directoryURL = current.deletingLastPathComponent() }
        if panel.runModal() == .OK, let url = panel.url {
            store.data.soundOverrides[event.id] = url.path
            AppController.shared.preview(event)
        }
    }
}

// MARK: - Event Sounds

struct EventSoundsSettingsView: View {
    @Bindable var store: SettingsStore
    var library: SoundpackLibrary

    var body: some View {
        Form {
            Section {
                Toggle("Play sounds for system events", isOn: $store.data.eventSounds.enabled)
                SoundpackPicker(title: "Soundpack", packID: $store.data.eventSounds.packID, library: library)
                Slider(value: $store.data.eventSounds.volume, in: 0...1) { Text("Volume") }
                    .accessibilityValue("\(Int(store.data.eventSounds.volume * 100)) percent")
                Toggle("Use Classic sounds for events the pack does not cover", isOn: $store.data.eventSounds.fillMissingFromClassic)
                HStack {
                    Button("Enable All") { setAll(true) }
                    Button("Disable All") { setAll(false) }
                    Button("Reset to Defaults") { store.data.eventSounds.eventStates = [:] }
                }
            }
            ForEach(SoundGroup.eventGroups) { group in
                Section(group.title) {
                    ForEach(SoundEvent.events(in: group)) { event in
                        SoundEventRow(event: event, store: store, library: library)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func setAll(_ on: Bool) {
        for event in SoundEvent.all where !event.isKeyClick { store.data.eventSounds.eventStates[event.id] = on }
    }
}

// MARK: - Key Clicks

struct KeyClicksSettingsView: View {
    @Bindable var store: SettingsStore
    var library: SoundpackLibrary

    var body: some View {
        Form {
            Section {
                Toggle("Play a click for each key press", isOn: $store.data.keyClicks.enabled)
                SoundpackPicker(title: "Soundpack", packID: $store.data.keyClicks.packID, library: library)
                Slider(value: $store.data.keyClicks.volume, in: 0...1) { Text("Volume") }
                    .accessibilityValue("\(Int(store.data.keyClicks.volume * 100)) percent")
                Toggle("Use Classic sounds for keys the pack does not cover", isOn: $store.data.keyClicks.fillMissingFromClassic)
            }
            Section("When to click") {
                Picker("Play clicks", selection: $store.data.keyClicks.scope) {
                    ForEach(KeyClickScope.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Click while a key repeats", isOn: $store.data.keyClicks.playOnRepeat)
                Toggle("Silent when Command is held", isOn: $store.data.keyClicks.ignoreWithCommand)
                Toggle("Silent when Control is held", isOn: $store.data.keyClicks.ignoreWithControl)
                Toggle("Silent when Option is held", isOn: $store.data.keyClicks.ignoreWithOption)
            }
            Section("Key sounds") {
                ForEach(SoundEvent.events(in: .keys)) { event in
                    SoundEventRow(event: event, store: store, library: library)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Tools

struct ToolsSettingsView: View {
    @Bindable var store: SettingsStore

    var body: some View {
        Form {
            Section("Audio Devices") {
                Toggle("Wrap around from the last device to the first", isOn: $store.data.audioDevices.wrapAround)
                Toggle("Speak the device's volume after switching", isOn: $store.data.audioDevices.speakVolume)
                Picker("Microphone mute feedback", selection: $store.data.audioDevices.muteFeedback) {
                    ForEach(MuteFeedback.allCases) { Text($0.title).tag($0) }
                }
                Text("Choose the sounds under Event Sounds → Audio Devices. If no sound is assigned, the mute shortcut speaks instead.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Menu Extras") {
                Toggle("Enable menu extra shortcuts (Option-Shift-1 to 0)", isOn: $store.data.menuExtras.enabled)
                Button("Speak All Menu Extras Now") { AppController.shared.menuExtras.speakAll() }
                Text("Items are numbered from left to right across the menu bar, hidden items excluded. Press a shortcut once to hear the item, twice to open it.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Double Press") {
                Slider(value: $store.data.general.doublePressInterval, in: 0.2...0.8, step: 0.05) {
                    Text("Time allowed between presses")
                } minimumValueLabel: { Text("Fast") } maximumValueLabel: { Text("Slow") }
                .accessibilityValue("\(Int(store.data.general.doublePressInterval * 1000)) milliseconds")
                Text("CPU, memory and menu extra shortcuts wait this long for a second press. Pressing twice speaks the top processes or opens the menu extra.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("System Information") {
                Stepper(value: $store.data.systemInfo.clipboardReadLimit, in: 100...20_000, step: 100) {
                    Text("Summarise clipboard text longer than \(store.data.systemInfo.clipboardReadLimit) characters")
                }
                Toggle("Only report volumes shown in Finder", isOn: $store.data.systemInfo.browsableVolumesOnly)
                Stepper(value: $store.data.systemInfo.topProcessCount, in: 1...20) {
                    Text("Processes named by a double press: \(store.data.systemInfo.topProcessCount)")
                }
                Toggle("Include the top GPU processes in the CPU double press", isOn: $store.data.systemInfo.includeGPUProcesses)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Shortcuts

struct ShortcutsSettingsView: View {
    @Bindable var store: SettingsStore

    private var conflicts: [HotKeyAction: [HotKeyAction]] {
        var byCombo: [KeyCombo: [HotKeyAction]] = [:]
        for action in HotKeyAction.allCases {
            if let combo = store.data.combo(for: action) { byCombo[combo, default: []].append(action) }
        }
        var result: [HotKeyAction: [HotKeyAction]] = [:]
        for (_, actions) in byCombo where actions.count > 1 {
            for action in actions { result[action] = actions.filter { $0 != action } }
        }
        return result
    }

    var body: some View {
        Form {
            Section {
                Text("Activate a shortcut field, press the new keys, then it saves automatically. Escape cancels, Delete removes the shortcut.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Reset All Shortcuts") {
                    store.data.hotkeys = [:]
                    store.data.disabledHotkeys = []
                }
            }
            ForEach(HotKeyAction.Group.allCases) { group in
                Section(group.rawValue) {
                    ForEach(group.actions) { action in
                        row(for: action)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func row(for action: HotKeyAction) -> some View {
        let binding = Binding<KeyCombo?>(
            get: { store.data.combo(for: action) },
            set: { store.data.setCombo($0, for: action) }
        )
        let clash = conflicts[action]
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(action.title)
                if let clash {
                    Text("Also used by \(clash.map(\.title).joined(separator: ", "))")
                        .font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
            ShortcutRecorder(label: action.title, combo: binding)
                .frame(width: 150, height: 24)
            Button("Reset") { store.data.resetCombo(for: action) }
                .accessibilityLabel("Reset \(action.title) to default")
                .disabled(store.data.hotkeys[action.rawValue] == nil && !store.data.disabledHotkeys.contains(action.rawValue))
        }
    }
}

// MARK: - Soundpacks

struct SoundpacksSettingsView: View {
    @Bindable var store: SettingsStore
    var library: SoundpackLibrary
    @State private var selection: String?
    @State private var showNewSheet = false
    @State private var newSheetSource: Soundpack?
    @State private var exportMode = false
    @State private var errorMessage: String?

    private var selectedPack: Soundpack? { selection.flatMap { library.pack(id: $0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Soundpacks")
                .font(.headline)
                .padding(.horizontal)
            HSplitView {
                List(library.packs, selection: $selection) { pack in
                    VStack(alignment: .leading) {
                        Text(pack.name)
                        Text("\(pack.eventCount) sounds\(pack.isBuiltIn ? ", built-in" : "")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(pack.id)
                    .accessibilityElement(children: .combine)
                }
                .frame(minWidth: 220)
                detail
                    .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding()
            }
            HStack {
                Button("New…") { newSheetSource = nil; exportMode = false; showNewSheet = true }
                Button("Duplicate…") { newSheetSource = selectedPack; exportMode = false; showNewSheet = true }
                    .disabled(selectedPack == nil)
                Button("Export Current Scheme…") { newSheetSource = nil; exportMode = true; showNewSheet = true }
                    .help("Creates a pack from the sounds currently in use, custom files included.")
                Button("Import Folder…") { importPack() }
                Spacer()
                Button("Show in Finder") {
                    if let pack = selectedPack { NSWorkspace.shared.activateFileViewerSelecting([pack.url]) }
                }
                .disabled(selectedPack == nil)
                Button("Delete", role: .destructive) { deleteSelected() }
                    .disabled(selectedPack == nil || selectedPack?.isBuiltIn == true)
            }
            .padding([.horizontal, .bottom])
        }
        .sheet(isPresented: $showNewSheet) {
            NewSoundpackSheet(library: library, source: newSheetSource, exportScheme: exportMode) { pack in
                selection = pack.id
            }
        }
        .alert("Soundpack", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .onAppear { if selection == nil { selection = library.packs.first?.id } }
    }

    @ViewBuilder
    private var detail: some View {
        if let pack = selectedPack {
            let missing = SoundEvent.all.filter { pack.url(for: $0.id) == nil }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(pack.name).font(.title2)
                    if let author = pack.manifest.author { LabeledContent("Author", value: author) }
                    if let version = pack.manifest.version { LabeledContent("Version", value: version) }
                    if let description = pack.manifest.description { Text(description) }
                    LabeledContent("Folder", value: pack.url.path)
                    LabeledContent("Sounds", value: "\(pack.eventCount) of \(SoundEvent.all.count) events")
                    HStack {
                        Button("Use for Event Sounds") { store.data.eventSounds.packID = pack.id }
                            .disabled(store.data.eventSounds.packID == pack.id)
                        Button("Use for Key Clicks") { store.data.keyClicks.packID = pack.id }
                            .disabled(store.data.keyClicks.packID == pack.id)
                    }
                    if !missing.isEmpty {
                        DisclosureGroup("Events without a sound (\(missing.count))") {
                            ForEach(missing) { event in
                                Text("\(event.title) — \(event.id)").font(.caption)
                            }
                        }
                    }
                    Text("A soundpack is a folder of audio files named after event IDs, such as application.launched.wav or key.lower.wav, plus an optional pack.json. Drop files into the folder and they are picked up the next time the pack is used.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        } else {
            Text("Select a soundpack.").foregroundStyle(.secondary)
        }
    }

    private func importPack() {
        let panel = NSOpenPanel()
        panel.title = "Choose a soundpack folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let pack = try library.importPack(from: url)
            selection = pack.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteSelected() {
        guard let pack = selectedPack else { return }
        let alert = NSAlert()
        alert.messageText = "Move \(pack.name) to the Trash?"
        alert.informativeText = "Settings that use this pack will fall back to Classic."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try library.deletePack(pack)
            selection = library.packs.first?.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct NewSoundpackSheet: View {
    var library: SoundpackLibrary
    var source: Soundpack?
    var exportScheme: Bool
    var onCreate: (Soundpack) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var author = NSFullUserName()
    @State private var description = ""
    @State private var copyFrom: String = ""
    @State private var errorMessage: String?

    private var title: String {
        if exportScheme { return "Export Current Sound Scheme" }
        return source == nil ? "New Soundpack" : "Duplicate \(source!.name)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)
            Form {
                TextField("Name", text: $name)
                TextField("Author", text: $author)
                TextField("Description", text: $description)
                if !exportScheme {
                    Picker("Start with sounds from", selection: $copyFrom) {
                        Text("Nothing (empty pack)").tag("")
                        ForEach(library.packs) { Text($0.name).tag($0.id) }
                    }
                }
            }
            if exportScheme {
                Text("Copies every sound currently in use, including custom files, into a new pack.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") { create() }.keyboardShortcut(.defaultAction)
                    .disabled(SoundpackLibrary.sanitizedFolderName(name) == nil)
            }
        }
        .padding()
        .frame(width: 440)
        .onAppear {
            copyFrom = source?.id ?? ""
            if let source { name = "\(source.name) Copy" }
        }
    }

    private func create() {
        do {
            let pack: Soundpack
            if exportScheme {
                let scheme = AppController.shared.scheme
                var files: [String: URL] = [:]
                for event in SoundEvent.all { if let url = scheme.url(for: event) { files[event.id] = url } }
                pack = try library.createPack(named: name, author: author, description: description, files: files)
            } else {
                pack = try library.createPack(named: name, author: author, description: description,
                                              copying: library.pack(id: copyFrom))
            }
            onCreate(pack)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Voices

enum SpeechVoices {
    struct Voice: Identifiable {
        let identifier: String
        let title: String
        var id: String { identifier }
    }

    static func available() -> [Voice] {
        AVSpeechVoiceList.voices()
    }
}
