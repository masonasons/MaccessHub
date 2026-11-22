// Checks the downloadable soundpack catalog. Run with `make check`.
// `make check-catalog-download` also downloads one small pack into a scratch
// folder (network needed; nothing is written to your real soundpacks).
import AppKit
import Foundation

// SettingsView.swift is not built here.
func announce(_ message: String) { print("announce: \(message)") }

@main
struct SoundCatalogCheck {
    static var failures = 0

    static func check(_ condition: Bool, _ name: String) {
        print("\(condition ? "PASS" : "FAIL"): \(name)")
        if !condition { failures += 1 }
    }

    static func main() async {
        let args = CommandLine.arguments
        let path = args.count > 1 ? args[1] : "Resources/SoundCatalog/catalog.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let catalog = try? JSONDecoder().decode(SoundCatalog.self, from: data) else {
            print("FAIL: \(path) could not be read as a catalog")
            exit(1)
        }
        let files = catalog.packs.flatMap(\.files)
        check(catalog.format == 1, "format 1")
        check(!catalog.packs.isEmpty, "has packs")
        check(Set(catalog.packs.map(\.id)).count == catalog.packs.count, "pack ids are unique")
        check(Set(catalog.packs.map { $0.name.lowercased() }).count == catalog.packs.count, "pack names are unique")
        check(files.allSatisfy { SoundCatalog.isAllowed($0.url) }, "every URL is https on an allowed host")
        check(files.allSatisfy { SoundEvent.byID[$0.event] != nil }, "every event id exists")
        check(files.allSatisfy { $0.sha256.count == 64 && $0.sha256.allSatisfy(\.isHexDigit) }, "every file has a SHA-256")
        check(files.allSatisfy { $0.bytes > 0 && $0.bytes <= 8 * 1024 * 1024 }, "file sizes are sane")
        check(catalog.packs.allSatisfy { Set($0.files.map(\.event)).count == $0.files.count }, "one file per event")
        check(catalog.packs.allSatisfy { $0.bytes == $0.files.reduce(0) { $0 + $1.bytes } }, "pack sizes add up")
        check(!SoundCatalog.isAllowed(URL(string: "http://archive.org/x.wav")), "plain http refused")
        check(!SoundCatalog.isAllowed(URL(string: "https://notarchive.org/x.wav")), "look-alike host refused")
        check(SoundCatalog.isAllowed(URL(string: "https://ia800.us.archive.org/x.wav")), "archive.org mirrors allowed")

        if args.contains("--download") {
            await downloadSmallest(catalog)
        }
        print(failures == 0 ? "All checks passed." : "\(failures) check(s) failed.")
        exit(failures == 0 ? 0 : 1)
    }

    /// Downloads the smallest pack that needs a conversion (if any) and the
    /// smallest plain one, into a scratch folder, and loads them as packs.
    @MainActor
    static func downloadSmallest(_ catalog: SoundCatalog) async {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("MaccessHub-catalog-check-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let bySize = catalog.packs.sorted { $0.bytes < $1.bytes }
        var picks: [SoundCatalog.Pack] = []
        if let named = CommandLine.arguments.firstIndex(of: "--pack").map({ CommandLine.arguments[$0 + 1] }),
           let pack = catalog.packs.first(where: { $0.name == named || $0.id == named }) {
            picks.append(pack)
        } else {
            if let plain = bySize.first(where: { $0.files.allSatisfy { Soundpack.supportedExtensions.contains($0.url.pathExtension.lowercased()) } }) {
                picks.append(plain)
            }
            if let converted = bySize.first(where: { $0.files.contains { !Soundpack.supportedExtensions.contains($0.url.pathExtension.lowercased()) } }) {
                picks.append(converted)
            }
        }
        let library = SoundpackLibrary()
        for pack in picks {
            let installer = SoundCatalogInstaller()
            let result: Result<SoundCatalogInstaller.Outcome, Error> = await withCheckedContinuation { done in
                installer.install(pack, into: library, directory: scratch) { done.resume(returning: $0) }
            }
            switch result {
            case .success(let outcome):
                let folder = scratch.appendingPathComponent(outcome.folderName)
                let loaded = Soundpack.load(from: folder, isBuiltIn: false)
                check(loaded != nil, "\(pack.name): folder loads as a pack")
                check(loaded?.eventCount == pack.files.count,
                      "\(pack.name): \(loaded?.eventCount ?? 0) of \(pack.files.count) sounds usable, skipped \(outcome.skipped)")
                check(loaded?.manifest.name == outcome.folderName, "\(pack.name): pack.json names the pack")
                check(FileManager.default.fileExists(atPath: folder.appendingPathComponent(SoundCatalog.markerName).path),
                      "\(pack.name): marked as downloaded")
                for (event, url) in (loaded?.files ?? [:]).sorted(by: { $0.key < $1.key }) {
                    print("    \(event) <- \(url.lastPathComponent)")
                }
            case .failure(let error):
                check(false, "\(pack.name): \(error.localizedDescription)")
            }
        }
    }
}
