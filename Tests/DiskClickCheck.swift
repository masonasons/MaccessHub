// Checks that the disk click synthesis matches Plattersong (and so Sensor
// Readout 6.6.1) sample for sample. Run with `make check`.
import CryptoKit
import Foundation

// Settings.swift is not built here; this is the one helper DiskMix needs from it.
extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, default defaultValue: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? defaultValue
    }
}

@main
struct DiskClickCheck {
    static var failures = 0

    static func check(_ condition: Bool, _ name: String) {
        print("\(condition ? "PASS" : "FAIL"): \(name)")
        if !condition { failures += 1 }
    }

    static func hash(_ samples: [Int16]) -> String {
        samples.withUnsafeBytes { SHA256.hash(data: Data($0)).map { String(format: "%02x", $0) }.joined() }
    }

    static func main() {
        check(DiskCounters(read: 1, write: 2).change(since: nil).isEmpty, "first reading is silent")
        check(DiskCounters(read: 20, write: 31).change(since: .init(read: 19, write: 30)) == [.read, .write],
              "reads and writes together")
        check(DiskCounters(read: 2, write: 31).change(since: .init(read: 19, write: 30)) == .write,
              "a counter reset does not sound")
        let mix = DiskMix()
        let pair = DiskClick.Pair(mix)
        check(pair.read.count == 1056 && pair.write.count == 1056 && pair.read != pair.write, "click shape")
        // Reference hashes from Plattersong's self-test.
        check(hash(pair.read) == "f1764ed79fec2f8030d7b8c6bcf953a6a081bece375f23de983847de7b581dfa",
              "read click matches Plattersong and Sensor Readout 6.6.1")
        check(hash(pair.write) == "d3294e1711c822d36625437b88f2797085b8801cb4f838ca68f719d886c744cb",
              "write click matches Plattersong and Sensor Readout 6.6.1")
        let combined = DiskClick.render([([.read, .write], pair)])
        check(combined.count == 1824 && Array(combined.prefix(DiskClick.stagger * 2)) == Array(pair.read.prefix(384)),
              "read and write start apart")
        var left = mix; left.pan = -100
        check(DiskClick.Pair(left).read.enumerated().filter { !$0.offset.isMultiple(of: 2) }.allSatisfy { $0.element == 0 },
              "hard left")
        var right = mix; right.pan = 100
        check(DiskClick.Pair(right).write.enumerated().filter { $0.offset.isMultiple(of: 2) }.allSatisfy { $0.element == 0 },
              "hard right")
        var boosted = mix; boosted.treble = 12
        check(DiskClick.Pair(boosted).read != pair.read, "tone changes the sound")
        let decoded = try? JSONDecoder().decode(DiskMix.self, from: Data(#"{"volume": 55}"#.utf8))
        check(decoded?.volume == 55 && decoded?.enabled == true && decoded?.bass == 0, "partial settings fall back per field")
        exit(failures == 0 ? 0 : 1)
    }
}
