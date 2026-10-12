import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        let movies = app.uniqueMovies.filter { $0.variant == nil }
        let series = app.uniqueSeries.filter { $0.variant == nil }
        let resume = app.continueWatching
        let favorites = app.channels(app.state.favoriteLiveChannelIds)
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                let featured = app.featuredMovies.isEmpty ? featuredItems(movies) : app.featuredMovies
                if featured.isEmpty {
                    Color.clear.frame(height: 90)
                } else {
                    FeaturedCarousel(items: featured)
                }
                if !resume.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "İzlemeye devam et")
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 12) {
                                ForEach(resume) { item in
                                    ContinueCard(item: item)
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                }
                if !app.upNext.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "Sıradaki bölümler")
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 12) {
                                ForEach(app.upNext) { item in UpNextCard(item: item) }
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                }
                PosterRow(title: "Listem", items: app.myList)
                ForEach(app.forYou) { shelf in
                    PosterRow(title: shelf.title, items: shelf.items)
                }
                if !favorites.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "Favori kanallar")
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 10) {
                                ForEach(favorites, id: \.key) { channel in
                                    ChannelTile(channel: channel, playlist: favorites)
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                }
                CatalogStatus(kind: .movie)
                TopTenRow(items: app.top10Movies)
                PosterRow(title: "Yeni eklenen filmler", items: Array(movies.prefix(30)))
                PosterRow(title: "Yeni eklenen diziler", items: Array(series.prefix(30)))
                PosterRow(title: "IMDb'de yüksek puanlı filmler", items: app.topMovies)
                PosterRow(title: "IMDb'de yüksek puanlı diziler", items: app.topSeries)
            }
            .padding(.bottom, 24)
        }
        .ignoresSafeArea(edges: .top)
        .overlay(alignment: .top) { HomeHeader() }
        .refreshable {
            await app.refreshState()
            await app.loadLibrary(force: true)
        }
        .task { await app.loadCatalog(.live) }
        .task(id: app.uniqueMovies.count + app.uniqueSeries.count) { await app.prepareHomeShelves() }
        .task(id: recommendationKey) {
            app.prepareRecommendations()
            await app.prepareUpNext()
        }
        .toolbar(.hidden, for: .navigationBar)
        .fenotipNavigation()
    }

    private var recommendationKey: String {
        "\(app.state.recent.prefix(6).map(\.id).joined(separator: ","))|\(app.movies.count)|\(app.series.count)"
    }

    /// Vitrin (IMDb sonucu gelene kadar): en yeni, afişli ve puanı fena olmayan filmler.
    private func featuredItems(_ movies: [CatalogItem]) -> [CatalogItem] {
        Array(movies.prefix(200).filter { $0.artwork != nil && ($0.trustedRating ?? 6) >= 6 }.prefix(6))
    }
}

/// Üstte logo, TV ve profil; vitrinin üzerinde, okunur kalsın diye koyu geçişli.
private struct HomeHeader: View {
    @EnvironmentObject private var tv: TvRemote

