import Foundation

/// Resolves an event to the file that should play, honouring user overrides,
/// the selected pack, fallback categories, and the Classic pack as a last resort.
struct SoundScheme {
    var settings: SettingsData
    var library: SoundpackLibrary

    /// Where an event's sound comes from. Pack sources carry every variant,
    /// primary first; a custom file is always a single sound.
    enum Source {
        case override(URL)
        case pack([URL], Soundpack)
        case fallback([URL], Soundpack, viaEvent: String)
        case classic([URL])

        var urls: [URL] {
            switch self {
            case .override(let u): return [u]
            case .classic(let u): return u
            case .pack(let u, _), .fallback(let u, _, _): return u
            }
        }

        /// The primary file.
        var url: URL { urls[0] }
        var variantCount: Int { urls.count }

        var description: String {
            switch self {
            case .override: return "Custom file"
            case .pack(_, let p): return p.name
            case .fallback(_, let p, let via): return "\(p.name), same sound as \(SoundEvent.byID[via]?.title ?? via)"
            case .classic: return "Classic (not in this pack)"
            }
        }
    }

    func pack(for event: SoundEvent) -> Soundpack? {
        let id: String
        switch event.group {
        case .keys: id = settings.keyClicks.packID
        case .focus: id = settings.focusSounds.packID
        default: id = settings.eventSounds.packID
        }
        return library.resolvedPack(id: id)
    }

    private func fillsMissing(_ event: SoundEvent) -> Bool {
        switch event.group {
        case .keys: return settings.keyClicks.fillMissingFromClassic
        case .focus: return settings.focusSounds.fillMissingFromClassic
        default: return settings.eventSounds.fillMissingFromClassic
        }
    }

    func source(for event: SoundEvent) -> Source? {
        if let path = settings.soundOverrides[event.id] {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) { return .override(url) }
        }
        let chain = [event.id] + event.fallbacks
        if let pack = pack(for: event) {
            for id in chain {
                let urls = pack.urls(for: id)
                if !urls.isEmpty {
                    return id == event.id ? .pack(urls, pack) : .fallback(urls, pack, viaEvent: id)
                }
            }
        }
        if fillsMissing(event), let classic = library.classic, classic.id != pack(for: event)?.id {
            for id in chain {
                let urls = classic.urls(for: id)
                if !urls.isEmpty { return .classic(urls) }
            }
        }
        return nil
    }

    /// The event's primary file.
    func url(for event: SoundEvent) -> URL? { source(for: event)?.url }

    /// Every variant the event can play, primary first.
    func urls(for event: SoundEvent) -> [URL] { source(for: event)?.urls ?? [] }

    /// Every file the current configuration can play, variants included, for preloading.
    func allURLs() -> Set<URL> {
        Set(SoundEvent.all.flatMap { urls(for: $0) })
    }
}
