import AVFoundation
import CoreAudio
import Foundation
import os

/// Low-latency, polyphonic sample player built on AVAudioEngine.
///
/// Every file is decoded once into a PCM buffer in the engine's common format,
/// then scheduled on one of a small pool of player nodes. Each sound group
/// (`SoundBus`) has its own players and its own volume, EQ and reverb chain.
/// Key clicks use
/// `exclusive: true` so a rapid retype cuts off the previous click the way
/// the original spoon's `stop():play()` did.
final class SoundEngine {
    private let log = Logger(subsystem: "com.maccesshub.app", category: "audio")
    private let engine = AVAudioEngine()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    private let monoFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    /// Players in the Progress group, plain and spatial. A Pleasant beep fades
    /// out on its own, so rather than cutting it (a click at full level) each
    /// new one starts on the next of these and the old one finishes its fade.
    /// Three cover beeps up to 100 ms arriving every 40 ms. Classic beeps use
    /// only the first, cut each time, as NVDA does.
    static let beepVoices = 3
    private var buffers: [URL: AVAudioPCMBuffer] = [:]
    private var monoBuffers: [URL: AVAudioPCMBuffer] = [:]
    /// One processing chain (volume, EQ, reverb) per sound group.
    private var chains: [SoundBus: SoundBusChain] = [:]
    /// Plain (stereo) players per group.
    private var pools: [SoundBus: PlayerPool] = [:]
    /// HRTF players per group. Each spatial group has its own environment node
    /// so its output lands on that group's chain: focus sounds go to the Focus
    /// chain and spatial progress beeps to the Progress chain.
    private var spatialPools: [SoundBus: PlayerPool] = [:]
    private var environments: [SoundBus: AVAudioEnvironmentNode] = [:]
    /// Every player node, for start, stop and rebuild.
    private var allNodes: [AVAudioPlayerNode] = []
    private var allSpatialNodes: [AVAudioPlayerNode] = []
    /// Disk sounds: batches queue one after another here instead of cutting
    /// each other off. Feeds the Disk group's chain; the group has no pool.
    private let streamNode = AVAudioPlayerNode()
    /// Batches scheduled on `streamNode` and not yet played. Guarded by `lock`.
    private var streamQueued = 0
    /// Bumped whenever `streamNode` is stopped, so completions from before don't count.
    private var streamGeneration = 0
    private let lock = NSLock()
    private var configObserver: NSObjectProtocol?
    private var defaultDeviceListener: AudioObjectPropertyListenerBlock?
    private var meterPeak: Float = 0
    /// Peak that reached the mixer output during the last metered play (diagnostics).
    private(set) var lastPeak: Float = -1
    private var meterUntil: TimeInterval = 0
    private var meterArmed = false
    /// Set while the Mac sleeps. The audio hardware powers down and comes back
    /// (several times through dark wakes), so the engine is left stopped and
    /// configuration changes are ignored until `resume()`.
    private var suspended = false
    /// After a player fails to start, sounds are dropped until this uptime and
    /// the engine is rebuilt then. See `playerFailed(_:)`.
    private var retryAt: TimeInterval = 0
    /// The last wait between retries; doubles on each failure, up to 30 s.
    private var retryDelay: TimeInterval = 0
    private var retryWork: DispatchWorkItem?
    /// Which Progress player the next Pleasant beep uses.
    private var nextBeepVoice = 0

    /// Players for one group. Round-robin, except that an exclusive sound reuses
    /// the node it last played on so a repeat cuts off the previous copy.
    private final class PlayerPool {
        let nodes: [AVAudioPlayerNode]
        private var next = 0
        private var active: [URL: AVAudioPlayerNode] = [:]
        init(_ nodes: [AVAudioPlayerNode]) { self.nodes = nodes }
        /// Caller holds the engine lock.
        func node(for url: URL, exclusive: Bool) -> AVAudioPlayerNode {
            let node: AVAudioPlayerNode
            if exclusive, let previous = active[url] {
                node = previous
            } else {
                node = nodes[next]
                next = (next + 1) % nodes.count
            }
            active[url] = node
            return node
        }
    }

