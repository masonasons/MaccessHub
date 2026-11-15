import AppKit
import CryptoKit
import DiskArbitration
import Foundation
import IOKit
import Observation
import os

// Disk sounds come from Plattersong by Onj (https://github.com/OnjLouis/Plattersong, MIT).

/// A physical disk that can make sounds.
struct PhysicalDisk: Equatable, Identifiable {
    /// Stable across reboots and ports (a hash of model, size and serial or media
    /// UUID), so a disk keeps its mix.
    let id: String
    let bsdName: String
    let model: String
    var title: String { "\(model) (\(bsdName))" }
}

/// One physical disk's block storage driver in the I/O Registry.
final class DiskService {
    private let handle: io_registry_entry_t
    /// The registry entry ID: changes when the disk is reconnected.
    let generation: UInt64
    let disk: PhysicalDisk

    private init(handle: io_registry_entry_t, generation: UInt64, disk: PhysicalDisk) {
        self.handle = handle
        self.generation = generation
        self.disk = disk
    }

    deinit { IOObjectRelease(handle) }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    func counters() -> DiskCounters? {
        guard let stats = Self.property(handle, "Statistics") as? [String: NSNumber],
              let read = stats["Operations (Read)"], let write = stats["Operations (Write)"] else { return nil }
        return DiskCounters(read: read.uint64Value, write: write.uint64Value)
    }

    /// Whole physical disks, skipping disk images and virtual devices.
    static func discover() -> [DiskService] {
        guard let session = DASessionCreate(kCFAllocatorDefault) else { return [] }
        var list: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &list)
                == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(list) }
        var result: [DiskService] = []
        while case let driver = IOIteratorNext(list), driver != 0 {
            if let service = describe(driver, session: session) { result.append(service) }
            else { IOObjectRelease(driver) }
        }
        // Never share one mix between devices that report the same identity.
        let counts = Dictionary(grouping: result, by: { $0.disk.id }).mapValues(\.count)
        return result.filter { counts[$0.disk.id] == 1 }.sorted {
            $0.disk.bsdName.localizedStandardCompare($1.disk.bsdName) == .orderedAscending
        }
    }

    private static func describe(_ driver: io_registry_entry_t, session: DASession) -> DiskService? {
        var children: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(driver, kIOServicePlane, &children) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(children) }
        while case let media = IOIteratorNext(children), media != 0 {
            defer { IOObjectRelease(media) }
            guard IOObjectConformsTo(media, "IOMedia") != 0,
                  property(media, "Whole") as? Bool == true,
                  let bytes = property(media, "Size") as? NSNumber, bytes.uint64Value > 0,
                  let bsd = property(media, "BSD Name") as? String,
                  let disk = DADiskCreateFromIOMedia(kCFAllocatorDefault, session, media),
                  let description = DADiskCopyDescription(disk) as? [String: Any] else { continue }
            let transport = description[kDADiskDescriptionDeviceProtocolKey as String] as? String ?? ""
            let model = (description[kDADiskDescriptionDeviceModelKey as String] as? String ?? "Disk")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transport.isEmpty, !transport.localizedCaseInsensitiveContains("virtual"),
                  !model.localizedCaseInsensitiveContains("disk image") else { continue }
            var parent: io_registry_entry_t = 0
            var device: [String: Any] = [:], protocolInfo: [String: Any] = [:]
            if IORegistryEntryGetParentEntry(driver, kIOServicePlane, &parent) == KERN_SUCCESS {
                device = property(parent, "Device Characteristics") as? [String: Any] ?? [:]
                protocolInfo = property(parent, "Protocol Characteristics") as? [String: Any] ?? [:]
                IOObjectRelease(parent)
            }
            let serial = (device["Serial Number"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let path = description[kDADiskDescriptionDevicePathKey as String] as? String ?? ""
            let mediaUUID = property(media, "UUID") as? String
            let lun = (protocolInfo["SCSI Logical Unit Number"] as? NSNumber)?.stringValue ?? ""
            let identity: String
            if let serial, !serial.isEmpty, serial.contains(where: { !"0 -".contains($0) }) {
                identity = "serial:\(serial):\(lun)"
            } else if let mediaUUID, !mediaUUID.isEmpty { identity = "media:\(mediaUUID)" }
            else if !path.isEmpty { identity = "port:\(path)" }
            else { continue }
            let key = SHA256.hash(data: Data("\(model):\(bytes):\(identity)".utf8))
                .map { String(format: "%02x", $0) }.joined()
            var generation: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(driver, &generation) == KERN_SUCCESS else { continue }
            return DiskService(handle: driver, generation: generation,
                               disk: PhysicalDisk(id: key, bsdName: bsd, model: model))
        }
        return nil
    }
}

