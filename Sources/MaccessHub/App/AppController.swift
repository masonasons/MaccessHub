import AppKit
import Foundation
import os
import ServiceManagement

/// Central object: owns the settings, sound engine, speaker, hotkeys and every feature,
/// and re-applies configuration whenever settings change.
@MainActor
final class AppController {
    static let shared = AppController()

    let log = Logger(subsystem: "com.maccesshub.app", category: "app")
    let settings = SettingsStore()
    let library = SoundpackLibrary()
    let engine = SoundEngine()
    let speaker = Speaker()
    let hotkeys = HotKeyCenter()

    let audioSwitch: AudioSwitchFeature
    let systemInfo: SystemInfoFeature
    let appInfo: AppInfoFeature
    let positionInfo: PositionInfoFeature
    let menuExtras: MenuExtrasFeature
    let keyClicks = KeyClickMonitor()

    private let workspaceMonitor = WorkspaceMonitor()
    private let eventMonitors: [EventMonitor]
    private var monitorsRunning = false

    /// Set by the settings UI while a shortcut is being recorded.
    var isRecordingShortcut = false {
        didSet { isRecordingShortcut ? hotkeys.suspend() : hotkeys.resume() }
    }

    var scheme: SoundScheme { SoundScheme(settings: settings.data, library: library) }

    private init() {
        audioSwitch = AudioSwitchFeature(speaker: speaker)
        systemInfo = SystemInfoFeature(speaker: speaker, audio: audioSwitch)
        appInfo = AppInfoFeature(speaker: speaker)
        positionInfo = PositionInfoFeature(speaker: speaker)
        menuExtras = MenuExtrasFeature(speaker: speaker)
        eventMonitors = [workspaceMonitor, PowerMonitor(), NetworkMonitor(), USBMonitor(),
                         BluetoothMonitor(), UIEventMonitor()]

        for monitor in eventMonitors {
            monitor.onEvent = { [weak self] id in self?.handleEvent(id) }
        }
        workspaceMonitor.onWillEndSession = { [weak self] in
            // Give the logout sound a moment before the session is torn down.
            guard let self, let event = SoundEvent.byID["system.logout"],
                  settings.data.eventSounds.enabled, settings.data.isEnabled(event), scheme.url(for: event) != nil
            else { return }
            Thread.sleep(forTimeInterval: 1.5)
        }
        keyClicks.onKey = { [weak self] category in
            DispatchQueue.main.async { self?.handleKey(category) }
        }
        hotkeys.handler = { [weak self] action in self?.perform(action) }
        settings.onChange = { [weak self] _ in self?.applySettings() }
    }

    // MARK: Lifecycle

    func start() {
        applySettings()
        if settings.data.eventSounds.enabled { play("system.login", ignoreEnabledState: false) }
        log.info("MaccessHub started")
    }

    func applySettings() {
        let data = settings.data

        speaker.output = data.general.speechOutput
        speaker.rate = data.general.speechRate
        speaker.volume = data.general.speechVolume
        speaker.voiceIdentifier = data.general.speechVoice

        audioSwitch.wrapAround = data.audioDevices.wrapAround
        audioSwitch.speakVolume = data.audioDevices.speakVolume
        systemInfo.clipboardReadLimit = data.systemInfo.clipboardReadLimit
        systemInfo.browsableVolumesOnly = data.systemInfo.browsableVolumesOnly
        menuExtras.action = data.menuExtras.action

        keyClicks.scope = data.keyClicks.scope
        keyClicks.playOnRepeat = data.keyClicks.playOnRepeat
        keyClicks.ignoreWithCommand = data.keyClicks.ignoreWithCommand
        keyClicks.ignoreWithControl = data.keyClicks.ignoreWithControl
        keyClicks.ignoreWithOption = data.keyClicks.ignoreWithOption

        if data.keyClicks.enabled {
            if !keyClicks.isRunning, !keyClicks.start() {
                log.error("Key clicks enabled but the event tap could not start")
            }
        } else if keyClicks.isRunning {
            keyClicks.stop()
        }

        if data.eventSounds.enabled, !monitorsRunning {
            eventMonitors.forEach { $0.start() }
            monitorsRunning = true
        } else if !data.eventSounds.enabled, monitorsRunning {
            eventMonitors.forEach { $0.stop() }
            monitorsRunning = false
        }

        hotkeys.apply(bindings: data.activeHotkeys)
        applyLaunchAtLogin(data.general.launchAtLogin)

        // Warm the cache off the main thread so the first sound is instant.
        let urls = scheme.allURLs()
        DispatchQueue.global(qos: .utility).async { [engine] in
            urls.forEach { engine.preload($0) }
            engine.retainOnly(urls)
        }
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        let isRegistered = service.status == .enabled
        guard enabled != isRegistered else { return }
        do {
            if enabled { try service.register() } else { try service.unregister() }
        } catch {
            log.error("Launch at login change failed: \(error.localizedDescription)")
        }
    }

