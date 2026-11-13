import AVFoundation
import Foundation

/// A group of sounds that shares one processing chain: its own volume, EQ and
/// reverb, so each group can sound different (reverb on focus sounds but not on
/// key clicks, more treble on progress beeps, and so on).
enum SoundBus: String, Codable, CaseIterable, Identifiable {
    case events, focus, keys, progress

    var id: String { rawValue }

    var title: String {
        switch self {
        case .events: return "Event sounds"
        case .focus: return "Focus sounds"
        case .keys: return "Key clicks"
        case .progress: return "Progress beeps"
        }
    }
}

/// Reverb rooms for a sound group, backed by Apple's factory reverb presets.
enum BusReverb: String, Codable, CaseIterable, Identifiable {
    case none, smallRoom, mediumRoom, largeRoom, mediumHall, largeHall, plate, cathedral

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .smallRoom: return "Small room"
        case .mediumRoom: return "Medium room"
        case .largeRoom: return "Large room"
        case .mediumHall: return "Medium hall"
        case .largeHall: return "Large hall"
        case .plate: return "Plate"
        case .cathedral: return "Cathedral"
        }
    }

    var preset: AVAudioUnitReverbPreset? {
        switch self {
        case .none: return nil
        case .smallRoom: return .smallRoom
        case .mediumRoom: return .mediumRoom
        case .largeRoom: return .largeRoom
        case .mediumHall: return .mediumHall
        case .largeHall: return .largeHall
        case .plate: return .plate
        case .cathedral: return .cathedral
        }
    }
}

/// Processing for one sound group. The defaults change nothing: full volume,
/// no reverb, flat EQ.
struct AudioBusSettings: Codable, Equatable {
    /// 0...1. Multiplies with the volume set on the feature's own tab.
    var volume = 1.0
    var reverb: BusReverb = .none
    /// 0...1, how much of the group goes through the reverb (0 dry, 1 fully wet).
    var reverbMix = 0.3
    /// Decibels, -12...12. Bass (low shelf), middle (peak) and treble (high shelf).
    var eqLow = 0.0
    var eqMid = 0.0
    var eqHigh = 0.0

    static let eqRange: ClosedRange<Double> = -12...12

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        volume = c.value(.volume, default: 1.0)
        reverb = c.value(.reverb, default: .none)
        reverbMix = c.value(.reverbMix, default: 0.3)
        eqLow = c.value(.eqLow, default: 0.0)
        eqMid = c.value(.eqMid, default: 0.0)
        eqHigh = c.value(.eqHigh, default: 0.0)
    }

    var isFlat: Bool { eqLow == 0 && eqMid == 0 && eqHigh == 0 }

    /// A few starting points. They only touch the EQ.
    enum EQPreset: String, CaseIterable, Identifiable {
        case flat, clearer, warmer
        var id: String { rawValue }
        var title: String {
            switch self {
            case .flat: return "Flat"
            case .clearer: return "Clearer"
            case .warmer: return "Warmer"
            }
        }
        var help: String {
            switch self {
            case .flat: return "Bass, middle and treble at 0 decibels."
            case .clearer: return "Less bass, more middle and treble. Can help if high sounds are hard to hear."
            case .warmer: return "More bass, less treble. Softer on the ears."
            }
        }
        var gains: (low: Double, mid: Double, high: Double) {
            switch self {
            case .flat: return (0, 0, 0)
            case .clearer: return (-3, 3, 6)
            case .warmer: return (4, 0, -4)
            }
        }
    }

    mutating func apply(_ preset: EQPreset) {
        let g = preset.gains
        eqLow = g.low; eqMid = g.mid; eqHigh = g.high
    }
}

/// One `AudioBusSettings` per sound group.
struct SoundProcessingSettings: Codable, Equatable {
    var events = AudioBusSettings()
    var focus = AudioBusSettings()
    var keys = AudioBusSettings()
    var progress = AudioBusSettings()

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        events = c.value(.events, default: AudioBusSettings())
        focus = c.value(.focus, default: AudioBusSettings())
        keys = c.value(.keys, default: AudioBusSettings())
        progress = c.value(.progress, default: AudioBusSettings())
    }

    subscript(bus: SoundBus) -> AudioBusSettings {
        get {
            switch bus {
            case .events: return events
            case .focus: return focus
            case .keys: return keys
            case .progress: return progress
            }
        }
        set {
            switch bus {
            case .events: events = newValue
            case .focus: focus = newValue
            case .keys: keys = newValue
            case .progress: progress = newValue
            }
        }
    }
}

