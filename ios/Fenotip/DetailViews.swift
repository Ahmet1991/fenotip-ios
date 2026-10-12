import SwiftUI

struct DetailView: View {
    let item: CatalogItem

    var body: some View {
        if item.kind == .series {
            SeriesDetailView(item: item)
        } else {
            MovieDetailView(item: item)
        }
    }
}

/// "1:23:45" / "12:34".
func clockText(_ seconds: Double) -> String {
    let total = max(0, Int(seconds))
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}

private struct DetailHeader: View {
    let title: String
    let backdrop: URL?
    let poster: URL?
    let meta: [String]
    let imdb: Double?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Rectangle()
                .fill(Theme.card)
                .frame(height: 260)
                .overlay { RemoteImage(url: backdrop ?? poster, maxPixel: 1600) }
                .clipped()
                .overlay {
                    LinearGradient(colors: [.clear, Theme.background], startPoint: .center, endPoint: .bottom)
                }
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.title2.bold()).foregroundStyle(.white).lineLimit(3)
                HStack(spacing: 8) {
                    if let imdb {
                        Text(String(format: "IMDb %.1f", imdb))
                            .font(.caption.weight(.heavy))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color(red: 0.96, green: 0.77, blue: 0.09), in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(.black)
                    }
                    if !meta.isEmpty {
                        Text(meta.joined(separator: " · ")).font(.footnote).foregroundStyle(Theme.muted).lineLimit(2)
                    }
                }
            }
            .padding(16)
        }
    }
}

private struct InfoBlock: View {
    let label: String
    let value: String?

    var body: some View {
        if let value, !value.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(label).font(.caption.bold()).foregroundStyle(Theme.muted)
                Text(value).font(.footnote).foregroundStyle(.white.opacity(0.9))
            }
        }
    }
}

/// İkincil eylem düğmesi (TV'de oynat, Listem, Fragman, Baştan başla).
private struct ActionButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: systemImage).font(.title3)
                Text(title).font(.caption2.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }
}

private struct PlotText: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.9))
            .lineLimit(expanded ? nil : 4)
            .onTapGesture { withAnimation { expanded.toggle() } }
    }
}

struct MovieDetailView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var tv: TvRemote
    @Environment(\.openURL) private var openURL
    let item: CatalogItem
    @State private var details: MovieDetails?
    @State private var error: String?
    @State private var trailerKey: String?

    var body: some View {
        let position = app.position(.movie, item.id)
        let resumeAt = app.resumePosition(.movie, item.id)
        let saved = app.isSaved(item)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DetailHeader(
                    title: item.title,
                    backdrop: (details?.backdrop).flatMap { URL(string: $0) },
                    poster: item.artworkURL,
                    meta: movieMeta,
                    imdb: app.imdbRating(item)
                )
                VStack(alignment: .leading, spacing: 14) {
                    Button {
                        play(from: resumeAt)
                    } label: {
                        Label(resumeAt > 0 ? "Devam et · \(clockText(resumeAt))" : "İzle", systemImage: "play.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    if let position, resumeAt > 0 { ProgressBar(value: position.fraction).clipShape(Capsule()) }
                    HStack(spacing: 4) {
                        if resumeAt > 0 {
                            ActionButton(title: "Baştan", systemImage: "arrow.counterclockwise") { play(from: 0) }
                        }
                        ActionButton(title: "TV'de oynat", systemImage: "tv") {
                            Task { await tv.play(playback(from: resumeAt), at: resumeAt) }
                        }
                        ActionButton(title: saved ? "Listemde" : "Listem", systemImage: saved ? "checkmark" : "plus") { app.toggleMyList(item) }
                        let watched = app.isWatched(.movie, item.id)
                        ActionButton(title: watched ? "İzlendi" : "İzlenmedi", systemImage: watched ? "checkmark.circle.fill" : "circle") {
                            app.setWatched(!watched, kind: .movie, id: item.id, duration: position?.duration)
                        }
                        if let key = trailerKey ?? details?.trailer, let url = URL(string: "https://www.youtube.com/watch?v=\(key)") {
                            ActionButton(title: "Fragman", systemImage: "film") { openURL(url) }
                        }
                    }
                    if let plot = details?.plot { PlotText(text: plot) }
                    InfoBlock(label: "Oyuncular", value: details?.cast)
                    InfoBlock(label: "Yönetmen", value: details?.director)
                    InfoBlock(label: "Yayın tarihi", value: details?.releaseDate)
                    if details == nil && error == nil { ProgressView().tint(.white).frame(maxWidth: .infinity) }
                    if let error { Text(error).font(.footnote).foregroundStyle(Theme.muted) }
                }
                .padding(.horizontal, 16)
                PosterRow(title: "Benzer filmler", items: app.related(to: item))
                    .padding(.bottom, 24)
            }
        }
        .ignoresSafeArea(edges: .top)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard details == nil, let provider = app.provider else { return }
            do { details = try await provider.movieDetails(id: item.id) } catch { self.error = "Ayrıntılar alınamadı." }
            await app.loadImdb(for: item, tmdbId: details?.tmdbId)
            if details?.trailer == nil {
                trailerKey = await app.server.trailerKey(kind: .movie, tmdbId: details?.tmdbId, title: item.title, year: item.year)
            }
        }
    }

    private var movieMeta: [String] {
        var parts: [String] = []
        if let year = item.year { parts.append(String(year)) }
        if app.imdbRating(item) == nil, let rating = details?.rating ?? item.trustedRating, rating <= 9.3 { parts.append(String(format: "★ %.1f", rating)) }
        if let duration = details?.duration { parts.append(duration) }
        if let genre = details?.genre { parts.append(genre) }
        return parts
    }

    private func playback(from start: Double) -> PlaybackItem {
        PlaybackItem(
            kind: .movie,
            contentId: item.id,
            seriesId: nil,
            title: item.title,
            artwork: item.artwork,
            ext: item.ext ?? "mp4",
            startAt: start,
            episodes: [],
            seriesTitle: nil
        )
    }

    private func play(from start: Double) {
        app.play(playback(from: start))
    }
}

