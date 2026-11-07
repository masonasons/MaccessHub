import AVFoundation
import Foundation
import Observation

/// Short previews for the Sound Processing page. Nothing here plays unless the
/// user presses a button; pressing the same button again stops it, and every
/// preview is under about four seconds. Settings changes apply to the engine
/// immediately, so moving a slider during a preview changes what is heard.
@MainActor
@Observable
final class BusPreviewer {
    enum Kind { case sample, context }

    /// What is playing now, for the buttons' labels.
    private(set) var playing: (bus: SoundBus, kind: Kind)?

    @ObservationIgnored private var pending: [DispatchWorkItem] = []
    @ObservationIgnored private unowned let app: AppController

    init(app: AppController) { self.app = app }

    func isPlaying(_ bus: SoundBus, _ kind: Kind) -> Bool {
        playing?.bus == bus && playing?.kind == kind
    }

    /// Starts the preview, or stops it if that same preview is already playing.
    func toggle(_ bus: SoundBus, _ kind: Kind) {
        if isPlaying(bus, kind) { stop(); return }
        stop()
        let steps = kind == .sample ? sample(bus) : context(bus)
        guard !steps.isEmpty else {
            app.speaker.speak("No sounds available for \(bus.title.lowercased()).")
            return
        }
        playing = (bus, kind)
        for (delay, action) in steps {
            let item = DispatchWorkItem(block: action)
            pending.append(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }
        // Clear the playing state once the last sound and a reverb tail are done.
        let last = steps.map(\.0).max() ?? 0
        let end = DispatchWorkItem { [weak self] in
            self?.pending.removeAll()
            self?.playing = nil
        }
        pending.append(end)
        DispatchQueue.main.asyncAfter(deadline: .now() + last + 1.2, execute: end)
    }

    /// Cancels anything still to come and silences the group being previewed.
    func stop() {
        pending.forEach { $0.cancel() }
        pending.removeAll()
        if let bus = playing?.bus { app.engine.stop(bus) }
        playing = nil
    }

    // MARK: Sequences

    private typealias Step = (TimeInterval, () -> Void)

    private var data: SettingsData { app.settings.data }

    private func url(_ id: String) -> URL? {
        SoundEvent.byID[id].flatMap { app.scheme.url(for: $0) }
    }

    private func event(_ id: String, at time: TimeInterval) -> Step? {
        guard let url = url(id) else { return nil }
        let volume = Float(data.eventSounds.volume)
        return (time, { [app] in app.engine.play(url, volume: volume, bus: .events) })
    }

    /// A focus sound as the real feature plays it: placed on screen when HRTF
    /// is on (`x` runs 0...1 from the left of the desktop), plain otherwise.
    private func focus(_ id: String, x: CGFloat, at time: TimeInterval) -> Step? {
        guard let url = url(id) else { return nil }
        let volume = Float(data.focusSounds.volume)
        if data.focusSounds.spatial {
            let desktop = SpatialMapper.desktopBounds()
            let frame = CGRect(x: desktop.minX + desktop.width * x, y: desktop.midY, width: 1, height: 1)
            let position = SpatialMapper.position(for: frame, in: desktop)
            return (time, { [app] in app.engine.playSpatial(url, volume: volume, at: position, bus: .focus) })
        }
        return (time, { [app] in app.engine.play(url, volume: volume, bus: .focus, exclusive: true) })
    }

    private func key(_ id: String, at time: TimeInterval) -> Step? {
        guard let url = url(id) else { return nil }
        let volume = Float(data.keyClicks.volume)
        return (time, { [app] in app.engine.play(url, volume: volume, bus: .keys, exclusive: true) })
    }

    /// A progress beep the way the real feature makes it, from the centre when HRTF is on.
    private func beep(percent: Int, at time: TimeInterval) -> Step {
        let progress = data.progress
        let frequency = Double(progress.beepMinHz) * pow(2, Double(percent) / 25)
        let position: AVAudio3DPoint? = data.focusSounds.spatial ? SpatialMapper.center : nil
        let volume = Float(progress.beepVolume)
        return (time, { [app] in
            app.engine.playTone(frequency: frequency, duration: 0.04, volume: volume, at: position)
        })
    }

    /// One representative sound (a few for clicks and beeps, which are too short to judge alone).
    private func sample(_ bus: SoundBus) -> [Step] {
        switch bus {
        case .events:
            let id = url("system.login") != nil ? "system.login"
                : SoundEvent.all.first { $0.group != .keys && $0.group != .focus && url($0.id) != nil }?.id
            return [id.flatMap { event($0, at: 0) }].compactMap { $0 }
        case .focus:
            return [focus("focus.button", x: 0.5, at: 0)].compactMap { $0 }
        case .keys:
            return [key("key.lower", at: 0), key("key.lower", at: 0.25), key("key.lower", at: 0.5)].compactMap { $0 }
        case .progress:
            return [beep(percent: 0, at: 0), beep(percent: 50, at: 0.3), beep(percent: 100, at: 0.6)]
        }
    }

    /// A few seconds of everyday use.
    private func context(_ bus: SoundBus) -> [Step] {
        switch bus {
        case .events:
            // An app opens, Wi-Fi connects, the app quits.
            return [event("application.launched", at: 0),
                    event("network.wifiConnected", at: 1.0),
                    event("application.terminated", at: 2.0)].compactMap { $0 }
        case .focus:
            // Tabbing through a dialog from left to right.
            let ids = ["focus.editableText", "focus.checkbox", "focus.comboBox", "focus.link", "focus.button", "focus.button"]
            return ids.enumerated().compactMap { i, id in
                focus(id, x: 0.15 + 0.7 * CGFloat(i) / CGFloat(ids.count - 1), at: Double(i) * 0.4)
            }
        case .keys:
            // "Hi there," with a typo fixed, then Return, at a natural pace.
            let typed = "Hi thre\u{8}\u{8}ere,\n"
            var time = 0.0
            var steps: [Step] = []
            for ch in typed {
                let id: String
                switch ch {
                case " ": id = "key.space"
                case "\n": id = "key.enter"
                case "\u{8}": id = "key.delete"
                case ",": id = "key.punctuation"
                default: id = ch.isUppercase ? "key.upper" : "key.lower"
                }
                if let step = key(id, at: time) { steps.append(step) }
                time += 0.1 + Double.random(in: -0.035...0.06)
            }
            return steps
        case .progress:
            // A bar filling from 0 to 100 percent.
            return stride(from: 0, through: 100, by: 5).enumerated().map { i, percent in
                beep(percent: percent, at: Double(i) * 0.1)
            }
        }
    }
}
