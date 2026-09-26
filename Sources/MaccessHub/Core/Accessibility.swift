import AppKit
import ApplicationServices

/// Thin wrapper over AXUIElement with typed attribute access.
struct AXElement {
    let element: AXUIElement

    init(_ element: AXUIElement) { self.element = element }

    static var systemWide: AXElement { AXElement(AXUIElementCreateSystemWide()) }

    static func application(pid: pid_t) -> AXElement { AXElement(AXUIElementCreateApplication(pid)) }

    static var focused: AXElement? { systemWide.element(kAXFocusedUIElementAttribute) }

    /// Raw attribute value, or nil if the attribute is missing or unsupported.
    func raw(_ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return status == .success ? value : nil
    }

    func string(_ attribute: String) -> String? {
        guard let value = raw(attribute) else { return nil }
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        if let u = value as? URL { return u.path }
        return nil
    }

    func int(_ attribute: String) -> Int? {
        guard let value = raw(attribute) else { return nil }
        return (value as? NSNumber)?.intValue
    }

    func bool(_ attribute: String) -> Bool? {
        guard let value = raw(attribute) else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    func element(_ attribute: String) -> AXElement? {
        guard let value = raw(attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return AXElement(value as! AXUIElement)
    }

    func elements(_ attribute: String) -> [AXElement] {
        guard let value = raw(attribute) as? [AnyObject] else { return [] }
        return value.compactMap { item in
            guard CFGetTypeID(item) == AXUIElementGetTypeID() else { return nil }
            return AXElement(item as! AXUIElement)
        }
    }

    /// Number of values in an array attribute without fetching them all.
    func count(_ attribute: String) -> Int? {
        var count: CFIndex = 0
        let status = AXUIElementGetAttributeValueCount(element, attribute as CFString, &count)
        return status == .success ? count : nil
    }

    func range(_ attribute: String) -> CFRange? {
        guard let value = raw(attribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(value as! AXValue, .cfRange, &range) ? range : nil
    }

    func point(_ attribute: String) -> CGPoint? {
        guard let value = raw(attribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    func parameterizedInt(_ attribute: String, parameter: Int) -> Int? {
        var value: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(element, attribute as CFString,
                                                                parameter as CFNumber, &value)
        guard status == .success, let value else { return nil }
        return (value as? NSNumber)?.intValue
    }

    var role: String? { string(kAXRoleAttribute) }
    var subrole: String? { string(kAXSubroleAttribute) }
    var title: String? { string(kAXTitleAttribute) }

    var pid: pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }

    @discardableResult
    func perform(_ action: String) -> Bool {
        AXUIElementPerformAction(element, action as CFString) == .success
    }
}

enum AccessibilityPermission {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt (once per app build) and returns the current state.
    @discardableResult
    static func request() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    static func openInputMonitoringSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        NSWorkspace.shared.open(url)
    }

    static func openAutomationSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
        NSWorkspace.shared.open(url)
    }
}