struct SeriesDetailView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var tv: TvRemote
    @Environment(\.openURL) private var openURL
    let item: CatalogItem
    @State private var details: SeriesDetails?
    @State private var season: Int?
    @State private var error: String?
    @State private var trailerKey: String?

    var body: some View {
        let episodes = details?.episodes ?? []
        let seasons = details?.seasons ?? []
        let target = resumeTarget(episodes)
        let current = season ?? target?.episode.season ?? seasons.first
        let saved = app.isSaved(item)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DetailHeader(
                    title: item.title,
                    backdrop: (details?.backdrop).flatMap { URL(string: $0) },
                    poster: (details?.cover).flatMap { URL(string: $0) } ?? item.artworkURL,
                    meta: seriesMeta(seasonCount: seasons.count),
                    imdb: app.imdbRating(item)
                )
                VStack(alignment: .leading, spacing: 14) {
                    if let target {
                        Button {
                            play(target.episode, all: episodes)
                        } label: {
                            Label(primaryTitle(target), systemImage: "play.fill")
                                .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    HStack(spacing: 4) {
                        if let target {
                            ActionButton(title: "TV'de oynat", systemImage: "tv") { sendToTv(target.episode, all: episodes) }
                        }
                        ActionButton(title: saved ? "Listemde" : "Listem", systemImage: saved ? "checkmark" : "plus") { app.toggleMyList(item) }
                        if let key = trailerKey ?? details?.trailer, let url = URL(string: "https://www.youtube.com/watch?v=\(key)") {
                            ActionButton(title: "Fragman", systemImage: "film") { openURL(url) }
                        }
                    }
                    if let plot = details?.plot { PlotText(text: plot) }
                    InfoBlock(label: "Oyuncular", value: details?.cast)
                    if seasons.count > 1, let current {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(seasons, id: \.self) { value in
                                    Button { season = value } label: {
                                        Text("\(value). Sezon")
                                            .font(.subheadline.weight(.semibold))
                                            .padding(.horizontal, 14).padding(.vertical, 8)
                                            .background(value == current ? Theme.accent : Theme.card, in: Capsule())
                                            .foregroundStyle(value == current ? Color.black : Color.white)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    if let current, let details {
                        let inSeason = details.episodes(in: current)
                        let watchedCount = inSeason.filter { app.isWatched(.series, $0.id) }.count
                        Text("\(inSeason.count) bölüm\(watchedCount > 0 ? " · \(watchedCount) izlendi" : "")")
                            .font(.caption).foregroundStyle(Theme.muted)
                    }
                    if let current, let details {
                        LazyVStack(spacing: 10) {
                            ForEach(details.episodes(in: current)) { episode in
                                EpisodeRowView(episode: episode, position: app.position(.series, episode.id)) {
                                    play(episode, all: episodes)
                                }
                                .contextMenu {
                                    Button { play(episode, all: episodes) } label: { Label("Oynat", systemImage: "play") }
                                    Button { sendToTv(episode, all: episodes) } label: { Label("TV'de oynat", systemImage: "tv") }
                                    if app.isWatched(.series, episode.id) {
                                        Button { app.setWatched(false, kind: .series, id: episode.id, duration: episode.durationSecs) } label: {
                                            Label("İzlenmedi olarak işaretle", systemImage: "circle")
                                        }
                                    } else {
                                        Button { app.setWatched(true, kind: .series, id: episode.id, duration: episode.durationSecs) } label: {
                                            Label("İzlendi olarak işaretle", systemImage: "checkmark.circle")
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if details == nil && error == nil { ProgressView().tint(.white).frame(maxWidth: .infinity) }
                    if let error { Text(error).font(.footnote).foregroundStyle(Theme.muted) }
                }
                .padding(.horizontal, 16)
                PosterRow(title: "Benzer diziler", items: app.related(to: item))
                    .padding(.bottom, 24)
            }
        }
        .ignoresSafeArea(edges: .top)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard details == nil, let provider = app.provider else { return }
            do { details = try await provider.seriesDetails(id: item.id) } catch { self.error = "Bölümler alınamadı." }
            await app.loadImdb(for: item, tmdbId: details?.tmdbId)
            if details?.trailer == nil {
                trailerKey = await app.server.trailerKey(kind: .series, tmdbId: details?.tmdbId, title: item.title, year: item.year)
            }
        }
    }

    private func seriesMeta(seasonCount: Int) -> [String] {
        var parts: [String] = []
        if let year = item.year { parts.append(String(year)) }
        if app.imdbRating(item) == nil, let rating = details?.rating ?? item.trustedRating, rating <= 9.3 { parts.append(String(format: "★ %.1f", rating)) }
        if seasonCount > 0 { parts.append("\(seasonCount) sezon") }
        if let genre = details?.genre { parts.append(genre) }
        return parts
    }

    /// Sitedeki kural: en son izlenen bölüm; bittiyse sıradaki (baştan). Hiç izlenmediyse ilk bölüm.
    private func resumeTarget(_ episodes: [Episode]) -> (episode: Episode, resume: Bool)? {
        let watched = episodes.enumerated().compactMap { index, episode -> (Int, WatchPosition)? in
            guard let position = app.position(.series, episode.id), position.position > 0 else { return nil }
            return (index, position)
        }
        guard let latest = watched.max(by: { $0.1.updatedAt < $1.1.updatedAt }) else {
            return episodes.first.map { (episode: $0, resume: false) }
        }
        if latest.1.duration > 0, latest.1.fraction >= 0.95 {
            let index = latest.0 + 1 < episodes.count ? latest.0 + 1 : latest.0
            return (episode: episodes[index], resume: false)
        }
        return (episode: episodes[latest.0], resume: true)
    }

    private func primaryTitle(_ target: (episode: Episode, resume: Bool)) -> String {
        let label = "S\(target.episode.season) B\(target.episode.number)"
        let at = app.resumePosition(.series, target.episode.id)
        if target.resume, at > 0 { return "Devam et · \(label) · \(clockText(at))" }
        return target.resume ? "Devam et · \(label)" : "İzle · \(label)"
    }

    private func episodeItem(_ episode: Episode, all: [Episode]) -> PlaybackItem {
        let base = PlaybackItem(
            kind: .series,
            contentId: episode.id,
            seriesId: item.id,
            title: item.title,
            artwork: (details?.cover) ?? item.artwork,
            ext: episode.ext,
            startAt: 0,
            episodes: all,
            seriesTitle: item.title
        )
        return app.episodeItem(episode, from: base)
    }

    private func play(_ episode: Episode, all: [Episode]) {
        app.play(episodeItem(episode, all: all))
    }

    private func sendToTv(_ episode: Episode, all: [Episode]) {
        let playback = episodeItem(episode, all: all)
        Task { await tv.play(playback, at: playback.startAt) }
    }
}

private struct EpisodeRowView: View {
    let episode: Episode
    let position: WatchPosition?
    let action: () -> Void

    var body: some View {
        let watched = (position?.duration ?? 0) > 0 && (position?.fraction ?? 0) >= 0.95
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Rectangle()
                    .fill(Theme.card)
                    .frame(width: 128, height: 72)
                    .overlay { RemoteImage(url: episode.image.flatMap { URL(string: $0) }) }
                    .overlay { Image(systemName: "play.fill").foregroundStyle(.white.opacity(0.85)) }
                    .overlay(alignment: .bottom) {
                        if let position, position.position > 0 { ProgressBar(value: position.fraction) }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(episode.number). \(episode.title)").font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(2)
                        if watched {
                            Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(Theme.accent)
                        }
                    }
                    HStack(spacing: 6) {
                        if let minutes = episode.durationSecs.map({ Int($0 / 60) }), minutes > 0 {
                            Text("\(minutes) dk").font(.caption2).foregroundStyle(Theme.muted)
                        }
                        if let position, !watched, position.position >= 10 {
                            Text("· \(clockText(position.position))'da kaldın").font(.caption2).foregroundStyle(Theme.accent)
                        }
                    }
                    if let plot = episode.plot {
                        Text(plot).font(.caption).foregroundStyle(Theme.muted).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
    }
}
