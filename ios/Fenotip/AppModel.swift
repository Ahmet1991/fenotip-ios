import SwiftUI
import UIKit

@MainActor
final class AppModel: ObservableObject {
    enum Stage {
        case loading
        case login
        case profiles
        case ready
        case offline(String)
    }

    @Published var stage: Stage = .loading
    @Published var profiles: [Profile] = []
    @Published var profile: Profile?
    @Published var state = ProfileState.empty
    @Published var connection: Connection?
    @Published var movies: [CatalogItem] = []
    @Published var series: [CatalogItem] = []
    @Published var live: [CatalogItem] = []
    /// Kopyaları birleştirilmiş listeler ("Tümü", raflar, arama).
    @Published var uniqueMovies: [CatalogItem] = []
    @Published var uniqueSeries: [CatalogItem] = []
    @Published var backdrops: [String: URL] = [:]
    @Published var categories: [ContentKind: [ProviderCategory]] = [:]
    @Published var loadingKinds: Set<ContentKind> = []
    @Published var catalogErrors: [ContentKind: String] = [:]
    /// Canlı kanal yayın akışı (kanal kimliği → programlar).
    @Published var epg: [String: [EpgEntry]] = [:]
    /// IMDb bilgisi (anahtar: "movie:123"). Değer nil: IMDb'de puanı yok. Anahtar yok: henüz bakılmadı.
    @Published var imdb: [String: ImdbInfo?] = [:]
    /// Ana sayfadaki IMDb oy sayısıyla süzülmüş raflar (sitedeki imdb-gate).
    @Published var topMovies: [CatalogItem] = []
    @Published var topSeries: [CatalogItem] = []
    @Published var featuredMovies: [CatalogItem] = []
    @Published var top10Movies: [CatalogItem] = []
    /// "Senin için": izlenenlerin türlerine göre raflar.
    @Published var forYou: [HomeShelf] = []
    /// Bitirdiğin bölümün sıradakisi (yeni eklendiyse işaretli).
    @Published var upNext: [UpNextEpisode] = []
    /// Ana sayfada kullanılan hazır/süzülmüş diziler; ağır hesaplar View.body dışında tutulur.
    @Published var home = HomeDashboard.empty
    @Published var homeMetadata: [String: HomeItemMetadata] = [:]
    @Published var homeLastUpdated: Date?
    @Published var homeGeneration = 0
    private var seriesDetailsCache: [String: (details: SeriesDetails, fetchedAt: Date)] = [:]
    private var movieDetailsCache: [String: (details: MovieDetails, fetchedAt: Date)] = [:]
    private var luckyMovieCandidates: [CatalogItem] = []

    let server: ServerAPI
    let tv: TvRemote
    private var lastStateRefresh = Date.distantPast
    private var byId: [ContentKind: [String: CatalogItem]] = [:]
    /// Aynı filmin kopyaları (ad + yıl + sürüm → kimlikler): PC'de izlenen kopyanın konumu diğerlerine de geçer.
    private var copyKeyById: [String: String] = [:]
    private var copiesByKey: [String: [String]] = [:]
    private var epgAttemptAt: [String: Date] = [:]
    private var epgLoadedAt: [String: Date] = [:]
    private var imdbInflight: Set<String> = []
    /// TMDB en yüksek puanlılar listesinden katalogda bulunanların "ad|yıl" anahtarları (sıra korunur).
    private var topRatedKeys: [ContentKind: [String]] = [:]
    private var topRatedRequested: Set<ContentKind> = []
    @Published var imdbLoading = false
    private var imdbLoadedFromDisk = false
    /// Kategori → türler (sitedeki film türü süzgeci kategori adından okunur).
    private var genreIndex: [ContentKind: [String: Set<String>]] = [:]

    var provider: ProviderAPI? { connection.map { ProviderAPI(connection: $0) } }

    init() {
        let server = ServerAPI()
        self.server = server
        tv = TvRemote(server: server)
    }

    // MARK: Oturum

    func start() async {
        stage = .loading
        do {
            connection = try await server.get("/api/connection", as: Connection.self)
            let list = try await server.get("/api/profiles", as: ProfilesResponse.self)
            profiles = list.profiles
            if list.selectedProfileId != nil, (try? await loadState()) != nil {
                stage = .ready
                Task { await loadLibrary() }
                return
            }
            stage = .profiles
        } catch let error as ServerError where error.status == 401 {
            stage = .login
        } catch {
            stage = .offline("Sunucuya ulaşılamadı. İnternet bağlantını kontrol edip tekrar dene.")
        }
    }

    func login(pin: String) async throws {
        try await server.login(pin: pin)
        await start()
    }

    func choose(_ profile: Profile) async throws {
        try await server.selectProfile(id: profile.id)
        try await loadState()
        stage = .ready
        Task { await loadLibrary() }
    }

    /// Çocuk profilinden çıkış: önce profil kilidi açılır, sonra seçim yinelenir.
    func unlockAndChoose(_ profile: Profile, pin: String) async throws {
        try await server.unlockProfile(pin: pin)
        try await choose(profile)
    }

    func switchProfile() {
        stage = .profiles
    }

    func logout() async {
        await server.logout()
        profile = nil
        state = .empty
        home = .empty
        homeMetadata = [:]
        homeGeneration &+= 1
        stage = .login
    }

    private func loadState() async throws {
        let response = try await server.profileState()
        profile = response.profile
        state = response.state
        lastStateRefresh = Date()
        homeGeneration &+= 1
    }

