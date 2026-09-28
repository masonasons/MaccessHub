import AppKit

// `MaccessHub.app/Contents/MacOS/MaccessHub --report` prints every spoken
// report to standard output instead of speaking it. Handy for checking what
// the shortcuts would say without VoiceOver, and for bug reports.
if CommandLine.arguments.contains("--report") {
    Diagnostics.printReports()
    exit(0)
}
// `--vo-cursor`: print the VoiceOver cursor bounds a few times (tracker diagnostics).
if CommandLine.arguments.contains("--vo-cursor") {
    print("Accessibility: \(AccessibilityPermission.isTrusted), VoiceOver running: \(Speaker.isVoiceOverRunning)")
    for _ in 0..<5 {
        switch VoiceOverCursorTracker.cursorBounds() {
        case .success(let rect): print("cursor: \(rect)")
        case .failure(let error): print("error: \(error.localizedDescription)")
        }
        Thread.sleep(forTimeInterval: 0.3)
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
