// Checks the table of related events used by "Fill gaps with this pack's
// similar sounds". Run with `make check`.
import Foundation

@main
struct RelatedSoundsCheck {
    static var failures = 0

    static func check(_ condition: Bool, _ name: String) {
        print("\(condition ? "PASS" : "FAIL"): \(name)")
        if !condition { failures += 1 }
    }

    static func kind(_ group: SoundGroup) -> String {
        group == .keys ? "keys" : group == .focus ? "focus" : "events"
    }

    static func main() {
        var unknown: [String] = [], selfRefs: [String] = [], crossKind: [String] = [], dupes: [String] = []
        for (id, others) in SoundEvent.related {
            guard let event = SoundEvent.byID[id] else { unknown.append(id); continue }
            if Set(others).count != others.count { dupes.append(id) }
            for other in others {
                guard let o = SoundEvent.byID[other] else { unknown.append(other); continue }
                if other == id { selfRefs.append(id) }
                if kind(o.group) != kind(event.group) { crossKind.append("\(id) -> \(other)") }
            }
        }
        check(unknown.isEmpty, "every related ID is a real event \(unknown)")
        check(selfRefs.isEmpty, "no event lists itself \(selfRefs)")
        check(crossKind.isEmpty, "related events stay in their kind of pack \(crossKind)")
        check(dupes.isEmpty, "no repeats in a list \(dupes)")

        let events = SoundEvent.all.filter { kind($0.group) == "events" }
        let uncovered = events.filter { SoundEvent.related[$0.id] == nil }.map(\.id)
        check(uncovered.isEmpty, "every system event has stand-ins \(uncovered)")

        // A pack with only USB sounds: Bluetooth borrows them, the others don't.
        let has: (String) -> Bool = { ["usb.connected", "usb.disconnected"].contains($0) }
        check(SoundEvent.relatedStandIn(for: "bluetooth.connected", has: has) == "usb.connected",
              "Bluetooth connected borrows USB connected")
        check(SoundEvent.relatedStandIn(for: "bluetooth.disconnected", has: has) == "usb.disconnected",
              "Bluetooth disconnected borrows USB disconnected")
        check(SoundEvent.relatedStandIn(for: "power.charged", has: has) == nil,
              "nothing borrowed when no related event has a sound")
        // Order matters: the first related event the pack has wins.
        let both: (String) -> Bool = { ["window.created", "application.launched"].contains($0) }
        check(SoundEvent.relatedStandIn(for: "application.launching", has: both) == "application.launched",
              "first listed stand-in wins")
        // One hop only: launching -> launched is fine, but an empty launched
        // never sends launching on to what launched would borrow.
        let onlyRestored: (String) -> Bool = { $0 == "media.playing" }
        check(SoundEvent.relatedStandIn(for: "application.launching", has: onlyRestored) == nil,
              "stand-ins are never followed further")

        print(failures == 0 ? "All related-sound checks passed." : "\(failures) related-sound check(s) failed.")
        exit(failures == 0 ? 0 : 1)
    }
}