    /// Uygulama öne gelince PC'de izlenenler de görünsün.
    func refreshState() async {
        guard case .ready = stage, Date().timeIntervalSince(lastStateRefresh) > 15 else { return }
        try? await loadState()
    }

    private func mutate(_ mutation: [String: Any]) {
        Task { [weak self] in
            guard let self else { return }
            if let next = try? await self.server.mutate(mutation) {
                self.state = next
                self.lastStateRefresh = Date()
                self.homeGeneration &+= 1
            }
        }
    }

    // MARK: Katalog (doğrudan sağlayıcıdan)

    func loadLibrary(force: Bool = false) async {
        async let movieLoad: Void = loadCatalog(.movie, force: force)
        async let seriesLoad: Void = loadCatalog(.series, force: force)
        _ = await (movieLoad, seriesLoad)
    }

    func loadCatalog(_ kind: ContentKind, force: Bool = false) async {
        guard let provider, !loadingKinds.contains(kind) else { return }
        let cacheName = "\(kind.rawValue)-\(provider.connection.username)"
        if !force, items(kind).isEmpty, let cached = await Task.detached(priority: .userInitiated, operation: { CatalogCache.read(cacheName) }).value {
            apply(kind, cached)
            if Date().timeIntervalSince1970 - cached.storedAt < CatalogCache.maxAge { return }
        } else if !force, !items(kind).isEmpty {
            return
        }
        loadingKinds.insert(kind)
        defer { loadingKinds.remove(kind) }
        do {
            let bundle = try await provider.fetchCatalog(kind)
            apply(kind, bundle)
            catalogErrors[kind] = nil
            Task.detached(priority: .utility) { CatalogCache.write(cacheName, bundle) }
        } catch {
            if items(kind).isEmpty { catalogErrors[kind] = "Katalog yüklenemedi: \(error.localizedDescription)" }
        }
    }

    func items(_ kind: ContentKind) -> [CatalogItem] {
        switch kind {
        case .movie: return movies
        case .series: return series
        case .live: return live
        }
    }

