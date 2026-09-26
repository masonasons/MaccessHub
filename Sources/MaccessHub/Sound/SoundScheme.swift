import Foundation

/// Resolves an event to the file that should play, honouring user overrides,
/// the selected pack, fallback categories, and the Classic pack as a last resort.
struct SoundScheme {
    var settings: SettingsData
    var library: SoundpackLibrary

    enum Source {
        case override(URL)
        case pack(URL, Soundpack)
        case fallback(URL, Soundpack, viaEvent: String)
        case classic(URL)

        var url: URL {
            switch self {
            case .override(let u), .classic(let u): return u
            case .pack(let u, _), .fallback(let u, _, _): return u
            }
        }

        var description: String {
            switch self {
            case .override: return "Custom file"
            case .pack(_, let p): return p.name
            case .fallback(_, let p, let via): return "\(p.name), using \(via)"
            case .classic: return "Classic (fallback)"
            }
        }
    }

    func pack(for event: SoundEvent) -> Soundpack? {
        let id = event.isKeyClick ? settings.keyClicks.packID : settings.eventSounds.packID
        return library.resolvedPack(id: id)
    }

    func source(for event: SoundEvent) -> Source? {
        if let path = settings.soundOverrides[event.id] {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) { return .override(url) }
        }
        let chain = [event.id] + event.fallbacks
        if let pack = pack(for: event) {
            for id in chain {
                if let url = pack.url(for: id) {
                    return id == event.id ? .pack(url, pack) : .fallback(url, pack, viaEvent: id)
                }
            }
        }
        let fill = event.isKeyClick ? settings.keyClicks.fillMissingFromClassic : settings.eventSounds.fillMissingFromClassic
        if fill, let classic = library.classic, classic.id != pack(for: event)?.id {
            for id in chain {
                if let url = classic.url(for: id) { return .classic(url) }
            }
        }
        return nil
    }

    func url(for event: SoundEvent) -> URL? { source(for: event)?.url }

    /// Every file the current configuration can play, for preloading.
    func allURLs() -> Set<URL> {
        Set(SoundEvent.all.compactMap { url(for: $0) })
    }
}
