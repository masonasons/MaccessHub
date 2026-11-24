import AppKit
import CoreServices
import Foundation
import os

/// Watches the folders the user picked and reports what was added, removed,
/// renamed or changed in each. FSEvents only says that something happened
/// under a folder; the folder is then read again and compared with the last
/// reading, a second after things go quiet, so a burst becomes one report.
final class FolderMonitor: EventMonitor {
    var onEvent: ((String) -> Void)?
    /// Called on the main thread with each batch of changes.
    var onChanges: ((WatchedFolder, FolderChanges) -> Void)?
    /// Called on the main thread when a folder exists but can't be read.
    var onUnreadable: ((WatchedFolder) -> Void)?

    /// Set from settings; changing it while running starts watching afresh.
    var folders: [WatchedFolder] = [] {
        didSet {
            guard folders != oldValue else { return }
            let list = folders
            queue.async { [self] in
                watchList = list
                if running { restart() }
            }
        }
    }

    private let log = Logger(subsystem: "com.maccesshub.app", category: "folders")
    private let queue = DispatchQueue(label: "com.maccesshub.folders")
    /// Seconds of quiet before a folder is read again.
    private let quiet = 1.0
    /// A file written more recently than this is still being written.
    private let settle = 1.0

    // Everything below is only touched on `queue`.
    private var running = false
    private var watchList: [WatchedFolder] = []
    private var stream: FSEventStreamRef?
    private var watched: [Watched] = []
    private var mountObserver: NSObjectProtocol?
    /// Folders already reported as unreadable, so it is said once, not at every restart.
    private var toldUnreadable: Set<String> = []

    private struct Watched {
        var folder: WatchedFolder
        /// The real path (symlinks resolved), which is what FSEvents reports.
        var root: String
        var snapshot: FolderSnapshot?
        var pending: DispatchWorkItem?
    }

    func start() {
        let list = folders
        queue.async { [self] in
            watchList = list
            running = true
            restart()
        }
        // A folder on a disk that wasn't connected starts once the disk is.
        mountObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            queue.async { if self.running { self.restart() } }
        }
    }

    func stop() {
        if let mountObserver { NSWorkspace.shared.notificationCenter.removeObserver(mountObserver) }
        mountObserver = nil
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
        watched.forEach { $0.pending?.cancel() }
        watched = []
    }

    private func restart() {
        tearDown()
        watched = watchList.map { folder in
            return Watched(folder: folder, root: Self.realPath(folder.expandedPath), snapshot: nil)
        }
        guard !watched.isEmpty else { return }
        // The first reading is the starting point; nothing is announced for it.
        for i in watched.indices { baseline(i) }

        let paths = watched.map(\.root) as CFArray
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let monitor = Unmanaged<FolderMonitor>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            monitor.received(Array(list.prefix(count)))
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                                             | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(nil, callback, &context, paths,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags) else {
            log.error("Could not watch folders")
            return
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    /// FSEvents reports real paths, such as /private/tmp for /tmp. (URL's
    /// resolvingSymlinksInPath goes the other way and drops /private.)
    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private func baseline(_ i: Int) {
        let item = watched[i]
        watched[i].snapshot = FolderSnapshot.scan(item.root, subfolders: item.folder.includeSubfolders)
        guard watched[i].snapshot == nil else { toldUnreadable.remove(item.root); return }
        var isDir: ObjCBool = false
        // It exists but can't be listed: macOS is keeping it private.
        if FileManager.default.fileExists(atPath: item.root, isDirectory: &isDir), isDir.boolValue,
           !toldUnreadable.contains(item.root) {
            toldUnreadable.insert(item.root)
            log.error("Can't read watched folder \(item.root, privacy: .public)")
            let folder = item.folder
            DispatchQueue.main.async { [weak self] in self?.onUnreadable?(folder) }
        }
    }

    /// FSEvents callback, on `queue`.
    private func received(_ paths: [String]) {
        guard running else { return }
        for i in watched.indices {
            let root = watched[i].root.lowercased()
            let subfolders = watched[i].folder.includeSubfolders
            let touched = paths.contains { path in
                let p = path.lowercased()
                if p == root { return true }
                guard p.hasPrefix(root + "/") else { return false }
                // Without subfolders, only the folder's own items count.
                return subfolders || (p as NSString).deletingLastPathComponent == root
            }
            if touched { schedule(i, after: quiet) }
        }
    }

    private func schedule(_ i: Int, after delay: Double) {
        watched[i].pending?.cancel()
        let root = watched[i].root
        let work = DispatchWorkItem { [weak self] in
            guard let self, let index = watched.firstIndex(where: { $0.root == root }) else { return }
            rescan(index)
        }
        watched[i].pending = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func rescan(_ i: Int) {
        watched[i].pending = nil
        guard let old = watched[i].snapshot else { baseline(i); return }
        guard let new = FolderSnapshot.scan(watched[i].root, subfolders: watched[i].folder.includeSubfolders) else {
            // Gone (the disk was ejected, say): start over when it is back.
            watched[i].snapshot = nil
            return
        }
        let result = FolderChanges.diff(old: old, new: new, now: Date().timeIntervalSince1970, settle: settle)
        watched[i].snapshot = result.snapshot
        if result.held { schedule(i, after: settle) }
        guard !result.changes.isEmpty else { return }
        let folder = watched[i].folder
        DispatchQueue.main.async { [weak self] in self?.onChanges?(folder, result.changes) }
    }
}
