// Verification harness for the NVDA Navigation Sounds importer and sound variants.
// Built and run by scripts/verify-nvda-import.sh; not part of the app target.
import Foundation

@main
struct VerifyNVDAImport {
    static var failures = 0

    static func check(_ condition: Bool, _ message: String) {
        print(condition ? "  ok    \(message)" : "  FAIL  \(message)")
        if !condition { failures += 1 }
    }

    static func show(_ results: [NavSoundsImporter.Result]) {
        for r in results {
            print("  -> \(r.name) [\(r.kind.rawValue)] \(r.soundCount) source files, \(r.eventCount) events")
            for (event, sources) in r.mapping { print("       \(event): \(sources.joined(separator: ", "))") }
            if !r.skipped.isEmpty { print("       skipped (\(r.skipped.count)): \(r.skipped.joined(separator: ", "))") }
            if !r.unreadable.isEmpty { print("       not playable: \(r.unreadable.joined(separator: ", "))") }
            // Read it back the way the app does, so variant parsing is checked too.
            if let pack = Soundpack.load(from: r.folder, isBuiltIn: false) {
                let summary = pack.variants.keys.sorted().map { "\($0)×\(pack.variantCount(for: $0))" }
                print("       loaded: \(pack.name), \(pack.eventCount) events, \(pack.fileCount) files: \(summary.joined(separator: " "))")
                for (event, sources) in r.mapping {
                    check(pack.variantCount(for: event) == sources.count, "\(r.name): \(event) reloads with \(sources.count) variant(s)")
                }
            } else {
                check(false, "\(r.name) loads as a soundpack")
            }
        }
    }

    static func attempt(_ label: String, _ source: URL, into dest: URL, reserved: Set<String> = []) -> [NavSoundsImporter.Result]? {
        print("\n== \(label)")
        do {
            let results = try NavSoundsImporter.importPacks(from: source, into: dest, reservedNames: reserved)
            show(results)
            return results
        } catch {
            print("  error: \(error.localizedDescription)")
            return nil
        }
    }

    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 4 else {
            print("usage: verify <navsounds clone> <empty output dir> <bad-zip dir>"); exit(2)
        }
        let clone = URL(fileURLWithPath: args[1])
        let out = URL(fileURLWithPath: args[2])
        let bad = URL(fileURLWithPath: args[3])
        let effects = clone.appendingPathComponent("navsounds/globalPlugins/NavigationSounds/effects")
        let fm = FileManager.default

        print("== Variant naming")
        for event in SoundEvent.all {
            let parsed = Soundpack.parseStem(event.id)
            if parsed.eventID != event.id || parsed.index != 1 { check(false, "\(event.id) parses as itself") }
        }
        check(true, "all \(SoundEvent.all.count) event IDs parse as themselves (no numeric last component)")
        check(Soundpack.parseStem("key.lower.2") == ("key.lower", 2), "key.lower.2 is variant 2 of key.lower")
        check(Soundpack.parseStem("key.lower.10") == ("key.lower", 10), "key.lower.10 is variant 10")
        check(Soundpack.parseStem("power.battery20Minutes") == ("power.battery20Minutes", 1), "power.battery20Minutes is not a variant")
        check(Soundpack.parseStem("my.sound.2") == ("my.sound.2", 1), "unknown event IDs keep their numeric suffix")
        check(Soundpack.parseStem("key.lower.0") == ("key.lower.0", 1), "variant 0 is not a variant")

        let picker = VariantPicker()
        let two = [URL(fileURLWithPath: "/a"), URL(fileURLWithPath: "/b")]
        let five = (1...5).map { URL(fileURLWithPath: "/v\($0)") }
        var last: URL?
        var repeated = false
        for _ in 0..<500 { let u = picker.pick(from: five); if u == last { repeated = true }; last = u }
        check(!repeated, "five variants never repeat back to back over 500 picks")
        last = nil; repeated = false
        for _ in 0..<100 { let u = picker.pick(from: two); if u == last { repeated = true }; last = u }
        check(!repeated, "two variants alternate")
        check(picker.pick(from: [URL(fileURLWithPath: "/one")])?.path == "/one", "one file always plays")

