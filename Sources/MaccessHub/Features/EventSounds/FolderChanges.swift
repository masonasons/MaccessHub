import Foundation

/// One item in a watched folder, as far as change detection cares.
struct FolderEntry: Equatable {
    var inode: UInt64
    var isDirectory: Bool
    var size: Int64
    /// Seconds since 1970.
    var modified: Double
}

/// What a watched folder holds, keyed by path relative to the folder.
/// Comparing two of these (rather than reading FSEvents flags, which are
/// coalesced and ambiguous) tells adds, removes, renames and changes apart.
struct FolderSnapshot: Equatable {
    var entries: [String: FolderEntry] = [:]

    /// Names that are never reported: Finder's own files, and the temporary
    /// files browsers and editors write while a download or save is under way.
    /// The finished file is what gets announced.
    static func isIgnored(_ name: String) -> Bool {
        if name.hasPrefix(".") || name.hasPrefix("~$") { return true }
        let lower = name.lowercased()
        let partial = [".part", ".partial", ".crdownload", ".download", ".opdownload", ".tmp", ".temp", ".swp"]
        return partial.contains { lower.hasSuffix($0) }
    }

    /// Reads the folder. Nil when it is missing or can't be read. With
    /// `subfolders`, walks into folders (not into packages such as apps, and
    /// not onto other disks); past `limit` items it gives up on subfolders
    /// and reads the top level only, so a huge tree can't stall the Mac.
    static func scan(_ root: String, subfolders: Bool, limit: Int = 20_000) -> FolderSnapshot? {
        // An item renamed between listing the folder and looking at the item
        // would read as one removal and no addition; read again if that happens.
        var attempt = 0
        while true {
            attempt += 1
            var complete = true
            let snapshot = read(root, subfolders: subfolders, limit: limit, complete: &complete)
            if complete || attempt == 3 { return snapshot }
        }
    }

    private static func read(_ root: String, subfolders: Bool, limit: Int, complete: inout Bool) -> FolderSnapshot? {
        var rootInfo = stat()
        guard lstat(root, &rootInfo) == 0, (rootInfo.st_mode & S_IFMT) == S_IFDIR,
              let top = try? FileManager.default.contentsOfDirectory(atPath: root) else { return nil }
        if subfolders, let deep = walk(root, device: rootInfo.st_dev, limit: limit, complete: &complete) { return deep }
        var snapshot = FolderSnapshot()
        for name in top where !isIgnored(name) {
            if let entry = entry(at: root + "/" + name) { snapshot.entries[name] = entry } else { complete = false }
        }
        return snapshot
    }

    private static func walk(_ root: String, device: dev_t, limit: Int, complete: inout Bool) -> FolderSnapshot? {
        var snapshot = FolderSnapshot()
        var pending = [""]
        while let relative = pending.popLast() {
            let dir = relative.isEmpty ? root : root + "/" + relative
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for name in names where !isIgnored(name) {
                let path = relative.isEmpty ? name : relative + "/" + name
                var info = stat()
                guard lstat(root + "/" + path, &info) == 0 else { complete = false; continue }
                snapshot.entries[path] = entry(from: info)
                if snapshot.entries.count > limit { return nil }
                if (info.st_mode & S_IFMT) == S_IFDIR, info.st_dev == device,
                   (try? URL(fileURLWithPath: root + "/" + path).resourceValues(forKeys: [.isPackageKey]))?.isPackage != true {
                    pending.append(path)
                }
            }
        }
        return snapshot
    }

    private static func entry(at path: String) -> FolderEntry? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return entry(from: info)
    }

    private static func entry(from info: stat) -> FolderEntry {
        FolderEntry(inode: UInt64(info.st_ino), isDirectory: (info.st_mode & S_IFMT) == S_IFDIR,
                    size: Int64(info.st_size),
                    modified: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9)
    }
}

/// The differences between two snapshots of one folder.
struct FolderChanges: Equatable {
    enum Kind: CaseIterable {
        case added, removed, renamed, changed

        var eventID: String {
            switch self {
            case .added: return "folder.added"
            case .removed: return "folder.removed"
            case .renamed: return "folder.renamed"
            case .changed: return "folder.changed"
            }
        }
    }

    struct Rename: Equatable {
        var from: String
        var to: String
    }

    var added: [String] = []
    /// Paths among `added` that are folders, so they can be called folders.
    var addedFolders: Set<String> = []
    var removed: [String] = []
    var renamed: [Rename] = []
    var changed: [String] = []

    var isEmpty: Bool { added.isEmpty && removed.isEmpty && renamed.isEmpty && changed.isEmpty }

    func count(_ kind: Kind) -> Int {
        switch kind {
        case .added: return added.count
        case .removed: return removed.count
        case .renamed: return renamed.count
        case .changed: return changed.count
        }
    }

