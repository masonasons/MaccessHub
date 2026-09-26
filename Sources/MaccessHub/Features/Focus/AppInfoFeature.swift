import AppKit
import Foundation

/// The AppInfo spoon: name, version and location of the frontmost application.
final class AppInfoFeature {
    let speaker: Speaker

    init(speaker: Speaker) { self.speaker = speaker }

    func speakFrontmostApp() {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            speaker.speak("No frontmost application.")
            return
        }
        speaker.speak(Self.describe(app))
    }

    static func describe(_ app: NSRunningApplication) -> String {
        let name = app.localizedName ?? "Unknown application"
        var parts = [name]
        if let url = app.bundleURL, let bundle = Bundle(url: url) {
            let short = bundle.infoDictionary?["CFBundleShortVersionString"] as? String
            let build = bundle.infoDictionary?["CFBundleVersion"] as? String
            switch (short, build) {
            case let (s?, b?) where s != b: parts.append("version \(s) (build \(b))")
            case let (s?, _): parts.append("version \(s)")
            case let (nil, b?): parts.append("build \(b)")
            default: break
            }
        }
        if let id = app.bundleIdentifier { parts.append("bundle identifier \(id)") }
        if let path = app.bundleURL?.path ?? app.executableURL?.path {
            parts.append("running from \(path)")
        }
        return parts.joined(separator: ", ") + "."
    }
}