    var body: some View {
        HStack(spacing: 18) {
            BrandLogo(height: 38)
            Spacer()
            Button { tv.open() } label: {
                Image(systemName: tv.link == nil ? "tv" : "appletvremote.gen4.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
            }
            .accessibilityLabel(tv.link == nil ? "TV'ye bağlan" : "TV kumandası")
            ProfileMenu()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .background(
            LinearGradient(colors: [Color.black.opacity(0.85), Color.black.opacity(0)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .top)
        )
    }
}

struct FeaturedCarousel: View {
    let items: [CatalogItem]
    @State private var page = 0

    var body: some View {
        TabView(selection: $page) {
            ForEach(Array(items.enumerated()), id: \.element.key) { index, item in
                FeaturedSlide(item: item).tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .frame(height: 520)
    }
}

private struct FeaturedSlide: View {
    @EnvironmentObject private var app: AppModel
    let item: CatalogItem
    @State private var backdrop: URL?

    var body: some View {
        let saved = app.isSaved(item)
        ZStack(alignment: .bottomLeading) {
            Rectangle()
                .fill(Theme.card)
                .overlay { RemoteImage(url: backdrop ?? item.artworkURL, maxPixel: 1600) }
                .clipped()
            LinearGradient(colors: [Color.black.opacity(0), Theme.background.opacity(0.75), Theme.background], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 10) {
                Text("BUGÜN ÖNE ÇIKAN")
                    .font(.caption2.weight(.heavy))
                    .tracking(2)
                    .foregroundStyle(Theme.accent)
                Text(item.title)
                    .font(.system(size: 30, weight: .heavy))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                Text([item.year.map { String($0) }, app.imdbRating(item).map { String(format: "IMDb %.1f", $0) } ?? item.trustedRating.map { String(format: "★ %.1f", $0) }].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(Theme.muted)
                HStack(spacing: 12) {
                    Button {
                        app.play(PlaybackItem(kind: .movie, contentId: item.id, seriesId: nil, title: item.title, artwork: item.artwork, ext: item.ext ?? "mp4", startAt: app.resumePosition(.movie, item.id), episodes: [], seriesTitle: nil))
                    } label: {
                        Label(app.resumePosition(.movie, item.id) > 0 ? "Devam et" : "İzle", systemImage: "play.fill")
                            .font(.headline)
                            .padding(.horizontal, 22).padding(.vertical, 11)
                            .background(Color.white, in: Capsule())
                            .foregroundStyle(Color.black)
                    }
                    Button {
                        app.toggleMyList(item)
                    } label: {
                        Image(systemName: saved ? "checkmark" : "plus")
                            .font(.headline)
                            .frame(width: 44, height: 44)
                            .background(Color.white.opacity(0.18), in: Circle())
                            .foregroundStyle(Color.white)
                    }
                    .accessibilityLabel(saved ? "Listemden çıkar" : "Listeme ekle")
                    NavigationLink(value: item) {
                        Image(systemName: "info.circle")
                            .font(.headline)
                            .frame(width: 44, height: 44)
                            .background(Color.white.opacity(0.18), in: Circle())
                            .foregroundStyle(Color.white)
                    }
                    .accessibilityLabel("Detay")
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 40)
        }
        .task { backdrop = await app.backdrop(for: item) }
    }
}

struct ContinueCard: View {
    @EnvironmentObject private var app: AppModel
    let item: ContinueItem

    var body: some View {
        // Dizi kaydı "Dizi · S1 B1 · Bölüm" biçiminde: ilk satır dizi adı, ikinci satır bölüm.
        let parts = item.entry.title.components(separatedBy: " · ")
        let headline = parts.first ?? item.entry.title
        let detail = parts.count > 1 ? parts.dropFirst().joined(separator: " · ") : nil
        ZStack(alignment: .topTrailing) {
            Button {
                Task { await app.resume(item) }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Rectangle()
                        .fill(Theme.card)
                        .frame(width: 230, height: 130)
                        .overlay { RemoteImage(url: item.entry.artwork.flatMap { URL(string: $0) }) }
                        .overlay(Color.black.opacity(0.2))
                        .overlay {
                            Image(systemName: "play.circle.fill").font(.system(size: 42)).foregroundStyle(.white.opacity(0.92))
                        }
                        .overlay(alignment: .bottom) { ProgressBar(value: item.position.fraction) }
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .padding(.bottom, 4)
                    Text(headline).font(.subheadline.weight(.semibold)).lineLimit(1).foregroundStyle(.white)
                    if let detail {
                        Text(detail).font(.caption).lineLimit(1).foregroundStyle(Theme.muted)
                    }
                    Text(remaining).font(.caption2).foregroundStyle(Theme.accent)
                }
                .frame(width: 230, alignment: .leading)
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button { Task { await app.resumeOnTv(item) } } label: { Label("TV'de devam et", systemImage: "tv") }
                Button { Task { await app.restart(item) } } label: { Label("Baştan başla", systemImage: "arrow.counterclockwise") }
                if let kind = item.entry.kind {
                    Button { app.setWatched(true, kind: kind, id: item.entry.id, duration: item.position.duration) } label: {
                        Label("İzlendi olarak işaretle", systemImage: "checkmark.circle")
                    }
                }
                Button(role: .destructive) { app.removeRecent(item) } label: { Label("Listeden kaldır", systemImage: "xmark.circle") }
            }
            Button { app.removeRecent(item) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.white)
                    .frame(width: 28, height: 28)
                    .background(Color.black.opacity(0.65), in: Circle())
            }
            .buttonStyle(.plain)
            .padding(6)
            .accessibilityLabel("İzlemeye devam et listesinden kaldır")
        }
    }

    private var remaining: String {
        let minutes = max(1, Int(((item.position.duration - item.position.position) / 60).rounded()))
        if minutes < 60 { return "\(minutes) dk kaldı" }
        let rest = minutes % 60
        return rest > 0 ? "\(minutes / 60) sa \(rest) dk kaldı" : "\(minutes / 60) sa kaldı"
    }
}

/// "Sıradaki bölümler" kartı: dokununca bölüm doğrudan başlar.
struct UpNextCard: View {
    @EnvironmentObject private var app: AppModel
    let item: UpNextEpisode

    var body: some View {
        Button {
            app.play(item)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Rectangle()
                    .fill(Theme.card)
                    .frame(width: 230, height: 130)
                    .overlay { RemoteImage(url: (item.episode.image ?? item.cover ?? item.series.artwork).flatMap { URL(string: $0) }) }
                    .overlay(Color.black.opacity(0.2))
                    .overlay {
                        Image(systemName: "play.circle.fill").font(.system(size: 42)).foregroundStyle(.white.opacity(0.92))
                    }
                    .overlay(alignment: .topLeading) {
                        if item.isNew {
                            Text("YENİ BÖLÜM")
                                .font(.caption2.weight(.heavy))
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 4))
                                .foregroundStyle(.black)
                                .padding(8)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.bottom, 4)
                Text(item.series.title).font(.subheadline.weight(.semibold)).lineLimit(1).foregroundStyle(.white)
                Text("S\(item.episode.season) B\(item.episode.number) · \(item.episode.title)").font(.caption).lineLimit(1).foregroundStyle(Theme.muted)
            }
            .frame(width: 230, alignment: .leading)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { app.setWatched(true, kind: .series, id: item.episode.id, duration: item.episode.durationSecs) } label: {
                Label("İzlendi olarak işaretle", systemImage: "checkmark.circle")
            }
        }
    }
}

struct ProfileMenu: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var tv: TvRemote
    @State private var showSettings = false

    var body: some View {
        Menu {
            if let profile = app.profile { Text("\(profile.emoji) \(profile.name)") }
            Button { showSettings = true } label: { Label("Ayarlar", systemImage: "gearshape") }
            Toggle(isOn: Binding(get: { app.state.autoNextEpisode }, set: { app.setAutoNextEpisode($0) })) {
                Label("Sonraki bölüm otomatik", systemImage: "forward.end")
            }
            Button { tv.open() } label: { Label(tv.link == nil ? "TV'ye bağlan" : "TV kumandası", systemImage: "tv") }
            Button { app.switchProfile() } label: { Label("Profil değiştir", systemImage: "person.2") }
            Button { Task { await app.loadLibrary(force: true) } } label: { Label("Kataloğu yenile", systemImage: "arrow.clockwise") }
            Button(role: .destructive) { Task { await app.logout() } } label: { Label("Çıkış yap", systemImage: "rectangle.portrait.and.arrow.right") }
        } label: {
            Text(app.profile?.emoji ?? "👤").font(.title3)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(app).environmentObject(tv)
        }
    }
}

/// Filmler / Diziler: sitedeki gibi tür kısayolları + süzgeç (kategori, yıl, puan, sıralama) + arama.
struct LibraryView: View {
    enum SortMode: String, CaseIterable, Identifiable {
        case newest = "En yeni"
        case rating = "Puana göre"
        case year = "Yıla göre"
        case title = "A–Z"
        var id: String { rawValue }
    }

    @EnvironmentObject private var app: AppModel
    let kind: ContentKind
    @State private var genre: String?
    @State private var category: String?
    @State private var year: Int?
    @State private var minRating: Double?
    @State private var query = ""
    @State private var sort = SortMode.newest
    @State private var limit = 90

    private var filtersActive: Bool { category != nil || year != nil || minRating != nil || sort != .newest }

    var body: some View {
        let genres = app.availableGenres(kind)
        let usedCategories = Set(app.items(kind).compactMap(\.categoryId))
        let categories = (app.categories[kind] ?? []).filter { usedCategories.contains($0.id) }
        let matches = filter()
        let filtered = sorted(matches)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !genres.isEmpty { GenreChips(genres: genres, selected: $genre) }
                CatalogStatus(kind: kind)
                if !app.items(kind).isEmpty {
                    HStack {
                        Text(summary(count: filtered.count, categories: categories)).font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
                        if sort == .rating && app.imdbLoading {
                            ProgressView().controlSize(.mini).tint(.white)
                            Text("IMDb kontrol ediliyor").font(.caption2).foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        if filtersActive || genre != nil {
                            Button("Temizle") { clearFilters() }.font(.caption.weight(.semibold))
                        }
                    }
                    .padding(.horizontal, 16)
                    if filtered.isEmpty {
                        EmptyNote(text: "Bu süzgeçle içerik bulunamadı.")
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12)], spacing: 18) {
                        ForEach(filtered.prefix(limit), id: \.key) { item in
                            NavigationLink(value: item) {
                                PosterCard(item: item, progress: app.position(item.kind, item.id)?.fraction)
                            }
                            .buttonStyle(.plain)
                            .myListMenu(item)
                        }
                    }
                    .padding(.horizontal, 16)
                    if filtered.count > limit {
                        Button("Daha fazla göster") { limit += 90 }
                            .buttonStyle(.bordered)
                            .frame(maxWidth: .infinity)
                            .onAppear { limit += 90 }
                    }
                }
            }
            .padding(.vertical, 12)
        }
        .searchable(text: $query, prompt: kind == .movie ? "Film ara" : "Dizi ara")
        .onChange(of: genre) { _ in limit = 90 }
        .onChange(of: category) { _ in limit = 90 }
        .onChange(of: year) { _ in limit = 90 }
        .onChange(of: minRating) { _ in limit = 90 }
        .onChange(of: query) { _ in limit = 90 }
        .onChange(of: sort) { _ in limit = 90 }
        .task(id: ratingTaskKey(matches.count)) {
            // Puana göre sıralamada en üstteki adayların IMDb oy sayısına bakılır (tek oyla 10 olanlar öne geçmesin).
            guard sort == .rating else { return }
            await app.loadTopRated(kind)
            await app.ensureImdb(app.ratingCandidates(matches))
        }
        .navigationTitle(kind == .movie ? "Filmler" : "Diziler")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                filterMenu(categories: categories)
            }
        }
        .task { await app.loadCatalog(kind) }
        .refreshable { await app.loadCatalog(kind, force: true) }
        .fenotipNavigation()
    }

    private func filterMenu(categories: [ProviderCategory]) -> some View {
        Menu {
            Picker("Sıralama", selection: $sort) {
                ForEach(SortMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
            }
            Menu("Puan: \(minRating.map { String(format: "%.0f+", $0) } ?? "Tümü")") {
                Picker("Puan", selection: $minRating) {
                    Text("Tüm puanlar").tag(Double?.none)
                    ForEach([6.0, 7.0, 8.0], id: \.self) { value in Text(String(format: "%.0f+", value)).tag(Double?.some(value)) }
                }
            }
            Menu("Yıl: \(year.map { String($0) } ?? "Tümü")") {
                Picker("Yıl", selection: $year) {
                    Text("Tüm yıllar").tag(Int?.none)
                    ForEach(yearOptions, id: \.self) { value in Text(String(value)).tag(Int?.some(value)) }
                }
            }
            if !categories.isEmpty {
                Menu("Kategori: \(categories.first(where: { $0.id == category })?.name ?? "Tümü")") {
                    Picker("Kategori", selection: $category) {
                        Text("Tüm kategoriler").tag(String?.none)
                        ForEach(categories) { item in Text(item.name).tag(String?.some(item.id)) }
                    }
                }
            }
            if filtersActive {
                Button(role: .destructive) { clearFilters() } label: { Label("Süzgeçleri temizle", systemImage: "xmark.circle") }
            }
        } label: {
            Image(systemName: filtersActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .font(.title3)
        }
        .accessibilityLabel("Süzgeç ve sıralama")
    }

    private func ratingTaskKey(_ count: Int) -> String {
        "\(sort.rawValue)|\(genre ?? "")|\(category ?? "")|\(year ?? 0)|\(minRating ?? 0)|\(query)|\(count)"
    }

    private var yearOptions: [Int] {
        let current = Calendar.current.component(.year, from: Date())
        return Array((1950...current).reversed())
    }

    private func clearFilters() {
        genre = nil
        category = nil
        year = nil
        minRating = nil
        sort = .newest
    }

    private func summary(count: Int, categories: [ProviderCategory]) -> String {
        var parts = ["\(count.formatted()) içerik"]
        if let genre, let label = MovieGenre.all.first(where: { $0.slug == genre })?.label { parts.append(label) }
        if let category, let name = categories.first(where: { $0.id == category })?.name { parts.append(name) }
        if let year { parts.append(String(year)) }
        if let minRating { parts.append(String(format: "%.0f+", minRating)) }
        parts.append(sort.rawValue)
        return parts.joined(separator: " · ")
    }

    /// Tür ve kategori bütün kopyalar üzerinde aranır (aynı film birkaç kategoride), sonra kopyalar birleştirilir.
    private func filter() -> [CatalogItem] {
        let tokens = TextFold.tokens(query)
        let narrowing = genre != nil || category != nil
        let source = narrowing ? app.items(kind) : app.uniqueItems(kind)
        let result = source.filter { item in
            if let category, item.categoryId != category { return false }
            if let genre, !app.hasGenre(item, genre) { return false }
            if let year, item.year != year { return false }
            if let minRating, (item.trustedRating ?? 0) < minRating { return false }
            return tokens.isEmpty || item.matches(tokens)
        }
        return narrowing ? result.collapsingDuplicates() : result
    }

    private func sorted(_ items: [CatalogItem]) -> [CatalogItem] {
        switch sort {
        case .newest: return items
        case .rating: return app.rankedByRating(items)
        case .year: return items.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
        case .title: return items.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
        }
    }
}

/// Tür kısayolları (Tümü, Aksiyon, Komedi…).
struct GenreChips: View {
    let genres: [MovieGenre]
    @Binding var selected: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("Tümü", isOn: selected == nil) { selected = nil }
                ForEach(genres) { genre in
                    chip(genre.label, isOn: selected == genre.slug) { selected = selected == genre.slug ? nil : genre.slug }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func chip(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(isOn ? Theme.accent : Theme.card, in: Capsule())
                .foregroundStyle(isOn ? Color.black : Color.white)
        }
        .buttonStyle(.plain)
    }
}

struct SearchView: View {
    @EnvironmentObject private var app: AppModel
    @State private var query = ""
    @AppStorage("fenotip.recentSearches") private var recentRaw = ""

    private var recentSearches: [String] { recentRaw.split(separator: "\n").map(String.init) }

    var body: some View {
        let tokens = TextFold.tokens(query)
        let active = tokens.joined().count >= 2
        let results: [CatalogItem] = active ? ranked(Array((app.uniqueMovies + app.uniqueSeries).lazy.filter { $0.matches(tokens) }.prefix(240)), tokens) : []
        let channels: [CatalogItem] = active ? Array(app.live.lazy.filter { $0.matches(tokens) }.prefix(12)) : []
        ScrollView {
            if !active {
                if recentSearches.isEmpty {
                    EmptyNote(text: "Film, dizi ya da kanal adı yaz.")
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Son aramalar").font(.headline)
                            Spacer()
                            Button("Temizle") { recentRaw = "" }.font(.subheadline)
                        }
                        ForEach(recentSearches, id: \.self) { text in
                            Button {
                                query = text
                            } label: {
                                HStack {
                                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(Theme.muted)
                                    Text(text).foregroundStyle(.white)
                                    Spacer()
                                }
                                .padding(.vertical, 6)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(16)
                }
            } else if results.isEmpty && channels.isEmpty {
                EmptyNote(text: "Sonuç bulunamadı.")
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    if !channels.isEmpty {
                        SectionHeader(title: "Kanallar")
                        LazyVStack(spacing: 8) {
                            ForEach(channels, id: \.key) { channel in ChannelRow(channel: channel, playlist: channels) }
                        }
                        .padding(.horizontal, 16)
                    }
                    if !results.isEmpty {
                        if !channels.isEmpty { SectionHeader(title: "Film ve diziler") }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12)], spacing: 18) {
                            ForEach(results.prefix(120), id: \.key) { item in
                                NavigationLink(value: item) { PosterCard(item: item, progress: app.position(item.kind, item.id)?.fraction) }
                                    .buttonStyle(.plain)
                                    .simultaneousGesture(TapGesture().onEnded { remember(query) })
                                    .myListMenu(item)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
                .padding(.vertical, 16)
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Film, dizi, kanal ara")
        .onSubmit(of: .search) { remember(query) }
        .navigationTitle("Ara")
        .task { await app.loadCatalog(.live) }
        .fenotipNavigation()
    }
}

extension SearchView {
    /// Başlığı aramayla başlayanlar önce, sonra kelime başında geçenler, sonra ötekiler (katalog sırası korunur).
    fileprivate func ranked(_ items: [CatalogItem], _ tokens: [String]) -> [CatalogItem] {
        let phrase = tokens.joined(separator: " ")
        func rank(_ item: CatalogItem) -> Int {
            if item.searchKey.hasPrefix(phrase) { return 0 }
            if item.searchKey.contains(" " + phrase) { return 1 }
            return 2
        }
        return items.enumerated().sorted { left, right in
            let l = rank(left.element), r = rank(right.element)
            return l != r ? l < r : left.offset < right.offset
        }.map(\.element)
    }

    fileprivate func remember(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return }
        let rest = recentSearches.filter { TextFold.fold($0) != TextFold.fold(trimmed) }
        recentRaw = ([trimmed] + rest).prefix(8).joined(separator: "\n")
    }
}

struct LiveView: View {
    @EnvironmentObject private var app: AppModel
    @State private var category: String?
    @State private var query = ""
    @State private var limit = 150

    var body: some View {
        let all = app.live
        let used = Set(all.compactMap(\.categoryId))
        let categories = (app.categories[.live] ?? []).filter { used.contains($0.id) }
        let needle = TextFold.fold(query.trimmingCharacters(in: .whitespaces))
        let channels = all.filter { (category == nil || $0.categoryId == category) && (needle.isEmpty || $0.searchKey.contains(needle)) }
        let browsing = category == nil && needle.isEmpty
        let favorites = browsing ? app.channels(app.state.favoriteLiveChannelIds) : []
        let recents = browsing ? Array(app.channels(app.state.recentLiveChannelIds).filter { !app.isFavorite($0.id) }.prefix(6)) : []
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !categories.isEmpty { CategoryChips(categories: categories, selected: $category) }
                CatalogStatus(kind: .live)
                if !favorites.isEmpty { channelSection("Favoriler", favorites) }
                if !recents.isEmpty { channelSection("Son izlenenler", recents) }
                if !all.isEmpty {
                    if browsing && !(favorites.isEmpty && recents.isEmpty) {
                        Text("Tüm kanallar").font(.headline).padding(.horizontal, 16).padding(.top, 6)
                    }
                    LazyVStack(spacing: 8) {
                        ForEach(channels.prefix(limit), id: \.key) { channel in
                            ChannelRow(channel: channel, playlist: channels)
                        }
                        if channels.count > limit {
                            Button("Daha fazla kanal") { limit += 150 }
                                .buttonStyle(.bordered)
                                .onAppear { limit += 150 }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            .padding(.vertical, 12)
        }
        .searchable(text: $query, prompt: "Kanal ara")
        .onChange(of: category) { _ in limit = 150 }
        .navigationTitle("Canlı TV")
        .task { await app.loadCatalog(.live) }
        .refreshable { await app.loadCatalog(.live, force: true) }
    }

    private func channelSection(_ title: String, _ channels: [CatalogItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).padding(.horizontal, 16)
            LazyVStack(spacing: 8) {
                ForEach(channels, id: \.key) { channel in ChannelRow(channel: channel, playlist: channels) }
            }
            .padding(.horizontal, 16)
        }
    }
}

extension CatalogItem {
    var livePlayback: PlaybackItem {
        PlaybackItem(kind: .live, contentId: id, seriesId: nil, title: title, artwork: artwork, ext: "m3u8", startAt: 0, episodes: [], seriesTitle: nil)
    }

    func livePlayback(in playlist: [CatalogItem]) -> PlaybackItem {
        var item = livePlayback
        item.channels = playlist
        return item
    }
}

/// "Top 10": büyük sıra numarasıyla afişler.
struct TopTenRow: View {
    let items: [CatalogItem]

    var body: some View {
        if items.count >= 5 {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Yeni filmlerde Top 10")
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .bottom, spacing: 6) {
                        ForEach(Array(items.enumerated()), id: \.element.key) { index, item in
                            NavigationLink(value: item) {
                                HStack(alignment: .bottom, spacing: -10) {
                                    Text("\(index + 1)")
                                        .font(.system(size: 92, weight: .black, design: .rounded))
                                        .foregroundStyle(Theme.accent.opacity(0.85))
                                        .shadow(color: .black.opacity(0.8), radius: 4)
                                        .padding(.bottom, 26)
                                    PosterCard(item: item, width: 108)
                                }
                            }
                            .buttonStyle(.plain)
                            .myListMenu(item)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
    }
}

/// Kanal satırı: logo, ad, şimdiki/sıradaki program, favori yıldızı. Basılı tutunca TV'de aç.
struct ChannelRow: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var tv: TvRemote
    let channel: CatalogItem
    /// Oynatıcıda kanal ileri/geri bu listede gezer.
    var playlist: [CatalogItem] = []

    var body: some View {
        let guide = app.nowNext(channel.id)
        let favorite = app.isFavorite(channel.id)
        HStack(spacing: 12) {
            Button {
                app.play(channel.livePlayback(in: playlist))
            } label: {
                HStack(spacing: 12) {
                    Rectangle().fill(Theme.card)
                        .frame(width: 64, height: 40)
                        .overlay { RemoteImage(url: channel.artworkURL).scaledToFit() }
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(channel.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                        if let current = guide?.current {
                            Text(current.title).font(.caption).foregroundStyle(Theme.accent).lineLimit(1)
                            ProgressBar(value: current.progress).clipShape(Capsule()).frame(maxWidth: 160)
                        }
                        if let next = guide?.next {
                            Text("Sonra: \(next.title)").font(.caption2).foregroundStyle(Theme.muted).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                app.toggleFavorite(channel.id)
            } label: {
                Image(systemName: favorite ? "star.fill" : "star")
                    .foregroundStyle(favorite ? Theme.accent : Theme.muted)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(favorite ? "Favorilerden çıkar" : "Favorilere ekle")
        }
        .padding(10)
        .background(Theme.card.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        .contextMenu {
            Button { Task { await tv.play(channel.livePlayback, at: 0) } } label: { Label("TV'de aç", systemImage: "tv") }
            Button { app.toggleFavorite(channel.id) } label: {
                Label(favorite ? "Favorilerden çıkar" : "Favorilere ekle", systemImage: favorite ? "star.slash" : "star")
            }
        }
        .task(id: channel.id) { await app.loadEpg(channel.id) }
    }
}

/// Ana sayfadaki favori kanal kutucuğu.
struct ChannelTile: View {
    @EnvironmentObject private var app: AppModel
    let channel: CatalogItem
    var playlist: [CatalogItem] = []

    var body: some View {
        Button {
            app.play(channel.livePlayback(in: playlist))
        } label: {
            VStack(spacing: 6) {
                Rectangle().fill(Theme.card)
                    .frame(width: 120, height: 68)
                    .overlay { RemoteImage(url: channel.artworkURL).scaledToFit().padding(8) }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                Text(channel.title).font(.caption.weight(.semibold)).lineLimit(1).frame(width: 120)
                if let current = app.nowNext(channel.id)?.current {
                    Text(current.title).font(.caption2).foregroundStyle(Theme.muted).lineLimit(1).frame(width: 120)
                }
            }
        }
        .buttonStyle(.plain)
        .task(id: channel.id) { await app.loadEpg(channel.id) }
    }
}
