import Foundation
import Observation
import os

/// Metadata stored in `pack.json` at the root of a soundpack folder.
struct SoundpackManifest: Codable {
    var name: String
    var author: String?
    var description: String?
    var version: String?
}

/// A folder of sound files named after event IDs (`application.launched.wav`).
/// Any extension AVFoundation can decode is accepted.
struct Soundpack: Identifiable, Hashable {
    static func == (a: Soundpack, b: Soundpack) -> Bool { a.id == b.id && a.url == b.url && a.files == b.files }
    func hash(into hasher: inout Hasher) { hasher.combine(id); hasher.combine(url) }

    static let builtInClassicID = "Classic"
    static let supportedExtensions: Set<String> = ["wav", "aiff", "aif", "caf", "mp3", "m4a", "aac", "flac"]

    /// The folder name. Built-in packs and user packs share one namespace;
    /// a user pack with the same folder name as a built-in one shadows it.
    let id: String
    let url: URL
    let manifest: SoundpackManifest
    let isBuiltIn: Bool
    /// event ID → file URL
    let files: [String: URL]

    var name: String { manifest.name }
    var eventCount: Int { files.count }

    func url(for eventID: String) -> URL? { files[eventID] }

    static func load(from url: URL, isBuiltIn: Bool) -> Soundpack? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return nil }
        let id = url.lastPathComponent
        var manifest = SoundpackManifest(name: id)
        let manifestURL = url.appendingPathComponent("pack.json")
        if let data = try? Data(contentsOf: manifestURL),
           let decoded = try? JSONDecoder().decode(SoundpackManifest.self, from: data) {
            manifest = decoded
        }
        var files: [String: URL] = [:]
        let contents = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil,
                                                    options: [.skipsHiddenFiles])) ?? []
        for file in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let ext = file.pathExtension.lowercased()
            guard supportedExtensions.contains(ext) else { continue }
            let eventID = file.deletingPathExtension().lastPathComponent
            // First match wins so the choice is deterministic when a pack has
            // both `x.wav` and `x.mp3`.
            if files[eventID] == nil { files[eventID] = file }
        }
        return Soundpack(id: id, url: url, manifest: manifest, isBuiltIn: isBuiltIn, files: files)
    }
}

/// Finds packs on disk and creates new ones.
///
/// Built-in packs live in the app bundle. User packs live in
/// `~/Library/Application Support/MaccessHub/Soundpacks/<Name>/`.
@Observable
final class SoundpackLibrary {
    @ObservationIgnored private let log = Logger(subsystem: "com.maccesshub.app", category: "soundpacks")