/// The processing chain for one group:
/// players → mixer → 3-band EQ → reverb → peak limiter → mixer (group volume) → main mixer.
/// EQ and reverb are bypassed while flat or dry, and the limiter while no EQ
/// band is boosted, so the default chain does no processing at all. The
/// limiter is there so a +12 dB boost cannot push a sound into clipping; its
/// attack is set to its 1 ms minimum because its look-ahead delays the sound.
/// The volume is the output mixer's `volume` into the main mixer: a sub-mixer's
/// `outputVolume` is ignored by AVAudioEngine (measured: no change at 0).
final class SoundBusChain {
    let input = AVAudioMixerNode()
    let output = AVAudioMixerNode()
    let eq = AVAudioUnitEQ(numberOfBands: 3)
    let reverb = AVAudioUnitReverb()
    let limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
    private var currentPreset: BusReverb?

    static let lowFrequency: Float = 200
    static let midFrequency: Float = 1500
    static let highFrequency: Float = 5000

    init() {
        let low = eq.bands[0]
        low.filterType = .lowShelf
        low.frequency = Self.lowFrequency
        low.gain = 0
        low.bypass = false
        let mid = eq.bands[1]
        mid.filterType = .parametric
        mid.frequency = Self.midFrequency
        mid.bandwidth = 1.5 // octaves
        mid.gain = 0
        mid.bypass = false
        let high = eq.bands[2]
        high.filterType = .highShelf
        high.frequency = Self.highFrequency
        high.gain = 0
        high.bypass = false
        eq.globalGain = 0
        eq.bypass = true
        reverb.wetDryMix = 0
        reverb.bypass = true
        let unit = limiter.audioUnit
        AudioUnitSetParameter(unit, kLimiterParam_AttackTime, kAudioUnitScope_Global, 0, 0.001, 0)
        AudioUnitSetParameter(unit, kLimiterParam_DecayTime, kAudioUnitScope_Global, 0, 0.05, 0)
        AudioUnitSetParameter(unit, kLimiterParam_PreGain, kAudioUnitScope_Global, 0, 0, 0)
        limiter.bypass = true
    }

    /// Attaches the chain and wires it, ending in `destination`.
    func attach(to engine: AVAudioEngine, destination: AVAudioNode, format: AVAudioFormat) {
        engine.attach(input)
        engine.attach(eq)
        engine.attach(reverb)
        engine.attach(limiter)
        engine.attach(output)
        engine.connect(input, to: eq, format: format)
        engine.connect(eq, to: reverb, format: format)
        engine.connect(reverb, to: limiter, format: format)
        engine.connect(limiter, to: output, format: format)
        engine.connect(output, to: destination, format: format)
    }

    func apply(_ settings: AudioBusSettings) {
        output.volume = Float(max(0, min(1, settings.volume)))
        let clamp = { (v: Double) in Float(max(AudioBusSettings.eqRange.lowerBound, min(AudioBusSettings.eqRange.upperBound, v))) }
        eq.bands[0].gain = clamp(settings.eqLow)
        eq.bands[1].gain = clamp(settings.eqMid)
        eq.bands[2].gain = clamp(settings.eqHigh)
        eq.bypass = settings.isFlat
        limiter.bypass = max(settings.eqLow, settings.eqMid, settings.eqHigh) <= 0
        if let preset = settings.reverb.preset {
            if currentPreset != settings.reverb { reverb.loadFactoryPreset(preset) }
            reverb.wetDryMix = Float(max(0, min(1, settings.reverbMix)) * 100)
            reverb.bypass = settings.reverbMix <= 0
        } else {
            reverb.wetDryMix = 0
            reverb.bypass = true
        }
        currentPreset = settings.reverb
    }
}