        let typing = effects.appendingPathComponent("typingsound")
        for folder in ((try? fm.contentsOfDirectory(at: typing, includingPropertiesForKeys: nil)) ?? [])
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where folder.hasDirectoryPath {
            if let r = attempt("typing folder \(folder.lastPathComponent)", folder, into: out) {
                check(r.count == 1 && r[0].kind == .typing, "detected as one typing pack")
            }
        }
        let nav = effects.appendingPathComponent("navsounds")
        for folder in ((try? fm.contentsOfDirectory(at: nav, includingPropertiesForKeys: nil)) ?? [])
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where folder.hasDirectoryPath {
            if let r = attempt("navigation folder \(folder.lastPathComponent)", folder, into: out) {
                check(r.count == 1 && r[0].kind == .navigation, "detected as one navigation pack")
            }
        }
        let store = clone.appendingPathComponent("store/packs")
        if let r = attempt("store zip classic-typewriter.zip", store.appendingPathComponent("classic-typewriter/classic-typewriter.zip"), into: out) {
            check(r.first?.name == "classic-typewriter", "flat zip is named after the archive")
        }
        if let r = attempt("store zip voiceover.zip (navigation)", store.appendingPathComponent("voiceover/voiceover.zip"), into: out) {
            check(r.first?.kind == .navigation, "voiceover.zip is a navigation pack")
            check(r.first?.name == "voiceover 2", "name collision with the earlier voiceover import gets a number")
        }

        print("\n== Edge cases")
        let multi = attempt("the whole typingsound folder (a folder of packs)", typing, into: out)
        check(multi?.count == 12, "imports each of the 12 packs inside")
        check(multi?.allSatisfy { $0.name.hasSuffix(" 2") } == true, "every name collides and gets a number")
        let reserved = attempt("a pack named like a built-in", bad.appendingPathComponent("Classic"), into: out, reserved: ["Classic"])
        check(reserved?.first?.name == "Classic 2", "a built-in pack name is never shadowed")
        check(attempt("zip with ../ entry", bad.appendingPathComponent("traversal.zip"), into: out) == nil, "path traversal zip is refused")
        check(attempt("zip with absolute entry", bad.appendingPathComponent("absolute.zip"), into: out) == nil, "absolute path zip is refused")
        check(attempt("zip that is not a zip", bad.appendingPathComponent("broken.zip"), into: out) == nil, "broken zip is refused")
        check(attempt("zip with no sounds", bad.appendingPathComponent("nosounds.zip"), into: out) == nil, "zip without sounds is refused")
        let nested = attempt("zip with several pack folders and __MACOSX junk", bad.appendingPathComponent("multi.zip"), into: out)
        check(nested?.count == 2, "both pack folders imported, __MACOSX ignored")
        check(nested?.first?.unreadable == ["garbage.wav"], "a file that is not audio is left out and reported")
        check(attempt("a MaccessHub pack picked by mistake", bad.appendingPathComponent("AlreadyMaccessHub"), into: out) == nil,
              "a MaccessHub pack is refused with a pointer to Import Folder")
        let unicode = attempt("zip with a non-English pack name", bad.appendingPathComponent("unicode.zip"), into: out)
        check(unicode?.first?.name == "لوحة مفاتيح", "Arabic folder name survives")
        let leftovers = (try? fm.contentsOfDirectory(atPath: fm.temporaryDirectory.path))?.filter { $0.hasPrefix("MaccessHub-import-") } ?? []
        check(leftovers.isEmpty, "no temporary extraction folders left behind")
        let escaped = fm.fileExists(atPath: out.deletingLastPathComponent().appendingPathComponent("evil.wav").path)
        check(!escaped, "nothing written outside the output folder")

        print("\n\(failures == 0 ? "All checks passed." : "\(failures) check(s) FAILED.")")
        exit(failures == 0 ? 0 : 1)
    }
}