    private func apply(_ kind: ContentKind, _ bundle: CatalogBundle) {
        switch kind {
        case .movie:
            movies = bundle.items
            uniqueMovies = bundle.items.collapsingDuplicates()
            var keyById: [String: String] = [:]
            var copies: [String: [String]] = [:]
            keyById.reserveCapacity(bundle.items.count)
            for item in bundle.items {
                let key = "\(item.searchKey)|\(item.year ?? 0)|\(item.variant ?? "")"
                keyById[item.id] = key
                copies[key, default: []].append(item.id)
            }
            copyKeyById = keyById
            copiesByKey = copies.filter { $0.value.count > 1 }
        case .series:
            series = bundle.items
            uniqueSeries = bundle.items.collapsingDuplicates()
        case .live:
            live = bundle.items
        }
        byId[kind] = Dictionary(bundle.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        categories[kind] = bundle.categories
        genreIndex[kind] = kind == .live ? [:] : MovieGenre.index(bundle.categories)
        if kind != .live {
            homeLastUpdated = Date(timeIntervalSince1970: bundle.storedAt)
        }
        homeGeneration &+= 1
    }

    func uniqueItems(_ kind: ContentKind) -> [CatalogItem] {
        switch kind {
        case .movie: return uniqueMovies
        case .series: return uniqueSeries
        case .live: return live
        }
    }

    /// Bu katalogda en az bir kategoriyle eşleşen türler (sitedeki sırayla).
    func availableGenres(_ kind: ContentKind) -> [MovieGenre] {
        let present = Set((genreIndex[kind] ?? [:]).values.flatMap { $0 })
        return MovieGenre.all.filter { present.contains($0.slug) }
    }

    func hasGenre(_ item: CatalogItem, _ slug: String) -> Bool {
        guard let category = item.categoryId else { return false }
        return genreIndex[item.kind]?[category]?.contains(slug) == true
    }

    func item(_ kind: ContentKind, id: String) -> CatalogItem? {
        byId[kind]?[id]
    }

    /// Detay sayfasındaki "Benzer içerikler": aynı kategoriden, kendisi ve kopyaları hariç.
    func related(to item: CatalogItem) -> [CatalogItem] {
        guard let category = item.categoryId else { return [] }
        return Array(uniqueItems(item.kind).lazy.filter { $0.categoryId == category && $0.searchKey != item.searchKey && $0.variant == nil }.prefix(18))
    }

    /// Vitrin için geniş görsel (film bilgisinden); bir kez alınır.
    func backdrop(for item: CatalogItem) async -> URL? {
        if let known = backdrops[item.key] { return known }
        guard item.kind == .movie, let details = await cachedMovieDetails(id: item.id) else { return nil }
        guard let raw = details.backdrop ?? details.poster, let url = URL(string: raw) else { return nil }
        backdrops[item.key] = url
        return url
    }

    private func cachedMovieDetails(id: String) async -> MovieDetails? {
        if let cached = movieDetailsCache[id], Date().timeIntervalSince(cached.fetchedAt) < 1800 {
            return cached.details
        }
        guard let provider, let details = try? await provider.movieDetails(id: id) else { return nil }
        movieDetailsCache[id] = (details, Date())
        return details
    }

    /// Vitrin ve uzun basma önizlemesi için kısa tür/özet bilgisini tek kez yükler.
    func loadHomeMetadata(for item: CatalogItem) async {
        guard homeMetadata[item.key] == nil, item.kind != .live else { return }
        switch item.kind {
        case .movie:
            guard let details = await cachedMovieDetails(id: item.id) else { return }
            homeMetadata[item.key] = HomeItemMetadata(genre: details.genre, plot: details.plot)
            if let raw = details.backdrop ?? details.poster, let url = URL(string: raw) {
                backdrops[item.key] = url
            }
        case .series:
            let details: SeriesDetails?
            if let cached = seriesDetailsCache[item.id], Date().timeIntervalSince(cached.fetchedAt) < 1800 {
                details = cached.details
            } else if let provider, let fetched = try? await provider.seriesDetails(id: item.id) {
                seriesDetailsCache[item.id] = (fetched, Date())
                details = fetched
            } else {
                details = nil
            }
            if let details {
                homeMetadata[item.key] = HomeItemMetadata(genre: details.genre, plot: details.plot)
            }
        case .live:
            break
        }
    }

    // MARK: IMDb (sitedeki imdb-gate: raflar ve puan sıralaması oy sayısına göre)

    func imdbRating(_ item: CatalogItem) -> Double? {
        imdb[item.key].flatMap { $0 }?.rating
    }

    /// Yeterince oy almış (güvenilir) IMDb puanı.
    func verifiedRating(_ item: CatalogItem, minVotes: Int = 1_000) -> Double? {
        guard let info = imdb[item.key].flatMap({ $0 }), info.votes >= minVotes else { return nil }
        return info.rating
    }

    /// Detay sayfası: TMDB kimliği varsa onunla (daha kesin) bakılır.
    func loadImdb(for item: CatalogItem, tmdbId: String?) async {
        guard item.kind != .live else { return }
        if let known = imdb[item.key], known != nil { return }
        if let info = try? await server.imdbInfo(kind: item.kind, tmdbId: tmdbId, title: item.title, year: item.year) {
            imdb[item.key] = info
            saveImdbCache()
        }
    }

    /// TMDB'nin en yüksek puanlılar listesi bir kez alınır ve katalogla ad + yıl üzerinden eşlenir.
    func loadTopRated(_ kind: ContentKind) async {
        guard kind != .live, !topRatedRequested.contains(kind), !uniqueItems(kind).isEmpty else { return }
        topRatedRequested.insert(kind)
        let entries = await server.topRated(kind: kind)
        guard !entries.isEmpty else {
            topRatedRequested.remove(kind)
            return
        }
        let present = Set(uniqueItems(kind).map { "\($0.searchKey)|\($0.year ?? 0)" })
        var keys: [String] = []
        for entry in entries {
            let names = [TextFold.fold(entry.title), TextFold.fold(entry.originalTitle)]
            let years = entry.year.map { [$0, $0 - 1, $0 + 1] } ?? [0]
            if let key = names.flatMap({ name in years.map { "\(name)|\($0)" } }).first(where: { present.contains($0) }) {
                keys.append(key)
            }
        }
        topRatedKeys[kind] = keys
    }

    /// Puan sıralamasında IMDb'sine bakılacak adaylar: TMDB en yüksek puanlılardan bu listede olanlar
    /// (klasikler aranmadan da öne çıksın) + sağlayıcı puanı en yüksekler.
    func ratingCandidates(_ items: [CatalogItem], count: Int = 48) -> [CatalogItem] {
        let byKey = Dictionary(items.map { ("\($0.searchKey)|\($0.year ?? 0)", $0) }, uniquingKeysWith: { first, _ in first })
        let classics = (topRatedKeys[items.first?.kind ?? .movie] ?? []).compactMap { byKey[$0] }.prefix(150)
        let provider = items.filter { $0.trustedRating != nil }.sorted { ($0.trustedRating ?? 0) > ($1.trustedRating ?? 0) }.prefix(count)
        var seen = Set<String>()
        return (Array(classics) + Array(provider)).filter { seen.insert($0.key).inserted }
    }

    /// Bilinmeyenlere en çok 6'şar paralel bakılır; sonuçlar tek seferde yayınlanır, diske 3 gün saklanır.
    func ensureImdb(_ items: [CatalogItem]) async {
        loadImdbCacheIfNeeded()
        let missing = items.filter { $0.kind != .live && imdb[$0.key] == nil && !imdbInflight.contains($0.key) }
        guard !missing.isEmpty else { return }
        missing.forEach { imdbInflight.insert($0.key) }
        imdbLoading = true
        defer {
            missing.forEach { imdbInflight.remove($0.key) }
            imdbLoading = !imdbInflight.isEmpty
        }
        let server = self.server
        var found: [String: ImdbInfo?] = [:]
        for start in stride(from: 0, to: missing.count, by: 6) {
            if Task.isCancelled { break }
            let chunk = missing[start..<min(start + 6, missing.count)]
            await withTaskGroup(of: (String, ImdbInfo??).self) { group in
                for item in chunk {
                    group.addTask {
                        do {
                            return (item.key, .some(try await server.imdbInfo(kind: item.kind, tmdbId: nil, title: item.title, year: item.year)))
                        } catch {
                            return (item.key, .none)
                        }
                    }
                }
                for await (key, result) in group {
                    if let result { found[key] = result }
                }
            }
        }
        guard !found.isEmpty else { return }
        imdb.merge(found) { _, new in new }
        saveImdbCache()
    }

    private struct StoredImdb: Codable {
        let r: Double?
        let v: Int?
        let t: Double
    }

    private var imdbCacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("fenotip-imdb-v1.json")
    }

