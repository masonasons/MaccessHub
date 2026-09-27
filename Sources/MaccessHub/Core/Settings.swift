import Foundation
import Observation
import os

/// Helper so every settings struct tolerates missing keys (older files, hand edits).
extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, default defaultValue: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? defaultValue
    }
}

enum MuteFeedback: String, Codable, CaseIterable, Identifiable {
    case speech, sound, both
    var id: String { rawValue }
    var title: String {
        switch self {
        case .speech: return "Speak muted or unmuted"
        case .sound: return "Play a sound"
        case .both: return "Play a sound and speak"
        }
    }
}

enum KeyClickScope: String, Codable, CaseIterable, Identifiable {
    case textFieldsOnly, everywhere
    var id: String { rawValue }
    var title: String {
        switch self {
        case .textFieldsOnly: return "Only while typing in a text field"
        case .everywhere: return "Everywhere"
        }
    }
}

struct GeneralSettings: Codable {
    var launchAtLogin = false
    var speechOutput: SpeechOutput = .automatic
    var speechRate = 0.5
    var speechVolume = 1.0
    var speechVoice: String? = nil
    var hasSeenWelcome = false
    /// Seconds within which a second press of the same shortcut counts as a double press.
    var doublePressInterval = 0.35

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        launchAtLogin = c.value(.launchAtLogin, default: false)
        speechOutput = c.value(.speechOutput, default: .automatic)
        speechRate = c.value(.speechRate, default: 0.5)
        speechVolume = c.value(.speechVolume, default: 1.0)
        speechVoice = c.value(.speechVoice, default: nil)
        hasSeenWelcome = c.value(.hasSeenWelcome, default: false)
        doublePressInterval = c.value(.doublePressInterval, default: 0.35)
    }
}

struct EventSoundSettings: Codable {
    var enabled = true
    var packID = Soundpack.builtInClassicID
    var volume = 1.0
    /// Use the Classic pack's file when the chosen pack has none for an event.
    var fillMissingFromClassic = true
    /// Event IDs the user switched on or off. Absent → the event's default.
    var eventStates: [String: Bool] = [:]

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = c.value(.enabled, default: true)
        packID = c.value(.packID, default: Soundpack.builtInClassicID)
        volume = c.value(.volume, default: 1.0)
        fillMissingFromClassic = c.value(.fillMissingFromClassic, default: true)
        eventStates = c.value(.eventStates, default: [:])
    }

    func isEnabled(_ event: SoundEvent) -> Bool { eventStates[event.id] ?? event.defaultEnabled }
}

struct KeyClickSettings: Codable {
    var enabled = true
    var packID = Soundpack.builtInClassicID
    var volume = 0.4
    var scope: KeyClickScope = .textFieldsOnly
    var playOnRepeat = true
    var ignoreWithCommand = true
    var ignoreWithControl = false
    var ignoreWithOption = false
    var fillMissingFromClassic = true
    var eventStates: [String: Bool] = [:]

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = c.value(.enabled, default: true)
        packID = c.value(.packID, default: Soundpack.builtInClassicID)
        volume = c.value(.volume, default: 0.4)
        scope = c.value(.scope, default: .textFieldsOnly)
        playOnRepeat = c.value(.playOnRepeat, default: true)
        ignoreWithCommand = c.value(.ignoreWithCommand, default: true)
        ignoreWithControl = c.value(.ignoreWithControl, default: false)
        ignoreWithOption = c.value(.ignoreWithOption, default: false)
        fillMissingFromClassic = c.value(.fillMissingFromClassic, default: true)
        eventStates = c.value(.eventStates, default: [:])
    }

    func isEnabled(_ event: SoundEvent) -> Bool { eventStates[event.id] ?? event.defaultEnabled }
}

struct FocusSoundSettings: Codable {
    var enabled = true
    var volume = 0.8
    var keyboardFocus = true
    var menuItems = true
    var rows = true
    /// Render each sound from the control's on-screen position (HRTF).
    var spatial = true
    var reverb: SoundEngine.Reverb = .smallRoom
    var packID = Soundpack.builtInClassicID
    var fillMissingFromClassic = true
    var eventStates: [String: Bool] = [:]

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = c.value(.enabled, default: true)
        volume = c.value(.volume, default: 0.8)
        keyboardFocus = c.value(.keyboardFocus, default: true)
        menuItems = c.value(.menuItems, default: true)
        rows = c.value(.rows, default: true)
        spatial = c.value(.spatial, default: true)
        reverb = c.value(.reverb, default: .smallRoom)
        packID = c.value(.packID, default: Soundpack.builtInClassicID)
        fillMissingFromClassic = c.value(.fillMissingFromClassic, default: true)
        eventStates = c.value(.eventStates, default: [:])
    }

    func isEnabled(_ event: SoundEvent) -> Bool { eventStates[event.id] ?? event.defaultEnabled }
}

struct AudioDeviceSettings: Codable {
    /// Continue from the last device to the first instead of stopping.
    var wrapAround = true
    /// Include the device's volume when announcing a switch.
    var speakVolume = false
    /// How the microphone mute toggle confirms itself.
    var muteFeedback: MuteFeedback = .speech

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        wrapAround = c.value(.wrapAround, default: true)
        speakVolume = c.value(.speakVolume, default: false)
        muteFeedback = c.value(.muteFeedback, default: .speech)
    }
}

