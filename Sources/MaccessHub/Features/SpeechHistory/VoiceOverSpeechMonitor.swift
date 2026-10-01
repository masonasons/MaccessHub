import AppKit
import Carbon
import os

/// Polls VoiceOver's `last phrase` over Apple Events and reports each change.
///
/// VoiceOver exposes only the phrase's text — no identifier or timestamp — so
/// an announcement identical to the one before it cannot be detected.
final class VoiceOverSpeechMonitor {
    private let log = Logger(subsystem: "com.maccesshub.app", category: "speech-history")
    private let queue = DispatchQueue(label: "com.maccesshub.speech-history", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var lastPhrase: String?
    private var failureLogged = false

    /// Called on the main thread with each new phrase.
    var onPhrase: ((String) -> Void)?
    var interval: TimeInterval = 0.1

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    // Runs on `queue`. The timer does not fire again until this returns, so a
    // slow reply delays polling instead of stacking requests.
    private func poll() {
        // Addressed by PID, not bundle ID, so a poll racing VoiceOver's exit
        // cannot relaunch it.
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.VoiceOver")
            .first?.processIdentifier else {
            lastPhrase = nil
            return
        }
        guard let phrase = Self.readLastPhrase(pid: pid, log: log, failureLogged: &failureLogged),
              phrase != lastPhrase else { return }
        lastPhrase = phrase
        DispatchQueue.main.async { [weak self] in self?.onPhrase?(phrase) }
    }

    /// `get content of last phrase` sent as a raw Apple Event: unlike
    /// NSAppleScript it is safe off the main thread and takes a timeout.
    private static func readLastPhrase(pid: pid_t, log: Logger, failureLogged: inout Bool) -> String? {
        let app = NSAppleEventDescriptor.null()
        let phrase = property("lapr", of: app)
        let content = property("lptx", of: phrase)
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kAECoreSuite), eventID: AEEventID(kAEGetData),
                                           targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid),
                                           returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(content, forKeyword: keyDirectObject)
        do {
            let reply = try event.sendEvent(options: [.waitForReply], timeout: 1)
            failureLogged = false
            return reply.paramDescriptor(forKeyword: keyDirectObject)?.stringValue
        } catch {
            // Logged once per outage; a denied Automation permission fails every poll.
            if !failureLogged {
                log.error("Reading VoiceOver's last phrase failed: \(error.localizedDescription)")
                failureLogged = true
            }
            return nil
        }
    }

    private static func property(_ code: String, of container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        let fourCC = code.utf8.reduce(0) { ($0 << 8) | OSType($1) }
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: OSType(cProperty)), forKeyword: AEKeyword(keyAEDesiredClass))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: OSType(formPropertyID)), forKeyword: AEKeyword(keyAEKeyForm))
        record.setDescriptor(NSAppleEventDescriptor(typeCode: fourCC), forKeyword: AEKeyword(keyAEKeyData))
        record.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
        return record.coerce(toDescriptorType: DescType(typeObjectSpecifier)) ?? record
    }
}
