import AppKit
import Foundation

/// What a sound does in one app, compared with the app-wide setting.
enum AppSoundMode: String, Codable, CaseIterable, Identifiable {
    case same, off, quieter
    var id: String { rawValue }
    var title: String {
        switch self {
        case .same: return "Same as everywhere"
        case .off: return "Off"
        case .quieter: return "Quieter"
        }
    }
}

/// Progress bars in one app: as everywhere else, or silent.
enum AppProgressMode: String, Codable, CaseIterable, Identifiable {
    case same, off
    var id: String { rawValue }
    var title: String {
        switch self {
        case .same: return "Same as everywhere"
        case .off: return "Off"
        }
    }
}

/// Sound changes for one app. They apply while that app is in front
/// (for progress bars: to bars that belong to that app).
/// A new rule changes nothing until the user picks something.
struct AppSoundRule: Codable, Identifiable, Equatable {
    var bundleID: String
    /// Name saved when the app was added, used if the app can no longer be found.
    var name: String
    var keyClicks: AppSoundMode = .same
    /// Percent of the normal key click volume when `keyClicks` is `.quieter`.
    var keyClickPercent = 50
    var focusSounds: AppSoundMode = .same
    /// Percent of the normal focus sound volume when `focusSounds` is `.quieter`.
    var focusPercent = 50
    var progress: AppProgressMode = .same

    var id: String { bundleID }

    static let percentRange = 5...95
    static let percentStep = 5

    init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bundleID = try c.decode(String.self, forKey: .bundleID)
        name = c.value(.name, default: bundleID)
        keyClicks = c.value(.keyClicks, default: .same)
        keyClickPercent = c.value(.keyClickPercent, default: 50)
        focusSounds = c.value(.focusSounds, default: .same)
        focusPercent = c.value(.focusPercent, default: 50)
        progress = c.value(.progress, default: .same)
    }

    /// Multiplier for key click volume: nil means silent.
    var keyClickScale: Double? { Self.scale(keyClicks, keyClickPercent) }
    /// Multiplier for focus sound volume: nil means silent.
    var focusScale: Double? { Self.scale(focusSounds, focusPercent) }

    private static func scale(_ mode: AppSoundMode, _ percent: Int) -> Double? {
        switch mode {
        case .same: return 1
        case .off: return nil
        case .quieter: return Double(min(max(percent, percentRange.lowerBound), percentRange.upperBound)) / 100
        }
    }

    /// The app's current name, falling back to the saved one.
    var displayName: String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return name }
        let shown = FileManager.default.displayName(atPath: url.path)
        return shown.hasSuffix(".app") ? String(shown.dropLast(4)) : shown
    }

    /// One line for the list and for VoiceOver, e.g. "REAPER: key clicks off, focus sounds 50 percent".
    var summary: String {
        var parts: [String] = []
        switch keyClicks {
        case .same: break
        case .off: parts.append("key clicks off")
        case .quieter: parts.append("key clicks \(keyClickPercent) percent")
        }
        switch focusSounds {
        case .same: break
        case .off: parts.append("focus sounds off")
        case .quieter: parts.append("focus sounds \(focusPercent) percent")
        }
        if progress == .off { parts.append("progress bars off") }
        return "\(displayName): " + (parts.isEmpty ? "same as everywhere" : parts.joined(separator: ", "))
    }
}

extension SettingsData {
    func appRule(for bundleID: String?) -> AppSoundRule? {
        guard let bundleID else { return nil }
        return appSoundRules.first { $0.bundleID == bundleID }
    }
}
