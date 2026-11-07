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
            FocusSoundsSettingsView(store: store, library: library)
                .tabItem { Label("Focus Sounds", systemImage: "scope") }
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
                Text("Through VoiceOver, messages use your VoiceOver voice and can be interrupted like any other VoiceOver speech. The system voice settings are only used when VoiceOver isn't. The first time, macOS asks you to let MaccessHub control VoiceOver.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Permissions") {
                LabeledContent("Accessibility") {
                    HStack {
                        Text(accessibilityTrusted ? "Granted" : "Not granted")
                            .foregroundStyle(accessibilityTrusted ? .green : .red)
                        if !accessibilityTrusted {
                            Button("Request Access") {
                                AccessibilityPermission.request()
                                AccessibilityPermission.openSystemSettings()
                            }
                            .accessibilityHint("Asks macOS for Accessibility access and opens the settings page where you turn it on.")
                        }
                    }
                }
                Text("Accessibility access is needed for key clicks, focus sounds, position info, menu extras, and window and menu sounds. If key clicks stay silent after you allow it, also turn on MaccessHub in Input Monitoring. Automation is what lets MaccessHub speak through VoiceOver.")
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
                .accessibilityLabel("Choose a sound file for \(event.title)")
            if store.data.soundOverrides[event.id] != nil {
                Button("Use Pack Sound") { store.data.soundOverrides[event.id] = nil }
                    .accessibilityLabel("Go back to the pack's sound for \(event.title)")
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
                Toggle("Use the Classic sound when this pack has none", isOn: $store.data.eventSounds.fillMissingFromClassic)
                HStack {
                    Button("Turn All On") { setAll(true) }
                        .accessibilityLabel("Turn all event sounds on")
                    Button("Turn All Off") { setAll(false) }
                        .accessibilityLabel("Turn all event sounds off")
                    Button("Reset to Defaults") { store.data.eventSounds.eventStates = [:] }
                        .accessibilityHint("Puts back which events play when MaccessHub is first installed. Your soundpack and chosen sound files stay.")
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
                Toggle("Use the Classic sound when this pack has none", isOn: $store.data.keyClicks.fillMissingFromClassic)
            }
            Section("When to click") {
                Picker("Play clicks", selection: $store.data.keyClicks.scope) {
                    ForEach(KeyClickScope.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Keep clicking while a key is held down and repeats", isOn: $store.data.keyClicks.playOnRepeat)
                Toggle("No clicks while Command is held", isOn: $store.data.keyClicks.ignoreWithCommand)
                Toggle("No clicks while Control is held", isOn: $store.data.keyClicks.ignoreWithControl)
                Toggle("No clicks while Option is held", isOn: $store.data.keyClicks.ignoreWithOption)
            }
            Section("Sound for each kind of key") {
                ForEach(SoundEvent.events(in: .keys)) { event in
                    SoundEventRow(event: event, store: store, library: library)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Focus Sounds

struct FocusSoundsSettingsView: View {
    @Bindable var store: SettingsStore
    var library: SoundpackLibrary

    var body: some View {
        Form {
            Section {
                Toggle("Play a sound when focus lands on a control", isOn: $store.data.focusSounds.enabled)
                SoundpackPicker(title: "Soundpack", packID: $store.data.focusSounds.packID, library: library)
                Slider(value: $store.data.focusSounds.volume, in: 0...1) { Text("Volume") }
                    .accessibilityValue("\(Int(store.data.focusSounds.volume * 100)) percent")
                Toggle("Use the Classic sound when this pack has none", isOn: $store.data.focusSounds.fillMissingFromClassic)
                Text("Each kind of control, such as a button, checkbox or link, has its own sound. If you've used NVDA, it's like the Unspoken add-on.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Where sounds come from") {
                Toggle("Play sounds from where the control is on screen (3D audio)", isOn: $store.data.focusSounds.spatial)
                Picker("Room echo", selection: $store.data.focusSounds.reverb) {
                    ForEach(SoundEngine.Reverb.allCases) { Text($0.title).tag($0) }
                }
                .disabled(!store.data.focusSounds.spatial)
                Slider(value: $store.data.focusSounds.reverbAmount, in: 0...1) {
                    Text("Echo amount")
                } minimumValueLabel: { Text("Less") } maximumValueLabel: { Text("More") }
                .accessibilityValue("\(Int(store.data.focusSounds.reverbAmount * 100)) percent")
                .disabled(!store.data.focusSounds.spatial || store.data.focusSounds.reverb == .none)
                Button("Play Test: Left, Center, Right") { AppController.shared.previewSpatialPositions() }
                    .disabled(!store.data.focusSounds.spatial)
                Text("A control on the left of the screen sounds on your left, and so on across all your displays. Controls near the top sound a little higher up than those near the bottom. You need headphones to hear this.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Play focus sounds for") {
                Toggle("Keyboard focus changes", isOn: $store.data.focusSounds.keyboardFocus)
                Toggle("Menu items", isOn: $store.data.focusSounds.menuItems)
                Toggle("Selected rows in lists, tables and outlines", isOn: $store.data.focusSounds.rows)
                Toggle("The VoiceOver cursor (experimental, can slow VoiceOver down)", isOn: $store.data.focusSounds.followVoiceOverCursor)
                Text("Plays a sound for whatever the VoiceOver cursor is on, even items that never get keyboard focus. To do this, MaccessHub asks VoiceOver where its cursor is a few times a second, which can make VoiceOver noticeably sluggish. That's why it's off by default.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Progress bars") {
                Picker("Report progress bars by", selection: $store.data.progress.output) {
                    ForEach(ProgressOutput.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Also report bars in the app's other windows", isOn: $store.data.progress.backgroundWindows)
                    .disabled(store.data.progress.output == .off)
                Toggle("Also report bars in apps in the background", isOn: $store.data.progress.backgroundApps)
                    .disabled(store.data.progress.output == .off)
                Stepper(value: $store.data.progress.speakEvery, in: 1...50) {
                    Text("Speak every \(store.data.progress.speakEvery) percent")
                }
                .disabled(store.data.progress.output == .off || store.data.progress.output == .beep)
                Stepper(value: $store.data.progress.beepEvery, in: 1...25) {
                    Text("Beep every \(store.data.progress.beepEvery) percent")
                }
                .disabled(store.data.progress.output == .off || store.data.progress.output == .speak)
                Stepper(value: $store.data.progress.beepMinHz, in: 55...880, step: 5) {
                    Text("Starting beep pitch, at 0 percent: \(store.data.progress.beepMinHz) hertz")
                }
                .disabled(store.data.progress.output == .off || store.data.progress.output == .speak)
                Slider(value: $store.data.progress.beepVolume, in: 0...1) { Text("Beep volume") }
                    .accessibilityValue("\(Int(store.data.progress.beepVolume * 100)) percent")
                    .disabled(store.data.progress.output == .off || store.data.progress.output == .speak)
                Button("Test Beeps") { AppController.shared.previewProgressBeeps() }
                    .disabled(store.data.progress.output == .off || store.data.progress.output == .speak)
                Text("These work like NVDA's progress beeps: a short beep that rises in pitch as the bar fills, an octave every 25 percent. The defaults match NVDA. With 3D audio on, beeps come from where the bar is on screen.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Sound for each kind of control") {
                ForEach(SoundEvent.events(in: .focus)) { event in
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
                Picker("When you mute or unmute the microphone", selection: $store.data.audioDevices.muteFeedback) {
                    ForEach(MuteFeedback.allCases) { Text($0.title).tag($0) }
                }
                Text("You can pick the mute sounds in the Event Sounds tab, under Audio Devices. If there's no sound, the mute shortcut speaks instead.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Menu Extras") {
                Toggle("Turn on menu extra shortcuts (Option-Shift-1 through 0)", isOn: $store.data.menuExtras.enabled)
                Button("Speak All Menu Extras Now") { AppController.shared.menuExtras.speakAll() }
                Text("Menu extras are the status icons on the right side of the menu bar, like Wi-Fi and Battery. They're numbered from left to right, skipping hidden ones. Press a shortcut once to hear an item, twice to open it.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Double Press") {
                Slider(value: $store.data.general.doublePressInterval, in: 0.2...0.8, step: 0.05) {
                    Text("Time allowed between presses")
                } minimumValueLabel: { Text("Short") } maximumValueLabel: { Text("Long") }
                .accessibilityValue("\(Int(store.data.general.doublePressInterval * 1000)) milliseconds")
                Text("Some shortcuts do something extra when pressed twice, like naming the top processes or opening a menu extra. They wait this long for the second press.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("System Information") {
                Stepper(value: $store.data.systemInfo.clipboardReadLimit, in: 100...20_000, step: 100) {
                    Text("Summarize clipboard text longer than \(store.data.systemInfo.clipboardReadLimit) characters")
                }
                Toggle("Disk usage: only include disks shown in Finder", isOn: $store.data.systemInfo.browsableVolumesOnly)
                Stepper(value: $store.data.systemInfo.topProcessCount, in: 1...20) {
                    Text("Top processes to name on a double press: \(store.data.systemInfo.topProcessCount)")
                }
                Toggle("Include top GPU processes when you double press CPU", isOn: $store.data.systemInfo.includeGPUProcesses)
                LabeledContent("Wi-Fi network name") {
                    HStack {
                        Text(AppController.shared.network.locationAuthorized ? "Available" : "Needs Location access")
                        if !AppController.shared.network.locationAuthorized {
                            Button("Allow Location Access") {
                                AppController.shared.network.requestLocationIfNeeded()
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!)
                            }
                        }
                    }
                }
                Text("macOS only reveals the Wi-Fi network name to apps with Location access. The network shortcut still reports connection type, signal, link speed, IP address and transfer speed without it.")
                    .font(.callout).foregroundStyle(.secondary)
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
                Text("To change a shortcut, press its button, then press the new keys. It saves right away. Escape cancels, and Delete removes the shortcut.")
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
                Button("Save Current Sounds as Pack…") { newSheetSource = nil; exportMode = true; showNewSheet = true }
                    .help("Makes a new pack from the sounds you're using now, including any sound files you chose yourself.")
                Button("Import Soundpack Folder…") { importPack() }
                Spacer()
                Button("Show in Finder") {
                    if let pack = selectedPack { NSWorkspace.shared.activateFileViewerSelecting([pack.url]) }
                }
                .disabled(selectedPack == nil)
                Button("Delete", role: .destructive) { deleteSelected() }
                    .accessibilityLabel("Delete soundpack")
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
                                Text("\(event.title), file name \(event.id)").font(.caption)
                            }
                        }
                    }
                    Text("A soundpack is a folder of audio files, each named after the event it plays for, such as application.launched.wav or key.lower.wav. An optional pack.json holds the name and author. Add files to the folder and they're used the next time the pack loads.")
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
        if exportScheme { return "Save Current Sounds as a Pack" }
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
                Text("Copies every sound you're using now, including sound files you chose yourself, into a new pack.")
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
