import Foundation

/// Sağlayıcıyla (Xtream Codes) doğrudan konuşur: katalog, film/dizi bilgisi ve yayın adresleri.
struct ProviderAPI {
    let connection: Connection

    private var base: String {
        connection.server.hasSuffix("/") ? String(connection.server.dropLast()) : connection.server
    }

    private func apiURL(_ action: String, _ extra: [String: String] = [:]) -> URL? {
        var components = URLComponents(string: base + "/player_api.php")
        components?.queryItems = [
            URLQueryItem(name: "username", value: connection.username),
            URLQueryItem(name: "password", value: connection.password),
            URLQueryItem(name: "action", value: action),
        ] + extra.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components?.url
    }

    private func data(_ action: String, _ extra: [String: String] = [:]) async throws -> Data {
        guard let url = apiURL(action, extra) else { throw AppError.message("Sağlayıcı adresi geçersiz.") }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 40
        let (payload, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw AppError.message("Sağlayıcı yanıt vermedi (HTTP \(status)).") }
        return payload
    }

    private static let pathAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    private func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: ProviderAPI.pathAllowed) ?? value
    }

    func streamURL(kind: ContentKind, id: String, ext: String?) -> URL? {
        let folder = kind == .live ? "live" : kind == .movie ? "movie" : "series"
        let suffix: String
        if kind == .live {
            suffix = "m3u8"
        } else if let ext, !ext.isEmpty {
            suffix = ext
        } else {
            suffix = "mp4"
        }
        return URL(string: "\(base)/\(folder)/\(encode(connection.username))/\(encode(connection.password))/\(encode(id)).\(suffix)")
    }

    // MARK: Katalog

    func fetchCatalog(_ kind: ContentKind) async throws -> CatalogBundle {
        let streamsAction = kind == .movie ? "get_vod_streams" : kind == .series ? "get_series" : "get_live_streams"
        let categoriesAction = kind == .movie ? "get_vod_categories" : kind == .series ? "get_series_categories" : "get_live_categories"
        async let streamsPayload = data(streamsAction)
        async let categoriesPayload = data(categoriesAction)
        let rows = try JSONDecoder().decode([ProviderRow].self, from: try await streamsPayload)
        let categoryData: Data? = try? await categoriesPayload
        let categoryRows = categoryData.flatMap { try? JSONDecoder().decode([CategoryRow].self, from: $0) } ?? []
        let categories = categoryRows.compactMap { row -> ProviderCategory? in
            guard let id = row.id, let name = row.name else { return nil }
            return ProviderCategory(id: id, name: name)
        }
        let adult = Set(categories.filter { CatalogText.isAdultCategory($0.name) }.map(\.id))
        let threeD = Set(categories.filter { CatalogText.is3DCategory($0.name) }.map(\.id))
        let visibleCategories = categories.filter { !adult.contains($0.id) }
        var items: [CatalogItem] = []
        items.reserveCapacity(rows.count)
        for row in rows {
            guard let id = kind == .series ? row.seriesId : row.streamId, let name = row.name else { continue }
            if let category = row.categoryId, adult.contains(category) { continue }
            if CatalogText.isSeparator(name) { continue }
            let parsed = CatalogText.parseTitle(name)
            let rating = row.rating.flatMap { $0 > 0 && $0 <= 10 ? $0 : nil } ?? parsed.rating
            let year = row.year.flatMap { $0 > 1900 ? Int($0) : nil } ?? parsed.year
            let artwork = kind == .series ? row.cover : row.streamIcon
            let ext = kind == .live ? "m3u8" : kind == .movie ? row.ext?.lowercased() : nil
            items.append(CatalogItem(
                id: id,
                kind: kind,
                title: parsed.title,
                artwork: artwork,
                ext: ext,
                year: year,
                rating: rating,
                categoryId: row.categoryId,
                addedAt: row.added ?? row.lastModified,
                searchKey: TextFold.fold(parsed.title),
                variant: row.categoryId.flatMap { threeD.contains($0) ? "3D" : nil },
                updatedAt: row.lastModified
            ))
        }
        if kind == .live {
            // Kanallar kategori sırasıyla.
            let rank = Dictionary(uniqueKeysWithValues: visibleCategories.enumerated().map { ($1.id, $0) })
            items = items.enumerated().sorted { left, right in
                let l = rank[left.element.categoryId ?? ""] ?? Int.max
                let r = rank[right.element.categoryId ?? ""] ?? Int.max
                return l != r ? l < r : left.offset < right.offset
            }.map(\.element)
        } else {
            items.sort { ($0.addedAt ?? 0) > ($1.addedAt ?? 0) }
        }
        return CatalogBundle(storedAt: Date().timeIntervalSince1970, items: items, categories: visibleCategories)
    }

    // MARK: Ayrıntılar

    func movieDetails(id: String) async throws -> MovieDetails {
        let response = try JSONDecoder().decode(MovieInfoResponse.self, from: try await data("get_vod_info", ["vod_id": id]))
        let info = response.info
        return MovieDetails(
            plot: info?.plot,
            cast: info?.cast,
            director: info?.director,
            genre: info?.genre,
            releaseDate: info?.releaseDate,
            duration: info?.duration,
            rating: info?.rating.flatMap { $0 > 0 ? $0 : nil },
            backdrop: info?.backdrop,
            poster: info?.poster,
            tmdbId: info?.tmdbId,
            trailer: info?.trailer
        )
    }

    func seriesDetails(id: String) async throws -> SeriesDetails {
        let response = try JSONDecoder().decode(SeriesInfoResponse.self, from: try await data("get_series_info", ["series_id": id]))
        let info = response.info
        let episodes = response.episodes.compactMap { pair -> Episode? in
            let row = pair.row
            guard let id = row.id else { return nil }
            let season = row.season.map { Int($0) } ?? pair.season ?? 1
            let number = row.episodeNum.map { Int($0) } ?? 0
            return Episode(
                id: id,
                season: season,
                number: number,
                title: CatalogText.episodeTitle(row.title, number: number),
                ext: row.ext?.lowercased() ?? "mkv",
                image: row.info?.image,
                plot: row.info?.plot,
                durationSecs: row.info?.durationSecs
            )
        }
        return SeriesDetails(
            plot: info?.plot,
            cast: info?.cast,
            genre: info?.genre,
            releaseDate: info?.releaseDate,
            rating: info?.rating.flatMap { $0 > 0 ? $0 : nil },
            backdrop: info?.backdrop,
            cover: info?.cover,
            tmdbId: info?.tmdbId,
            trailer: info?.trailer,
            episodes: episodes.sorted { ($0.season, $0.number) < ($1.season, $1.number) }
        )
    }
}