    /// Compares two snapshots. A file written in the last `settle` seconds is
    /// held back (the returned snapshot keeps its old state) so a download or
    /// copy is announced once, when it has finished, rather than as it starts.
    /// `held` says whether anything was held, meaning look again shortly.
    static func diff(old: FolderSnapshot, new: FolderSnapshot, now: Double, settle: Double)
        -> (changes: FolderChanges, snapshot: FolderSnapshot, held: Bool) {
        var result = FolderChanges()
        var snapshot = new
        var held = false
        let newPathByInode = Dictionary(new.entries.map { ($0.value.inode, $0.key) }, uniquingKeysWith: { a, _ in a })
        let oldPathByInode = Dictionary(old.entries.map { ($0.value.inode, $0.key) }, uniquingKeysWith: { a, _ in a })

        func isFresh(_ entry: FolderEntry) -> Bool { !entry.isDirectory && now - entry.modified < settle }

        for (path, entry) in new.entries {
            if let before = old.entries[path] {
                guard !entry.isDirectory, !before.isDirectory else { continue }
                // Saving over a file (a new file renamed over the old one) gives
                // the name a new inode; it is still the same file, changed.
                if before.inode != entry.inode || before.size != entry.size || before.modified != entry.modified {
                    if isFresh(entry) { snapshot.entries[path] = before; held = true; continue }
                    result.changed.append(path)
                }
            } else if let oldPath = oldPathByInode[entry.inode], new.entries[oldPath]?.inode != entry.inode {
                result.renamed.append(Rename(from: oldPath, to: path))
            } else {
                if isFresh(entry) { snapshot.entries[path] = nil; held = true; continue }
                result.added.append(path)
                if entry.isDirectory { result.addedFolders.insert(path) }
            }
        }
        for (path, entry) in old.entries where new.entries[path] == nil {
            // Moved within the folder: already counted as a rename.
            if let newPath = newPathByInode[entry.inode], old.entries[newPath]?.inode != entry.inode { continue }
            result.removed.append(path)
        }

        // A folder added, removed or renamed takes everything inside it along;
        // say it once for the folder, not once for every file in it.
        func underAny(_ path: String, _ folders: Set<String>) -> Bool {
            var parent = (path as NSString).deletingLastPathComponent
            while !parent.isEmpty {
                if folders.contains(parent) { return true }
                parent = (parent as NSString).deletingLastPathComponent
            }
            return false
        }
        let addedSet = Set(result.added)
        result.added = result.added.filter { !underAny($0, addedSet) }
        result.addedFolders = result.addedFolders.intersection(result.added)
        result.changed = result.changed.filter { !underAny($0, addedSet) }
        let removedSet = Set(result.removed)
        result.removed = result.removed.filter { !underAny($0, removedSet) }
        let renamedTo = Set(result.renamed.map(\.to))
        result.renamed = result.renamed.filter { !underAny($0.to, renamedTo) }

        result.added.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        result.removed.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        result.changed.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        result.renamed.sort { $0.to.localizedStandardCompare($1.to) == .orderedAscending }
        return (result, snapshot, held)
    }

    /// What to say, for the kinds asked for: one sentence per kind, naming up
    /// to three items and counting the rest. Nil when there is nothing to say.
    func summary(folder: String, kinds: Set<Kind>) -> String? {
        var sentences: [String] = []
        func name(_ path: String) -> String { (path as NSString).lastPathComponent }
        func list(_ names: [String]) -> String {
            names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names.last!
        }
        if kinds.contains(.added), !added.isEmpty {
            if added.count == 1 {
                let what = addedFolders.contains(added[0]) ? "folder" : "file"
                sentences.append("New \(what) in \(folder): \(name(added[0]))")
            } else if added.count <= 3 {
                sentences.append("\(added.count) items added to \(folder): \(list(added.map(name)))")
            } else {
                sentences.append("\(added.count) items added to \(folder)")
            }
        }
        if kinds.contains(.removed), !removed.isEmpty {
            if removed.count == 1 {
                sentences.append("Removed from \(folder): \(name(removed[0]))")
            } else if removed.count <= 3 {
                sentences.append("\(removed.count) items removed from \(folder): \(list(removed.map(name)))")
            } else {
                sentences.append("\(removed.count) items removed from \(folder)")
            }
        }
        if kinds.contains(.renamed), !renamed.isEmpty {
            if renamed.count == 1 {
                sentences.append("Renamed in \(folder): \(name(renamed[0].from)) to \(name(renamed[0].to))")
            } else {
                sentences.append("\(renamed.count) items renamed in \(folder)")
            }
        }
        if kinds.contains(.changed), !changed.isEmpty {
            if changed.count == 1 {
                sentences.append("Changed in \(folder): \(name(changed[0]))")
            } else if changed.count <= 3 {
                sentences.append("\(changed.count) items changed in \(folder): \(list(changed.map(name)))")
            } else {
                sentences.append("\(changed.count) items changed in \(folder)")
            }
        }
        return sentences.isEmpty ? nil : sentences.joined(separator: ". ")
    }
}