    // MARK: Sounds

    private func handleEvent(_ id: String) {
        guard settings.data.eventSounds.enabled else { return }
        play(id, ignoreEnabledState: false)
    }

    private func handleKey(_ category: KeyCategory) {
        let data = settings.data
        guard data.keyClicks.enabled, let event = SoundEvent.byID[category.eventID],
              data.keyClicks.isEnabled(event), let url = scheme.url(for: event) else { return }
        engine.play(url, volume: Float(data.keyClicks.volume), exclusive: true)
    }

    /// Plays the event's sound. `ignoreEnabledState` is used by the preview buttons.
    @discardableResult
    func play(_ id: String, ignoreEnabledState: Bool) -> Bool {
        guard let event = SoundEvent.byID[id] else { return false }
        let data = settings.data
        if !ignoreEnabledState, !data.isEnabled(event) { return false }
        guard let url = scheme.url(for: event) else { return false }
        let volume = event.isKeyClick ? data.keyClicks.volume : data.eventSounds.volume
        engine.play(url, volume: Float(volume), exclusive: event.isKeyClick)
        return true
    }

    func preview(_ event: SoundEvent) {
        if !play(event.id, ignoreEnabledState: true) {
            speaker.speak("No sound for \(event.title).")
        }
    }

    // MARK: Hotkeys

    func perform(_ action: HotKeyAction) {
        switch action {
        case .previousOutputDevice: audioSwitch.step(.output, by: -1)
        case .nextOutputDevice: audioSwitch.step(.output, by: 1)
        case .previousInputDevice: audioSwitch.step(.input, by: -1)
        case .nextInputDevice: audioSwitch.step(.input, by: 1)
        case .toggleInputMute: audioSwitch.toggleInputMute()
        case .listOutputDevices: audioSwitch.list(.output)
        case .listInputDevices: audioSwitch.list(.input)
        case .cpuUsage: systemInfo.speakCPU()
        case .memoryUsage: systemInfo.speakMemory()
        case .diskUsage: systemInfo.speakDisks()
        case .osVersion: systemInfo.speakOSVersion()
        case .uptime: systemInfo.speakUptime()
        case .battery: systemInfo.speakBattery()
        case .audioDevices: systemInfo.speakAudioDevices()
        case .clipboard: systemInfo.speakClipboard()
        case .appInfo: appInfo.speakFrontmostApp()
        case .positionInfo: positionInfo.speakPosition()
        case .toggleEventSounds: toggleEventSounds()
        case .toggleKeyClicks: toggleKeyClicks()
        case .openSettings: SettingsWindowController.shared.show()
        default:
            if let index = action.menuExtraIndex { menuExtras.handle(index: index) }
        }
    }

    func toggleEventSounds() {
        settings.data.eventSounds.enabled.toggle()
        speaker.speak(settings.data.eventSounds.enabled ? "Event sounds on" : "Event sounds off")
    }

    func toggleKeyClicks() {
        settings.data.keyClicks.enabled.toggle()
        speaker.speak(settings.data.keyClicks.enabled ? "Key clicks on" : "Key clicks off")
    }
}
