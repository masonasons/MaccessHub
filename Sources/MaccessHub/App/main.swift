import AppKit

// `MaccessHub.app/Contents/MacOS/MaccessHub --report` prints every spoken
// report to standard output instead of speaking it. Handy for checking what
// the shortcuts would say without VoiceOver, and for bug reports.
if CommandLine.arguments.contains("--report") {
    Diagnostics.printReports()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
