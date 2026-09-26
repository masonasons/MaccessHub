import ApplicationServices
import Foundation

/// The PositionInfo spoon: where the focus is inside a list, table, outline or text.
final class PositionInfoFeature {
    let speaker: Speaker

    init(speaker: Speaker) { self.speaker = speaker }

    func speakPosition() {
        guard AccessibilityPermission.isTrusted else {
            speaker.speak("MaccessHub needs the Accessibility permission to read the focused element.")
            return
        }
        guard let element = AXElement.focused else {
            speaker.speak("Nothing is focused.")
            return
        }
        speaker.speak(Self.describe(element))
    }

    static func describe(_ element: AXElement) -> String {
        let role = element.role ?? ""
        switch role {
        case kAXTableRole, kAXOutlineRole:
            return describeRows(element)
        case kAXListRole, "AXBrowser":
            return describeChildren(element)
        case kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole, "AXSearchField":
            return describeText(element)
        default:
            // Editable web content and similar: use text if a selection range is exposed.
            if element.range(kAXSelectedTextRangeAttribute) != nil, element.int(kAXNumberOfCharactersAttribute) != nil {
                return describeText(element)
            }
            // Some apps focus a row rather than its table.
            if role == kAXRowRole, let parent = element.element(kAXParentAttribute) {
                return describeRows(parent, focusedRow: element)
            }
            let spoken = role.replacingOccurrences(of: "AX", with: "").lowercased()
            return "No position information for this \(spoken.isEmpty ? "element" : spoken)."
        }
    }

    private static func percent(_ n: Int, of total: Int) -> Int {
        total > 0 ? Int((Double(n) / Double(total) * 100).rounded()) : 0
    }

    private static func describeRows(_ table: AXElement, focusedRow: AXElement? = nil) -> String {
        let total = table.count(kAXRowsAttribute) ?? table.elements(kAXRowsAttribute).count
        guard total > 0 else { return "The list is empty." }
        let selected = focusedRow ?? table.elements(kAXSelectedRowsAttribute).first
        guard let selected else { return "No row selected of \(total)." }
        var index = selected.int(kAXIndexAttribute)
        if index == nil {
            let rows = table.elements(kAXRowsAttribute)
            index = rows.firstIndex { CFEqual($0.element, selected.element) }
        }
        guard let index else { return "\(total) rows." }
        let current = index + 1
        return "\(percent(current, of: total)) percent, item \(current) of \(total)."
    }

    private static func describeChildren(_ list: AXElement) -> String {
        let children = list.elements(kAXChildrenAttribute)
        let total = children.count
        guard total > 0 else { return "The list is empty." }
        let selected = list.elements(kAXSelectedChildrenAttribute).first
            ?? children.first { $0.bool(kAXSelectedAttribute) == true }
        guard let selected, let index = children.firstIndex(where: { CFEqual($0.element, selected.element) }) else {
            return "No item selected of \(total)."
        }
        return "\(percent(index + 1, of: total)) percent, item \(index + 1) of \(total)."
    }

    private static func describeText(_ field: AXElement) -> String {
        let total = field.int(kAXNumberOfCharactersAttribute) ?? 0
        let caret = field.range(kAXSelectedTextRangeAttribute)?.location ?? 0
        var s = "\(percent(caret, of: total)) percent, character \(caret) of \(total)"
        if total > 0,
           let line = field.parameterizedInt(kAXLineForIndexParameterizedAttribute, parameter: min(caret, total)),
           let lastLine = field.parameterizedInt(kAXLineForIndexParameterizedAttribute, parameter: max(0, total - 1)) {
            s += ", line \(line + 1) of \(lastLine + 1)"
        }
        return s + "."
    }
}