extension ProviderAPI {
    /// Kanalın şimdiki ve sıradaki programları.
    func shortEpg(channelId: String) async throws -> [EpgEntry] {
        let payload = try await data("get_short_epg", ["stream_id": channelId, "limit": "4"])
        let root = (try JSONSerialization.jsonObject(with: payload)) as? [String: Any]
        let rows = root?["epg_listings"] as? [[String: Any]] ?? []
        return rows.compactMap { row in
            func number(_ key: String) -> Double? {
                if let value = row[key] as? NSNumber { return value.doubleValue }
                if let value = row[key] as? String { return Double(value) }
                return nil
            }
            guard let start = number("start_timestamp"), let end = number("stop_timestamp") else { return nil }
            let title = CatalogText.base64(row["title"] as? String) ?? "Program"
            return EpgEntry(title: title, description: CatalogText.base64(row["description"] as? String), start: start, end: end)
        }
    }
}

// MARK: - Sağlayıcı JSON'u

private struct ProviderRow: Decodable {
    let streamId: String?
    let seriesId: String?
    let name: String?
    let streamIcon: String?
    let cover: String?
    let categoryId: String?
    let ext: String?
    let rating: Double?
    let added: Double?
    let lastModified: Double?
    let year: Double?

    enum CodingKeys: String, CodingKey {
        case stream_id, series_id, name, stream_icon, cover, category_id, container_extension, rating, added, last_modified, year
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        streamId = c.flexString(.stream_id)
        seriesId = c.flexString(.series_id)
        name = c.flexString(.name)
        streamIcon = c.flexString(.stream_icon)
        cover = c.flexString(.cover)
        categoryId = c.flexString(.category_id)
        ext = c.flexString(.container_extension)
        rating = c.flexDouble(.rating)
        added = c.flexDouble(.added)
        lastModified = c.flexDouble(.last_modified)
        year = c.flexDouble(.year)
    }
}

