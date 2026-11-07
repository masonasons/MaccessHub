import AppKit
import SwiftUI

/// Per-app changes to key clicks, focus sounds and progress bars.
struct AppSoundsSettingsView: View {
    @Bindable var store: SettingsStore

    @State private var runningApps: [NSRunningApplication] = []
    @State private var expanded: Set<String> = []

    private static let ownBundleID = Bundle.main.bundleIdentifier

    var body: some View {
        Form {
            Section {
                Text("Give an app its own key clicks, focus sounds and progress bar reports. For example, turn key clicks off in REAPER. The change applies while that app is in front. Apps you add here start out the same as everywhere else, so nothing changes until you pick something.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Event sounds stay the same in every app, because they come from the system, not from the app in front.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Add App…") { chooseApps() }
                    Menu("Add a Running App") {
                        ForEach(addableRunningApps, id: \.processIdentifier) { app in
                            Button(app.localizedName ?? app.bundleIdentifier ?? "Unknown app") { add(app) }
                        }
                        if addableRunningApps.isEmpty {
                            Text("Every open app is already in the list")
                        }
                    }
                    .fixedSize()
                }
            }
            if store.data.appSoundRules.isEmpty {
                Section("Apps") {
                    Text("No apps yet.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Apps") {
                    ForEach($store.data.appSoundRules) { $rule in
                        AppSoundRuleRow(rule: $rule, isExpanded: expansion(for: rule.bundleID)) {
                            remove(rule.bundleID)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refreshRunningApps)
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in
            refreshRunningApps()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in
            refreshRunningApps()
        }
    }

    private var addableRunningApps: [NSRunningApplication] {
        let taken = Set(store.data.appSoundRules.map(\.bundleID))
        return runningApps.filter { app in
            guard let id = app.bundleIdentifier else { return false }
            return !taken.contains(id)
        }
    }

    private func refreshRunningApps() {
        runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.bundleIdentifier != Self.ownBundleID }
            .sorted { ($0.localizedName ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending }
    }

    private func expansion(for bundleID: String) -> Binding<Bool> {
        Binding(get: { expanded.contains(bundleID) },
                set: { if $0 { expanded.insert(bundleID) } else { expanded.remove(bundleID) } })
    }

    private func add(_ app: NSRunningApplication) {
        guard let id = app.bundleIdentifier else { return }
        add(bundleID: id, name: app.localizedName ?? id)
    }

    private func add(bundleID: String, name: String) {
        guard !store.data.appSoundRules.contains(where: { $0.bundleID == bundleID }) else {
            expanded.insert(bundleID)
            return
        }
        store.data.appSoundRules.append(AppSoundRule(bundleID: bundleID, name: name))
        store.data.appSoundRules.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        // Open the new app's settings so the next thing VoiceOver finds is its pickers.
        expanded.insert(bundleID)
    }

    private func remove(_ bundleID: String) {
        store.data.appSoundRules.removeAll { $0.bundleID == bundleID }
        expanded.remove(bundleID)
    }

    private func chooseApps() {
        let panel = NSOpenPanel()
        panel.title = "Choose apps to give their own sounds"
        panel.prompt = "Add"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let id = Bundle(url: url)?.bundleIdentifier, id != Self.ownBundleID else { continue }
            let shown = FileManager.default.displayName(atPath: url.path)
            add(bundleID: id, name: shown.hasSuffix(".app") ? String(shown.dropLast(4)) : shown)
        }
    }
}

/// One app: a summary line that opens to show its pickers.
private struct AppSoundRuleRow: View {
    @Binding var rule: AppSoundRule
    @Binding var isExpanded: Bool
    let onRemove: () -> Void

    var body: some View {
        let name = rule.displayName
        DisclosureGroup(isExpanded: $isExpanded) {
            Picker("Key clicks in \(name)", selection: $rule.keyClicks) {
                ForEach(AppSoundMode.allCases) { Text($0.title).tag($0) }
            }
            if rule.keyClicks == .quieter {
                Stepper(value: $rule.keyClickPercent, in: AppSoundRule.percentRange, step: AppSoundRule.percentStep) {
                    Text("Key click volume in \(name): \(rule.keyClickPercent) percent of normal")
                }
            }
            Picker("Focus sounds in \(name)", selection: $rule.focusSounds) {
                ForEach(AppSoundMode.allCases) { Text($0.title).tag($0) }
            }
            if rule.focusSounds == .quieter {
                Stepper(value: $rule.focusPercent, in: AppSoundRule.percentRange, step: AppSoundRule.percentStep) {
                    Text("Focus sound volume in \(name): \(rule.focusPercent) percent of normal")
                }
            }
            Picker("Progress bars in \(name)", selection: $rule.progress) {
                ForEach(AppProgressMode.allCases) { Text($0.title).tag($0) }
            }
            Text("Off means no beeps and no spoken percentages for this app's progress bars, even when it is in the background.")
                .font(.callout).foregroundStyle(.secondary)
            Button("Remove \(name)") { onRemove() }
        } label: {
            HStack {
                AppIcon(bundleID: rule.bundleID)
                Text(rule.summary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(rule.summary)
        }
    }
}

private struct AppIcon: View {
    let bundleID: String

    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
        }
    }
}
