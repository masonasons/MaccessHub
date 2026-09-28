import AVFoundation
import CoreAudio
import Foundation
import os

/// Low-latency, polyphonic sample player built on AVAudioEngine.
///
/// Every file is decoded once into a PCM buffer in the engine's common format,
/// then scheduled on one of a small pool of player nodes. Key clicks use
/// `exclusive: true` so a rapid retype cuts off the previous click the way
/// the original spoon's `stop():play()` did.
final class SoundEngine {
    private let log = Logger(subsystem: "com.maccesshub.app", category: "audio")
    private let engine = AVAudioEngine()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    private let monoFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    private var nodes: [AVAudioPlayerNode] = []
    private var nextNode = 0
    private var buffers: [URL: AVAudioPCMBuffer] = [:]
    private var monoBuffers: [URL: AVAudioPCMBuffer] = [:]
    private var activeNode: [URL: AVAudioPlayerNode] = [:]
    /// HRTF path: mono players feeding an environment node that renders binaurally.
    private let environment = AVAudioEnvironmentNode()
    private var spatialNodes: [AVAudioPlayerNode] = []
    private var nextSpatialNode = 0
    private var activeSpatialNode: [URL: AVAudioPlayerNode] = [:]
    private let lock = NSLock()
    private var configObserver: NSObjectProtocol?

    init(voices: Int = 12) {
        for _ in 0..<voices {
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            nodes.append(node)
        }
        // Spatial pool. The environment node only spatialises mono inputs.
        engine.attach(environment)
        engine.connect(environment, to: engine.mainMixerNode, format: format)
        environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
        environment.listenerVectorOrientation = AVAudio3DVectorOrientation(
            forward: AVAudio3DVector(x: 0, y: 0, z: -1), up: AVAudio3DVector(x: 0, y: 1, z: 0))
        environment.distanceAttenuationParameters.referenceDistance = 1
        environment.distanceAttenuationParameters.maximumDistance = 100
        environment.outputType = .headphones
        for _ in 0..<6 {
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: environment, format: monoFormat)
            node.renderingAlgorithm = .HRTFHQ
            node.sourceMode = .pointSource
            spatialNodes.append(node)
        }
        setReverb(.smallRoom)
        engine.prepare()
        startIfNeeded()
        // The engine stops when the default output device changes (exactly what
        // the audio-switch feature does). Restart it so the next sound plays.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.log.info("Audio configuration changed, restarting engine")
            self?.startIfNeeded()
        }
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
    }

    /// Frames per IO cycle requested from the output device. 256 at 48 kHz is
    /// about 5 ms; the macOS default of 512 is about 11 ms.
    private let ioBufferFrames: UInt32 = 256

    private func startIfNeeded() {
        if !engine.isRunning {
            do {
                try engine.start()
                applyIOBufferSize()
            } catch {
                log.error("Could not start audio engine: \(error.localizedDescription)")
                return
            }
        }
        // Player nodes stay running. Scheduling a buffer with `.interrupts`
        // on a running node costs microseconds; `stop()` and `play()` each
        // block for an IO cycle (5–12 ms measured), so they are avoided on the
        // playback path.
        for node in nodes + spatialNodes where !node.isPlaying { node.play() }
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

    /// Plays the file. `volume` is 0...1. Returns the sound's duration in seconds.
    @discardableResult
    func play(_ url: URL, volume: Float, exclusive: Bool = false) -> TimeInterval {
        guard let buffer = preload(url) else { return 0 }
        lock.lock()
        let node: AVAudioPlayerNode
        if exclusive, let previous = activeNode[url] {
            node = previous
        } else {
            node = nodes[nextNode]
            nextNode = (nextNode + 1) % nodes.count
        }
        activeNode[url] = node
        lock.unlock()

        startIfNeeded()
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

    func setReverb(_ reverb: Reverb) {
        // The environment node hosts the reverb, but each source decides how
        // much of itself it sends there (`reverbBlend`, 0 by default). Both are
        // needed, or the presets do nothing.
        let params = environment.reverbParameters
        let blend: Float
        switch reverb {
        case .none:
            params.enable = false
            blend = 0
        case .smallRoom:
            params.enable = true; params.loadFactoryReverbPreset(.smallRoom); params.level = -6
            blend = 0.35
        case .mediumRoom:
            params.enable = true; params.loadFactoryReverbPreset(.mediumRoom); params.level = -4
            blend = 0.45
        case .hall:
            params.enable = true; params.loadFactoryReverbPreset(.largeHall); params.level = -2
            blend = 0.55
        }
        for node in spatialNodes { node.reverbBlend = blend }
    }

    /// Plays the file binaurally at a position on the unit sphere around the
    /// listener (+x right, +y up, -z forward).
    @discardableResult
    func playSpatial(_ url: URL, volume: Float, at position: AVAudio3DPoint, exclusive: Bool = true) -> TimeInterval {
        guard let buffer = preloadMono(url) else { return 0 }
        lock.lock()
        let node: AVAudioPlayerNode
        if exclusive, let previous = activeSpatialNode[url] {
            node = previous
        } else {
            node = spatialNodes[nextSpatialNode]
            nextSpatialNode = (nextSpatialNode + 1) % spatialNodes.count
        }
        activeSpatialNode[url] = node
        lock.unlock()

        startIfNeeded()
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

    func stopAll() {
        for node in nodes + spatialNodes { node.stop() }
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
