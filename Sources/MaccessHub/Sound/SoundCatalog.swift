import AVFoundation
import CryptoKit
import Foundation
import Observation

/// Classic sound schemes MaccessHub can download on request.
///
/// The catalog (Resources/SoundCatalog/catalog.json, made by
/// scripts/make-sound-catalog.py) holds no audio. Each pack lists, per event,
/// a URL where a public copy of the sound already lives, with its size and
/// SHA-256. Nothing is fetched until the user picks a pack, and every file
/// must match its hash before it is used.
struct SoundCatalog: Decodable {
    struct File: Decodable, Hashable {
        let event: String
        let url: URL
        let bytes: Int
        let sha256: String
    }

    struct Pack: Decodable, Identifiable, Hashable {
        let id: String
        let name: String
        let group: String
        let license: String
        let sources: [URL]
        let bytes: Int
        let files: [File]

        static func == (a: Pack, b: Pack) -> Bool { a.id == b.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }

        /// "33 sounds, 1.6 MB"
        var summary: String {
            let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            return "\(files.count) sound\(files.count == 1 ? "" : "s"), \(size)"
        }

        /// Host names the files come from, for "Downloaded from …".
        var hosts: [String] {
            var seen: [String] = []
            for source in sources {
                let host = (source.host ?? "").replacingOccurrences(of: "www.", with: "")
                if !host.isEmpty, !seen.contains(host) { seen.append(host) }
            }
            return seen
        }
    }

    let format: Int
    let packs: [Pack]

    /// Group names in catalog order, with their packs.
    var groups: [(name: String, packs: [Pack])] {
        var order: [String] = []
        var byGroup: [String: [Pack]] = [:]
        for pack in packs {
            if byGroup[pack.group] == nil { order.append(pack.group) }
            byGroup[pack.group, default: []].append(pack)
        }
        return order.map { ($0, byGroup[$0]!) }
    }

    static let bundled: SoundCatalog? = {
        guard let url = Bundle.main.url(forResource: "catalog", withExtension: "json", subdirectory: "SoundCatalog"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SoundCatalog.self, from: data)
    }()

    /// Hosts the catalog may download from. Redirects must stay inside them too.
    static let allowedHosts = ["archive.org", "raw.githubusercontent.com"]

    static func isAllowed(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return allowedHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Name of the hidden file that marks a user pack as downloaded from the catalog.
    static let markerName = ".maccesshub-catalog.json"

    struct Marker: Codable {
        var catalogID: String
        var downloaded: Date
        var sources: [URL]
    }

    /// Catalog pack id → user pack folder name, for packs already downloaded.
    static func installed(in library: SoundpackLibrary) -> [String: String] {
        var result: [String: String] = [:]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for pack in library.packs where !pack.isBuiltIn {
            let url = pack.url.appendingPathComponent(markerName)
            if let data = try? Data(contentsOf: url),
               let marker = try? decoder.decode(Marker.self, from: data) {
                result[marker.catalogID] = pack.id
            }
        }
        return result
    }
}

/// Downloads one catalog pack at a time into the user soundpacks folder.
@MainActor
@Observable
final class SoundCatalogInstaller {
    struct Outcome {
        let folderName: String
        let soundCount: Int
        let skipped: [String]
    }

    enum InstallError: LocalizedError {
        case nothingUsable(String)

        var errorDescription: String? {
            switch self {
            case .nothingUsable(let n):
                return "None of the sounds for \(n) could be downloaded. Check your internet connection and try again."
            }
        }
    }

    /// The pack being downloaded, if any.
    private(set) var activePack: SoundCatalog.Pack?
    /// 0...1 by bytes received.
    private(set) var fraction: Double = 0
    private(set) var status = ""
    private var task: Task<Void, Never>?
    private var lastAnnouncedQuarter = 0

    var isBusy: Bool { activePack != nil }

    func cancel() {
        task?.cancel()
    }

    /// `directory` is where the pack folder goes; tests pass a scratch folder.
    func install(_ pack: SoundCatalog.Pack, into library: SoundpackLibrary,
                 directory: URL = SoundpackLibrary.userPacksDirectory,
                 completion: @escaping (Result<Outcome, Error>) -> Void) {
        guard activePack == nil else { return }
        activePack = pack
        fraction = 0
        lastAnnouncedQuarter = 0
        status = "Downloading \(pack.name)…"
        announce("Downloading \(pack.name), \(pack.summary).")
        task = Task { [weak self] in
            guard let self else { return }
            let result: Result<Outcome, Error>
            do {
                result = .success(try await self.download(pack, library: library, directory: directory))
            } catch {
                result = .failure(error)
            }
            self.activePack = nil
            self.task = nil
            self.status = ""
            completion(result)
        }
    }

    private func progressed(_ received: Int, of total: Int, pack: SoundCatalog.Pack) {
        fraction = total > 0 ? min(1, Double(received) / Double(total)) : 0
        let percent = Int(fraction * 100)
        status = "Downloading \(pack.name): \(percent) percent"
        // Speak at 25, 50 and 75 percent, not on every file: a small pack
        // finishes in a second or two and the result is announced anyway.
        let quarter = Int(fraction * 4)
        if quarter > lastAnnouncedQuarter, quarter < 4 {
            lastAnnouncedQuarter = quarter
            announce("\(quarter * 25) percent")
        }
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.httpMaximumConnectionsPerHost = 4
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1"
        config.httpAdditionalHeaders = ["User-Agent": "MaccessHub/\(version) (sound catalog)"]
        return URLSession(configuration: config)
    }()

