import Foundation

enum ContentKind: String, Codable, Hashable {
    case movie, series, live
}

struct CatalogItem: Identifiable, Hashable, Codable {
    let id: String
    let kind: ContentKind
    let title: String
    let artwork: String?
    let ext: String?
    let year: Int?
    let rating: Double?
    let categoryId: String?
    let addedAt: Double?
    /// Aramada kullanılan katlanmış başlık (küçük harf, Türkçe harfler sadeleşmiş).
    let searchKey: String
    /// "3D" gibi özel sürüm (yan yana görüntü); raflarda gösterilmez.
    let variant: String?
    /// Sağlayıcının son değişiklik zamanı (sn); dizide yeni bölüm gelince ilerler.
    var updatedAt: Double? = nil

    var key: String { "\(kind.rawValue):\(id)" }
    var artworkURL: URL? { artwork.flatMap { URL(string: $0) } }
}

extension Array where Element == CatalogItem {
    /// Sağlayıcı aynı filmi birkaç kategoride ayrı kimlikle veriyor (ör. "Animals" üç kez).
    /// Ad + yıl + sürüm başına bir kopya kalır; MP4 varsa o tercih edilir (sitedeki kural).
    func collapsingDuplicates() -> [CatalogItem] {
        var index: [String: Int] = [:]
        var kept: [CatalogItem] = []
        kept.reserveCapacity(count)
        for item in self {
            let key = "\(item.searchKey)|\(item.year ?? 0)|\(item.variant ?? "")"
            if let existing = index[key] {
                if kept[existing].ext != "mp4" && item.ext == "mp4" { kept[existing] = item }
                continue
            }
            index[key] = kept.count
            kept.append(item)
        }
        return kept
    }
}

struct ProviderCategory: Identifiable, Hashable, Codable {
    let id: String
    let name: String
}

struct CatalogBundle: Codable {
    let storedAt: Double
    let items: [CatalogItem]
    let categories: [ProviderCategory]
}

struct Connection: Codable, Equatable {
    let server: String
    let username: String
    let password: String
}

struct ProfilePolicy: Codable, Hashable {
    let mode: String
    let maxAge: Int?
}

struct Profile: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let avatar: String
    let policy: ProfilePolicy?

    var emoji: String {
        let map: [String: String] = [
            "lion": "🦁", "tiger": "🐯", "eagle": "🦅", "wolf": "🐺", "bear": "🐻", "fox": "🦊", "panda": "🐼",
            "shark": "🦈", "owl": "🦉", "gorilla": "🦍", "panther": "🐆", "rhino": "🦏", "leopard": "🐆",
            "husky": "🐺", "crocodile": "🐊", "horse": "🐴", "red": "🔴", "blue": "🔵", "green": "🟢",
        ]
        return map[avatar] ?? "👤"
    }
}

struct ProfilesResponse: Decodable {
    let profiles: [Profile]
    let selectedProfileId: String?
}

struct WatchPosition: Codable, Hashable {
    var position: Double
    var duration: Double
    var updatedAt: Double

    /// Sitedeki "izlemeye devam et" kuralı: %3'ten fazla, %95'ten az izlenmiş.
    var isResumable: Bool {
        guard duration > 0, position > 0 else { return false }
        let ratio = position / duration
        return ratio >= 0.03 && ratio <= 0.95
    }

    var fraction: Double { duration > 0 ? min(1, max(0, position / duration)) : 0 }

    /// Uygulamadaki "izlemeye devam et" kartı: sitedeki %3 kuralına ek olarak en az 1 dk izlenenler de
    /// görünür (kısa denemeler kaybolmasın); bitmiş (%95+) olanlar görünmez.
    var isContinuable: Bool {
        guard duration > 0, position > 0, fraction <= 0.95 else { return false }
        return position >= 60 || fraction >= 0.03
    }
}

struct RecentEntry: Decodable, Hashable {
    let kind: ContentKind?
    let id: String
    let seriesId: String?
    let title: String
    let artwork: String?
    let ext: String?
    let updatedAt: Double

    enum CodingKeys: String, CodingKey {
        case kind, id, seriesId, title, artwork, updatedAt
        case ext = "extension"
    }

    init(kind: ContentKind?, id: String, seriesId: String?, title: String, artwork: String?, ext: String?, updatedAt: Double) {
        self.kind = kind
        self.id = id
        self.seriesId = seriesId
        self.title = title
        self.artwork = artwork
        self.ext = ext
        self.updatedAt = updatedAt
    }

    init?(json: [String: Any]) {
        func text(_ key: String) -> String? {
            if let value = json[key] as? String { return value.isEmpty ? nil : value }
            if let value = json[key] as? NSNumber { return value.stringValue }
            return nil
        }
        guard let id = text("id") else { return nil }
        self.id = id
        kind = text("kind").flatMap(ContentKind.init(rawValue:))
        seriesId = text("seriesId")
        title = text("title") ?? "İçerik"
        artwork = text("artwork")
        ext = text("extension")
        updatedAt = (json["updatedAt"] as? NSNumber)?.doubleValue ?? 0
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = c.flexString(.kind).flatMap(ContentKind.init(rawValue:))
        id = c.flexString(.id) ?? ""
        seriesId = c.flexString(.seriesId)
        title = c.flexString(.title) ?? "İçerik"
        artwork = c.flexString(.artwork)
        ext = c.flexString(.ext)
        updatedAt = c.flexDouble(.updatedAt) ?? 0
    }
}

