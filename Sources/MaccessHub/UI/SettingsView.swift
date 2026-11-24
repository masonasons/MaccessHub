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
            AppSoundsSettingsView(store: store)
                .tabItem { Label("Apps", systemImage: "app.badge") }
            DiskSoundsSettingsView(store: store)
                .tabItem { Label("Disk Sounds", systemImage: "internaldrive") }
            SoundProcessingSettingsView(store: store)
                .tabItem { Label("Sound Processing", systemImage: "slider.horizontal.3") }
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

// MARK: - Announcements

/// Confirms a button whose effect is elsewhere on the page, so VoiceOver users
/// hear that it worked instead of the button being read again.
func announce(_ message: String) {
    NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                         userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
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
    // Sparkle's settings aren't observable, so mirror them here and re-read
    // after every change; otherwise the toggles never redraw.
    @State private var automaticallyChecks = Updater.shared.automaticallyChecks
    @State private var automaticallyDownloads = Updater.shared.automaticallyDownloads
    @State private var lastCheck = Updater.shared.lastCheck

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch MaccessHub at login", isOn: $store.data.general.launchAtLogin)
            }
            Section("Audio") {
                Picker("Release the audio device after", selection: $store.data.general.audioIdleTimeout) {
                    Text("10 seconds of quiet").tag(10.0)
                    Text("30 seconds of quiet").tag(30.0)
                    Text("1 minute of quiet").tag(60.0)
                    Text("5 minutes of quiet").tag(300.0)
                    Text("Never (keeps the Mac awake)").tag(0.0)
                }
                Text("While MaccessHub holds the audio device, the Mac can't go to sleep on its own. Releasing it sooner saves battery. The first sound after a release can start a moment late.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Speech") {
                Picker("Speak messages with", selection: $store.data.general.speechOutput) {
                    ForEach(SpeechOutput.allCases) { Text($0.title).tag($0) }
                }
                .help(store.data.general.speechOutput.help)
                Text(store.data.general.speechOutput.help)
                    .font(.callout).foregroundStyle(.secondary)
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
                    get: { automaticallyChecks },
                    set: { Updater.shared.automaticallyChecks = $0; readUpdaterSettings() }))
                Toggle("Download and install updates automatically", isOn: Binding(
                    get: { automaticallyDownloads },
                    set: { Updater.shared.automaticallyDownloads = $0; readUpdaterSettings() }))
                LabeledContent("Installed version", value: Self.versionString)
                HStack {
                    Button("Check for Updates Now") { Updater.shared.checkForUpdates() }
                    if let last = lastCheck {
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
            readUpdaterSettings()
        }
        .onAppear {
            accessibilityTrusted = AccessibilityPermission.isTrusted
            readUpdaterSettings()
        }
    }

    private func readUpdaterSettings() {
        automaticallyChecks = Updater.shared.automaticallyChecks
        automaticallyDownloads = Updater.shared.automaticallyDownloads
        lastCheck = Updater.shared.lastCheck
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
        if let source {
            parts.append(source.description)
            if source.variantCount > 1 { parts.append("\(source.variantCount) variants, one picked at random") }
        } else { parts.append("No sound") }
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
                Toggle("Fill gaps with this pack's similar sounds", isOn: $store.data.eventSounds.fillFromRelated)
                    .help("When this pack has no sound for something, use its own sound for something close, before the Classic sound. Off by default.")
                Toggle("Use the Classic sound when this pack has none", isOn: $store.data.eventSounds.fillMissingFromClassic)
                HStack {
                    Button("Turn All On") {
                        setAll(true)
                        announce("All event sounds on")
                    }
                    .accessibilityLabel("Turn all event sounds on")
                    Button("Turn All Off") {
                        setAll(false)
                        announce("All event sounds off")
                    }
                    .accessibilityLabel("Turn all event sounds off")
                    Button("Reset to Defaults") {
                        store.data.eventSounds.eventStates = [:]
                        announce("Event sounds reset to defaults")
                    }
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

    /// Only the groups shown on this page. Control (focus) and key sounds keep
    /// their own states and their own tabs, so they are left alone here.
    private func setAll(_ on: Bool) {
        let ids = Set(SoundGroup.eventGroups.flatMap { SoundEvent.events(in: $0) }.map(\.id))
        // Drop entries older versions wrote here for control sounds; nothing reads them.
        var states = store.data.eventSounds.eventStates.filter { ids.contains($0.key) }
        for id in ids { states[id] = on }
        store.data.eventSounds.eventStates = states
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
                Toggle("Fill gaps with this pack's similar sounds", isOn: $store.data.keyClicks.fillFromRelated)
                    .help("When this pack has no sound for something, use its own sound for something close, before the Classic sound. Off by default.")
                Toggle("Use the Classic sound when this pack has none", isOn: $store.data.keyClicks.fillMissingFromClassic)
                Button("Preview Typing") { AppController.shared.previewTyping() }
                    .help("Plays the pack as if you typed a short phrase. Press again to stop.")
            }
            Section("When to click") {
                Picker("Play clicks", selection: $store.data.keyClicks.scope) {
                    ForEach(KeyClickScope.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Keep clicking while a key is held down and repeats", isOn: $store.data.keyClicks.playOnRepeat)
                Toggle("No clicks while Command is held", isOn: $store.data.keyClicks.ignoreWithCommand)
                Toggle("No clicks while Control is held", isOn: $store.data.keyClicks.ignoreWithControl)
                Toggle("No clicks while Option is held", isOn: $store.data.keyClicks.ignoreWithOption)
                Toggle("Same click for every key in password fields", isOn: $store.data.keyClicks.maskSecureFields)
                Text("In a password field, letters, numbers, symbols and Space all make the same click, so nobody nearby can tell what you typed. Return, Delete, Tab and the arrow keys keep their own sounds.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Sound for each kind of key") {
                HStack {
                    Button("Turn All On") {
                        for event in SoundEvent.events(in: .keys) { store.data.keyClicks.eventStates[event.id] = true }
                        announce("All key sounds on")
                    }
                    .accessibilityLabel("Turn all key sounds on")
                    Button("Turn All Off") {
                        for event in SoundEvent.events(in: .keys) { store.data.keyClicks.eventStates[event.id] = false }
                        announce("All key sounds off")
                    }
                    .accessibilityLabel("Turn all key sounds off")
                    Button("Reset to Defaults") {
                        store.data.keyClicks.eventStates = [:]
                        announce("Key sounds reset to defaults")
                    }
                }
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
    @State private var simulating = false

    var body: some View {
        Form {
            Section {
                Toggle("Play a sound when focus lands on a control", isOn: $store.data.focusSounds.enabled)
                SoundpackPicker(title: "Soundpack", packID: $store.data.focusSounds.packID, library: library)
                Slider(value: $store.data.focusSounds.volume, in: 0...1) { Text("Volume") }
                    .accessibilityValue("\(Int(store.data.focusSounds.volume * 100)) percent")
                Toggle("Fill gaps with this pack's similar sounds", isOn: $store.data.focusSounds.fillFromRelated)
                    .help("When this pack has no sound for something, use its own sound for something close, before the Classic sound. Off by default.")
                Toggle("Use the Classic sound when this pack has none", isOn: $store.data.focusSounds.fillMissingFromClassic)
                Button("Preview Focus Sounds") { AppController.shared.previewFocusSounds() }
                    .help("Plays each control's sound in turn. Press again to stop.")
                Text("Each kind of control, such as a button, checkbox or link, has its own sound. If you've used NVDA, it's like the Unspoken add-on.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Where sounds come from") {
                Toggle("Play sounds from where the control is on screen (3D audio)", isOn: $store.data.focusSounds.spatial)
                Picker("Room reverb", selection: $store.data.focusSounds.reverb) {
                    ForEach(SoundEngine.Reverb.allCases) { Text($0.title).tag($0) }
                }
                .disabled(!store.data.focusSounds.spatial)
                Slider(value: $store.data.focusSounds.reverbAmount, in: 0...1) {
                    Text("Reverb amount")
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
                ForEach(store.data.progress.excludedApps, id: \.self) { bundleID in
                    HStack {
                        Text("Never report bars in \(Self.appName(bundleID))")
                        Spacer()
                        Button("Remove") { store.data.progress.excludedApps.removeAll { $0 == bundleID } }
                            .accessibilityLabel("Report bars in \(Self.appName(bundleID)) again")
                    }
                }
                Button("Leave Out an App…") { chooseExcludedApps() }
                    .disabled(store.data.progress.output == .off)
                Stepper(value: $store.data.progress.speakEvery, in: 1...50) {
                    Text("Speak every \(store.data.progress.speakEvery) percent")
                }
                .disabled(store.data.progress.output == .off || store.data.progress.output == .beep)
                Stepper(value: $store.data.progress.beepEvery, in: 1...25) {
                    Text("Beep every \(store.data.progress.beepEvery) percent")
                }
                .disabled(store.data.progress.output == .off || store.data.progress.output == .speak)
                let beepsOff = store.data.progress.output == .off || store.data.progress.output == .speak
                Picker("Beep sound", selection: $store.data.progress.beepStyle) {
                    ForEach(ProgressBeepStyle.allCases) { Text($0.title).tag($0) }
                }
                .disabled(beepsOff)
                if store.data.progress.beepStyle == .classic {
                    Stepper(value: $store.data.progress.beepMinHz, in: 55...880, step: 5) {
                        Text("Starting beep pitch, at 0 percent: \(store.data.progress.beepMinHz) hertz")
                    }
                    .accessibilityLabel("Beep pitch at 0 percent")
                    .accessibilityValue("\(store.data.progress.beepMinHz) hertz")
                    .disabled(beepsOff)
                } else {
                    Picker("Wave shape", selection: $store.data.progress.beepWaveform) {
                        ForEach(BeepWaveform.allCases) { Text($0.title).tag($0) }
                    }
                    .disabled(beepsOff)
                    Picker("Fade", selection: $store.data.progress.beepEnvelope) {
                        ForEach(BeepEnvelope.allCases) { Text($0.title).tag($0) }
                    }
                    .disabled(beepsOff)
                    Text("Wave shape sets the tone of the beep. Fade sets how each beep swells in and dies away. If high beeps are hard to hear, lower the pitch at 100 percent.")
                        .font(.callout).foregroundStyle(.secondary)
                    Stepper(value: $store.data.progress.beepLengthMs, in: ProgressSettings.beepLengthRange, step: 5) {
                        Text("Beep length: \(store.data.progress.beepLengthMs) ms")
                    }
                    .accessibilityLabel("Beep length")
                    .accessibilityValue("\(store.data.progress.beepLengthMs) milliseconds")
                    .disabled(beepsOff)
                    Stepper(value: $store.data.progress.beepLowHz, in: ProgressSettings.beepLowRange, step: 5) {
                        Text("Pitch at 0 percent: \(store.data.progress.beepLowHz) Hz")
                    }
                    .accessibilityLabel("Pitch at 0 percent")
                    .accessibilityValue("\(store.data.progress.beepLowHz) hertz")
                    .disabled(beepsOff)
                    Stepper(value: $store.data.progress.beepHighHz, in: ProgressSettings.beepHighRange, step: 10) {
                        Text("Pitch at 100 percent: \(store.data.progress.beepHighHz) Hz")
                    }
                    .accessibilityLabel("Pitch at 100 percent")
                    .accessibilityValue("\(store.data.progress.beepHighHz) hertz")
                    .disabled(beepsOff)
                }
                Slider(value: $store.data.progress.beepVolume, in: 0...1) { Text("Beep volume") }
                    .accessibilityValue("\(Int(store.data.progress.beepVolume * 100)) percent")
                    .disabled(beepsOff)
                let placement = store.data.progress.placement(spatialFocus: store.data.focusSounds.spatial)
                Picker("Beep position", selection: Binding(get: { placement },
                                                           set: { store.data.progress.beepPlacement = $0 })) {
                    ForEach(BeepPlacement.allCases) { Text($0.title).tag($0) }
                }
                .disabled(beepsOff)
                if placement == .fixed {
                    Slider(value: Binding(get: { Double(store.data.progress.beepPan) },
                                          set: { store.data.progress.beepPan = Int($0.rounded()) }),
                           in: -100...100, step: 10) {
                        Text("Beep pan")
                    } minimumValueLabel: { Text("Left") } maximumValueLabel: { Text("Right") }
                    .accessibilityValue(ProgressSettings.panDescription(store.data.progress.beepPan))
                    .disabled(beepsOff)
                }
                Text(placement == .screen
                     ? "Beeps come from the bar's place on screen, in 3D. Best with headphones. The previews play from the middle of the screen."
                     : "Left and right need headphones or two speakers. With 3D audio on for focus sounds, these beeps are placed in 3D too and get the same room reverb.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Play Sample") { AppController.shared.playProgressBeepSample() }
                        .accessibilityHint("Plays beeps for 0, 25, 50, 75 and 100 percent with these settings")
                    Button("Test Beeps") { AppController.shared.previewProgressBeeps() }
                        .accessibilityHint("Plays a beep every 10 percent from 0 to 100")
                    Button(simulating ? "Stop" : "Hear in Context") {
                        if simulating {
                            AppController.shared.stopProgressSimulation()
                        } else {
                            simulating = true
                            AppController.shared.startProgressSimulation { simulating = false }
                        }
                    }
                    .accessibilityLabel(simulating ? "Stop progress bar simulation" : "Hear in context")
                    .accessibilityHint(simulating ? "" : "Simulates a progress bar filling from 0 to 100 percent over about four seconds, beeping as a real one would")
                }
                .disabled(beepsOff)
                Text(store.data.progress.beepStyle == .classic
                     ? "NVDA's progress beeps, sample for sample: 40 ms, pitch doubling every 25 percent, and speech at each interval. Defaults match NVDA's."
                     : "Pleasant beeps fade in and out and rise from the low pitch to the high pitch as the bar fills. Inspired by the Pleasant Progress Bar add-on for NVDA.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Sound for each kind of control") {
                HStack {
                    Button("Turn All On") {
                        for event in SoundEvent.events(in: .focus) { store.data.focusSounds.eventStates[event.id] = true }
                        announce("All control sounds on")
                    }
                    .accessibilityLabel("Turn all control sounds on")
                    Button("Turn All Off") {
                        for event in SoundEvent.events(in: .focus) { store.data.focusSounds.eventStates[event.id] = false }
                        announce("All control sounds off")
                    }
                    .accessibilityLabel("Turn all control sounds off")
                    Button("Reset to Defaults") {
                        store.data.focusSounds.eventStates = [:]
                        announce("Control sounds reset to defaults")
                    }
                }
                ForEach(SoundEvent.events(in: .focus)) { event in
                    SoundEventRow(event: event, store: store, library: library)
                }
            }
        }
        .formStyle(.grouped)
        // A preview never outlives the window it was started from.
        .onDisappear { AppController.shared.stopProgressSimulation() }
    }

    /// The app's name for a bundle ID, or the ID itself if the app isn't installed.
    static func appName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    private func chooseExcludedApps() {
        let panel = NSOpenPanel()
        panel.title = "Choose apps whose progress bars should never be reported"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let id = Bundle(url: url)?.bundleIdentifier,
                  !store.data.progress.excludedApps.contains(id) else { continue }
            store.data.progress.excludedApps.append(id)
        }
    }
}

// MARK: - Sound Processing

/// Volume, EQ and reverb per sound group. One page: pick a group, then adjust it.
struct SoundProcessingSettingsView: View {
    @Bindable var store: SettingsStore
    @State private var bus: SoundBus = .events

    private var previewer: BusPreviewer { AppController.shared.busPreviewer }

    private var settings: Binding<AudioBusSettings> {
        Binding(get: { store.data.soundProcessing[bus] }, set: { store.data.soundProcessing[bus] = $0 })
    }

    private var current: AudioBusSettings { store.data.soundProcessing[bus] }

    static func decibels(_ value: Double) -> String {
        let n = Int(value.rounded())
        if n == 0 { return "0 decibels, flat" }
        let unit = abs(n) == 1 ? "decibel" : "decibels"
        return "\(n > 0 ? "plus" : "minus") \(abs(n)) \(unit)"
    }

    private static func shortDecibels(_ value: Double) -> String {
        let n = Int(value.rounded())
        return n > 0 ? "+\(n) dB" : "\(n) dB"
    }

    var body: some View {
        Form {
            Section {
                Picker("Sound group", selection: $bus) {
                    ForEach(SoundBus.allCases) { Text($0.title).tag($0) }
                }
                Text("Each group of sounds has its own volume, tone and reverb, so you can add reverb to some sounds and keep others dry, or make one group brighter and easier to hear. Changes apply right away. Nothing plays until you press Play Sample or Hear in Context, and moving a control while one is playing changes what you hear.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Volume") {
                Slider(value: settings.volume, in: 0...1, step: 0.05) { Text("Volume") }
                    minimumValueLabel: { Text("0%") } maximumValueLabel: { Text("100%") }
                    .accessibilityLabel("Volume for \(bus.title.lowercased())")
                    .accessibilityValue("\(Int((current.volume * 100).rounded())) percent")
                Text("This works together with the volume on the group's own tab: at 50 percent here, everything in the group plays at half its usual level.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Tone") {
                eqSlider("Bass", value: settings.eqLow, note: "around 200 Hz and below")
                eqSlider("Middle", value: settings.eqMid, note: "around 1,500 Hz")
                eqSlider("Treble", value: settings.eqHigh, note: "around 5,000 Hz and above")
                HStack {
                    ForEach(AudioBusSettings.EQPreset.allCases) { preset in
                        Button(preset.title) { store.data.soundProcessing[bus].apply(preset) }
                            .accessibilityLabel("\(preset.title) tone")
                            .accessibilityHint(preset.help)
                            .help(preset.help)
                    }
                }
                Text("Boosts are limited so a sound never distorts.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Reverb") {
                Picker("Reverb", selection: settings.reverb) {
                    ForEach(BusReverb.allCases) { Text($0.title).tag($0) }
                }
                Slider(value: settings.reverbMix, in: 0...1, step: 0.05) {
                    Text("Reverb amount")
                } minimumValueLabel: { Text("Dry") } maximumValueLabel: { Text("Wet") }
                .accessibilityValue("\(Int((current.reverbMix * 100).rounded())) percent")
                .disabled(current.reverb == .none)
                Text("More reverb puts the sound further away: at 100 percent you hear only the room.")
                    .font(.callout).foregroundStyle(.secondary)
                if bus == .focus || bus == .progress {
                    Text("With HRTF on, the Room setting on the Focus tab also applies to these sounds. This reverb is added on top of it.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Section("Try it") {
                HStack {
                    Button(previewer.isPlaying(bus, .sample) ? "Stop Sample" : "Play Sample") {
                        previewer.toggle(bus, .sample)
                    }
                    .accessibilityHint("Plays a short sample of \(bus.title.lowercased()). Press again to stop.")
                    Button(previewer.isPlaying(bus, .context) ? "Stop" : "Hear in Context") {
                        previewer.toggle(bus, .context)
                    }
                    .accessibilityLabel(previewer.isPlaying(bus, .context) ? "Stop" : "Hear \(bus.title.lowercased()) in context")
                    .accessibilityHint(contextHint)
                    Spacer()
                    Button("Reset This Group") { store.data.soundProcessing[bus] = AudioBusSettings() }
                        .accessibilityLabel("Reset \(bus.title.lowercased())")
                        .accessibilityHint("Full volume, flat tone, no reverb.")
                        .disabled(current == AudioBusSettings())
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: bus) { previewer.stop() }
        .onDisappear { previewer.stop() }
    }

    private var contextHint: String {
        switch bus {
        case .events: return "Plays a few seconds of event sounds: an app opening, Wi-Fi connecting, the app quitting."
        case .focus: return "Plays focus sounds as if tabbing through a dialog."
        case .keys: return "Plays key clicks as if typing a short phrase, with a correction."
        case .progress: return "Plays beeps as if a progress bar fills from 0 to 100 percent."
        case .disk: return "Plays disk clicks as if an app opens and then a file is saved, with your disks' own sounds."
        }
    }

    private func eqSlider(_ title: String, value: Binding<Double>, note: String) -> some View {
        Slider(value: value, in: AudioBusSettings.eqRange, step: 1) {
            Text("\(title): \(Self.shortDecibels(value.wrappedValue))")
        } minimumValueLabel: { Text("-12") } maximumValueLabel: { Text("+12") }
        .accessibilityLabel(title)
        .accessibilityValue(Self.decibels(value.wrappedValue))
        .accessibilityHint(note.prefix(1).uppercased() + note.dropFirst() + ".")
        .help("\(title), \(note)")
    }
}

// MARK: - Tools

struct ToolsSettingsView: View {
    @Bindable var store: SettingsStore

    /// Preset sizes, plus the stored value if it was hand-edited to something else.
    static func historySizes(including current: Int) -> [Int] {
        Array(Set([50, 100, 250, 500, 1000, 2500, 5000, current])).sorted()
    }

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
            Section("Speech History") {
                Toggle("Keep a history of VoiceOver speech", isOn: $store.data.speechHistory.enabled)
                Picker("Maximum announcements", selection: $store.data.speechHistory.maximumEntries) {
                    ForEach(Self.historySizes(including: store.data.speechHistory.maximumEntries), id: \.self) {
                        Text("\($0)").tag($0)
                    }
                }
                Toggle("Trim whitespace from the beginning", isOn: $store.data.speechHistory.trimLeadingWhitespace)
                Toggle("Trim whitespace from the end", isOn: $store.data.speechHistory.trimTrailingWhitespace)
                HStack {
                    Button("Open Speech History…") { SpeechHistoryWindowController.shared.show() }
                    Button("Clear Speech History") { AppController.shared.speechHistory.clear() }
                }
                Text("Review what VoiceOver said with Shift-F11 and Shift-F12, and copy the current announcement with F12. Recording and the history window can be given shortcuts under Shortcuts. VoiceOver cannot tell MaccessHub when the same announcement is spoken twice in a row, so repeats are stored once.")
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
    @State private var search = ""

    /// Matches the action's name or its current keys, spoken ("Control-Shift-1") or as symbols.
    private func matches(_ action: HotKeyAction) -> Bool {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        if action.title.localizedCaseInsensitiveContains(query) { return true }
        guard let combo = store.data.combo(for: action) else { return false }
        return combo.spokenString.localizedCaseInsensitiveContains(query)
            || combo.displayString.localizedCaseInsensitiveContains(query)
    }

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
                    announce("All shortcuts reset to defaults")
                }
                TextField("Search shortcuts", text: $search)
                if !search.trimmingCharacters(in: .whitespaces).isEmpty {
                    let count = HotKeyAction.allCases.filter(matches).count
                    Text(count == 1 ? "1 shortcut matches" : "\(count) shortcuts match")
                }
            }
            ForEach(HotKeyAction.Group.allCases) { group in
                let actions = group.actions.filter(matches)
                if !actions.isEmpty {
                    Section(group.rawValue) {
                        ForEach(actions) { action in
                            row(for: action)
                        }
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
    /// What the last NVDA import did, shown until dismissed.
    @State private var importResults: [NavSoundsImporter.Result] = []
    @State private var importSummary: String?

    private var selectedPack: Soundpack? { selection.flatMap { library.pack(id: $0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Soundpacks")
                .font(.headline)
                .padding(.horizontal)
            if let importSummary { importBanner(importSummary) }
            HSplitView {
                List(library.packs, selection: $selection) { pack in
                    VStack(alignment: .leading) {
                        Text(pack.name)
                        Text("\(pack.eventCount) sounds\(pack.fileCount > pack.eventCount ? " (\(pack.fileCount) files with variants)" : "")\(pack.isBuiltIn ? ", built-in" : "")")
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
                Button("Import NVDA Sounds…") { importNVDA() }
                    .help("Imports a typing or navigation pack from the NVDA add-on Navigation Sounds, as a folder or a zip file.")
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
                    if pack.fileCount > pack.eventCount {
                        let varied = SoundEvent.all.filter { pack.variantCount(for: $0.id) > 1 }
                        LabeledContent("Variants", value: varied.map { "\($0.title): \(pack.variantCount(for: $0.id))" }
                            .joined(separator: ", "))
                    }
                    HStack {
                        Button("Use for Event Sounds") { store.data.eventSounds.packID = pack.id }
                            .disabled(store.data.eventSounds.packID == pack.id)
                        Button("Use for Key Clicks") { store.data.keyClicks.packID = pack.id }
                            .disabled(store.data.keyClicks.packID == pack.id)
                        Button("Use for Focus Sounds") { store.data.focusSounds.packID = pack.id }
                            .disabled(store.data.focusSounds.packID == pack.id)
                    }
                    HStack {
                        if Self.hasSounds(pack, in: .keys) {
                            Button("Preview Typing") { AppController.shared.previewTyping(packID: pack.id) }
                                .accessibilityLabel("Preview typing with \(pack.name)")
                                .help("Plays this pack as if you typed a short phrase. Press again to stop.")
                        }
                        if Self.hasSounds(pack, in: .focus) {
                            Button("Preview Focus Sounds") { AppController.shared.previewFocusSounds(packID: pack.id) }
                                .accessibilityLabel("Preview focus sounds of \(pack.name)")
                                .help("Plays each control's sound from this pack in turn. Press again to stop.")
                        }
                    }
                    if !missing.isEmpty {
                        DisclosureGroup("Events without a sound (\(missing.count))") {
                            ForEach(missing) { event in
                                Text("\(event.title), file name \(event.id)").font(.caption)
                            }
                        }
                    }
                    Text("A soundpack is a folder of audio files, each named after the event it plays for, such as application.launched.wav or key.lower.wav. An optional pack.json holds the name and author. To have a sound vary, add key.lower.2.wav, key.lower.3.wav and so on, and one is picked at random each time. Add files to the folder and they're used the next time the pack loads.")
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

    static func hasSounds(_ pack: Soundpack, in group: SoundGroup) -> Bool {
        SoundEvent.events(in: group).contains { pack.url(for: $0.id) != nil }
    }

    private func importNVDA() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Navigation Sounds pack folder or zip file"
        panel.message = "Choose a typing or navigation pack from the NVDA add-on Navigation Sounds: a folder of wav files, a folder of packs, or a zip file."
        panel.prompt = "Import"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.zip, .folder]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let results = try library.importNavigationSoundsPacks(from: url)
            importResults = results
            let summary = Self.describe(results)
            importSummary = summary
            if let first = results.first { selection = first.name }
            AppController.shared.speaker.speak(summary)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    static func describe(_ results: [NavSoundsImporter.Result]) -> String {
        if results.count == 1, let r = results.first {
            var text = "Imported \(r.name), a \(r.kind.noun) pack with \(r.soundCount) sound\(r.soundCount == 1 ? "" : "s")."
            if !r.skipped.isEmpty {
                text += " Left out \(r.skipped.count) sound\(r.skipped.count == 1 ? "" : "s") for controls MaccessHub does not use."
            }
            if !r.unreadable.isEmpty {
                text += " \(r.unreadable.count) file\(r.unreadable.count == 1 ? " was" : "s were") not playable audio and \(r.unreadable.count == 1 ? "was" : "were") skipped."
            }
            return text
        }
        let names = results.map(\.name).joined(separator: ", ")
        return "Imported \(results.count) packs: \(names). Select one in the list to preview it."
    }

    @ViewBuilder
    private func importBanner(_ summary: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(summary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isStaticText)
            Spacer()
            if importResults.count == 1, let result = importResults.first, library.pack(id: result.name) != nil {
                if result.kind == .typing {
                    Button("Preview") { AppController.shared.previewTyping(packID: result.name) }
                        .accessibilityLabel("Preview typing with \(result.name)")
                    Button("Use for Key Clicks") { store.data.keyClicks.packID = result.name }
                        .disabled(store.data.keyClicks.packID == result.name)
                        .accessibilityLabel("Use \(result.name) for key clicks")
                } else {
                    Button("Preview") { AppController.shared.previewFocusSounds(packID: result.name) }
                        .accessibilityLabel("Preview focus sounds of \(result.name)")
                    Button("Use for Focus Sounds") { store.data.focusSounds.packID = result.name }
                        .disabled(store.data.focusSounds.packID == result.name)
                        .accessibilityLabel("Use \(result.name) for focus sounds")
                }
            }
            Button("Dismiss") { importSummary = nil; importResults = [] }
                .accessibilityLabel("Dismiss import message")
        }
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal)
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
            if importResults.contains(where: { $0.name == pack.id }) { importSummary = nil; importResults = [] }
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
                var variants: [String: [URL]] = [:]
                for event in SoundEvent.all {
                    let urls = scheme.urls(for: event)
                    if !urls.isEmpty { variants[event.id] = urls }
                }
                pack = try library.createPack(named: name, author: author, description: description, variants: variants)
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
