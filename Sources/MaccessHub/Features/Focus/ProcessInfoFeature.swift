import AppKit
import Darwin
import Foundation

/// Spoken facts about the frontmost application's process.
final class ProcessInfoFeature {
    let speaker: Speaker

    init(speaker: Speaker) { self.speaker = speaker }

    /// Single press: the essentials.
    func speakSummary() {
        guard let app = NSWorkspace.shared.frontmostApplication else { speaker.speak("No frontmost application."); return }
        let pid = app.processIdentifier
        let name = app.localizedName ?? "Unknown"
        Self.cpuPercent(pid: pid) { [speaker] cpu in
            var parts = ["\(name), process \(pid)"]
            if let cpu { parts.append(String(format: "CPU %.0f percent", cpu)) }
            if let memory = Self.footprint(pid: pid) { parts.append("memory \(SystemStats.bytesToHuman(memory))") }
            if let since = Self.launchDate(pid: pid) {
                parts.append("running \(SystemStats.durationDescription(seconds: Int(Date().timeIntervalSince(since))))")
            }
            speaker.speak(parts.joined(separator: ", ") + ".")
        }
    }

    /// Double press: everything else worth knowing.
    func speakDetails() {
        guard let app = NSWorkspace.shared.frontmostApplication else { speaker.speak("No frontmost application."); return }
        let pid = app.processIdentifier
        var parts = ["\(app.localizedName ?? "Unknown"), process \(pid)"]
        if let id = app.bundleIdentifier { parts.append("bundle \(id)") }
        if let url = app.bundleURL, let bundle = Bundle(url: url) {
            let short = bundle.infoDictionary?["CFBundleShortVersionString"] as? String
            let build = bundle.infoDictionary?["CFBundleVersion"] as? String
            if let short { parts.append("version \(short)" + (build.map { $0 != short ? " build \($0)" : "" } ?? "")) }
        }
        parts.append(Self.architecture(of: app))
        if let path = app.bundleURL?.path ?? app.executableURL?.path { parts.append("at \(path)") }
        if let parent = Self.parentName(pid: pid) { parts.append("launched by \(parent)") }
        if let threads = Self.threadCount(pid: pid) { parts.append(threads == 1 ? "1 thread" : "\(threads) threads") }
        if let cpuTime = Self.totalCPUTime(pid: pid) {
            parts.append("\(SystemStats.durationDescription(seconds: Int(cpuTime))) of CPU time")
        }
        if let since = Self.launchDate(pid: pid) {
            parts.append("launched \(since.formatted(date: .abbreviated, time: .shortened))")
        }
        let windows = AXElement.application(pid: pid).count(kAXWindowsAttribute) ?? 0
        parts.append(windows == 1 ? "1 window" : "\(windows) windows")
        if app.isHidden { parts.append("hidden") }
        speaker.speak(parts.joined(separator: ", ") + ".")
    }

    // MARK: Measurements

    private static func rusage(pid: pid_t) -> rusage_info_current? {
        var info = rusage_info_current()
        let status = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0) }
        }
        return status == 0 ? info : nil
    }

    private static var timebase: Double = {
        var info = mach_timebase_info(); mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()

    static func footprint(pid: pid_t) -> UInt64? { rusage(pid: pid)?.ri_phys_footprint }

    /// Total user+system CPU seconds the process has used so far.
    static func totalCPUTime(pid: pid_t) -> Double? {
        guard let r = rusage(pid: pid) else { return nil }
        return Double(r.ri_user_time + r.ri_system_time) * timebase / 1e9
    }

    /// Percent of one core over half a second, on the main thread when done.
    static func cpuPercent(pid: pid_t, completion: @escaping (Double?) -> Void) {
        guard let first = totalCPUTime(pid: pid) else { completion(nil); return }
        let start = Date()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            let second = totalCPUTime(pid: pid)
            let elapsed = Date().timeIntervalSince(start)
            let percent = second.map { ($0 - first) / elapsed * 100 }
            DispatchQueue.main.async { completion(percent) }
        }
    }

    static func threadCount(pid: pid_t) -> Int? {
        var task = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, size) == size ? Int(task.pti_threadnum) : nil
    }

    static func launchDate(pid: pid_t) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1e6)
    }

    static func parentName(pid: pid_t) -> String? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let parent = pid_t(info.pbi_ppid)
        if parent <= 1 { return parent == 1 ? "launchd" : nil }
        if let app = NSRunningApplication(processIdentifier: parent), let name = app.localizedName { return name }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(parent, &buffer, UInt32(buffer.count)) > 0 else { return "process \(parent)" }
        return (String(cString: buffer) as NSString).lastPathComponent
    }

    static func architecture(of app: NSRunningApplication) -> String {
        switch app.executableArchitecture {
        case NSBundleExecutableArchitectureARM64: return "Apple silicon native"
        case NSBundleExecutableArchitectureX86_64: return "Intel, running under Rosetta"
        case NSBundleExecutableArchitectureI386: return "32-bit Intel"
        default: return "unknown architecture"
        }
    }
}
