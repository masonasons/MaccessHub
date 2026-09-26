import AppKit

/// Every global shortcut the app offers, with its default binding.
enum HotKeyAction: String, CaseIterable, Codable, Identifiable {
    // Audio devices
    case previousOutputDevice, nextOutputDevice, previousInputDevice, nextInputDevice
    case toggleInputMute, listOutputDevices, listInputDevices
    // System information
    case cpuUsage, memoryUsage, diskUsage, osVersion, uptime, battery, audioDevices, clipboard
    // Focus & app information
    case appInfo, positionInfo
    // Menu extras: item 1–9, and 0 for the tenth
    case menuExtra1, menuExtra2, menuExtra3, menuExtra4, menuExtra5
    case menuExtra6, menuExtra7, menuExtra8, menuExtra9, menuExtra10
    // App control
    case toggleEventSounds, toggleKeyClicks, openSettings

    var id: String { rawValue }

    enum Group: String, CaseIterable, Identifiable {
        case audio = "Audio Devices"
        case systemInfo = "System Information"
        case focus = "Application & Focus"
        case menuExtras = "Menu Extras"
        case app = "MaccessHub"
        var id: String { rawValue }
        var actions: [HotKeyAction] { HotKeyAction.allCases.filter { $0.group == self } }
    }

    var group: Group {
        switch self {
        case .previousOutputDevice, .nextOutputDevice, .previousInputDevice, .nextInputDevice,
             .toggleInputMute, .listOutputDevices, .listInputDevices:
            return .audio
        case .cpuUsage, .memoryUsage, .diskUsage, .osVersion, .uptime, .battery, .audioDevices, .clipboard:
            return .systemInfo
        case .appInfo, .positionInfo:
            return .focus
        case .menuExtra1, .menuExtra2, .menuExtra3, .menuExtra4, .menuExtra5,
             .menuExtra6, .menuExtra7, .menuExtra8, .menuExtra9, .menuExtra10:
            return .menuExtras
        case .toggleEventSounds, .toggleKeyClicks, .openSettings:
            return .app
        }
    }

    var title: String {
        switch self {
        case .previousOutputDevice: return "Previous output device"
        case .nextOutputDevice: return "Next output device"
        case .previousInputDevice: return "Previous input device"
        case .nextInputDevice: return "Next input device"
        case .toggleInputMute: return "Mute or unmute microphone"
        case .listOutputDevices: return "Speak output devices"
        case .listInputDevices: return "Speak input devices"
        case .cpuUsage: return "Speak CPU usage"
        case .memoryUsage: return "Speak memory usage"
        case .diskUsage: return "Speak disk usage"
        case .osVersion: return "Speak macOS version"
        case .uptime: return "Speak uptime"
        case .battery: return "Speak battery status"
        case .audioDevices: return "Speak current audio devices"
        case .clipboard: return "Speak clipboard"
        case .appInfo: return "Speak frontmost application info"
        case .positionInfo: return "Speak position in list or text"
        case .menuExtra1: return "Menu extra 1"
        case .menuExtra2: return "Menu extra 2"
        case .menuExtra3: return "Menu extra 3"
        case .menuExtra4: return "Menu extra 4"
        case .menuExtra5: return "Menu extra 5"
        case .menuExtra6: return "Menu extra 6"
        case .menuExtra7: return "Menu extra 7"
        case .menuExtra8: return "Menu extra 8"
        case .menuExtra9: return "Menu extra 9"
        case .menuExtra10: return "Menu extra 10"
        case .toggleEventSounds: return "Toggle event sounds"
        case .toggleKeyClicks: return "Toggle key clicks"
        case .openSettings: return "Open MaccessHub settings"
        }
    }

    /// Bindings carried over from the spoons. Nil means unbound by default.
    var defaultCombo: KeyCombo? {
        let cs: NSEvent.ModifierFlags = [.control, .shift]
        let ccs: NSEvent.ModifierFlags = [.control, .command, .shift]
        let os: NSEvent.ModifierFlags = [.option, .shift]
        switch self {
        case .previousOutputDevice: return KeyCombo("[", cs)
        case .nextOutputDevice: return KeyCombo("]", cs)
        case .previousInputDevice: return KeyCombo("[", ccs)
        case .nextInputDevice: return KeyCombo("]", ccs)
        case .toggleInputMute: return KeyCombo("m", cs)
        case .listOutputDevices: return KeyCombo("l", cs)
        case .listInputDevices: return KeyCombo("l", ccs)
        case .cpuUsage: return KeyCombo("1", cs)
        case .memoryUsage: return KeyCombo("2", cs)
        case .diskUsage: return KeyCombo("3", cs)
        case .osVersion: return KeyCombo("4", cs)
        case .uptime: return KeyCombo("5", cs)
        case .battery: return KeyCombo("6", cs)
        case .audioDevices: return KeyCombo("7", cs)
        case .clipboard: return KeyCombo("8", cs)
        case .appInfo: return KeyCombo("v", cs)
        case .positionInfo: return KeyCombo("p", cs)
        case .menuExtra1: return KeyCombo("1", os)
        case .menuExtra2: return KeyCombo("2", os)
        case .menuExtra3: return KeyCombo("3", os)
        case .menuExtra4: return KeyCombo("4", os)
        case .menuExtra5: return KeyCombo("5", os)
        case .menuExtra6: return KeyCombo("6", os)
        case .menuExtra7: return KeyCombo("7", os)
        case .menuExtra8: return KeyCombo("8", os)
        case .menuExtra9: return KeyCombo("9", os)
        case .menuExtra10: return KeyCombo("0", os)
        case .toggleEventSounds, .toggleKeyClicks, .openSettings: return nil
        }
    }

    /// 1-based index for the menu extra actions.
    var menuExtraIndex: Int? {
        switch self {
        case .menuExtra1: return 1
        case .menuExtra2: return 2
        case .menuExtra3: return 3
        case .menuExtra4: return 4
        case .menuExtra5: return 5
        case .menuExtra6: return 6
        case .menuExtra7: return 7
        case .menuExtra8: return 8
        case .menuExtra9: return 9
        case .menuExtra10: return 10
        default: return nil
        }
    }
}
