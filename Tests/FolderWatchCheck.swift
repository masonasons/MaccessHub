// Checks folder watching: telling adds, removes, renames and changes apart,
// holding files still being written, and what is said. Run with `make check`.
import Foundation

@main
struct FolderWatchCheck {
    static var failures = 0

    static func check(_ condition: Bool, _ name: String) {
        print("\(condition ? "PASS" : "FAIL"): \(name)")
        if !condition { failures += 1 }
    }

    static func file(_ inode: UInt64, size: Int64 = 10, at time: Double = 0) -> FolderEntry {
        FolderEntry(inode: inode, isDirectory: false, size: size, modified: time)
    }
    static func dir(_ inode: UInt64) -> FolderEntry { FolderEntry(inode: inode, isDirectory: true, size: 0, modified: 0) }
    static func snap(_ entries: [String: FolderEntry]) -> FolderSnapshot { FolderSnapshot(entries: entries) }
    static func diff(_ old: [String: FolderEntry], _ new: [String: FolderEntry], now: Double = 100) -> FolderChanges {
        FolderChanges.diff(old: snap(old), new: snap(new), now: now, settle: 1.5).changes
    }
    static let all = Set(FolderChanges.Kind.allCases)

    static func main() {
        // Kinds of change.
        var c = diff(["a.txt": file(1)], ["a.txt": file(1), "b.pdf": file(2)])
        check(c.added == ["b.pdf"] && c.removed.isEmpty && c.renamed.isEmpty && c.changed.isEmpty, "added")
        check(c.summary(folder: "Downloads", kinds: all) == "New file in Downloads: b.pdf", "added wording")
        c = diff(["a.txt": file(1)], [:])
        check(c.removed == ["a.txt"], "removed")
        check(c.summary(folder: "Downloads", kinds: all) == "Removed from Downloads: a.txt", "removed wording")
        c = diff(["draft.txt": file(1)], ["final.txt": file(1)])
        check(c.renamed == [.init(from: "draft.txt", to: "final.txt")] && c.added.isEmpty && c.removed.isEmpty, "renamed")
        check(c.summary(folder: "Notes", kinds: all) == "Renamed in Notes: draft.txt to final.txt", "renamed wording")
        c = diff(["a.txt": file(1, size: 10)], ["a.txt": file(1, size: 20)])
        check(c.changed == ["a.txt"], "changed in place")
        c = diff(["a.txt": file(1)], ["a.txt": file(7)])
        check(c.changed == ["a.txt"] && c.added.isEmpty && c.removed.isEmpty, "saved over (new inode) is changed")
        c = diff(["sub": dir(1)], ["sub": FolderEntry(inode: 1, isDirectory: true, size: 0, modified: 50)])
        check(c.isEmpty, "a subfolder's own date changing says nothing")

        // Bursts.
        c = diff([:], ["a": file(1), "b": file(2)])
        check(c.summary(folder: "Downloads", kinds: all) == "2 items added to Downloads: a and b", "two named")
        c = diff([:], ["a": file(1), "b": file(2), "c": file(3)])
        check(c.summary(folder: "Downloads", kinds: all) == "3 items added to Downloads: a, b and c", "three named")
        c = diff([:], Dictionary(uniqueKeysWithValues: (1...20).map { ("f\($0)", file(UInt64($0))) }))
        check(c.summary(folder: "Downloads", kinds: all) == "20 items added to Downloads", "many counted")
        check(c.added.first == "f1" && c.added.last == "f20", "sorted the way Finder sorts")

        // A folder copied in, with subfolders on, is one item.
        c = diff([:], ["Album": dir(1), "Album/1.mp3": file(2), "Album/2.mp3": file(3)])
        check(c.added == ["Album"], "folder copied in is one item")
        check(c.summary(folder: "Music", kinds: all) == "New folder in Music: Album", "folder wording")
        c = diff(["Old": dir(1), "Old/1.mp3": file(2)], ["New": dir(1), "New/1.mp3": file(2)])
        check(c.renamed == [.init(from: "Old", to: "New")], "renamed folder is one rename")
        c = diff(["Album": dir(1), "Album/1.mp3": file(2)], [:])
        check(c.removed == ["Album"], "removed folder is one item")

        // Still being written: held, then reported once settled.
        var r = FolderChanges.diff(old: snap([:]), new: snap(["big.mov": file(1, at: 99.5)]), now: 100, settle: 1.5)
        check(r.changes.isEmpty && r.held && r.snapshot.entries.isEmpty, "a file still being written is held")
        r = FolderChanges.diff(old: r.snapshot, new: snap(["big.mov": file(1, at: 99.5)]), now: 102, settle: 1.5)
        check(r.changes.added == ["big.mov"] && !r.held, "then announced once it settles")
        r = FolderChanges.diff(old: snap(["a": file(1, at: 0)]), new: snap(["a": file(1, size: 99, at: 99.9)]), now: 100, settle: 1.5)
        check(r.changes.isEmpty && r.held && r.snapshot.entries["a"] == file(1, at: 0), "a change still being written is held")

        // Only the kinds switched on are spoken.
        c = diff(["gone": file(1)], ["new": file(2)])
        check(c.summary(folder: "F", kinds: [.removed]) == "Removed from F: gone", "only enabled kinds")
        check(c.summary(folder: "F", kinds: []) == nil, "nothing enabled, nothing said")
        check(c.summary(folder: "F", kinds: all) == "New file in F: new. Removed from F: gone", "two kinds, one line each")

        // Ignored names.
        check(FolderSnapshot.isIgnored(".DS_Store") && FolderSnapshot.isIgnored("x.crdownload")
              && FolderSnapshot.isIgnored("film.mp4.part") && FolderSnapshot.isIgnored("~$report.docx")
              && FolderSnapshot.isIgnored("song.download"), "temporary and hidden names are skipped")
        check(!FolderSnapshot.isIgnored("report.pdf") && !FolderSnapshot.isIgnored("partner.txt"), "ordinary names are kept")

        // Real folder on disk.
        let root = NSTemporaryDirectory() + "folder-watch-check-\(getpid())"
        let fm = FileManager.default
        try? fm.removeItem(atPath: root)
        try! fm.createDirectory(atPath: root + "/sub", withIntermediateDirectories: true)
        fm.createFile(atPath: root + "/a.txt", contents: Data("a".utf8))
        fm.createFile(atPath: root + "/sub/b.txt", contents: Data("b".utf8))
        fm.createFile(atPath: root + "/.DS_Store", contents: Data())
        let top = FolderSnapshot.scan(root, subfolders: false)
        check(top.map { Set($0.entries.keys) } == ["a.txt", "sub"], "scan, top level only")
        let deep = FolderSnapshot.scan(root, subfolders: true)
        check(deep.map { Set($0.entries.keys) } == ["a.txt", "sub", "sub/b.txt"], "scan with subfolders")
        try! fm.moveItem(atPath: root + "/a.txt", toPath: root + "/renamed.txt")
        let after = FolderSnapshot.scan(root, subfolders: true)!
        let real = FolderChanges.diff(old: deep!, new: after, now: Date().timeIntervalSince1970 + 60, settle: 1.5).changes
        check(real.renamed == [.init(from: "a.txt", to: "renamed.txt")], "real rename on disk")
        check(FolderSnapshot.scan(root + "/missing", subfolders: false) == nil, "missing folder")
        try? fm.removeItem(atPath: root)

        print(failures == 0 ? "All folder watching checks passed." : "\(failures) folder watching check(s) failed.")
        exit(failures == 0 ? 0 : 1)
    }
}
