import AppKit
import Foundation
import os

/// Polls VoiceOver for its cursor bounds ("bounds of vo cursor" in its
/// scripting dictionary) on a background thread and reports changes.
///
/// One round trip costs 5–120 ms inside VoiceOver, so this never runs on the
/// main thread and slows its polling while the cursor is idle.
final class VoiceOverCursorTracker {
    /// Called on the main thread with the new cursor rectangle (global top-left coordinates).
    var onChange: ((CGRect) -> Void)?

    private let log = Logger(subsystem: "com.maccesshub.app", category: "vocursor")
    private var thread: Thread?
    private var running = false
    private let activeInterval: TimeInterval = 0.15
    private let idleInterval: TimeInterval = 0.4
    private let idleAfter: TimeInterval = 3

    func start() {
        guard thread == nil else { return }
        running = true
        let thread = Thread { [weak self] in self?.loop() }
        thread.name = "com.maccesshub.vocursor"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    func stop() {
        running = false
        thread = nil
    }

    private func loop() {
        var last: CGRect?
        var lastChange = Date()
        log.debug("tracker loop started")
        var failures = 0
        while running {
            guard Speaker.isVoiceOverRunning else {
                last = nil
                Thread.sleep(forTimeInterval: 2)
                continue
            }
            switch Self.cursorBounds() {
            case .success(let rect):
                failures = 0
                if rect != last {
                    last = rect
                    lastChange = Date()
                    log.debug("cursor \(Int(rect.minX), privacy: .public),\(Int(rect.minY), privacy: .public) \(Int(rect.width), privacy: .public)x\(Int(rect.height), privacy: .public)")
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        if self.onChange == nil { self.log.error("cursor change with no handler") }
                        self.onChange?(rect)
                    }
                }
            case .failure(let error):
                failures += 1
                // -1712 is a timeout: VoiceOver was busy speaking. Only worth noting if persistent.
                if failures == 10 || failures % 200 == 0 {
                    log.error("cursor bounds query keeps failing: \(error.localizedDescription, privacy: .public)")
                }
            }
            let idle = Date().timeIntervalSince(lastChange) > idleAfter
            Thread.sleep(forTimeInterval: idle ? idleInterval : activeInterval)
        }
    }

    // MARK: Apple Events

    private static func code(_ s: String) -> OSType {
        s.utf8.reduce(0) { ($0 << 8) | OSType($1) }
    }

    private static let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.VoiceOver")

    /// `get bounds of vo cursor` as a raw event: property pbnd of property vocu of the application.
    private static let getBoundsEvent: NSAppleEventDescriptor = {
        func property(_ name: String, of container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
            let record = NSAppleEventDescriptor.record()
            record.setDescriptor(NSAppleEventDescriptor(typeCode: code("prop")), forKeyword: code("want"))
            record.setDescriptor(container, forKeyword: code("from"))
            record.setDescriptor(NSAppleEventDescriptor(enumCode: code("prop")), forKeyword: code("form"))
            record.setDescriptor(NSAppleEventDescriptor(typeCode: code(name)), forKeyword: code("seld"))
            return record.coerce(toDescriptorType: code("obj ")) ?? record
        }
        let cursor = property("vocu", of: NSAppleEventDescriptor.null())
        let bounds = property("pbnd", of: cursor)
        let event = NSAppleEventDescriptor(eventClass: code("core"), eventID: code("getd"), targetDescriptor: target,
                                           returnID: Int16(kAutoGenerateReturnID), transactionID: Int32(kAnyTransactionID))
        event.setParam(bounds, forKeyword: code("----"))
        return event
    }()

    enum QueryError: LocalizedError {
        case noResult, badShape(String)
        var errorDescription: String? {
            switch self {
            case .noResult: return "no direct object in reply"
            case .badShape(let s): return "unexpected reply \(s)"
            }
        }
    }

    static func cursorBounds() -> Result<CGRect, Error> {
        let reply: NSAppleEventDescriptor
        do { reply = try getBoundsEvent.sendEvent(options: [.waitForReply, .neverInteract], timeout: 0.5) }
        catch { return .failure(error) }
        if let errorNumber = reply.paramDescriptor(forKeyword: code("errn"))?.int32Value, errorNumber != 0 {
            let message = reply.paramDescriptor(forKeyword: code("errs"))?.stringValue ?? "AE error \(errorNumber)"
            return .failure(NSError(domain: "VoiceOver", code: Int(errorNumber), userInfo: [NSLocalizedDescriptionKey: message]))
        }
        guard let value = reply.paramDescriptor(forKeyword: code("----")) else { return .failure(QueryError.noResult) }
        // VoiceOver answers with a QuickDraw rectangle: four little-endian
        // Int16s in top, left, bottom, right order, global top-left coordinates.
        if value.descriptorType == code("qdrt"), value.data.count >= 8 {
            let n = value.data.withUnsafeBytes { raw -> [Double] in
                (0..<4).map { Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self))) }
            }
            return .success(CGRect(x: n[1], y: n[0], width: n[3] - n[1], height: n[2] - n[0]))
        }
        // AppleScript-style list: left, top, right, bottom.
        let list = value.descriptorType == typeAEList ? value : value.coerce(toDescriptorType: typeAEList)
        guard let list, list.numberOfItems == 4 else { return .failure(QueryError.badShape(value.description)) }
        let n = (1...4).map { Double(list.atIndex($0)?.int32Value ?? 0) }
        return .success(CGRect(x: n[0], y: n[1], width: n[2] - n[0], height: n[3] - n[1]))
    }
}
