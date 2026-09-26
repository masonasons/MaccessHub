import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = StatusItemController()
        let controller = AppController.shared
        controller.start()

        if !controller.settings.data.general.hasSeenWelcome || !AccessibilityPermission.isTrusted {
            // First run, or permission lost: show settings so the user can grant access.
            AccessibilityPermission.request()
            SettingsWindowController.shared.show()
            controller.settings.data.general.hasSeenWelcome = true
        }
    }

    /// Reopening the app (e.g. double-clicking it in Finder) shows settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppController.shared.settings.save()
    }
}