/// Sitede ses/altyazı seçimi profile kaydediliyor; uygulama da aynısını uygular ve günceller.
struct PlaybackPreferences: Hashable {
    var audioLanguage: String?
    var subtitleLanguage: String?
    var subtitlesEnabled: Bool?
    var playbackRate: Double?

    static let empty = PlaybackPreferences()

    init(audioLanguage: String? = nil, subtitleLanguage: String? = nil, subtitlesEnabled: Bool? = nil, playbackRate: Double? = nil) {
        self.audioLanguage = audioLanguage
        self.subtitleLanguage = subtitleLanguage
        self.subtitlesEnabled = subtitlesEnabled
        self.playbackRate = playbackRate
    }

    init(raw: [String: Any]?) {
        audioLanguage = raw?["audioLanguage"] as? String
        subtitleLanguage = raw?["subtitleLanguage"] as? String
        subtitlesEnabled = raw?["subtitlesEnabled"] as? Bool
        playbackRate = raw?["playbackRate"] as? Double
    }
}

struct ProfileState {
    var revision: Int
    var recent: [RecentEntry]
    var positions: [String: WatchPosition]
    var myList: [RecentEntry]
    var favoriteLiveChannelIds: [String]
    var recentLiveChannelIds: [String]
    var playbackPreferences: PlaybackPreferences
    var autoNextEpisode: Bool

    static let empty = ProfileState(revision: 0, recent: [], positions: [:], myList: [], favoriteLiveChannelIds: [], recentLiveChannelIds: [], playbackPreferences: .empty, autoNextEpisode: true)

    init(revision: Int, recent: [RecentEntry], positions: [String: WatchPosition], myList: [RecentEntry], favoriteLiveChannelIds: [String], recentLiveChannelIds: [String], playbackPreferences: PlaybackPreferences, autoNextEpisode: Bool) {
        self.revision = revision
        self.recent = recent
        self.positions = positions
        self.myList = myList
        self.favoriteLiveChannelIds = favoriteLiveChannelIds
        self.recentLiveChannelIds = recentLiveChannelIds
        self.playbackPreferences = playbackPreferences
        self.autoNextEpisode = autoNextEpisode
    }

    /// Durum JSON'u serbest biçimli (eski profiller, PC'den gelen alanlar); bozuk kayıt tümünü düşürmesin.
    init(json: [String: Any]) {
        revision = (json["revision"] as? NSNumber)?.intValue ?? 0
        recent = ProfileState.entries(json["recent"])
        myList = ProfileState.entries(json["myList"])
        var positions: [String: WatchPosition] = [:]
        for (key, value) in json["positions"] as? [String: Any] ?? [:] {
            guard let row = value as? [String: Any],
                  let position = (row["position"] as? NSNumber)?.doubleValue,
                  let duration = (row["duration"] as? NSNumber)?.doubleValue else { continue }
            positions[key] = WatchPosition(position: position, duration: duration, updatedAt: (row["updatedAt"] as? NSNumber)?.doubleValue ?? 0)
        }
        self.positions = positions
        favoriteLiveChannelIds = ProfileState.ids(json["favoriteLiveChannelIds"])
        recentLiveChannelIds = ProfileState.ids(json["recentLiveChannelIds"])
        playbackPreferences = PlaybackPreferences(raw: json["playbackPreferences"] as? [String: Any])
        autoNextEpisode = json["autoNextEpisode"] as? Bool ?? true
    }

    private static func entries(_ value: Any?) -> [RecentEntry] {
        (value as? [[String: Any]] ?? []).compactMap(RecentEntry.init(json:))
    }

    private static func ids(_ value: Any?) -> [String] {
        (value as? [Any] ?? []).compactMap { item in
            if let text = item as? String { return text }
            if let number = item as? NSNumber { return number.stringValue }
            return nil
        }
    }

    func position(_ kind: ContentKind, _ id: String) -> WatchPosition? {
        positions["\(kind.rawValue):\(id)"]
    }

    func isSaved(_ kind: ContentKind, _ id: String) -> Bool {
        myList.contains { $0.kind == kind && $0.id == id }
    }
}

/// "İzlemeye devam et" kartı.
struct ContinueItem: Identifiable, Hashable {
    let entry: RecentEntry
    let position: WatchPosition
    var id: String { "\(entry.kind?.rawValue ?? "?"):\(entry.id)" }
}

struct Episode: Identifiable, Hashable {
    let id: String
    let season: Int
    let number: Int
    let title: String
    let ext: String
    let image: String?
    let plot: String?
    let durationSecs: Double?
}