    private func loadImdbCacheIfNeeded() {
        guard !imdbLoadedFromDisk else { return }
        imdbLoadedFromDisk = true
        guard let data = try? Data(contentsOf: imdbCacheURL),
              let stored = try? JSONDecoder().decode([String: StoredImdb].self, from: data) else { return }
        let now = Date().timeIntervalSince1970
        for (key, value) in stored where now - value.t < 3 * 24 * 60 * 60 && imdb[key] == nil {
            imdb[key] = value.r.map { ImdbInfo(rating: $0, votes: value.v ?? 0) }
        }
    }

    private func saveImdbCache() {
        let now = Date().timeIntervalSince1970
        var stored: [String: StoredImdb] = [:]
        for (key, value) in imdb {
            stored[key] = StoredImdb(r: value?.rating, v: value?.votes, t: now)
        }
        let url = imdbCacheURL
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(stored) { try? data.write(to: url, options: .atomic) }
        }
    }

    /// Ana sayfa: "Yüksek puanlı" rafları en yeni içerikler arasından IMDb'de ≥1.000 oy ve ≥6,5 puanı
    /// olanlar (IMDb puanına göre), vitrin ≥5.000 oy (sitedeki HOME_GATES).
    func prepareHomeShelves() async {
        let movies = uniqueMovies.lazy.filter { $0.variant == nil && $0.artwork != nil }
        let series = uniqueSeries.lazy.filter { $0.variant == nil && $0.artwork != nil }
        let movieCandidates = Array(movies.filter { ($0.rating ?? 6) >= 5.5 }.prefix(90))
        let seriesCandidates = Array(series.filter { ($0.rating ?? 6) >= 5.5 }.prefix(40))
        await ensureImdb(movieCandidates + seriesCandidates)
        func gate(_ items: [CatalogItem], minVotes: Int, limit: Int) -> [CatalogItem] {
            Array(items.filter { (verifiedRating($0, minVotes: minVotes) ?? 0) >= 6.5 }
                .sorted { (verifiedRating($0) ?? 0) > (verifiedRating($1) ?? 0) }
                .prefix(limit))
        }
        topMovies = gate(movieCandidates, minVotes: 1_000, limit: 24)
        topSeries = gate(seriesCandidates, minVotes: 1_000, limit: 24)
        featuredMovies = Array(movieCandidates.filter { (verifiedRating($0, minVotes: 5_000) ?? 0) >= 6.5 }.prefix(6))
        // Top 10: yeni filmler arasında IMDb'de çok oy almış (≥10.000) en yüksek puanlılar.
        top10Movies = Array(movieCandidates.filter { verifiedRating($0, minVotes: 10_000) != nil }
            .sorted { (verifiedRating($0, minVotes: 10_000) ?? 0) > (verifiedRating($1, minVotes: 10_000) ?? 0) }
            .prefix(10))
    }

    /// "Sıradaki bölümler": son izlenen dizilerde bitirdiğin bölümden sonraki, hiç açılmamış bölüm.
    /// Dizi son izlemenden sonra güncellendiyse "yeni bölüm" sayılır. En çok 8 dizi, bilgi 30 dk saklanır.
    func prepareUpNext() async {
        guard let provider else { return }
        var lastWatched: [String: Double] = [:]
        for entry in state.recent where entry.kind == .series {
            guard let seriesId = entry.seriesId else { continue }
            lastWatched[seriesId] = max(lastWatched[seriesId] ?? 0, entry.updatedAt)
        }
        var result: [UpNextEpisode] = []
        for (seriesId, watchedAt) in lastWatched.sorted(by: { $0.value > $1.value }).prefix(8) {
            guard let series = item(.series, id: seriesId) else { continue }
            let details: SeriesDetails
            if let cached = seriesDetailsCache[seriesId], Date().timeIntervalSince(cached.fetchedAt) < 1800 {
                details = cached.details
            } else {
                guard let fetched = try? await provider.seriesDetails(id: seriesId) else { continue }
                seriesDetailsCache[seriesId] = (fetched, Date())
                details = fetched
            }
            let episodes = details.episodes
            let watched = episodes.indices.compactMap { index -> (Int, WatchPosition)? in
                guard let position = state.position(.series, episodes[index].id), position.position > 0 else { return nil }
                return (index, position)
            }
            guard let latest = watched.max(by: { $0.1.updatedAt < $1.1.updatedAt }),
                  latest.1.duration > 0, latest.1.fraction >= 0.9, latest.0 + 1 < episodes.count else { continue }
            let next = episodes[latest.0 + 1]
            guard (state.position(.series, next.id)?.position ?? 0) <= 0 else { continue }
            let updated = (series.updatedAt ?? 0) * 1000
            result.append(UpNextEpisode(series: series, cover: details.cover, episode: next, episodes: episodes, isNew: updated > watchedAt))
        }
        upNext = result
    }

    func play(_ upNext: UpNextEpisode) {
        let base = PlaybackItem(kind: .series, contentId: upNext.episode.id, seriesId: upNext.series.id, title: upNext.series.title,
                                artwork: upNext.cover ?? upNext.series.artwork, ext: upNext.episode.ext, startAt: 0,
                                episodes: upNext.episodes, seriesTitle: upNext.series.title)
        play(episodeItem(upNext.episode, from: base))
    }

    /// İzlendi / izlenmedi işareti (PC ile ortak konum kaydı): izlendi = sonuna kadar, izlenmedi = başa.
    func setWatched(_ watched: Bool, kind: ContentKind, id: String, duration: Double?) {
        let length = max(1, duration ?? state.position(kind, id)?.duration ?? 1)
        saveProgress(kind: kind, id: id, position: watched ? length : 0, duration: length, allowZero: true)
        if watched { upNext.removeAll { $0.episode.id == id } }
    }

    func isWatched(_ kind: ContentKind, _ id: String) -> Bool {
        guard let position = position(kind, id), position.duration > 0 else { return false }
        return position.fraction >= 0.95
    }

    /// Son izlenenlerin türlerinden (kategori adı) en sık iki tür için öneri rafları: izlenmemiş,
    /// afişli, puanı fena olmayan en yeni içerikler.
    func prepareRecommendations() {
        var score: [String: Int] = [:]
        var seed: [String: String] = [:]
        var kinds: [String: Set<ContentKind>] = [:]
        var watched = Set<String>()
        for entry in state.recent.prefix(25) {
            guard let kind = entry.kind, kind != .live else { continue }
            let base = kind == .series ? entry.seriesId.flatMap { item(.series, id: $0) } : item(.movie, id: entry.id)
            guard let base, let category = base.categoryId else { continue }
            watched.insert(base.searchKey)
            for slug in genreIndex[base.kind]?[category] ?? [] {
                score[slug, default: 0] += 1
                kinds[slug, default: []].insert(base.kind)
                if seed[slug] == nil { seed[slug] = base.title }
            }
        }
        let top = score.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(2).map(\.key)
        forYou = top.compactMap { slug -> HomeShelf? in
            guard let genre = MovieGenre.all.first(where: { $0.slug == slug }) else { return nil }
            var picks: [CatalogItem] = []
            for kind in [ContentKind.movie, .series] where kinds[slug]?.contains(kind) == true {
                let inGenre = Set(items(kind).filter { hasGenre($0, slug) }.map(\.searchKey))
                picks += uniqueItems(kind).lazy.filter {
                    inGenre.contains($0.searchKey) && !watched.contains($0.searchKey) && $0.variant == nil && $0.artwork != nil && ($0.trustedRating ?? 0) >= 6.5
                }.prefix(20)
            }
            guard picks.count >= 4 else { return nil }
            let title = seed[slug].map { "\(genre.label) · \($0) izlediğin için" } ?? genre.label
            return HomeShelf(id: slug, title: title, items: Array(picks.prefix(24)))
        }
    }

    /// Ana sayfanın katalog/profil tabanlı raflarını tek sefer hesaplar.
    func prepareHomeDashboard() {
        let movies = uniqueMovies.filter { $0.variant == nil }
        let seriesItems = uniqueSeries.filter { $0.variant == nil }
        let allContinue = continueWatching.filter { entry in
            guard let kind = entry.entry.kind else { return false }
            if kind == .movie {
                return item(.movie, id: entry.entry.id)?.variant == nil
            }
            if kind == .series, let seriesId = entry.entry.seriesId {
                return item(.series, id: seriesId)?.variant == nil
            }
            return kind != .live
        }
        let almostDone = allContinue.filter { $0.position.fraction >= 0.85 }
        let regularContinue = allContinue.filter { $0.position.fraction < 0.85 }

        var watchedSearchKeys = Set<String>()
        for entry in state.recent {
            guard let kind = entry.kind else { continue }
            if kind == .movie, let known = item(.movie, id: entry.id) {
                watchedSearchKeys.insert(known.searchKey)
            } else if kind == .series, let seriesId = entry.seriesId, let known = item(.series, id: seriesId) {
                watchedSearchKeys.insert(known.searchKey)
            }
        }

        var replaySeen = Set<String>()
        let replay = state.recent.sorted { $0.updatedAt > $1.updatedAt }.compactMap { entry -> CatalogItem? in
            guard entry.kind == .movie,
                  let position = position(.movie, entry.id), position.fraction >= 0.95,
                  let known = item(.movie, id: entry.id), known.variant == nil,
                  replaySeen.insert(known.searchKey).inserted else { return nil }
            return known
        }

        let availableSlugs = Set(availableGenres(.movie).map(\.slug) + availableGenres(.series).map(\.slug))
        let available = MovieGenre.all.filter { availableSlugs.contains($0.slug) }
        let day = Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 1
        var selectedGenres: [MovieGenre] = []
        if !available.isEmpty {
            selectedGenres.append(available[(day - 1) % available.count])
            if available.count > 1 {
                var second = available[(day * 5 + 3) % available.count]
                if second.slug == selectedGenres[0].slug {
                    second = available[day % available.count]
                }
                selectedGenres.append(second)
            }
        }
        let dailyGenres = selectedGenres.compactMap { genre -> HomeShelf? in
            let moviePicks = movies.lazy.filter {
                self.hasGenre($0, genre.slug) && !watchedSearchKeys.contains($0.searchKey) && $0.artwork != nil
            }.prefix(30)
            let seriesPicks = seriesItems.lazy.filter {
                self.hasGenre($0, genre.slug) && !watchedSearchKeys.contains($0.searchKey) && $0.artwork != nil
            }.prefix(30)
            let items = Array((Array(moviePicks) + Array(seriesPicks)).prefix(48))
            guard items.count >= 4 else { return nil }
            return HomeShelf(id: "daily-\(genre.slug)", title: "Bugünün \(genre.label) seçkisi", items: items)
        }

        let luckyCandidates = movies.filter { candidate in
            guard candidate.artwork != nil, !watchedSearchKeys.contains(candidate.searchKey) else { return false }
            return (verifiedRating(candidate, minVotes: 1_000) ?? candidate.trustedRating ?? 0) >= 6.5
        }
        luckyMovieCandidates = luckyCandidates
        let currentLucky = home.luckyMovie.flatMap { current in
            luckyCandidates.first { $0.key == current.key }
        }

        let startOfToday = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        home = HomeDashboard(
            featuredFallback: Array(movies.prefix(200).filter { $0.artwork != nil && ($0.trustedRating ?? 6) >= 6 }.prefix(6)),
            continueWatching: regularContinue,
            almostDone: almostDone,
            replay: Array(replay.prefix(60)),
            myList: myList.filter { $0.variant == nil },
            favorites: channels(state.favoriteLiveChannelIds),
            newMovies: Array(movies.prefix(200)),
            newSeries: Array(seriesItems.prefix(200)),
            dailyGenres: dailyGenres,
            todayMovieCount: movies.reduce(into: 0) { count, movie in
                if (movie.addedAt ?? 0) >= startOfToday { count += 1 }
            },
            luckyMovie: currentLucky ?? luckyCandidates.randomElement()
        )
    }

    func shuffleLuckyMovie() {
        let alternatives = luckyMovieCandidates.filter { $0.key != home.luckyMovie?.key }
        home.luckyMovie = (alternatives.isEmpty ? luckyMovieCandidates : alternatives).randomElement()
    }

    /// "Puana göre" sıralama: IMDb'de yeterli oyu olanlar IMDb puanıyla önde; ötekiler sağlayıcı puanıyla
    /// (şişkin 9,3+ değerler puansız sayılır) arkada. Adayların IMDb'si ensureImdb ile önceden alınır.
    func rankedByRating(_ items: [CatalogItem]) -> [CatalogItem] {
        items.sorted { left, right in
            let l = verifiedRating(left), r = verifiedRating(right)
            switch (l, r) {
            case let (l?, r?): return l > r
            case (.some, .none): return true
            case (.none, .some): return false
            default: return (left.trustedRating ?? 0) > (right.trustedRating ?? 0)
            }
        }
    }



    // MARK: Canlı yayın akışı

    /// Görünen kanalın akışı; kanal başına 5 dk'da bir, hata sonrası dakikada bir (sitedeki kural).
    func loadEpg(_ channelId: String) async {
        let now = Date()
        if let loaded = epgLoadedAt[channelId], now.timeIntervalSince(loaded) < 300 { return }
        if let attempt = epgAttemptAt[channelId], now.timeIntervalSince(attempt) < 60 { return }
        // Hızlı kaydırmada her satır için sorgu gitmesin: satır bir an görünür kalırsa istenir.
        try? await Task.sleep(nanoseconds: 350_000_000)
        guard !Task.isCancelled, let provider else { return }
        epgAttemptAt[channelId] = Date()
        guard let entries = try? await provider.shortEpg(channelId: channelId) else { return }
        epg[channelId] = entries
        epgLoadedAt[channelId] = Date()
    }

    func nowNext(_ channelId: String) -> EpgNowNext? {
        guard let entries = epg[channelId], !entries.isEmpty else { return nil }
        return EpgNowNext(entries)
    }

    // MARK: İzleme ilerlemesi (PC ile ortak)

    /// Kendi kaydı yoksa aynı filmin başka kopyasındaki konum (sitedeki shareProgressAcrossCopies).
    func position(_ kind: ContentKind, _ id: String) -> WatchPosition? {
        if let own = state.position(kind, id) { return own }
        guard kind == .movie, let key = copyKeyById[id], let ids = copiesByKey[key] else { return nil }
        return ids.compactMap { state.position(.movie, $0) }.max { $0.updatedAt < $1.updatedAt }
    }

    /// Açılışta nereden başlanacağı: en az 10 sn izlenmiş ve bitmemişse kaldığı yer (sitedeki gibi).
    func resumePosition(_ kind: ContentKind, _ id: String) -> Double {
        guard kind != .live, let position = position(kind, id), position.position >= 10 else { return 0 }
        if position.duration > 0, position.fraction >= 0.95 { return 0 }
        return position.position
    }

    var continueWatching: [ContinueItem] {
        state.recent.compactMap { entry -> ContinueItem? in
            guard let kind = entry.kind, kind != .live, let position = self.position(kind, entry.id), position.isContinuable else { return nil }
            return ContinueItem(entry: entry, position: position)
        }
        .sorted { max($0.entry.updatedAt, $0.position.updatedAt) > max($1.entry.updatedAt, $1.position.updatedAt) }
    }

    func saveProgress(kind: ContentKind, id: String, position: Double, duration: Double, allowZero: Bool = false) {
        guard kind != .live, position > 0 || allowZero else { return }
        let now = (Date().timeIntervalSince1970 * 1000).rounded()
        state.positions["\(kind.rawValue):\(id)"] = WatchPosition(position: position, duration: duration, updatedAt: now)
        homeGeneration &+= 1
        mutate(["type": "setProgress", "kind": kind.rawValue, "id": id, "position": position, "duration": duration, "updatedAt": now])
    }

    /// "İzlemeye devam et"ten kaldırır (PC'deki listeden de).
    func removeRecent(_ item: ContinueItem) {
        guard let kind = item.entry.kind else { return }
        let id = item.entry.id
        state.recent.removeAll { $0.kind == kind && $0.id == id }
        homeGeneration &+= 1
        mutate(["type": "removeRecent", "kind": kind.rawValue, "id": id])
    }

    private func recordRecent(_ item: PlaybackItem) {
        let now = (Date().timeIntervalSince1970 * 1000).rounded()
        var entry: [String: Any] = [
            "kind": item.kind.rawValue,
            "id": item.contentId,
            "title": item.title,
            "artwork": item.artwork ?? "",
            "extension": item.ext ?? "",
            "updatedAt": now,
        ]
        if let seriesId = item.seriesId {
            entry["seriesId"] = seriesId
            entry["href"] = "/series/\(seriesId)?episode=\(item.contentId)"
        } else {
            entry["href"] = "/\(item.kind.rawValue)/\(item.contentId)"
        }
        state.recent.removeAll { $0.kind == item.kind && $0.id == item.contentId }
        state.recent.insert(RecentEntry(kind: item.kind, id: item.contentId, seriesId: item.seriesId, title: item.title, artwork: item.artwork, ext: item.ext, updatedAt: now), at: 0)
        homeGeneration &+= 1
        mutate(["type": "upsertRecent", "item": entry])
    }

    // MARK: Listem ve favori kanallar (PC ile ortak)

    var myList: [CatalogItem] {
        state.myList.sorted { $0.updatedAt > $1.updatedAt }.compactMap { entry in
            guard let kind = entry.kind else { return nil }
            if let known = item(kind, id: entry.id) { return known }
            return CatalogItem(id: entry.id, kind: kind, title: entry.title, artwork: entry.artwork, ext: entry.ext, year: nil, rating: nil, categoryId: nil, addedAt: nil, searchKey: TextFold.fold(entry.title), variant: nil)
        }
    }

    func isSaved(_ item: CatalogItem) -> Bool {
        state.isSaved(item.kind, item.id)
    }

    func toggleMyList(_ item: CatalogItem) {
        let saved = !isSaved(item)
        let now = (Date().timeIntervalSince1970 * 1000).rounded()
        var entry: [String: Any] = [
            "kind": item.kind.rawValue,
            "id": item.id,
            "title": item.title,
            "artwork": item.artwork ?? "",
            "href": "/\(item.kind.rawValue)/\(item.id)",
            "updatedAt": now,
        ]
        if let ext = item.ext { entry["extension"] = ext }
        state.myList.removeAll { $0.kind == item.kind && $0.id == item.id }
        if saved {
            state.myList.insert(RecentEntry(kind: item.kind, id: item.id, seriesId: nil, title: item.title, artwork: item.artwork, ext: item.ext, updatedAt: now), at: 0)
        }
        homeGeneration &+= 1
        mutate(["type": "setMyList", "saved": saved, "item": entry])
    }

    func isFavorite(_ channelId: String) -> Bool {
        state.favoriteLiveChannelIds.contains(channelId)
    }

    func toggleFavorite(_ channelId: String) {
        let saved = !isFavorite(channelId)
        state.favoriteLiveChannelIds.removeAll { $0 == channelId }
        if saved { state.favoriteLiveChannelIds.insert(channelId, at: 0) }
        homeGeneration &+= 1
        mutate(["type": "setLiveFavorite", "channelId": channelId, "saved": saved])
    }

    func channels(_ ids: [String]) -> [CatalogItem] {
        ids.compactMap { item(.live, id: $0) }
    }

    // MARK: Oynatma tercihleri (PC ile ortak)

    func savePlaybackPreferences(_ changes: [String: Any]) {
        if let value = changes["audioLanguage"] as? String { state.playbackPreferences.audioLanguage = value }
        if let value = changes["subtitleLanguage"] as? String { state.playbackPreferences.subtitleLanguage = value }
        if let value = changes["subtitlesEnabled"] as? Bool { state.playbackPreferences.subtitlesEnabled = value }
        if let value = changes["playbackRate"] as? Double { state.playbackPreferences.playbackRate = value }
        mutate(["type": "setPlaybackPreferences", "preferences": changes])
    }

    func setAutoNextEpisode(_ enabled: Bool) {
        state.autoNextEpisode = enabled
        mutate(["type": "setAutoNextEpisode", "enabled": enabled])
    }

    // MARK: Oynatma

    func play(_ playback: PlaybackItem) {
        presentPlayer(playback, allowAutomaticReconnect: true, recordActivity: true)
    }

    private func presentPlayer(_ playback: PlaybackItem, allowAutomaticReconnect: Bool, recordActivity: Bool) {
        var item = playback
        if item.kind == .live {
            let epg = nowNext(item.contentId)
            if let current = epg?.current {
                if item.programTitle == nil { item.programTitle = current.title }
                if item.programEnd == nil { item.programEnd = current.end }
            }
            if let next = epg?.next {
                item.nextProgramTitle = next.title
                item.nextProgramStart = next.start
            }
        }
        guard let url = provider?.streamURL(kind: item.kind, id: item.contentId, ext: item.ext) else { return }
        if recordActivity, item.kind == .live {
            state.recentLiveChannelIds.removeAll { $0 == item.contentId }
            state.recentLiveChannelIds.insert(item.contentId, at: 0)
            mutate(["type": "recordLiveChannel", "channelId": item.contentId])
        } else if recordActivity {
            recordRecent(item)
        }
        let player = PlayerViewController(
            item: item,
            url: url,
            preferences: state.playbackPreferences,
            allowAutomaticReconnect: allowAutomaticReconnect,
            autoNextEpisode: state.autoNextEpisode
        )
        player.onProgress = { [weak self] position, duration in
            self?.saveProgress(kind: item.kind, id: item.contentId, position: position, duration: duration)
        }
        player.onPreferences = { [weak self] changes in
            self?.savePlaybackPreferences(changes)
        }
        player.onFinish = { [weak self] position, duration, reason in
            guard let self else { return }
            self.saveProgress(kind: item.kind, id: item.contentId, position: position, duration: duration)
            switch reason {
            case .reconnect:
                let restarted = self.restarting(item, at: position)
                self.presentPlayer(restarted, allowAutomaticReconnect: false, recordActivity: false)
            case .retry:
                let restarted = self.restarting(item, at: position)
                self.presentPlayer(restarted, allowAutomaticReconnect: true, recordActivity: false)
            case .tv:
                Task { await self.tv.play(item, at: position) }
            case .ended where self.state.autoNextEpisode, .next:
                if let next = item.nextEpisode { self.play(self.episodeItem(next, from: item)) }
            case .previousEpisode:
                if let previous = item.previousEpisode { self.play(self.episodeItem(previous, from: item)) }
            case .episode(let id):
                if let episode = item.episodes.first(where: { $0.id == id }) { self.play(self.episodeItem(episode, from: item)) }
            case .channel(let id):
                if let channel = item.channels.first(where: { $0.id == id }) {
                    var playback = channel.livePlayback
                    playback.channels = item.channels
                    self.play(playback)
                }
            case .previousChannel, .nextChannel:
                let list = item.channels
                guard list.count > 1, let index = list.firstIndex(where: { $0.id == item.contentId }) else { break }
                let step = reason == .nextChannel ? 1 : -1
                var neighbour = list[(index + step + list.count) % list.count].livePlayback
                neighbour.channels = list
                self.play(neighbour)
            default:
                break
            }
        }
        PlayerPresenter.present(player)
    }

    private func restarting(_ item: PlaybackItem, at position: Double) -> PlaybackItem {
        var restarted = PlaybackItem(
            kind: item.kind,
            contentId: item.contentId,
            seriesId: item.seriesId,
            title: item.title,
            artwork: item.artwork,
            ext: item.ext,
            startAt: item.kind == .live ? 0 : max(0, position),
            episodes: item.episodes,
            seriesTitle: item.seriesTitle
        )
        restarted.channels = item.channels
        restarted.programTitle = item.programTitle
        restarted.programEnd = item.programEnd
        restarted.nextProgramTitle = item.nextProgramTitle
        restarted.nextProgramStart = item.nextProgramStart
        return restarted
    }

    func episodeItem(_ episode: Episode, from item: PlaybackItem) -> PlaybackItem {
        let seriesTitle = item.seriesTitle ?? item.title
        return PlaybackItem(
            kind: .series,
            contentId: episode.id,
            seriesId: item.seriesId,
            title: "\(seriesTitle) · S\(episode.season) B\(episode.number) · \(episode.title)",
            artwork: episode.image ?? item.artwork,
            ext: episode.ext,
            startAt: resumePosition(.series, episode.id),
            episodes: item.episodes,
            seriesTitle: seriesTitle
        )
    }

    /// "İzlemeye devam et" kaydından oynatılacak içerik; dizide sıradaki bölüm için bölüm listesi de alınır.
    func playbackItem(for item: ContinueItem) async -> PlaybackItem? {
        let entry = item.entry
        guard let kind = entry.kind else { return nil }
        var episodes: [Episode] = []
        var seriesTitle: String?
        if kind == .series, let seriesId = entry.seriesId, let provider {
            if let details = try? await provider.seriesDetails(id: seriesId) {
                episodes = details.episodes
            }
            seriesTitle = entry.title.components(separatedBy: " · ").first
        }
        let ext = entry.ext.flatMap { $0.isEmpty ? nil : $0 } ?? (kind == .movie ? "mp4" : "mkv")
        return PlaybackItem(
            kind: kind,
            contentId: entry.id,
            seriesId: entry.seriesId,
            title: entry.title,
            artwork: entry.artwork,
            ext: ext,
            startAt: item.position.position,
            episodes: episodes,
            seriesTitle: seriesTitle
        )
    }

    func resume(_ item: ContinueItem) async {
        if let playback = await playbackItem(for: item) { play(playback) }
    }

    func restart(_ item: ContinueItem) async {
        guard let playback = await playbackItem(for: item) else { return }
        play(PlaybackItem(kind: playback.kind, contentId: playback.contentId, seriesId: playback.seriesId, title: playback.title,
                          artwork: playback.artwork, ext: playback.ext, startAt: 0, episodes: playback.episodes, seriesTitle: playback.seriesTitle))
    }

    func resumeOnTv(_ item: ContinueItem) async {
        if let playback = await playbackItem(for: item) { await tv.play(playback, at: playback.startAt) }
    }
}

struct UpNextEpisode: Identifiable {
    let series: CatalogItem
    let cover: String?
    let episode: Episode
    let episodes: [Episode]
    let isNew: Bool
    var id: String { series.key }
}

struct HomeShelf: Identifiable {
    let id: String
    let title: String
    let items: [CatalogItem]
}

/// Oynatıcı tam ekran ve yatay açılsın diye UIKit'ten sunulur.
@MainActor
enum PlayerPresenter {
    static func present(_ controller: UIViewController) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first?.windows.first,
              var top = window.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        top.present(controller, animated: true)
    }
}
