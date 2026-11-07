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

enum ProgressOutput: String, Codable, CaseIterable, Identifiable {
    case off, beep, speak, both
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: return "Off"
        case .beep: return "Beep"
        case .speak: return "Speak"
        case .both: return "Beep and speak"
        }
    }
}

/// Where progress beeps come from.
enum BeepPlacement: String, Codable, CaseIterable, Identifiable {
    case screen, fixed, leftToRight, rightToLeft
    var id: String { rawValue }
    var title: String {
        switch self {
        case .screen: return "Where the bar is on screen"
        case .fixed: return "Fixed, set with Beep pan"
        case .leftToRight: return "Move left to right as it fills"
        case .rightToLeft: return "Move right to left as it fills"
        }
    }
}

/// NVDA-style progress bar reporting.
struct ProgressSettings: Codable {
    var output: ProgressOutput = .beep
    /// Also report bars in windows of the active app other than the focused one.
    var backgroundWindows = false
    /// Also report bars in apps that are not frontmost.
    var backgroundApps = false
    /// Speak every N percent (NVDA speaks every 10).
    var speakEvery = 10
    /// Beep every N percent (NVDA beeps every 1).
    var beepEvery = 1
    /// Pitch at 0 percent; NVDA's default is 110 Hz.
    var beepMinHz = 110
    /// 0.5 matches NVDA's default beep level.
    var beepVolume = 0.5
    /// Left/right placement of beeps, -100 (left) to 100 (right). Ignored when
    /// beeps are placed with HRTF at the bar's position.
    var beepPan = 0
    /// Where beeps come from. Unset means what earlier versions did: the bar's
    /// place on screen when focus sounds use 3D placement, otherwise the pan.
    var beepPlacement: BeepPlacement?
    /// Classic is NVDA's beep; Pleasant uses the settings below.
    var beepStyle: ProgressBeepStyle = .classic
    var beepWaveform: BeepWaveform = .sine
    var beepEnvelope: BeepEnvelope = .cosine
    /// Pleasant beep length, 40 to 100 ms.
    var beepLengthMs = 80
    /// Pleasant pitch at 0 percent, 55 to 600 Hz (the add-on offers 110 to 300).
    var beepLowHz = 110
    /// Pleasant pitch at 100 percent, 600 to 4000 Hz (the add-on offers 1200 to 1800).
    /// Wider so people who hear high or low pitches poorly can fit the sweep to their hearing.
    var beepHighHz = 1720

    static let beepPanRange = -100...100
    static let beepLengthRange = 40...100
    static let beepLowRange = 55...600
    static let beepHighRange = 600...4000

    /// The beep for a percentage, in whichever style is chosen.
    func beepTone(percent: Int) -> SoundEngine.Tone {
        switch beepStyle {
        case .classic:
            // NVDA: beepMinHZ * 2 ** (percentage / 25), 40 ms.
            return .classic(frequency: Double(beepMinHz) * pow(2, Double(percent) / 25), duration: 0.04)
        case .pleasant:
            let low = Double(beepLowHz.clamped(to: Self.beepLowRange))
            let high = Double(beepHighHz.clamped(to: Self.beepHighRange))
            return SoundEngine.Tone(style: .pleasant, waveform: beepWaveform, envelope: beepEnvelope,
                                    frequency: ToneSynth.frequency(percent: Double(percent), low: low, high: high),
                                    duration: Double(beepLengthMs.clamped(to: Self.beepLengthRange)) / 1000)
        }
    }

    /// -1...1 for the mixer.
    var beepPanAmount: Float { Float(beepPan.clamped(to: Self.beepPanRange)) / 100 }

    func placement(spatialFocus: Bool) -> BeepPlacement {
        beepPlacement ?? (spatialFocus ? .screen : .fixed)
    }

    /// Left/right position for a beep, -1...1. Moving placements sweep from
    /// one side to the other as the bar fills.
    func pan(percent: Int, placement: BeepPlacement) -> Float {
        let sweep = Float(percent.clamped(to: 0...100)) / 50 - 1
        switch placement {
        case .leftToRight: return sweep
        case .rightToLeft: return -sweep
        case .fixed, .screen: return beepPanAmount
        }
    }

    /// How VoiceOver reads the pan setting.
    static func panDescription(_ pan: Int) -> String {
        if pan == 0 { return "Centre" }
        return "\(abs(pan)) percent \(pan < 0 ? "left" : "right")"
    }

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        output = c.value(.output, default: .beep)
        backgroundWindows = c.value(.backgroundWindows, default: false)
        backgroundApps = c.value(.backgroundApps, default: false)
        speakEvery = c.value(.speakEvery, default: 10)
        beepEvery = c.value(.beepEvery, default: 1)
        beepMinHz = c.value(.beepMinHz, default: 110)
        beepVolume = c.value(.beepVolume, default: 0.5)
        beepPan = c.value(.beepPan, default: 0)
        beepPlacement = try? c.decodeIfPresent(BeepPlacement.self, forKey: .beepPlacement)
        beepStyle = c.value(.beepStyle, default: .classic)
        beepWaveform = c.value(.beepWaveform, default: .sine)
        beepEnvelope = c.value(.beepEnvelope, default: .cosine)
        beepLengthMs = c.value(.beepLengthMs, default: 80)
        beepLowHz = c.value(.beepLowHz, default: 110)
        beepHighHz = c.value(.beepHighHz, default: 1720)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}

struct FocusSoundSettings: Codable {
    var enabled = true
    var volume = 0.8
    var keyboardFocus = true
    var menuItems = true
    var rows = true
    /// Poll VoiceOver's cursor position and sound the item under it.
    /// Off by default: the polling noticeably slows VoiceOver.
    var followVoiceOverCursor = false
    /// Render each sound from the control's on-screen position (HRTF).
    var spatial = true
    var reverb: SoundEngine.Reverb = .smallRoom
    /// 0...1, how much of each sound goes to the reverb; 0.5 is the preset's own level.
    var reverbAmount = 0.5
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
        followVoiceOverCursor = c.value(.followVoiceOverCursor, default: false)
        spatial = c.value(.spatial, default: true)
        reverb = c.value(.reverb, default: .smallRoom)
        reverbAmount = c.value(.reverbAmount, default: 0.5)
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
    var progress = ProgressSettings()
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
        progress = c.value(.progress, default: ProgressSettings())
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