struct MovieDetails {
    let plot: String?
    let cast: String?
    let director: String?
    let genre: String?
    let releaseDate: String?
    let duration: String?
    let rating: Double?
    let backdrop: String?
    let poster: String?
    let tmdbId: String?
    let trailer: String?
}

struct SeriesDetails {
    let plot: String?
    let cast: String?
    let genre: String?
    let releaseDate: String?
    let rating: Double?
    let backdrop: String?
    let cover: String?
    let tmdbId: String?
    let trailer: String?
    let episodes: [Episode]

    var seasons: [Int] { Array(Set(episodes.map(\.season))).sorted() }
    func episodes(in season: Int) -> [Episode] { episodes.filter { $0.season == season }.sorted { $0.number < $1.number } }
}

/// Oynatıcıya verilen içerik.
struct PlaybackItem: Identifiable {
    let id = UUID()
    let kind: ContentKind
    let contentId: String
    let seriesId: String?
    let title: String
    let artwork: String?
    let ext: String?
    let startAt: Double
    /// Dizide sıradaki bölüm için aynı sezonun/dizinin bölüm listesi.
    let episodes: [Episode]
    let seriesTitle: String?
    /// Canlı: kanal ileri/geri için içinden açıldığı liste (favoriler, kategori…).
    var channels: [CatalogItem] = []
    /// Canlı: o an yayındaki program (oynatıcı başlığında).
    var programTitle: String? = nil
    /// Canlı: o anki programın bitiş zamanı (Unix sn); kalan dakika başlıkta gösterilir.
    var programEnd: Double? = nil
    /// Canlı: sıradaki program bilgisi.
    var nextProgramTitle: String? = nil
    var nextProgramStart: Double? = nil

    var nextEpisode: Episode? {
        guard kind == .series, let index = episodes.firstIndex(where: { $0.id == contentId }), index + 1 < episodes.count else { return nil }
        return episodes[index + 1]
    }

    var previousEpisode: Episode? {
        guard kind == .series, let index = episodes.firstIndex(where: { $0.id == contentId }), index > 0 else { return nil }
        return episodes[index - 1]
    }
}

/// IMDb puanı ve oy sayısı (sunucunun /api/imdb'si; sağlayıcının puanı tek oyla 10 olabiliyor).
struct ImdbInfo: Codable, Hashable {
    let rating: Double
    let votes: Int
}

extension CatalogItem {
    /// Sağlayıcı puanı; 9,3 üstü neredeyse her zaman birkaç oyluk şişkin değer (TMDB'de bile en iyiler ~8,7).
    var trustedRating: Double? {
        guard let rating, rating > 0, rating <= 9.3 else { return nil }
        return rating
    }
}

/// Canlı yayın akışı (sağlayıcının get_short_epg'si).
struct EpgEntry: Hashable {
    let title: String
    let description: String?
    let start: Double
    let end: Double

    var timeRange: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return "\(formatter.string(from: Date(timeIntervalSince1970: start)))–\(formatter.string(from: Date(timeIntervalSince1970: end)))"
    }

    var progress: Double {
        let now = Date().timeIntervalSince1970
        return end > start ? min(1, max(0, (now - start) / (end - start))) : 0
    }
}

struct EpgNowNext {
    let current: EpgEntry?
    let next: EpgEntry?

    init(_ entries: [EpgEntry], now: Double = Date().timeIntervalSince1970) {
        let sorted = entries.sorted { $0.start < $1.start }
        if let index = sorted.firstIndex(where: { $0.start <= now && $0.end > now }) {
            current = sorted[index]
            next = index + 1 < sorted.count ? sorted[index + 1] : nil
        } else {
            current = nil
            next = sorted.first { $0.start > now }
        }
    }
}

enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

extension KeyedDecodingContainer {
    /// Sağlayıcı aynı alanı bazen sayı, bazen metin gönderiyor.
    func flexString(_ key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let value = try? decodeIfPresent(Int64.self, forKey: key) { return String(value) }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return value == value.rounded() ? String(Int64(value)) : String(value)
        }
        return nil
    }

    func flexDouble(_ key: Key) -> Double? {
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Double(value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "."))
        }
        return nil
    }

    /// Tek metin ya da metin dizisi (backdrop_path gibi).
    func flexFirstString(_ key: Key) -> String? {
        if let list = try? decodeIfPresent([String].self, forKey: key) { return list.first { !$0.isEmpty } }
        return flexString(key)
    }
}

extension CatalogItem {
    /// Çok kelimeli arama: her kelime başlıkta geçmeli ("yuzuklerin kral" → "Yüzüklerin Efendisi: Kralın Dönüşü").
    func matches(_ tokens: [String]) -> Bool {
        !tokens.isEmpty && tokens.allSatisfy { searchKey.contains($0) }
    }
}

enum TextFold {
    static func tokens(_ query: String) -> [String] {
        fold(query).split(whereSeparator: { $0 == " " || $0 == "-" || $0 == ":" }).map(String.init)
    }

    /// Türkçe aramaya uygun katlama: "Işık" → "isik", "ÇAĞRI" → "cagri".
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "tr_TR"))
            .replacingOccurrences(of: "ı", with: "i")
            .lowercased()
    }
}