private struct CategoryRow: Decodable {
    let id: String?
    let name: String?
    enum CodingKeys: String, CodingKey { case category_id, category_name }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.flexString(.category_id)
        name = c.flexString(.category_name)
    }
}

private struct MovieInfoRow: Decodable {
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

    enum CodingKeys: String, CodingKey {
        case plot, description, cast, actors, director, genre, releasedate, release_date, duration, rating, backdrop_path, movie_image, cover_big, tmdb_id, youtube_trailer, trailer
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        plot = c.flexString(.plot) ?? c.flexString(.description)
        cast = c.flexString(.cast) ?? c.flexString(.actors)
        director = c.flexString(.director)
        genre = c.flexString(.genre)
        releaseDate = c.flexString(.releasedate) ?? c.flexString(.release_date)
        duration = c.flexString(.duration)
        rating = c.flexDouble(.rating)
        backdrop = c.flexFirstString(.backdrop_path)
        poster = c.flexString(.movie_image) ?? c.flexString(.cover_big)
        tmdbId = c.flexString(.tmdb_id)
        trailer = CatalogText.youtubeKey(c.flexString(.youtube_trailer) ?? c.flexString(.trailer))
    }
}

private struct MovieInfoResponse: Decodable {
    let info: MovieInfoRow?
    enum CodingKeys: String, CodingKey { case info }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Bilgi yoksa sağlayıcı nesne yerine boş dizi gönderiyor.
        info = try? c.decodeIfPresent(MovieInfoRow.self, forKey: .info)
    }
}

private struct SeriesInfoRow: Decodable {
    let plot: String?
    let cast: String?
    let genre: String?
    let releaseDate: String?
    let rating: Double?
    let backdrop: String?
    let cover: String?
    let tmdbId: String?
    let trailer: String?

    enum CodingKeys: String, CodingKey { case plot, cast, genre, releaseDate, release_date, rating, backdrop_path, cover, tmdb_id, tmdb, youtube_trailer, trailer }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        plot = c.flexString(.plot)
        cast = c.flexString(.cast)
        genre = c.flexString(.genre)
        releaseDate = c.flexString(.releaseDate) ?? c.flexString(.release_date)
        rating = c.flexDouble(.rating)
        backdrop = c.flexFirstString(.backdrop_path)
        cover = c.flexString(.cover)
        tmdbId = c.flexString(.tmdb_id) ?? c.flexString(.tmdb)
        trailer = CatalogText.youtubeKey(c.flexString(.youtube_trailer) ?? c.flexString(.trailer))
    }
}

private struct EpisodeInfoRow: Decodable {
    let image: String?
    let plot: String?
    let durationSecs: Double?
    enum CodingKeys: String, CodingKey { case movie_image, plot, duration_secs }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        image = c.flexString(.movie_image)
        plot = c.flexString(.plot)
        durationSecs = c.flexDouble(.duration_secs)
    }
}

private struct EpisodeRow: Decodable {
    let id: String?
    let episodeNum: Double?
    let title: String?
    let ext: String?
    let season: Double?
    let info: EpisodeInfoRow?

    enum CodingKeys: String, CodingKey { case id, episode_num, title, container_extension, season, info }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.flexString(.id)
        episodeNum = c.flexDouble(.episode_num)
        title = c.flexString(.title)
        ext = c.flexString(.container_extension)
        season = c.flexDouble(.season)
        info = try? c.decodeIfPresent(EpisodeInfoRow.self, forKey: .info)
    }
}

private struct SeriesInfoResponse: Decodable {
    let info: SeriesInfoRow?
    let episodes: [(row: EpisodeRow, season: Int?)]

