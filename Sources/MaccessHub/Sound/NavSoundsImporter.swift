import AVFoundation
import Foundation

/// Converts packs from the NVDA add-on Navigation Sounds
/// (https://github.com/ahmedthebest31/navsounds) into MaccessHub soundpacks.
///
/// Navigation Sounds has two kinds of pack, both plain folders of wav files:
/// - typing packs, which play a random file from the folder on every key, with
///   free-form names (`typing_1.wav`, `s3.wav`, `space.wav`, `bill.wav`);
/// - navigation packs, which name each file after an NVDA control role
///   (`button.wav`, `checkbox.wav`, `treeviewitem.wav`).
/// The kind is detected from the file names. Typing packs become key-click
/// packs with variants; navigation packs become focus-sound packs.
///
/// Nothing is bundled: the user picks a folder or a .zip they downloaded.
enum NavSoundsImporter {
    enum Kind: String {
        case typing, navigation

        var noun: String { self == .typing ? "typing" : "navigation" }
    }

    struct Result {
        /// The new pack's folder (its name is the folder name).
        let folder: URL
        let name: String
        let kind: Kind
        /// Source files that were used.
        let soundCount: Int
        /// Events the pack now covers.
        let eventCount: Int
        /// Source files that matched nothing (navigation packs only).
        let skipped: [String]
        /// Source files that are not playable audio and were left out.
        let unreadable: [String]
        /// event ID → source file names, in variant order.
        let mapping: [(eventID: String, sources: [String])]
    }