    static let userPacksDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MaccessHub/Soundpacks", isDirectory: true)
    }()

    static let builtInPacksDirectory: URL? =
        Bundle.main.resourceURL?.appendingPathComponent("Soundpacks", isDirectory: true)

    private(set) var packs: [Soundpack] = []

    init() {
        try? FileManager.default.createDirectory(at: Self.userPacksDirectory, withIntermediateDirectories: true)
        reload()
    }

    func reload() {
        var found: [String: Soundpack] = [:]
        if let dir = Self.builtInPacksDirectory {
            for pack in Self.scan(dir, builtIn: true) { found[pack.id] = pack }
        }
        for pack in Self.scan(Self.userPacksDirectory, builtIn: false) { found[pack.id] = pack }
        packs = found.values.sorted { a, b in
            if a.isBuiltIn != b.isBuiltIn { return a.isBuiltIn }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        log.info("Loaded \(self.packs.count) soundpacks")
    }

    private static func scan(_ dir: URL, builtIn: Bool) -> [Soundpack] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return contents.compactMap { Soundpack.load(from: $0, isBuiltIn: builtIn) }
    }

    func pack(id: String) -> Soundpack? { packs.first { $0.id == id } }

    var classic: Soundpack? { pack(id: Soundpack.builtInClassicID) }

    /// The event-sound pack to use when the configured one is gone.
    func resolvedPack(id: String) -> Soundpack? { pack(id: id) ?? classic }

    enum LibraryError: LocalizedError {
        case invalidName, alreadyExists(String), notAPack(URL), builtIn

        var errorDescription: String? {
            switch self {
            case .invalidName: return "Enter a name that can be used as a folder name."
            case .alreadyExists(let n): return "A soundpack named \(n) already exists."
            case .notAPack(let u): return "\(u.lastPathComponent) does not contain any supported sound files."
            case .builtIn: return "Built-in soundpacks cannot be changed. Duplicate it first."
            }
        }
    }

    static func sanitizedFolderName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return trimmed.isEmpty || trimmed.hasPrefix(".") ? nil : trimmed
    }

    /// Creates an empty user pack, optionally seeded with copies of another pack's files.
    @discardableResult
    func createPack(named name: String, author: String?, description: String?,
                    copying source: Soundpack?) throws -> Soundpack {
        guard let folder = Self.sanitizedFolderName(name) else { throw LibraryError.invalidName }
        let dest = Self.userPacksDirectory.appendingPathComponent(folder, isDirectory: true)
        if FileManager.default.fileExists(atPath: dest.path) { throw LibraryError.alreadyExists(folder) }
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        if let source {
            for (_, file) in source.files {
                try FileManager.default.copyItem(at: file, to: dest.appendingPathComponent(file.lastPathComponent))
            }
        }
        let manifest = SoundpackManifest(name: folder, author: author, description: description, version: "1.0")
        try writeManifest(manifest, to: dest)
        reload()
        guard let pack = pack(id: folder) else { throw LibraryError.notAPack(dest) }
        return pack
    }

    /// Writes a pack whose files are chosen by the caller (used to export the
    /// currently resolved scheme, overrides included, as a standalone pack).
    @discardableResult
    func createPack(named name: String, author: String?, description: String?,
                    files: [String: URL]) throws -> Soundpack {
        guard let folder = Self.sanitizedFolderName(name) else { throw LibraryError.invalidName }
        let dest = Self.userPacksDirectory.appendingPathComponent(folder, isDirectory: true)
        if FileManager.default.fileExists(atPath: dest.path) { throw LibraryError.alreadyExists(folder) }
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        for (eventID, file) in files {
            let target = dest.appendingPathComponent(eventID).appendingPathExtension(file.pathExtension)
            try FileManager.default.copyItem(at: file, to: target)
        }
        let manifest = SoundpackManifest(name: folder, author: author, description: description, version: "1.0")
        try writeManifest(manifest, to: dest)
        reload()
        guard let pack = pack(id: folder) else { throw LibraryError.notAPack(dest) }
        return pack
    }

    /// Copies a folder the user picked into the user packs directory.
    @discardableResult
    func importPack(from folder: URL) throws -> Soundpack {
        guard let probe = Soundpack.load(from: folder, isBuiltIn: false), probe.eventCount > 0 else {
            throw LibraryError.notAPack(folder)
        }
        let dest = Self.userPacksDirectory.appendingPathComponent(folder.lastPathComponent, isDirectory: true)
        if FileManager.default.fileExists(atPath: dest.path) {
            throw LibraryError.alreadyExists(folder.lastPathComponent)
        }
        try FileManager.default.copyItem(at: folder, to: dest)
        reload()
        guard let pack = pack(id: folder.lastPathComponent) else { throw LibraryError.notAPack(folder) }
        return pack
    }

    /// Moves a user pack to the Trash.
    func deletePack(_ pack: Soundpack) throws {
        guard !pack.isBuiltIn else { throw LibraryError.builtIn }
        try FileManager.default.trashItem(at: pack.url, resultingItemURL: nil)
        reload()
    }

    /// Replaces (or adds) one event's file inside a user pack.
    func setSound(_ file: URL, for eventID: String, in pack: Soundpack) throws {
        guard !pack.isBuiltIn else { throw LibraryError.builtIn }
        // Remove any existing file for this event regardless of extension.
        for ext in Soundpack.supportedExtensions {
            let old = pack.url.appendingPathComponent(eventID).appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: old.path) { try FileManager.default.removeItem(at: old) }
        }
        let target = pack.url.appendingPathComponent(eventID).appendingPathExtension(file.pathExtension)
        try FileManager.default.copyItem(at: file, to: target)
        reload()
    }

    func removeSound(for eventID: String, in pack: Soundpack) throws {
        guard !pack.isBuiltIn else { throw LibraryError.builtIn }
        if let existing = pack.url(for: eventID) { try FileManager.default.removeItem(at: existing) }
        reload()
    }

    func updateManifest(_ manifest: SoundpackManifest, for pack: Soundpack) throws {
        guard !pack.isBuiltIn else { throw LibraryError.builtIn }
        try writeManifest(manifest, to: pack.url)
        reload()
    }

    private func writeManifest(_ manifest: SoundpackManifest, to folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: folder.appendingPathComponent("pack.json"))
    }
}