/// Plays a short click whenever a physical disk reads or writes. Every 25 ms it
/// compares each enabled disk's operation counters with the last reading and
/// plays one mixed batch for whatever changed. While off (or with no enabled
/// disk connected) it only looks for disks every 5 seconds.
@Observable
final class DiskSoundsFeature {
    /// Connected disks, for the settings page. Updated on the main queue.
    private(set) var disks: [PhysicalDisk] = []

    @ObservationIgnored private let engine: SoundEngine
    @ObservationIgnored private let log = Logger(subsystem: "com.maccesshub.app", category: "diskSounds")
    @ObservationIgnored private let queue = DispatchQueue(label: "com.maccesshub.disksounds", qos: .userInitiated)
    @ObservationIgnored private var timer: DispatchSourceTimer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    // Owned by `queue`.
    @ObservationIgnored private var services: [DiskService] = []
    @ObservationIgnored private var previous: [UInt64: DiskCounters] = [:]
    @ObservationIgnored private var clicks: [String: DiskClick.Pair] = [:]
    @ObservationIgnored private var mixes: [String: DiskMix] = [:]
    @ObservationIgnored private var enabled = false
    @ObservationIgnored private var sampling = false
    @ObservationIgnored private var lastScan: UInt64?

    private static let discoveryInterval = DispatchTimeInterval.seconds(5)
    private static let discoveryNanoseconds: UInt64 = 4_750_000_000

    init(engine: SoundEngine) {
        self.engine = engine
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.schedule(deadline: .now(), repeating: Self.discoveryInterval, leeway: .milliseconds(250))
        timer.resume()
        self.timer = timer
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didWakeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.queue.async { [weak self] in self?.tick(forceDiscovery: true) }
            })
        }
    }

    deinit {
        timer?.cancel()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    /// Applies the on/off switch and every disk's mix.
    func configure(_ settings: DiskSoundSettings) {
        queue.async { [self] in
            if enabled != settings.enabled { previous.removeAll() }
            enabled = settings.enabled
            let next = settings.disks
            for id in clicks.keys where !(next[id] ?? DiskMix()).audible { clicks.removeValue(forKey: id) }
            for service in services {
                let id = service.disk.id
                let mix = next[id] ?? DiskMix()
                guard mix.audible, clicks[id] == nil || mixes[id] != mix else { continue }
                clicks[id] = DiskClick.Pair(mix)
                // Start counting afresh so a change of mix doesn't sound like activity.
                previous.removeValue(forKey: service.generation)
            }
            mixes = next
            updateTimer()
        }
    }

    /// Whether any connected disk would make a sound.
    func hasAudibleDisk(in settings: DiskSoundSettings) -> Bool {
        disks.contains { settings.mix(for: $0.id).audible }
    }

    /// Ten clicks with `mix`, whether or not disk sounds are on.
    func preview(_ mix: DiskMix, write: Bool) {
        queue.async { [engine] in engine.playStream(DiskClick.preview(mix, write: write), interrupt: true) }
    }

    private func updateTimer() {
        let active = enabled && services.contains { clicks[$0.disk.id] != nil }
        guard active != sampling else { return }
        sampling = active
        let interval: DispatchTimeInterval = active ? .milliseconds(25) : Self.discoveryInterval
        timer?.schedule(deadline: .now() + interval, repeating: interval,
                        leeway: active ? .milliseconds(3) : .milliseconds(250))
        log.debug("Disk sampling \(active ? "started" : "stopped", privacy: .public)")
    }

    private func tick(forceDiscovery: Bool = false) {
        let now = DispatchTime.now().uptimeNanoseconds
        if forceDiscovery || (lastScan.map { now - $0 >= Self.discoveryNanoseconds } ?? true) {
            lastScan = now
            let old = services.map(\.disk)
            let priorIdentity = Dictionary(uniqueKeysWithValues: services.map { ($0.generation, $0.disk.id) })
            services = DiskService.discover()
            let current = services.map(\.disk)
            // Keep baselines only for disks that are still the same connection.
            let connected = Set(services.filter { priorIdentity[$0.generation] == $0.disk.id }.map(\.generation))
            previous = previous.filter { connected.contains($0.key) }
            for service in services where clicks[service.disk.id] == nil {
                let mix = mixes[service.disk.id] ?? DiskMix()
                if mix.audible { clicks[service.disk.id] = DiskClick.Pair(mix) }
            }
            if current != old { DispatchQueue.main.async { self.disks = current } }
            updateTimer()
        }
        guard enabled else { return }
        var active: [(DiskActivity, DiskClick.Pair)] = []
        for service in services {
            guard let click = clicks[service.disk.id], let counters = service.counters() else {
                previous.removeValue(forKey: service.generation)
                continue
            }
            let change = counters.change(since: previous.updateValue(counters, forKey: service.generation))
            if !change.isEmpty { active.append((change, click)) }
        }
        if !active.isEmpty { engine.playStream(DiskClick.render(active), interrupt: false) }
    }
}

extension DiskMix {
    /// Enabled and above zero volume.
    var audible: Bool { enabled && volume > 0 }
}