    /// Plain players per group: events overlap the most, key clicks cut each
    /// other off, progress beeps get `beepVoices` (see there).
    private static let plainVoices: [SoundBus: Int] = [.events: 6, .keys: 4, .focus: 3, .progress: beepVoices, .disk: 0]
    /// HRTF players per group.
    private static let spatialVoices: [SoundBus: Int] = [.focus: 5, .progress: beepVoices]

    init() {
        for bus in SoundBus.allCases {
            let chain = SoundBusChain()
            chain.attach(to: engine, destination: engine.mainMixerNode, format: format)
            chains[bus] = chain

            var plain: [AVAudioPlayerNode] = []
            for _ in 0..<(Self.plainVoices[bus] ?? 1) {
                let node = AVAudioPlayerNode()
                engine.attach(node)
                engine.connect(node, to: chain.input, format: format)
                plain.append(node)
            }
            if !plain.isEmpty { pools[bus] = PlayerPool(plain) }
            allNodes += plain

            // Spatial players. The environment node only spatialises mono inputs.
            guard let count = Self.spatialVoices[bus] else { continue }
            let environment = AVAudioEnvironmentNode()
            engine.attach(environment)
            engine.connect(environment, to: chain.input, format: format)
            environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
            environment.listenerVectorOrientation = AVAudio3DVectorOrientation(
                forward: AVAudio3DVector(x: 0, y: 0, z: -1), up: AVAudio3DVector(x: 0, y: 1, z: 0))
            environment.distanceAttenuationParameters.referenceDistance = 1
            environment.distanceAttenuationParameters.maximumDistance = 100
            environment.outputType = .headphones
            environments[bus] = environment
            var spatial: [AVAudioPlayerNode] = []
            for _ in 0..<count {
                let node = AVAudioPlayerNode()
                engine.attach(node)
                engine.connect(node, to: environment, format: monoFormat)
                node.renderingAlgorithm = .HRTFHQ
                node.sourceMode = .pointSource
                spatial.append(node)
            }
            spatialPools[bus] = PlayerPool(spatial)
            allSpatialNodes += spatial
        }
        engine.attach(streamNode)
        engine.connect(streamNode, to: chains[.disk]?.input ?? engine.mainMixerNode, format: format)
        allNodes.append(streamNode)
        setReverb(.smallRoom)
        // Self-check meter: after each play, log the peak that actually reached the output.
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 2048, format: nil) { [weak self] buffer, _ in
            guard let self, meterArmed, let data = buffer.floatChannelData else { return }
            var peak: Float = 0
            for ch in 0..<Int(buffer.format.channelCount) {
                for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(data[ch][i])) }
            }
            meterPeak = max(meterPeak, peak)
            if ProcessInfo.processInfo.systemUptime > meterUntil {
                meterArmed = false
                let p = meterPeak
                lastPeak = p
                DispatchQueue.main.async { self.log.debug("output peak after play: \(p, privacy: .public)") }
            }
        }
        engine.prepare()
        startIfNeeded()
        // The engine stops when the default output device changes (exactly what
        // the audio-switch feature does). Restart it so the next sound plays.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.log.info("Audio configuration changed, restarting engine")
            self?.rebuild()
        }
        // The engine does not always follow a change of default output device
        // on its own (it can stay bound to a device that is gone or no longer
        // default, and plays into silence). Rebind whenever the default changes.
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.rebuild() }
        }
        defaultDeviceListener = listener
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, listener)
    }

    /// Applies a group's volume, EQ and reverb. Takes effect immediately, on
    /// sounds already playing too.
    func configure(_ bus: SoundBus, with settings: AudioBusSettings) {
        chains[bus]?.apply(settings)
    }

    /// Stops the engine, points its output at the current default device, and
    /// starts it again. Connections and attached nodes survive a stop.
    private func rebuild() {
        guard !suspended else { return }
        engine.stop()
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
           device != kAudioObjectUnknown, engine.outputNode.auAudioUnit.deviceID != device {
            do {
                try engine.outputNode.auAudioUnit.setDeviceID(device)
                log.info("Audio output rebound to device \(device, privacy: .public)")
            } catch {
                log.error("Could not rebind audio output: \(error.localizedDescription, privacy: .public)")
            }
        }
        engine.prepare()
        // Player nodes can report isPlaying after a restart while being idle;
        // cycle them so the state is real.
        for node in allNodes + allSpatialNodes { node.stop() }
        resetStream()
        startIfNeeded()
        log.info("Engine rebuilt: running=\(self.engine.isRunning, privacy: .public) output \(self.engine.outputNode.outputFormat(forBus: 0).sampleRate, privacy: .public) Hz")
    }

    /// Stops the engine and drops anything queued, so nothing plays late.
    func suspend() {
        guard !suspended else { return }
        suspended = true
        clearRetry()
        stopAll()
        engine.stop()
        log.info("Engine suspended for sleep")
    }

    func resume() {
        guard suspended else { return }
        suspended = false
        rebuild()
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
    }

    /// Frames per IO cycle requested from the output device. 256 at 48 kHz is
    /// about 5 ms; the macOS default of 512 is about 11 ms.
    private let ioBufferFrames: UInt32 = 256

    /// A running engine keeps the output device open, and Core Audio holds a
    /// PreventUserIdleSystemSleep assertion for it, so the Mac never sleeps on
    /// its own. Pause the engine after this long without a sound; the next
    /// sound starts it again. 0 never pauses it.
    var idleTimeout: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return idleSeconds }
        set {
            lock.lock()
            guard newValue != idleSeconds else { lock.unlock(); return }
            idleSeconds = newValue
            // A check already waiting was timed for the old value; start over.
            idleCheck?.cancel()
            idleCheck = nil
            lock.unlock()
            scheduleIdleCheck(after: 0)
        }
    }
    // Key clicks play from their own queue, so the idle state below is
    // guarded by `lock`. The check itself always runs on the main queue.
    private var idleSeconds: TimeInterval = 30
    /// Uptime at which the last scheduled sound finishes.
    private var busyUntil: TimeInterval = 0
    private var idleCheck: DispatchWorkItem?

    /// Notes that a sound plays until `until`, so the idle check leaves the engine alone.
    private func markBusy(until: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock(); busyUntil = max(busyUntil, until); lock.unlock()
    }

    /// Returns whether the engine is running and the players can take buffers.
    @discardableResult
    private func startIfNeeded() -> Bool {
        guard !suspended, !waitingToRetry else { return false }
        // Before the running check, so an idle check on the main queue can't
        // pause the engine between that check and the buffer being scheduled.
        markBusy()
        if !engine.isRunning {
            // While the output device is going away (sleep, unplugging) its
            // format reads as empty and starting would fail or half-succeed.
            let output = engine.outputNode.outputFormat(forBus: 0)
            guard output.channelCount > 0, output.sampleRate > 0 else {
                log.error("Audio output unavailable, not starting engine")
                return false
            }
            do {
                try engine.start()
                applyIOBufferSize()
            } catch {
                log.error("Could not start audio engine: \(error.localizedDescription)")
                return false
            }
        }
        // `AVAudioPlayerNode.play()` raises an Objective-C exception if the
        // engine is not running, and the engine can stop again right after
        // starting while the device changes.
        guard engine.isRunning else { return false }
        // Player nodes stay running. Scheduling a buffer with `.interrupts`
        // on a running node costs microseconds; `stop()` and `play()` each
        // block for an IO cycle (5–12 ms measured), so they are avoided on the
        // playback path.
        //
        // A running engine is not enough, though. Just after wake the output
        // device can be open but not yet running its IO cycles ("IO is still
        // disabled after waiting" in the log). `play()` then waits several
        // seconds for a render cycle and raises "player did not see an IO
        // cycle", which took the app down when it happened off the main
        // thread. Catch it, drop the sound and try again a little later.
        for node in allNodes + allSpatialNodes where !node.isPlaying {
            do {
                try ObjCExceptionCatcher.run { node.play() }
            } catch {
                playerFailed(error)
                return false
            }
        }
        lock.lock(); retryDelay = 0; lock.unlock()
        scheduleIdleCheck(after: idleTimeout)
        return true
    }

    /// Pauses the engine once nothing has played for `idleTimeout`. Pause, not
    /// stop: it releases the device but keeps the graph and the player nodes
    /// running, so restarting costs no more than the first start did.
    private func scheduleIdleCheck(after delay: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        guard idleCheck == nil, idleSeconds > 0 else { return }
        let check = DispatchWorkItem { [weak self] in
            guard let self else { return }
            lock.lock()
            idleCheck = nil
            let idle = ProcessInfo.processInfo.systemUptime - busyUntil
            let timeout = idleSeconds
            lock.unlock()
            if idle < timeout {
                scheduleIdleCheck(after: timeout - idle)
            } else if !suspended, engine.isRunning {
                engine.pause()
                log.debug("Audio engine paused after \(Int(idle), privacy: .public) s idle")
            }
        }
        idleCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: check)
    }

    /// Whether an earlier failure is still being waited out.
    private var waitingToRetry: Bool {
        lock.lock(); defer { lock.unlock() }
        return ProcessInfo.processInfo.systemUptime < retryAt
    }

    /// A player could not start or take a buffer. Stops the engine, drops
    /// sounds for a moment (each failed `play()` blocks for seconds, so trying
    /// again on every sound would stall the app) and rebuilds the engine
    /// when the wait is over. The wait doubles on each failure in a row.
    private func playerFailed(_ error: Error) {
        lock.lock()
        retryDelay = min(max(retryDelay * 2, 1), 30)
        let delay = retryDelay
        retryAt = ProcessInfo.processInfo.systemUptime + delay
        lock.unlock()
        log.error("Audio player failed (\(error.localizedDescription, privacy: .public)); dropping sounds and retrying in \(delay, privacy: .public) s")
        engine.stop()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            retryWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                retryWork = nil
                lock.lock(); retryAt = 0; lock.unlock()
                rebuild()
            }
            retryWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func clearRetry() {
        retryWork?.cancel()
        retryWork = nil
        lock.lock(); retryAt = 0; retryDelay = 0; lock.unlock()
    }

    /// Schedules `buffer` on `node`, cutting off whatever it was playing.
    /// Returns false if AVFoundation raised (a detached node, or a format the
    /// node's connection no longer has after a device change).
    private func schedule(_ buffer: AVAudioPCMBuffer, on node: AVAudioPlayerNode) -> Bool {
        do {
            try ObjCExceptionCatcher.run {
                node.scheduleBuffer(buffer, at: nil, options: [.interrupts], completionHandler: nil)
            }
            return true
        } catch {
            playerFailed(error)
            return false
        }
    }

    private func applyIOBufferSize() {
        let device = engine.outputNode.auAudioUnit.deviceID
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize,
                                                 mScope: kAudioObjectPropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var frames = ioBufferFrames
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames)
        if status != noErr { log.error("Could not set IO buffer size: \(status)") }
    }

    /// Decodes the file (cached). Safe to call from any thread.
    @discardableResult
    func preload(_ url: URL) -> AVAudioPCMBuffer? {
        lock.lock()
        if let cached = buffers[url] { lock.unlock(); return cached }
        lock.unlock()
        guard let buffer = Self.decode(url, to: format) else {
            log.error("Could not decode \(url.lastPathComponent)")
            return nil
        }
        lock.lock()
        buffers[url] = buffer
        lock.unlock()
        return buffer
    }

    /// Drops cached buffers for files that are no longer referenced.
    func retainOnly(_ urls: Set<URL>) {
        lock.lock()
        buffers = buffers.filter { urls.contains($0.key) }
        monoBuffers = monoBuffers.filter { urls.contains($0.key) }
        lock.unlock()
    }

    private func armMeter() {
        meterPeak = 0
        meterUntil = ProcessInfo.processInfo.systemUptime + 0.25
        meterArmed = true
    }

    /// Plays the file through `bus`'s volume, EQ and reverb. `volume` is 0...1
    /// and multiplies with the group's volume. Returns the sound's duration in seconds.
    @discardableResult
    func play(_ url: URL, volume: Float, bus: SoundBus, exclusive: Bool = false) -> TimeInterval {
        // A buffer scheduled on a stopped engine waits in its node and plays
        // when audio comes back, together with every other queued sound.
        guard startIfNeeded(), let buffer = preload(url), let pool = pools[bus] else { return 0 }
        lock.lock()
        let node = pool.node(for: url, exclusive: exclusive)
        lock.unlock()

        node.volume = max(0, min(1, volume))
        guard schedule(buffer, on: node) else { return 0 }
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate
        markBusy(until: ProcessInfo.processInfo.systemUptime + duration)
        return duration
    }

    enum Reverb: String, Codable, CaseIterable, Identifiable {
        case none, smallRoom, mediumRoom, hall
        var id: String { rawValue }
        var title: String {
            switch self {
            case .none: return "None"
            case .smallRoom: return "Small room"
            case .mediumRoom: return "Medium room"
            case .hall: return "Hall"
            }
        }
    }

    /// `amount` is 0...1; 0.5 is the preset's natural level, 1 is twice as wet.
    func setReverb(_ reverb: Reverb, amount: Double = 0.5) {
        // The environment node hosts the reverb, but each source decides how
        // much of itself it sends there (`reverbBlend`, 0 by default). Both are
        // needed, or the presets do nothing.
        // Every environment node (focus and progress) gets the same room, as
        // the single shared one did before sound groups existed.
        let blend: Float
        for environment in environments.values {
            let params = environment.reverbParameters
            switch reverb {
            case .none:
                params.enable = false
            case .smallRoom:
                params.enable = true; params.loadFactoryReverbPreset(.smallRoom); params.level = -6
            case .mediumRoom:
                params.enable = true; params.loadFactoryReverbPreset(.mediumRoom); params.level = -4
            case .hall:
                params.enable = true; params.loadFactoryReverbPreset(.largeHall); params.level = -2
            }
        }
        switch reverb {
        case .none: blend = 0
        case .smallRoom: blend = 0.35
        case .mediumRoom: blend = 0.45
        case .hall: blend = 0.55
        }
        let scaled = min(1, blend * Float(max(0, min(1, amount))) * 2)
        for node in allSpatialNodes { node.reverbBlend = scaled }
    }

    /// Plays the file binaurally at a position on the unit sphere around the
    /// listener (+x right, +y up, -z forward), through `bus`'s processing.
    /// Groups without spatial players fall back to plain playback.
    @discardableResult
    func playSpatial(_ url: URL, volume: Float, at position: AVAudio3DPoint, bus: SoundBus = .focus,
                     exclusive: Bool = true) -> TimeInterval {
        guard let pool = spatialPools[bus] else { return play(url, volume: volume, bus: bus, exclusive: exclusive) }
        guard startIfNeeded(), let buffer = preloadMono(url) else { return 0 }
        lock.lock()
        let node = pool.node(for: url, exclusive: exclusive)
        lock.unlock()

        node.position = position
        node.volume = max(0, min(1, volume))
        guard schedule(buffer, on: node) else { return 0 }
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate
        markBusy(until: ProcessInfo.processInfo.systemUptime + duration)
        return duration
    }

    private func preloadMono(_ url: URL) -> AVAudioPCMBuffer? {
        lock.lock()
        if let cached = monoBuffers[url] { lock.unlock(); return cached }
        lock.unlock()
        guard let buffer = Self.decode(url, to: monoFormat) else {
            log.error("Could not decode \(url.lastPathComponent) as mono")
            return nil
        }
        lock.lock()
        monoBuffers[url] = buffer
        lock.unlock()
        return buffer
    }

    private var toneBuffers: [String: AVAudioPCMBuffer] = [:]

    /// NVDA's beep, after nvdaHelper/local/beeps.cpp: a sine doubled and
    /// hard-clipped (the source of its slightly buzzy timbre), amplitude
    /// 14000/32767 at full pan; NVDA's default pan of 50 corresponds to a volume
    /// of 0.5 here.
    ///
    /// Two departures from the C++, both to stop it clicking:
    /// - The length is a whole number of *true* cycles. beeps.cpp rounds the
    ///   samples per cycle down to an integer, so at 48 kHz the beep stops
    ///   mid-wave (at 880 and 1760 Hz it ends at full level): an audible click
    ///   at the end of most beeps.
    /// - A 2 ms raised-cosine fade at each end, so the edges are exactly zero
    ///   whatever the pitch. Far too short to change the timbre.
    private func toneBuffer(frequency: Double, duration: TimeInterval, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let key = Tone.classic(frequency: frequency, duration: duration).cacheKey(channels: format.channelCount)
        lock.lock(); if let cached = toneBuffers[key] { lock.unlock(); return cached }; lock.unlock()
        let samples = Self.classicBeepSamples(frequency: frequency, duration: duration, sampleRate: format.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for channel in 0..<Int(format.channelCount) {
            samples.withUnsafeBufferPointer { src in
                buffer.floatChannelData![channel].update(from: src.baseAddress!, count: samples.count)
            }
        }
        lock.lock(); toneBuffers[key] = buffer; lock.unlock()
        return buffer
    }

    /// The Classic beep's samples (see `toneBuffer`). Static and free of the
    /// engine so it can be checked on its own.
    static func classicBeepSamples(frequency: Double, duration: TimeInterval, sampleRate rate: Double) -> [Float] {
        let f = max(1, frequency)
        let cycles = max(1, (duration * f).rounded(.up))
        let count = max(2, Int((cycles * rate / f).rounded()))
        let amplitude = 14000.0 / 32767.0
        let fade = max(1, min(count / 4, Int(rate * 0.002)))
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let phase = (Double(i) * f / rate).truncatingRemainder(dividingBy: 1)
            var s = min(max(sin(2 * Double.pi * phase) * 2.0, -1.0), 1.0) * amplitude
            let edge = min(i, count - 1 - i)
            if edge < fade { s *= 0.5 * (1 - cos(Double.pi * Double(edge) / Double(fade))) }
            out[i] = Float(s)
        }
        return out
    }

    /// Plays a beep, binaurally at `position` when given, otherwise through the plain mixer.
    func playTone(frequency: Double, duration: TimeInterval = 0.04, volume: Float, at position: AVAudio3DPoint?) {
        playTone(.classic(frequency: frequency, duration: duration), volume: volume, pan: 0, at: position)
    }

    /// What a progress beep sounds like.
    struct Tone {
        var style: ProgressBeepStyle
        var waveform: BeepWaveform = .sine
        var envelope: BeepEnvelope = .cosine
        var frequency: Double
        var duration: TimeInterval

        static func classic(frequency: Double, duration: TimeInterval = 0.04) -> Tone {
            Tone(style: .classic, frequency: frequency, duration: duration)
        }

        /// Everything that changes the samples, so differently shaped beeps never share a cache entry.
        func cacheKey(channels: AVAudioChannelCount) -> String {
            let ms = Int((duration * 1000).rounded())
            switch style {
            case .classic: return "classic/\(Int(frequency.rounded()))/\(ms)/\(channels)"
            case .pleasant: return "pleasant/\(waveform.rawValue)/\(envelope.rawValue)/\(Int(frequency.rounded()))/\(ms)/\(channels)"
            }
        }
    }

    private func pleasantBuffer(_ tone: Tone, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let key = tone.cacheKey(channels: format.channelCount)
        lock.lock(); if let cached = toneBuffers[key] { lock.unlock(); return cached }; lock.unlock()
        let samples = ToneSynth.render(waveform: tone.waveform, envelope: tone.envelope,
                                       frequency: tone.frequency, duration: tone.duration,
                                       sampleRate: format.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for channel in 0..<Int(format.channelCount) {
            samples.withUnsafeBufferPointer { src in
                buffer.floatChannelData![channel].update(from: src.baseAddress!, count: samples.count)
            }
        }
        lock.lock()
        // Settings can be changed freely, so keep the cache from growing without bound.
        if toneBuffers.count > 600 { toneBuffers.removeAll() }
        toneBuffers[key] = buffer
        lock.unlock()
        return buffer
    }

    /// Plays a beep, binaurally at `position` when given, otherwise through the
    /// plain mixer panned by `pan` (-1 left ... 1 right; ignored when spatial).
    func playTone(_ tone: Tone, volume: Float, pan: Float, at position: AVAudio3DPoint?) {
        let format = position == nil ? self.format : monoFormat
        let buffer: AVAudioPCMBuffer?
        switch tone.style {
        case .classic: buffer = toneBuffer(frequency: tone.frequency, duration: tone.duration, format: format)
        case .pleasant: buffer = pleasantBuffer(tone, format: format)
        }
        guard let buffer,
              let players = (position == nil ? pools : spatialPools)[.progress]?.nodes, !players.isEmpty,
              startIfNeeded() else { return }
        let node: AVAudioPlayerNode
        switch tone.style {
        case .classic:
            // One node per path: scheduling with .interrupts on it cuts the previous beep.
            node = players[0]
        case .pleasant:
            // Rotate through the Progress players so the previous beep fades out by itself.
            lock.lock()
            nextBeepVoice = (nextBeepVoice + 1) % players.count
            let index = nextBeepVoice
            lock.unlock()
            node = players[index]
        }
        if let position { node.position = position } else { node.pan = max(-1, min(1, pan)) }
        node.volume = max(0, min(1, volume))
        _ = schedule(buffer, on: node)
    }

    func stopAll() {
        for node in allNodes + allSpatialNodes { node.stop() }
        resetStream()
    }

    private func resetStream() {
        lock.lock(); streamQueued = 0; streamGeneration += 1; lock.unlock()
    }

    /// Plays interleaved 48 kHz stereo 16-bit samples on the stream player (disk
    /// sounds). With `interrupt` it cuts off whatever that player has (a
    /// preview). Otherwise the batch queues after the one playing, and is
    /// dropped while two are already waiting, so a busy disk never builds up a
    /// backlog that keeps clicking after the activity stops.
    func playStream(_ pcm: [Int16], interrupt: Bool) {
        lock.lock()
        let full = !interrupt && streamQueued >= 2
        lock.unlock()
        guard !full, !pcm.isEmpty, startIfNeeded(),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(pcm.count / 2)),
              let channels = buffer.floatChannelData else { return }
        buffer.frameLength = buffer.frameCapacity
        for frame in 0..<Int(buffer.frameLength) {
            channels[0][frame] = Float(pcm[2 * frame]) / 32768
            channels[1][frame] = Float(pcm[2 * frame + 1]) / 32768
        }
        lock.lock()
        if interrupt { streamQueued = 0; streamGeneration += 1 }
        streamQueued += 1
        let queued = streamQueued
        let token = streamGeneration
        lock.unlock()
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate
        markBusy(until: ProcessInfo.processInfo.systemUptime + duration * Double(queued))
        do {
            try ObjCExceptionCatcher.run {
                streamNode.scheduleBuffer(buffer, at: nil, options: interrupt ? [.interrupts] : [],
                                          completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    guard let self else { return }
                    lock.lock()
                    if token == streamGeneration { streamQueued = max(0, streamQueued - 1) }
                    lock.unlock()
                }
            }
        } catch {
            playerFailed(error)
        }
    }

    /// Silences whatever is playing in one group (used to stop a preview).
    /// The players are restarted at once so the next sound is still instant.
    func stop(_ bus: SoundBus) {
        var nodes = (pools[bus]?.nodes ?? []) + (spatialPools[bus]?.nodes ?? [])
        if bus == .disk { nodes.append(streamNode) }
        for node in nodes { node.stop() }
        if bus == .disk { resetStream() }
        startIfNeeded()
    }

    private static func decode(_ url: URL, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let sourceFormat = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let source = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else { return nil }
        do { try file.read(into: source) } catch { return nil }
        if sourceFormat == format { return source }

        guard let converter = AVAudioConverter(from: sourceFormat, to: format) else { return nil }
        let ratio = format.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(frameCount) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .endOfStream
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return source
        }
        guard status != .error, error == nil else { return nil }
        return output
    }
}