struct MenuExtraSettings: Codable {
    var enabled = false

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = c.value(.enabled, default: false)
    }
}

struct SystemInfoSettings: Codable {
    /// Clipboard text longer than this is summarised instead of read out.
    var clipboardReadLimit = 2048
    /// Skip hidden and non-browsable volumes in the disk report.
    var browsableVolumesOnly = true
    /// How many processes a double press of the CPU or memory shortcut names.
    var topProcessCount = 5
    /// Whether the CPU double press also names the top GPU processes.
    var includeGPUProcesses = true

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clipboardReadLimit = c.value(.clipboardReadLimit, default: 2048)
        browsableVolumesOnly = c.value(.browsableVolumesOnly, default: true)
        topProcessCount = c.value(.topProcessCount, default: 5)
        includeGPUProcesses = c.value(.includeGPUProcesses, default: true)
    }
}

struct SettingsData: Codable {
    var general = GeneralSettings()
    var eventSounds = EventSoundSettings()
    var keyClicks = KeyClickSettings()
    var focusSounds = FocusSoundSettings()
    var audioDevices = AudioDeviceSettings()
    var menuExtras = MenuExtraSettings()
    var systemInfo = SystemInfoSettings()
    /// event ID → absolute file path chosen by the user; beats any pack.
    var soundOverrides: [String: String] = [:]
    /// action raw value → combo; absent means the default binding.
    var hotkeys: [String: KeyCombo] = [:]
    var disabledHotkeys: Set<String> = []

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        general = c.value(.general, default: GeneralSettings())
        eventSounds = c.value(.eventSounds, default: EventSoundSettings())
        keyClicks = c.value(.keyClicks, default: KeyClickSettings())
        focusSounds = c.value(.focusSounds, default: FocusSoundSettings())
        audioDevices = c.value(.audioDevices, default: AudioDeviceSettings())
        menuExtras = c.value(.menuExtras, default: MenuExtraSettings())
        systemInfo = c.value(.systemInfo, default: SystemInfoSettings())
        soundOverrides = c.value(.soundOverrides, default: [:])
        hotkeys = c.value(.hotkeys, default: [:])
        disabledHotkeys = c.value(.disabledHotkeys, default: [])
    }

    // MARK: Hotkeys

    func combo(for action: HotKeyAction) -> KeyCombo? {
        if disabledHotkeys.contains(action.rawValue) { return nil }
        return hotkeys[action.rawValue] ?? action.defaultCombo
    }

    mutating func setCombo(_ combo: KeyCombo?, for action: HotKeyAction) {
        if let combo {
            disabledHotkeys.remove(action.rawValue)
            if combo == action.defaultCombo { hotkeys[action.rawValue] = nil } else { hotkeys[action.rawValue] = combo }
        } else {
            hotkeys[action.rawValue] = nil
            disabledHotkeys.insert(action.rawValue)
        }
    }

    mutating func resetCombo(for action: HotKeyAction) {
        hotkeys[action.rawValue] = nil
        disabledHotkeys.remove(action.rawValue)
    }

    /// Bindings that should actually be registered right now.
    var activeHotkeys: [HotKeyAction: KeyCombo] {
        var result: [HotKeyAction: KeyCombo] = [:]
        for action in HotKeyAction.allCases {
            if action.group == .menuExtras, !menuExtras.enabled { continue }
            if let combo = combo(for: action) { result[action] = combo }
        }
        return result
    }

    // MARK: Sound state helpers

    func isEnabled(_ event: SoundEvent) -> Bool {
        switch event.group {
        case .keys: return keyClicks.isEnabled(event)
        case .focus: return focusSounds.isEnabled(event)
        default: return eventSounds.isEnabled(event)
        }
    }

    mutating func setEnabled(_ enabled: Bool, for event: SoundEvent) {
        switch event.group {
        case .keys: keyClicks.eventStates[event.id] = enabled
        case .focus: focusSounds.eventStates[event.id] = enabled
        default: eventSounds.eventStates[event.id] = enabled
        }
    }
}

/// Owns the settings file and notifies the app when anything changes.
/// Stored as JSON at ~/Library/Application Support/MaccessHub/settings.json.
@Observable
final class SettingsStore {
    private let log = Logger(subsystem: "com.maccesshub.app", category: "settings")

    static let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MaccessHub/settings.json")
    }()

    var data: SettingsData {
        didSet { scheduleSave() }
    }

    /// Fired on the main thread after every change.
    @ObservationIgnored var onChange: ((SettingsData) -> Void)?
    @ObservationIgnored private var saveScheduled = false

    init() {
        if let raw = try? Data(contentsOf: Self.fileURL),
           let decoded = try? JSONDecoder().decode(SettingsData.self, from: raw) {
            data = decoded
        } else {
            data = SettingsData()
        }
    }

    private func scheduleSave() {
        onChange?(data)
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.saveScheduled = false
            self?.save()
        }
    }

    func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let dir = Self.fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try encoder.encode(data).write(to: Self.fileURL, options: .atomic)
        } catch {
            log.error("Could not save settings: \(error.localizedDescription)")
        }
    }
}
