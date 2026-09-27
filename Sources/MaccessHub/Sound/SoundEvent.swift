import Foundation

/// A category of sounds in a soundpack. Every event belongs to exactly one group.
enum SoundGroup: String, CaseIterable, Identifiable {
    case application, system, power, storage, usb, bluetooth, network, window, ui, media, audio, keys

    var id: String { rawValue }

    var title: String {
        switch self {
        case .application: return "Applications"
        case .system: return "System"
        case .power: return "Power & Battery"
        case .storage: return "Disks & Volumes"
        case .usb: return "USB"
        case .bluetooth: return "Bluetooth"
        case .network: return "Network"
        case .window: return "Windows"
        case .ui: return "Menus & Lists"
        case .media: return "Music"
        case .audio: return "Audio Devices"
        case .keys: return "Key Clicks"
        }
    }

    /// Groups that are driven by the event-sounds feature (everything but key clicks).
    static var eventGroups: [SoundGroup] { allCases.filter { $0 != .keys } }
}

/// One thing that can make a sound. The `id` doubles as the file name inside a
/// soundpack (`application.launched.wav`), so packs are plain folders of files.
struct SoundEvent: Identifiable, Hashable {
    let id: String
    let title: String
    let group: SoundGroup
    /// Whether the event plays when the user has never touched its toggle.
    let defaultEnabled: Bool
    /// Other event IDs whose sound is used when a pack has no file for this one.
    let fallbacks: [String]
    /// Extra explanation shown in settings.
    let note: String?

    init(_ id: String, _ title: String, _ group: SoundGroup, defaultEnabled: Bool = true,
         fallbacks: [String] = [], note: String? = nil) {
        self.id = id
        self.title = title
        self.group = group
        self.defaultEnabled = defaultEnabled
        self.fallbacks = fallbacks
        self.note = note
    }

    var isKeyClick: Bool { group == .keys }

    static let all: [SoundEvent] = [
        // Applications
        SoundEvent("application.launching", "Application starting", .application),
        SoundEvent("application.launched", "Application launched", .application),
        SoundEvent("application.terminated", "Application quit", .application),
        SoundEvent("application.activated", "Application came to front", .application, defaultEnabled: false,
                   note: "Plays every time you switch apps."),

        // System
        SoundEvent("system.login", "MaccessHub started", .system),
        SoundEvent("system.logout", "Log out or shut down", .system),
        SoundEvent("system.willSleep", "Going to sleep", .system),
        SoundEvent("system.didWake", "Woke from sleep", .system),
        SoundEvent("system.screenLocked", "Screen locked", .system, defaultEnabled: false),
        SoundEvent("system.screenUnlocked", "Screen unlocked", .system, defaultEnabled: false),
        SoundEvent("system.spaceChanged", "Desktop space changed", .system),

        // Power
        SoundEvent("power.acPower", "Switched to AC power", .power),
        SoundEvent("power.batteryPower", "Switched to battery power", .power),
        SoundEvent("power.upsPower", "Switched to UPS power", .power),
        SoundEvent("power.charging", "Battery started charging", .power),
        SoundEvent("power.charged", "Battery fully charged", .power),
        SoundEvent("power.battery20Minutes", "20 minutes of battery left", .power),
        SoundEvent("power.battery10Minutes", "10 minutes of battery left", .power),
        SoundEvent("power.battery5Minutes", "5 minutes of battery left", .power),

        // Storage
        SoundEvent("storage.mounted", "Volume mounted", .storage),
        SoundEvent("storage.willUnmount", "Volume about to unmount", .storage),
        SoundEvent("storage.unmounted", "Volume unmounted", .storage),
        SoundEvent("storage.renamed", "Volume renamed", .storage),

        // USB
        SoundEvent("usb.connected", "USB device connected", .usb),
        SoundEvent("usb.disconnected", "USB device disconnected", .usb),

        // Bluetooth
        SoundEvent("bluetooth.connected", "Bluetooth device connected", .bluetooth),
        SoundEvent("bluetooth.disconnected", "Bluetooth device disconnected", .bluetooth),

        // Network
        SoundEvent("network.wifiConnected", "Wi-Fi connected", .network),
        SoundEvent("network.wifiDisconnected", "Wi-Fi disconnected", .network),
        SoundEvent("network.ethernetConnected", "Ethernet connected", .network),
        SoundEvent("network.ethernetDisconnected", "Ethernet disconnected", .network),
        SoundEvent("network.ipv4Acquired", "Internet connection available", .network),
        SoundEvent("network.ipv4Released", "Internet connection lost", .network),

        // Windows (accessibility observer on the frontmost app)
        SoundEvent("window.created", "Window opened", .window, defaultEnabled: false),
        SoundEvent("window.focused", "Window focus changed", .window, defaultEnabled: false),
        SoundEvent("window.minimized", "Window minimized", .window, defaultEnabled: false),
        SoundEvent("window.restored", "Window restored from Dock", .window, defaultEnabled: false),
        SoundEvent("window.dialogOpened", "Dialog or sheet opened", .window, defaultEnabled: false),

        // Menus & lists
        SoundEvent("ui.menuOpened", "Menu opened", .ui, defaultEnabled: false),
        SoundEvent("ui.menuClosed", "Menu closed", .ui, defaultEnabled: false),
        SoundEvent("ui.menuItemSelected", "Menu item chosen", .ui, defaultEnabled: false),
        SoundEvent("ui.rowExpanded", "Row expanded", .ui, defaultEnabled: false),
        SoundEvent("ui.rowCollapsed", "Row collapsed", .ui, defaultEnabled: false),
        SoundEvent("ui.selectedRowChanged", "Selected row changed", .ui, defaultEnabled: false,
                   note: "Fires on every arrow key in tables and lists."),

        // Music
        SoundEvent("media.playing", "Music started playing", .media),
        SoundEvent("media.paused", "Music paused", .media),
        SoundEvent("media.stopped", "Music stopped", .media),

        // Audio devices (played by the mute shortcut when mute feedback is set to sound)
        SoundEvent("audio.inputMuted", "Microphone muted", .audio,
                   note: "Used by the mute shortcut when its feedback is set to a sound. Classic has no file; choose one."),
        SoundEvent("audio.inputUnmuted", "Microphone unmuted", .audio,
                   note: "Used by the mute shortcut when its feedback is set to a sound. Classic has no file; choose one."),

        // Key clicks. Fallbacks let a six-sound pack (like Classic) cover every category.
        SoundEvent("key.lower", "Lowercase letter", .keys),
        SoundEvent("key.upper", "Uppercase letter", .keys, fallbacks: ["key.lower"]),
        SoundEvent("key.digit", "Digit", .keys, fallbacks: ["key.other"]),
        SoundEvent("key.punctuation", "Punctuation or symbol", .keys, fallbacks: ["key.other"]),
        SoundEvent("key.space", "Space", .keys),
        SoundEvent("key.enter", "Return", .keys),
        SoundEvent("key.tab", "Tab", .keys, fallbacks: ["key.other"]),
        SoundEvent("key.delete", "Delete", .keys),
        SoundEvent("key.navigation", "Arrow and paging keys", .keys, defaultEnabled: false,
                   note: "Silent unless the pack provides key.navigation."),
        SoundEvent("key.function", "Escape and function keys", .keys, defaultEnabled: false,
                   note: "Silent unless the pack provides key.function."),
        SoundEvent("key.other", "Other keys", .keys),
    ]

    static let byID: [String: SoundEvent] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    static func events(in group: SoundGroup) -> [SoundEvent] { all.filter { $0.group == group } }
}