    enum CodingKeys: String, CodingKey { case info, episodes }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        info = try? c.decodeIfPresent(SeriesInfoRow.self, forKey: .info)
        if let bySeason = try? c.decode([String: [EpisodeRow]].self, forKey: .episodes) {
            episodes = bySeason.flatMap { key, rows in rows.map { (row: $0, season: Int(key)) } }
        } else if let nested = try? c.decode([[EpisodeRow]].self, forKey: .episodes) {
            episodes = nested.flatMap { rows in rows.map { (row: $0, season: nil) } }
        } else {
            episodes = []
        }
    }
}

// MARK: - Başlık ve kategori kuralları (sitedekilerle aynı)

enum CatalogText {
    /// "Film Adı | 2024 | 7.5 | TR" → başlık, yıl, puan.
    static func parseTitle(_ raw: String) -> (title: String, year: Int?, rating: Double?) {
        let parts = raw.split(separator: "|").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard let first = parts.first else { return ("İçerik", nil, nil) }
        var year: Int?
        var rating: Double?
        for part in parts.dropFirst() {
            if year == nil, part.count == 4, let value = Int(part), (1900...2100).contains(value) {
                year = value
            } else if rating == nil, part.count <= 4, let value = Double(part.replacingOccurrences(of: ",", with: ".")), value > 0, value <= 10 {
                rating = value
            }
        }
        return (first, year, rating)
    }

    /// Sağlayıcının "▃ ▅ ▆ █ SPORTS █ ▆ ▅ ▃" gibi ayraç satırları içerik değil.
    static func isSeparator(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        let decoration = CharacterSet(charactersIn: "#=-_*~|/\\ ")
        if trimmed.unicodeScalars.allSatisfy({ decoration.contains($0) }) { return true }
        let blocks = trimmed.unicodeScalars.prefix(6).filter { (0x2580...0x259F).contains($0.value) }.count
        return blocks >= 3
    }

    /// "TR ➾ 3D Filmler" gibi kategoriler yan yana 3D sürümler içerir.
    static func is3DCategory(_ name: String) -> Bool {
        name.range(of: #"(^|[^\p{L}\p{N}])3d([^\p{L}\p{N}]|$)"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func isAdultCategory(_ name: String) -> Bool {
        let upper = name.uppercased(with: Locale(identifier: "tr_TR"))
        if upper.hasPrefix("FOR ADULTS") { return true }
        let words = upper.components(separatedBy: CharacterSet.alphanumerics.inverted.subtracting(CharacterSet(charactersIn: "+")))
        return words.contains { ["XXX", "PORN", "YETİŞKİN", "ADULT", "ADULTS", "18+", "+18"].contains($0) }
    }

    /// YouTube adresi ya da 11 karakterlik anahtar → anahtar.
    static func youtubeKey(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let range = value.range(of: #"(?:v=|youtu\.be/|embed/)([A-Za-z0-9_-]{11})"#, options: .regularExpression) {
            return String(value[range].suffix(11))
        }
        return value.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil ? value : nil
    }

    /// Sağlayıcı EPG metinlerini base64 gönderiyor; çözülemezse olduğu gibi.
    static func base64(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        if let data = Data(base64Encoded: raw), let text = String(data: data, encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return raw
    }

    /// "High Potential - S01E01 - Pilot" → "Pilot".
    static func episodeTitle(_ raw: String?, number: Int) -> String {
        guard let raw, !raw.isEmpty else { return "\(number). Bölüm" }
        if let range = raw.range(of: #"S\d+E\d+\s*-\s*"#, options: [.regularExpression, .caseInsensitive]) {
            let rest = raw[range.upperBound...].trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { return rest }
        }
        return raw
    }
}

// MARK: - Cihazdaki katalog önbelleği

enum CatalogCache {
    static let maxAge: TimeInterval = 6 * 60 * 60

    private static func url(_ name: String) -> URL {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let safe = name.replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent("fenotip-\(safe).json")
    }

    static func read(_ name: String) -> CatalogBundle? {
        guard let data = try? Data(contentsOf: url(name)) else { return nil }
        return try? JSONDecoder().decode(CatalogBundle.self, from: data)
    }

    static func write(_ name: String, _ bundle: CatalogBundle) {
        guard let data = try? JSONEncoder().encode(bundle) else { return }
        try? data.write(to: url(name), options: .atomic)
    }
}
