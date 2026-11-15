import Foundation

/// How progress beeps sound.
enum ProgressBeepStyle: String, Codable, CaseIterable, Identifiable {
    /// NVDA's own beep: a clipped sine, 40 ms, pitch doubling every 25 percent.
    case classic
    /// A softer beep with a chosen waveform, a fade in and out, and a pitch range.
    case pleasant
    var id: String { rawValue }
    var title: String {
        switch self {
        case .classic: return "Classic (NVDA)"
        case .pleasant: return "Pleasant"
        }
    }
}

enum BeepWaveform: String, Codable, CaseIterable, Identifiable {
    case sine, square, triangle, sawtooth, pulse, noise
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sine: return "Sine (pure and soft)"
        case .square: return "Square (hollow, like an old game)"
        case .triangle: return "Triangle (soft, a little brighter)"
        case .sawtooth: return "Sawtooth (bright and buzzy)"
        case .pulse: return "Pulse (thin and reedy)"
        case .noise: return "White noise (a rising hiss)"
        }
    }
}

enum BeepEnvelope: String, Codable, CaseIterable, Identifiable {
    case cosine, gaussian
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cosine: return "Smooth (gentle swell in and out)"
        case .gaussian: return "Bell (short, rounder peak in the middle)"
        }
    }
}

/// Renders the "Pleasant" progress beep as mono float samples. Pure and free of
/// AVFoundation so it can be checked outside the app.
///
/// Inspired by the NVDA add-on Pleasant Progress Bar; this is an independent
/// implementation, not a port of its code.
enum ToneSynth {
    /// Peak level each waveform is normalised to. Waveforms with more energy per
    /// unit of peak (square, pulse, noise) sit lower so they all sound about as
    /// loud as each other and as the classic beep. All well under 1.0.
    static func targetPeak(_ waveform: BeepWaveform) -> Float {
        switch waveform {
        case .sine, .triangle: return 0.6
        case .sawtooth: return 0.45
        case .square: return 0.35
        case .pulse: return 0.4
        case .noise: return 0.4
        }
    }

    /// Pitch for a percentage: low at 0, high at 100, on an exponential curve
    /// (the same shape as NVDA's, which doubles at a fixed rate).
    static func frequency(percent: Double, low: Double, high: Double) -> Double {
        let p = max(0, min(100, percent)) / 100
        let lo = max(1, low), hi = max(lo, high)
        return lo * pow(hi / lo, p)
    }

    static func render(waveform: BeepWaveform, envelope: BeepEnvelope,
                       frequency: Double, duration: TimeInterval, sampleRate: Double) -> [Float] {
        let count = max(2, Int((duration * sampleRate).rounded()))
        var out = [Float](repeating: 0, count: count)
        let dt = frequency / sampleRate // phase increment, in cycles per sample
        var phase = 0.0

        // Noise state: a fixed seed per pitch so a beep sounds the same every
        // time (and the cache stays honest), and a one-pole low-pass whose
        // cutoff follows the pitch so the noise audibly rises with the bar.
        var seed = UInt64(max(1, frequency.rounded())) &* 0x9E3779B97F4A7C15 | 1
        let cutoff = min(sampleRate * 0.45, frequency * 4)
        let alpha = 1 - exp(-2 * Double.pi * cutoff / sampleRate)
        var lp = 0.0

        for i in 0..<count {
            var s: Double
            switch waveform {
            case .sine:
                s = sin(2 * Double.pi * phase)
            case .triangle:
                s = 4 * abs(phase - 0.5) - 1 // +1 at 0, -1 at 0.5
            case .sawtooth:
                s = 2 * phase - 1 - polyBLEP(phase, dt)
            case .square:
                s = phase < 0.5 ? 1 : -1
                s += polyBLEP(phase, dt)
                s -= polyBLEP((phase + 0.5).truncatingRemainder(dividingBy: 1), dt)
            case .pulse:
                // 25% duty, DC removed so the fade does not thump.
                let duty = 0.25
                var v = phase < duty ? 1.0 : 0.0
                v += polyBLEP(phase, dt) * 0.5
                v -= polyBLEP((phase + 1 - duty).truncatingRemainder(dividingBy: 1), dt) * 0.5
                s = v - duty
            case .noise:
                seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
                let white = Double(seed >> 11) / Double(1 << 53) * 2 - 1
                lp += alpha * (white - lp)
                // Light tremolo at the pitch itself, so it carries a tone too.
                s = lp * (1 + 0.3 * sin(2 * Double.pi * phase))
            }
            out[i] = Float(s)
            phase += dt
            if phase >= 1 { phase -= 1 }
        }

        // Envelope, then normalise the peak.
        let n = Double(count - 1)
        var peak: Float = 0
        for i in 0..<count {
            let t = Double(i) / n
            out[i] *= Float(gain(envelope, at: t))
            peak = max(peak, abs(out[i]))
        }
        if peak > 0 {
            let scale = targetPeak(waveform) / peak
            for i in 0..<count { out[i] *= scale }
        }
        return out
    }

    /// Envelope gain at position t in 0...1. Both shapes are exactly 0 at the ends.
    static func gain(_ envelope: BeepEnvelope, at t: Double) -> Double {
        switch envelope {
        case .cosine:
            let fade = 0.45
            if t < fade { return 0.5 * (1 - cos(Double.pi * t / fade)) }
            if t > 1 - fade { return 0.5 * (1 - cos(Double.pi * (1 - t) / fade)) }
            return 1
        case .gaussian:
            // Bell centred on the middle, sigma a quarter of the length, lowered
            // so it reaches zero at the edges instead of stopping at 0.135.
            let sigma = 0.25
            let g = exp(-0.5 * pow((t - 0.5) / sigma, 2))
            let edge = exp(-0.5 * pow(0.5 / sigma, 2))
            return max(0, (g - edge) / (1 - edge))
        }
    }

    /// Band-limited step correction, which takes the harsh aliasing out of the
    /// square, sawtooth and pulse at high pitches.
    private static func polyBLEP(_ t: Double, _ dt: Double) -> Double {
        if t < dt {
            let x = t / dt
            return x + x - x * x - 1
        } else if t > 1 - dt {
            let x = (t - 1) / dt
            return x * x + x + x + 1
        }
        return 0
    }
}