    enum ImportError: LocalizedError {
        case unreadable(String)
        case unsafeArchive(String)
        case tooLarge(String)
        case noSounds(String)
        case alreadyMaccessHub(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let n): return "\(n) could not be opened as a folder or a zip file."
            case .unsafeArchive(let n): return "\(n) was not imported because it contains files that would be written outside its own folder."
            case .tooLarge(let n): return "\(n) is too large to be a sound pack. The limit is 64 MB and 2000 files."
            case .noSounds(let n): return "\(n) does not contain any typing or navigation sounds that MaccessHub can use."
            case .alreadyMaccessHub(let n): return "\(n) is already a MaccessHub soundpack. Use Import Folder instead."
            }
        }
    }

    static let maxArchiveBytes: Int64 = 64 * 1024 * 1024
    static let maxExtractedBytes: Int64 = 256 * 1024 * 1024
    static let maxEntries = 2000

    static let typingDescription = "Imported from an NVDA Navigation Sounds typing pack"
    static let navigationDescription = "Imported from an NVDA Navigation Sounds navigation pack"

    /// Focus slot → NVDA role file names, best match first. NVDA role names are
    /// lowercased with underscores removed, as Navigation Sounds does.
    static let focusMap: [(eventID: String, roles: [String])] = [
        ("focus.button", ["button", "togglebutton"]),
        ("focus.checkbox", ["checkbox", "switch"]),
        ("focus.radioButton", ["radiobutton"]),
        ("focus.comboBox", ["combobox", "dropdownbutton", "droplist"]),
        ("focus.splitButton", ["splitbutton", "menubutton"]),
        ("focus.editableText", ["editabletext", "edittext", "richedit", "passwordedit"]),
        ("focus.link", ["link"]),
        ("focus.listItem", ["listitem", "dataitem"]),
        ("focus.treeItem", ["treeviewitem"]),
        ("focus.menuItem", ["menuitem"]),
        ("focus.tab", ["tab"]),
        ("focus.slider", ["slider", "spinbutton"]),
        ("focus.icon", ["graphic", "icon"]),
        ("focus.clock", ["progressbar", "clock"]),
    ]

    /// Role names that mark a pack as a navigation pack. Wider than `focusMap`
    /// so a pack is recognised even if it only covers roles MaccessHub lacks.
    static let navigationRoleNames: Set<String> = Set(focusMap.flatMap(\.roles)).union([
        "document", "heading", "list", "menu", "menubar", "window", "dialog", "statictext",
        "table", "treeview", "toolbar", "grouping", "pane", "application", "checkmenuitem",
        "radiomenuitem", "popupmenu", "dropdownbuttongrid", "unknown", "clickable",
    ])

    /// Normalises a file stem the way Navigation Sounds matches roles.
    static func roleKey(_ stem: String) -> String {
        stem.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Typing pack file → key events. The order of the checks matters: a file
    /// called "KeypressSpacebar" is a space, not a generic key press.
    static func typingEvents(for stem: String) -> [String] {
        let s = stem.lowercased()
        if s.contains("space") { return ["key.space"] }
        if s.contains("delete") || s.contains("backspace") { return ["key.delete"] }
        if s.contains("bill") || s.contains("bell") || s.contains("enter") || s.contains("return") {
            return ["key.enter"]
        }
        if s.contains("letter") { return ["key.lower"] }
        if s.contains("number") || s.contains("digit") { return ["key.digit"] }
        return ["key.lower", "key.other"]
    }

    /// Keys given the generic key presses when a typing pack has nothing specific for them.
    static let typingFillIns = ["key.space", "key.delete", "key.enter"]

    static func detectKind(stems: [String]) -> Kind {
        stems.contains { navigationRoleNames.contains(roleKey($0)) } ? .navigation : .typing
    }

    // MARK: Import

    /// Imports every pack found in `source` (a folder or a .zip) into `destination`.
    /// `reservedNames` are folder names that must not be used (built-in packs).
    static func importPacks(from source: URL, into destination: URL,
                            reservedNames: Set<String> = []) throws -> [Result] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDir) else {
            throw ImportError.unreadable(source.lastPathComponent)
        }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        let root: URL
        let rootName: String
        var tempDir: URL?
        defer { if let tempDir { try? fm.removeItem(at: tempDir) } }

        if isDir.boolValue {
            root = source
            rootName = source.lastPathComponent
        } else if source.pathExtension.lowercased() == "zip" {
            let temp = fm.temporaryDirectory.appendingPathComponent("MaccessHub-import-\(UUID().uuidString)",
                                                                    isDirectory: true)
            try fm.createDirectory(at: temp, withIntermediateDirectories: true)
            tempDir = temp
            try extract(zip: source, to: temp)
            root = temp
            rootName = source.deletingPathExtension().lastPathComponent
        } else {
            throw ImportError.unreadable(source.lastPathComponent)
        }

        let groups = try soundGroups(in: root, rootName: rootName)
        var results: [Result] = []
        var taken = reservedNames
        for group in groups {
            if let result = try writePack(group, into: destination, taken: &taken) {
                results.append(result)
            }
        }
        if results.isEmpty { throw ImportError.noSounds(source.lastPathComponent) }
        return results
    }

    /// Unzips with ditto (resource forks off, so a stray __MACOSX folder cannot break it) after checking the archive's entry names and sizes.
    private static func extract(zip: URL, to dir: URL) throws {
        let name = zip.lastPathComponent
        let size = (try? zip.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        if size > maxArchiveBytes { throw ImportError.tooLarge(name) }

        guard let listing = run("/usr/bin/zipinfo", ["-1", zip.path]) else { throw ImportError.unreadable(name) }
        let entries = listing.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        if entries.count > maxEntries { throw ImportError.tooLarge(name) }
        for entry in entries {
            let parts = entry.split(whereSeparator: { $0 == "/" || $0 == "\\" })
            let driveLetter = entry.count >= 2 && entry.dropFirst().first == ":"
            if entry.hasPrefix("/") || entry.hasPrefix("\\") || parts.contains("..") || driveLetter {
                throw ImportError.unsafeArchive(name)
            }
        }
        // "N files, B bytes uncompressed, C bytes compressed: x%"
        if let totals = run("/usr/bin/zipinfo", ["-t", zip.path]),
           let range = totals.range(of: #"(\d+) bytes uncompressed"#, options: .regularExpression) {
            let digits = totals[range].prefix { $0.isNumber }
            if let bytes = Int64(digits), bytes > maxExtractedBytes { throw ImportError.tooLarge(name) }
        }
        guard run("/usr/bin/ditto", ["-x", "-k", "--norsrc", "--noextattr", "--noacl", zip.path, dir.path]) != nil else {
            throw ImportError.unreadable(name)
        }
    }

    /// Runs a tool without a shell; returns its output, or nil on failure.
    private static func run(_ tool: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    struct Group {
        let name: String
        let files: [URL]
    }

    /// Every folder that directly holds sound files is one pack. Sound files at
    /// the top level take the name of the folder or archive itself.
    static func soundGroups(in root: URL, rootName: String) throws -> [Group] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: keys,
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var byFolder: [String: [URL]] = [:]
        var total: Int64 = 0
        var visited = 0
        var soundFiles = 0
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        for case let file as URL in walker {
            if file.lastPathComponent == "__MACOSX" { walker.skipDescendants(); continue }
            // Someone picking their whole home folder should get a quick answer, not a long walk.
            visited += 1
            if visited > maxEntries * 10 { throw ImportError.tooLarge(rootName) }
            guard let values = try? file.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            guard Soundpack.supportedExtensions.contains(file.pathExtension.lowercased()) else { continue }
            // Never follow anything that resolves outside the root.
            guard file.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(rootPath + "/") else { continue }
            soundFiles += 1
            if soundFiles > maxEntries { throw ImportError.tooLarge(rootName) }
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            if total > maxExtractedBytes { throw ImportError.tooLarge(rootName) }
            let folder = file.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
            byFolder[folder, default: []].append(file)
        }
        return byFolder.keys.sorted().map { folder in
            let name = folder == rootPath ? rootName : URL(fileURLWithPath: folder).lastPathComponent
            let files = byFolder[folder]!.sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
            return Group(name: name, files: files)
        }
    }

    /// The first free folder name: "Name", then "Name 2", "Name 3", …
    static func uniqueName(_ base: String, in destination: URL, taken: Set<String>) -> String {
        // Folder names compare the way APFS does: ignoring case and Unicode normalisation.
        func fold(_ s: String) -> String { s.precomposedStringWithCanonicalMapping.lowercased() }
        let existing = Set(((try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? []).map(fold))
        let reserved = Set(taken.map(fold))
        var candidate = base
        var n = 2
        while existing.contains(fold(candidate)) || reserved.contains(fold(candidate)) {
            candidate = "\(base) \(n)"
            n += 1
        }
        return candidate
    }

    /// Builds the event → files mapping for one group and writes it as a pack.
    /// Whether the file opens as audio with at least one frame.
    static func isPlayable(_ url: URL) -> Bool {
        guard let file = try? AVAudioFile(forReading: url) else { return false }
        return file.length > 0
    }

    private static func writePack(_ group: Group, into destination: URL, taken: inout Set<String>) throws -> Result? {
        // A folder of event-named files is a MaccessHub pack, not a Navigation Sounds one.
        if group.files.contains(where: {
            SoundEvent.byID[Soundpack.parseStem($0.deletingPathExtension().lastPathComponent).eventID] != nil
        }) {
            throw ImportError.alreadyMaccessHub(group.name)
        }
        let unreadable = group.files.filter { !isPlayable($0) }
        let group = Group(name: group.name, files: group.files.filter { !unreadable.contains($0) })
        let stems = group.files.map { $0.deletingPathExtension().lastPathComponent }
        let kind = detectKind(stems: stems)
        var mapping: [String: [URL]] = [:]
        var order: [String] = []
        var used = Set<URL>()
        var skipped: [String] = []

        func add(_ file: URL, to eventID: String) {
            if mapping[eventID] == nil { order.append(eventID) }
            mapping[eventID, default: []].append(file)
            used.insert(file)
        }

        switch kind {
        case .typing:
            for file in group.files {
                for eventID in typingEvents(for: file.deletingPathExtension().lastPathComponent) {
                    add(file, to: eventID)
                }
            }
            // Navigation Sounds plays the pack's own sounds for every key. Keys
            // the pack has no special file for use its generic key presses, so
            // the space bar does not suddenly switch to another pack's click.
            let generic = mapping["key.other"] ?? []
            for eventID in typingFillIns where mapping[eventID] == nil && !generic.isEmpty {
                order.append(eventID)
                mapping[eventID] = generic
            }
        case .navigation:
            var byRole: [String: URL] = [:]
            for file in group.files {
                let key = roleKey(file.deletingPathExtension().lastPathComponent)
                if byRole[key] == nil { byRole[key] = file }
            }
            for (eventID, roles) in focusMap {
                if let file = roles.lazy.compactMap({ byRole[$0] }).first { add(file, to: eventID) }
            }
            skipped = group.files.filter { !used.contains($0) }.map(\.lastPathComponent)
        }
        guard !mapping.isEmpty else { return nil }

        let baseName = SoundpackLibrary.sanitizedFolderName(group.name) ?? "Imported Pack"
        let name = uniqueName(baseName, in: destination, taken: taken)
        taken.insert(name)
        let folder = destination.appendingPathComponent(name, isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        do {
            for eventID in order {
                for (i, file) in mapping[eventID]!.enumerated() {
                    let target = folder.appendingPathComponent(
                        Soundpack.fileName(for: eventID, index: i + 1, ext: file.pathExtension.lowercased()))
                    try fm.copyItem(at: file, to: target)
                }
            }
            let manifest = SoundpackManifest(
                name: name, author: nil,
                description: kind == .typing ? typingDescription : navigationDescription, version: "1.0")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(to: folder.appendingPathComponent("pack.json"))
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }
        return Result(folder: folder, name: name, kind: kind, soundCount: used.count, eventCount: mapping.count,
                      skipped: skipped, unreadable: unreadable.map(\.lastPathComponent),
                      mapping: order.map { ($0, mapping[$0]!.map(\.lastPathComponent)) })
    }
}
