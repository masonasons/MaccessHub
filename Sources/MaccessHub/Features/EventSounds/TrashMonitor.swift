import AppKit
import CoreServices
import Foundation
import os

/// Items moved to the Trash, and the Trash being emptied.
///
/// macOS keeps the Trash private: without Full Disk Access an app can't list
/// it. It can still be told by FSEvents that something changed there, look up
/// a single item by name, and ask how many items the folder holds, which is
/// all this needs. The user's own Trash is watched, plus the Trash on each
/// connected disk that has one.
final class TrashMonitor: EventMonitor {
    var onEvent: ((String) -> Void)?

    private let log = Logger(subsystem: "com.maccesshub.app", category: "trash")
    private let queue = DispatchQueue(label: "com.maccesshub.trash")
    /// Seconds of quiet before a batch is judged, so emptying a full Trash is one sound.
    private let quiet = 0.5

    // Only touched on `queue`.
    private var running = false
    private var stream: FSEventStreamRef?
    /// The folders whose direct contents are trashed items.
    private var trashes: [String] = []
    private var lastCount = 0
    private var arrived = false
    private var deleted = false
    private var pending: DispatchWorkItem?
    private var volumeObservers: [NSObjectProtocol] = []

    /// The user's Trash; replaceable for testing.
    var homeTrash = TrashMonitor.realPath(NSHomeDirectory() + "/.Trash")

    func start() {
        queue.async { [self] in
            running = true
            restart()
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            volumeObservers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                guard let self else { return }
                queue.async { if self.running { self.restart() } }
            })
        }
    }

    func stop() {
        volumeObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        volumeObservers = []
        queue.sync {
            running = false
            tearDown()
        }
    }

    private func tearDown() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        pending?.cancel()
        pending = nil
        arrived = false
        deleted = false
    }

    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private func restart() {
        tearDown()
        // Each disk keeps its own Trash at .Trashes/<user ID>. Watch .Trashes,
        // which exists once anything on the disk has been trashed by anyone.
        var roots = [homeTrash]
        trashes = [homeTrash]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil,
                                                            options: [.skipHiddenVolumes]) ?? []
        for volume in volumes where volume.path != "/" {
            let dotTrashes = Self.realPath(volume.path + "/.Trashes")
            var info = stat()
            guard stat(dotTrashes, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { continue }
            roots.append(dotTrashes)
            trashes.append(dotTrashes + "/\(getuid())")
        }
        lastCount = count()

        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let monitor = Unmanaged<TrashMonitor>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            monitor.received(zip(list, UnsafeBufferPointer(start: flags, count: count)).map { ($0, $1) })
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        guard let stream = FSEventStreamCreate(nil, callback, &context, roots as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags) else {
            log.error("Could not watch the Trash")
            return
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    /// Items in every watched Trash, not counting Finder's .DS_Store. Asks the
    /// folder for its item count, which works where listing it does not.
    private func count() -> Int {
        trashes.reduce(0) { total, dir in
            var request = attrlist(bitmapcount: u_short(ATTR_BIT_MAP_COUNT), reserved: 0, commonattr: 0, volattr: 0,
                                   dirattr: attrgroup_t(ATTR_DIR_ENTRYCOUNT), fileattr: 0, forkattr: 0)
            var buffer = (UInt32(0), UInt32(0))
            guard getattrlist(dir, &request, &buffer, MemoryLayout.size(ofValue: buffer), 0) == 0 else { return total }
            var info = stat()
            let dsStore = lstat(dir + "/.DS_Store", &info) == 0 ? 1 : 0
            return total + max(0, Int(buffer.1) - dsStore)
        }
    }

    /// FSEvents callback, on `queue`.
    private func received(_ events: [(String, FSEventStreamEventFlags)]) {
        guard running else { return }
        var relevant = false
        for (path, flags) in events {
            let parent = (path as NSString).deletingLastPathComponent
            let name = (path as NSString).lastPathComponent
            guard name != ".DS_Store" else { continue }
            if trashes.contains(parent) {
                relevant = true
                var info = stat()
                if lstat(path, &info) == 0 {
                    // There now: moved in (a rename) or copied in from another disk.
                    if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemCreated) != 0 {
                        arrived = true
                    }
                } else if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved) != 0 {
                    // Gone and deleted, not put back (which is a rename).
                    deleted = true
                }
            } else if trashes.contains(where: { path.hasPrefix($0 + "/") }),
                      flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved) != 0 {
                // Something inside a trashed folder deleted: part of emptying.
                relevant = true
                deleted = true
            }
        }
        guard relevant else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.settle() }
        pending = work
        queue.asyncAfter(deadline: .now() + quiet, execute: work)
    }

    private func settle() {
        pending = nil
        let now = count()
        defer {
            lastCount = now
            arrived = false
            deleted = false
        }
        if arrived, now > 0 {
            DispatchQueue.main.async { [weak self] in self?.onEvent?("trash.added") }
        }
        // Emptied: it had items and now has none, and they were deleted rather
        // than put back. (Putting back the last item leaves it empty too.)
        if now == 0, lastCount > 0, deleted {
            DispatchQueue.main.async { [weak self] in self?.onEvent?("trash.emptied") }
        }
    }
}
