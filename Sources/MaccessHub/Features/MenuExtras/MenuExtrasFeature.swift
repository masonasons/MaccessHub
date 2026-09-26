import AppKit
import ApplicationServices
import Foundation

/// The MenuExt spoon: address menu bar extras (status items) by number.
final class MenuExtrasFeature {
    struct Extra {
        let appName: String
        let label: String
        let element: AXElement
        let x: CGFloat
    }

    enum Action { case speak, activate }

    let speaker: Speaker
    private let queue = DispatchQueue(label: "com.maccesshub.menuextras", qos: .userInitiated)

    init(speaker: Speaker) { self.speaker = speaker }

    /// Speaks or activates the `index`-th extra counted from the left (1-based).
    func handle(index: Int, action: Action) {
        guard AccessibilityPermission.isTrusted else {
            speaker.speak("MaccessHub needs the Accessibility permission to read the menu bar.")
            return
        }
        queue.async { [speaker] in
            let extras = Self.visibleExtras()
            guard index >= 1, index <= extras.count else {
                speaker.speak(extras.isEmpty ? "No menu extras found." : "Only \(extras.count) menu extras.")
                return
            }
            let extra = extras[index - 1]
            switch action {
            case .speak:
                speaker.speak(extra.label)
            case .activate:
                if !extra.element.perform(kAXPressAction) {
                    speaker.speak("Could not open \(extra.label).")
                }
            }
        }
    }

    func speakAll() {
        queue.async { [speaker] in
            let extras = Self.visibleExtras()
            guard !extras.isEmpty else { speaker.speak("No menu extras found."); return }
            let list = extras.enumerated().map { "\($0.offset + 1): \($0.element.label)" }
            speaker.speak(list.joined(separator: ". "))
        }
    }

    /// Collapses runs of whitespace and line breaks into single spaces.
    private static func cleaned(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    /// All status items sorted left to right, excluding hidden (off-screen) ones.
    static func visibleExtras() -> [Extra] {
        var extras: [Extra] = []
        let screenFrames = NSScreen.screens.map(\.frame)
        let labelAttributes = [kAXDescriptionAttribute, kAXTitleAttribute, kAXValueAttribute, kAXHelpAttribute]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy != .prohibited || app.bundleIdentifier == "com.apple.controlcenter" {
            let appElement = AXElement.application(pid: app.processIdentifier)
            guard let bar = appElement.element("AXExtrasMenuBar") else { continue }
            for item in bar.elements(kAXChildrenAttribute) {
                guard let position = item.point(kAXPositionAttribute),
                      screenFrames.contains(where: { $0.minX <= position.x && position.x < $0.maxX }) else { continue }
                var parts: [String] = []
                for attribute in labelAttributes {
                    if let value = item.string(attribute).map(cleaned), !value.isEmpty, !parts.contains(value) {
                        parts.append(value)
                    }
                }
                let label = parts.isEmpty ? (app.localizedName ?? "Unknown") : parts.joined(separator: ", ")
                extras.append(Extra(appName: app.localizedName ?? "", label: label, element: item, x: position.x))
            }
        }
        return extras.sorted { $0.x < $1.x }
    }
}
