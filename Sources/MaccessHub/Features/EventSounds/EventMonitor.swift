import Foundation

/// Something that watches the system and reports sound events by ID.
protocol EventMonitor: AnyObject {
    var onEvent: ((String) -> Void)? { get set }
    func start()
    func stop()
}
