import AVFoundation
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
    private var nodes: [AVAudioPlayerNode] = []
    private var nextNode = 0
    private var buffers: [URL: AVAudioPCMBuffer] = [:]
    private var activeNode: [URL: AVAudioPlayerNode] = [:]
    private let lock = NSLock()
    private var configObserver: NSObjectProtocol?

    init(voices: Int = 12) {
        for _ in 0..<voices {
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            nodes.append(node)
        }
        engine.prepare()
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

    private func startIfNeeded() {
        guard !engine.isRunning else { return }
        do {
            try engine.start()
        } catch {
            log.error("Could not start audio engine: \(error.localizedDescription)")
        }
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
        node.stop()
        node.volume = max(0, min(1, volume))
        node.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        node.play()
        return Double(buffer.frameLength) / buffer.format.sampleRate
    }

    func stopAll() {
        for node in nodes { node.stop() }
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
