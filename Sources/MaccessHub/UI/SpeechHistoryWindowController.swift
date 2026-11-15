import AppKit
import SwiftUI

/// The Speech History window, hosted like the settings window.
@MainActor
final class SpeechHistoryWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SpeechHistoryWindowController()

    /// True while the user is reading the window, when capture is paused so
    /// VoiceOver reading the list does not add to the history it shows.
    static var isReading: Bool {
        NSApp.isActive && shared.window?.isKeyWindow == true
    }

    private init() {
        let hosting = NSHostingController(rootView: SpeechHistoryView(history: AppController.shared.speechHistory))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Speech History"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 560, height: 480))
        window.minSize = NSSize(width: 400, height: 300)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .speechHistoryWindowShown, object: nil)
    }

    func windowWillClose(_ notification: Notification) {
        // A menu bar app has nowhere to send focus; hiding hands it back to the
        // app the user came from.
        let others = NSApp.windows.contains { $0 !== window && $0.isVisible && $0.styleMask.contains(.titled) }
        if !others { NSApp.hide(nil) }
    }
}

extension Notification.Name {
    static let speechHistoryWindowShown = Notification.Name("SpeechHistoryWindowShown")
}

struct SpeechHistoryView: View {
    var history: SpeechHistoryFeature
    @State private var selection: SpeechHistoryFeature.Entry.ID?
    @FocusState private var focus: Field?

    private enum Field { case list, close }

    private var newestFirst: [SpeechHistoryFeature.Entry] { history.history.reversed() }
    private var selectedEntry: SpeechHistoryFeature.Entry? {
        history.history.first { $0.id == selection }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if history.history.isEmpty {
                Text("No speech captured yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(newestFirst, selection: $selection) { entry in
                    // Truncated on screen only; VoiceOver reads the full text.
                    Text(entry.text).lineLimit(3).tag(entry.id)
                }
                .accessibilityLabel("Announcements, newest first")
                .focused($focus, equals: .list)
                .onChange(of: selection) { history.select(selection) }
                .onCopyCommand { selectedEntry.map { [NSItemProvider(object: $0.text as NSString)] } ?? [] }
            }
            HStack {
                Button("Copy Selected") { copy(selectedEntry?.text, confirmation: "Copied") }
                    .disabled(selectedEntry == nil)
                Button("Copy All") { copy(history.allText, confirmation: "All speech history copied") }
                    .disabled(history.history.isEmpty)
                Button("Clear", role: .destructive) { clear() }
                    .disabled(history.history.isEmpty)
                Spacer()
                Button("Close") { NSApp.keyWindow?.performClose(nil) }
                    .keyboardShortcut(.cancelAction)
                    .focused($focus, equals: .close)
            }
        }
        .padding()
        .onAppear(perform: focusNewest)
        .onReceive(NotificationCenter.default.publisher(for: .speechHistoryWindowShown)) { _ in focusNewest() }
    }

    private func focusNewest() {
        selection = history.history.last?.id
        focus = history.history.isEmpty ? .close : .list
    }

    private func copy(_ text: String?, confirmation: String) {
        guard let text else { return }
        SpeechHistoryFeature.copyToPasteboard(text)
        AccessibilityNotification.Announcement(confirmation).post()
    }

    private func clear() {
        history.clearSilently()
        selection = nil
        // The list and the Clear button just disappeared; keep focus somewhere real.
        focus = .close
        AccessibilityNotification.Announcement("Speech history cleared").post()
    }
}
