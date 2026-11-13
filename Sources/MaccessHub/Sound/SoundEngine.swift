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
    /// other off, progress beeps use a single node so each beep cuts the last.
    private static let plainVoices: [SoundBus: Int] = [.events: 6, .keys: 4, .focus: 3, .progress: 1]
    /// HRTF players per group.
    private static let spatialVoices: [SoundBus: Int] = [.focus: 5, .progress: 1]

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
            pools[bus] = PlayerPool(plain)
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
        startIfNeeded()
        log.info("Engine rebuilt: running=\(self.engine.isRunning, privacy: .public) output \(self.engine.outputNode.outputFormat(forBus: 0).sampleRate, privacy: .public) Hz")
    }

    /// Stops the engine and drops anything queued, so nothing plays late.
    func suspend() {
        guard !suspended else { return }
        suspended = true
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

    /// Returns whether the engine is running and the players can take buffers.
    @discardableResult
    private func startIfNeeded() -> Bool {
        guard !suspended else { return false }
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
        // `AVAudioPlayerNode.play()` raises an Objective-C exception (which
        // Swift cannot catch) if the engine is not running, and the engine can
        // stop again right after starting while the device changes.
        guard engine.isRunning else { return false }
        // Player nodes stay running. Scheduling a buffer with `.interrupts`
        // on a running node costs microseconds; `stop()` and `play()` each
        // block for an IO cycle (5–12 ms measured), so they are avoided on the
        // playback path.
        for node in allNodes + allSpatialNodes where !node.isPlaying { node.play() }
        return true
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
        node.scheduleBuffer(buffer, at: nil, options: [.interrupts], completionHandler: nil)
        return Double(buffer.frameLength) / buffer.format.sampleRate
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
        node.scheduleBuffer(buffer, at: nil, options: [.interrupts], completionHandler: nil)
        return Double(buffer.frameLength) / buffer.format.sampleRate
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

    /// NVDA's beep, ported from nvdaHelper/local/beeps.cpp: a sine doubled and
    /// hard-clipped (the source of its slightly buzzy timbre), no envelope, and
    /// the length rounded up to a whole number of cycles so it ends at a zero
    /// crossing. Amplitude 14000/32767 at full pan; NVDA's default pan of 50
    /// corresponds to a volume of 0.5 here.
    private func toneBuffer(frequency: Double, duration: TimeInterval, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let key = "\(Int(frequency.rounded()))/\(Int(duration * 1000))/\(format.channelCount)"
        lock.lock(); if let cached = toneBuffers[key] { lock.unlock(); return cached }; lock.unlock()
        let rate = format.sampleRate
        let samplesPerCycle = max(1, Int(rate / frequency))
        var totalSamples = Int(duration * rate)
        totalSamples += samplesPerCycle - (totalSamples % samplesPerCycle)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(totalSamples)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(totalSamples)
        let sinFreq = (2.0 * Double.pi) / (rate / frequency)
        let amplitude: Float = 14000.0 / 32767.0
        for i in 0..<totalSamples {
            let sample = Float(min(max(sin(Double(i % Int(rate)) * sinFreq) * 2.0, -1.0), 1.0)) * amplitude
            for channel in 0..<Int(format.channelCount) { buffer.floatChannelData![channel][i] = sample }
        }
        lock.lock(); toneBuffers[key] = buffer; lock.unlock()
        return buffer
    }

    /// Plays a progress beep through the Progress group, binaurally at
    /// `position` when given, otherwise plain.
    func playTone(frequency: Double, duration: TimeInterval = 0.04, volume: Float, at position: AVAudio3DPoint?) {
        guard let buffer = toneBuffer(frequency: frequency, duration: duration,
                                      format: position == nil ? format : monoFormat),
              let plain = pools[.progress]?.nodes.first, let spatial = spatialPools[.progress]?.nodes.first,
              startIfNeeded() else { return }
        // One node per path: scheduling with .interrupts on it cuts the previous beep.
        let node = position == nil ? plain : spatial
        if let position { node.position = position }
        node.volume = max(0, min(1, volume))
        node.scheduleBuffer(buffer, at: nil, options: [.interrupts], completionHandler: nil)
    }

    func stopAll() {
        for node in allNodes + allSpatialNodes { node.stop() }
    }

    /// Silences whatever is playing in one group (used to stop a preview).
    /// The players are restarted at once so the next sound is still instant.
    func stop(_ bus: SoundBus) {
        let nodes = (pools[bus]?.nodes ?? []) + (spatialPools[bus]?.nodes ?? [])
        for node in nodes { node.stop() }
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
