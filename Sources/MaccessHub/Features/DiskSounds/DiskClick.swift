import Foundation

// Disk sounds come from Plattersong by Onj (https://github.com/OnjLouis/Plattersong,
// MIT). Its click synthesis is itself a port of Sensor Readout 6.6.1's disk
// click (MIT, "Copyright (c) 2026 Sensor Readout contributors").

/// How one disk sounds: volume, pan and a three-band tone control.
struct DiskMix: Codable, Equatable {
    var enabled = true
    /// 0...100.
    var volume = 30
    /// -100 (left) ... 100 (right).
    var pan = 0
    /// -12...12 dB each.
    var bass = 0
    var middle = 0
    var treble = 0

    static let eqRange = -12...12

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = c.value(.enabled, default: true)
        volume = c.value(.volume, default: 30)
        pan = c.value(.pan, default: 0)
        bass = c.value(.bass, default: 0)
        middle = c.value(.middle, default: 0)
        treble = c.value(.treble, default: 0)
    }

    static func clamp(_ value: Int, _ range: ClosedRange<Int>) -> Int {
        min(range.upperBound, max(range.lowerBound, value))
    }
}

/// A disk's cumulative read and write operation counts.
struct DiskCounters: Equatable {
    let read: UInt64
    let write: UInt64

    /// What happened since `previous`. Silent on the first reading, and when a
    /// counter goes backwards (a reset), so neither sounds like activity.
    func change(since previous: DiskCounters?) -> DiskActivity {
        guard let previous else { return [] }
        var result: DiskActivity = []
        if read > previous.read { result.insert(.read) }
        if write > previous.write { result.insert(.write) }
        return result
    }
}

struct DiskActivity: OptionSet {
    let rawValue: Int
    static let read = DiskActivity(rawValue: 1)
    static let write = DiskActivity(rawValue: 2)
}

enum DiskClick {
    static let rate = 48_000
    /// 11 ms per click.
    static let frames = rate * 11 / 1_000
    /// Offset between clicks in one batch (a write after a read, or a second disk).
    static let stagger = rate * 4 / 1_000
    static let batchFrames = frames + 2 * stagger

    /// One click as interleaved stereo 16-bit samples: three sines (360, 1250
    /// and 3900 Hz, a write pitched down to 0.68) under a fast attack and a
    /// cubic decay, panned with Sensor Readout's pan law.
    static func synthesize(_ mix: DiskMix, write: Bool) -> [Int16] {
        let pan = Double(DiskMix.clamp(mix.pan, -100...100)) / 100
        let angle = (1 + pan * (2 - abs(pan))) * Double.pi / 4
        let level = 3500 * Double(DiskMix.clamp(mix.volume, 0...100)) / 100
        let left = level * cos(angle)
        let right = level * sin(angle)
        func gain(_ db: Int) -> Double { pow(10, Double(DiskMix.clamp(db, DiskMix.eqRange)) / 20) }
        let bass = gain(mix.bass), mid = gain(mix.middle), treble = gain(mix.treble)
        let pitch = write ? 0.68 : 1
        var pcm = [Int16](repeating: 0, count: frames * 2)
        for frame in 0..<frames {
            let phase = 2 * Double.pi * pitch * Double(frame) / Double(rate)
            let envelope = min(1, Double(frame) / 16) * pow(1 - Double(frame) / Double(frames), 3)
            let sample = envelope * (bass * sin(phase * 360) + mid * sin(phase * 1250) + treble * sin(phase * 3900))
            pcm[2 * frame] = Int16(clamping: Int(sample * left))
            pcm[2 * frame + 1] = Int16(clamping: Int(sample * right))
        }
        return pcm
    }

    /// A disk's read and write clicks, rendered once per mix.
    struct Pair {
        let read: [Int16]
        let write: [Int16]
        init(_ mix: DiskMix) {
            read = DiskClick.synthesize(mix, write: false)
            write = DiskClick.synthesize(mix, write: true)
        }
    }

    /// Mixes one sampling tick's activity into a single batch. Every other disk
    /// starts a stagger later, and a write that comes with a read follows it by
    /// a stagger, so simultaneous clicks stay distinct.
    static func render(_ active: [(DiskActivity, Pair)]) -> [Int16] {
        var sum = [Int32](repeating: 0, count: batchFrames * 2)
        func add(_ pcm: [Int16], at frame: Int) {
            for i in pcm.indices { sum[frame * 2 + i] += Int32(pcm[i]) }
        }
        for (i, item) in active.enumerated() {
            let offset = i.isMultiple(of: 2) ? 0 : stagger
            if item.0.contains(.read) { add(item.1.read, at: offset) }
            if item.0.contains(.write) { add(item.1.write, at: offset + (item.0.contains(.read) ? stagger : 0)) }
        }
        return sum.map { Int16(clamping: $0) }
    }

    /// Ten clicks 120 ms apart, for trying a mix.
    static func preview(_ mix: DiskMix, write: Bool) -> [Int16] {
        let click = synthesize(mix, write: write)
        let interval = rate * 120 / 1_000 * 2
        var pcm = [Int16](repeating: 0, count: interval * 10)
        for i in 0..<10 { pcm.replaceSubrange(i * interval..<i * interval + click.count, with: click) }
        return pcm
    }
}