    /// Fetches one file and checks it against the catalog.
    nonisolated private static func fetch(_ file: SoundCatalog.File) async throws -> Data {
        guard SoundCatalog.isAllowed(file.url) else { throw URLError(.unsupportedURL) }
        let (data, response) = try await session.data(from: file.url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              SoundCatalog.isAllowed(http.url) else { throw URLError(.badServerResponse) }
        guard data.count == file.bytes,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == file.sha256 else {
            throw URLError(.cannotDecodeContentData)
        }
        return data
    }

    private func download(_ pack: SoundCatalog.Pack, library: SoundpackLibrary, directory: URL) async throws -> Outcome {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("MaccessHub-catalog-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        let folder = temp.appendingPathComponent("pack", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        var received = 0
        var written = 0
        var skipped: [String] = []
        let known = pack.files.filter { SoundEvent.byID[$0.event] != nil }

        try await withThrowingTaskGroup(of: (SoundCatalog.File, Data?).self) { group in
            var queue = known[...]
            func addNext() {
                guard let file = queue.popFirst() else { return }
                group.addTask { (file, try? await Self.fetch(file)) }
            }
            for _ in 0..<4 { addNext() }
            while let (file, data) = try await group.next() {
                try Task.checkCancellation()
                received += file.bytes
                progressed(received, of: pack.bytes, pack: pack)
                let title = SoundEvent.byID[file.event]?.title ?? file.event
                if let data, (try? Self.write(data, for: file, into: folder, scratch: temp)) == true {
                    written += 1
                } else {
                    skipped.append(title)
                }
                addNext()
            }
        }
        try Task.checkCancellation()
        guard written > 0 else { throw InstallError.nothingUsable(pack.name) }

        let reserved = Set(library.packs.filter(\.isBuiltIn).map(\.id))
        let base = SoundpackLibrary.sanitizedFolderName(pack.name) ?? "Downloaded Pack"
        let name = NavSoundsImporter.uniqueName(base, in: directory, taken: reserved)
        let hosts = pack.hosts.joined(separator: " and ")
        let manifest = SoundpackManifest(
            name: name, author: "Downloaded from \(hosts)",
            description: "\(pack.name), downloaded with MaccessHub's Get More Soundpacks. \(pack.license)",
            version: "1.0")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: folder.appendingPathComponent("pack.json"))
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(SoundCatalog.Marker(catalogID: pack.id, downloaded: Date(), sources: pack.sources))
            .write(to: folder.appendingPathComponent(SoundCatalog.markerName))

        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try fm.moveItem(at: folder, to: directory.appendingPathComponent(name, isDirectory: true))
        library.reload()
        return Outcome(folderName: name, soundCount: written, skipped: skipped)
    }

    /// Saves a verified download under its event's file name. Formats
    /// MaccessHub doesn't read directly (QuickTime, Ogg) are converted to CAF.
    /// Returns false when the file is not playable audio.
    nonisolated private static func write(_ data: Data, for file: SoundCatalog.File, into folder: URL, scratch: URL) throws -> Bool {
        let ext = file.url.pathExtension.lowercased()
        if Soundpack.supportedExtensions.contains(ext) {
            let target = folder.appendingPathComponent(Soundpack.fileName(for: file.event, index: 1, ext: ext))
            try data.write(to: target)
            if NavSoundsImporter.isPlayable(target) { return true }
            try? FileManager.default.removeItem(at: target)
            return false
        }
        let source = scratch.appendingPathComponent("\(UUID().uuidString).\(ext)")
        try data.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let target = folder.appendingPathComponent(Soundpack.fileName(for: file.event, index: 1, ext: "caf"))
        do {
            try convertToCAF(source, target)
        } catch {
            try? FileManager.default.removeItem(at: target)
            return false
        }
        return NavSoundsImporter.isPlayable(target)
    }

    /// Decodes any file AVFoundation can read and writes it as PCM in a CAF.
    /// File to file only: no audio device is touched.
    nonisolated static func convertToCAF(_ source: URL, _ target: URL) throws {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = try AVAudioFile(forWriting: target, settings: settings,
                                     commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        let capacity: AVAudioFrameCount = 32_768
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw URLError(.cannotDecodeContentData)
        }
        // A compressed file's length is an estimate, so read until the decoder
        // runs dry; reading past the real end throws rather than returning 0.
        var written: AVAudioFramePosition = 0
        while true {
            do {
                try input.read(into: buffer, frameCount: capacity)
            } catch {
                if written > 0 { break }
                throw error
            }
            if buffer.frameLength == 0 { break }
            try output.write(from: buffer)
            written += AVAudioFramePosition(buffer.frameLength)
        }
        guard written > 0 else { throw URLError(.cannotDecodeContentData) }
    }
}
