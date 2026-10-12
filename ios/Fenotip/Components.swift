import ImageIO
import SwiftUI
import UIKit

/// Afiş ve görseller: bellekte saklanır ve ekran boyuna küçültülerek çözülür. AsyncImage her
/// kaydırmada görseli yeniden çözüp kısa bir boş kare gösteriyordu; artık geri dönünce anında görünür.
struct RemoteImage: View {
    let url: URL?
    var maxPixel: CGFloat = 700
    @State private var image: UIImage?

    init(url: URL?, maxPixel: CGFloat = 700) {
        self.url = url
        self.maxPixel = maxPixel
        _image = State(initialValue: url.flatMap { ImageLoader.shared.cached($0, maxPixel: maxPixel) })
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(Theme.card)
            }
        }
        .task(id: url) {
            guard let url else {
                image = nil
                return
            }
            if let hit = ImageLoader.shared.cached(url, maxPixel: maxPixel) {
                image = hit
                return
            }
            image = nil
            let loaded = await ImageLoader.shared.load(url, maxPixel: maxPixel)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { image = loaded }
        }
    }
}

/// Görsel yükleyici: bellek önbelleği (NSCache) + aynı adrese tek istek + ImageIO ile küçültme.
final class ImageLoader {
    static let shared = ImageLoader()

    private let cache = NSCache<NSString, UIImage>()
    private let lock = NSLock()
    private var inflight: [String: Task<UIImage?, Never>] = [:]

    private init() {
        cache.countLimit = 600
        cache.totalCostLimit = 160 * 1024 * 1024
    }

    private func key(_ url: URL, _ maxPixel: CGFloat) -> String { "\(Int(maxPixel))|\(url.absoluteString)" }

    func clear() {
        cache.removeAllObjects()
    }

    func cached(_ url: URL, maxPixel: CGFloat) -> UIImage? {
        cache.object(forKey: key(url, maxPixel) as NSString)
    }

    func load(_ url: URL, maxPixel: CGFloat) async -> UIImage? {
        let cacheKey = key(url, maxPixel)
        if let hit = cache.object(forKey: cacheKey as NSString) { return hit }
        let task: Task<UIImage?, Never> = lock.withLock {
            if let existing = inflight[cacheKey] { return existing }
            let created = Task.detached(priority: .userInitiated) { [cache] () -> UIImage? in
                guard let response = try? await URLSession.shared.data(from: url),
                      let image = ImageLoader.downsample(response.0, maxPixel: maxPixel) else { return nil }
                let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
                cache.setObject(image, forKey: cacheKey as NSString, cost: cost)
                return image
            }
            inflight[cacheKey] = created
            return created
        }
        let result = await task.value
        lock.withLock { inflight[cacheKey] = nil }
        return result
    }

    private static func downsample(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else { return UIImage(data: data) }
        let thumbnail = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnail) else { return UIImage(data: data) }
        return UIImage(cgImage: image)
    }
}

struct PosterCard: View {
    @EnvironmentObject private var app: AppModel
    let item: CatalogItem
    var progress: Double?
    var width: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Rectangle()
                .fill(Theme.card)
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .overlay { RemoteImage(url: item.artworkURL) }
                .overlay(alignment: .topTrailing) {
                    // IMDb biliniyorsa o; yoksa sağlayıcı puanı (şişkin 9,3+ gösterilmez).
                    if let imdb = app.imdbRating(item) {
                        Text(String(format: "IMDb %.1f", imdb))
                            .font(.caption2.weight(.heavy))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color(red: 0.96, green: 0.77, blue: 0.09), in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(.black)
                            .padding(6)
                    } else if let rating = item.trustedRating {
                        Text(String(format: "★ %.1f", rating))
                            .font(.caption2.bold())
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Color.black.opacity(0.7), in: Capsule())
                            .padding(6)
                    }
                }
                .overlay(alignment: .bottom) {
                    if let progress, progress >= 0.02 { ProgressBar(value: progress) }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
            Text(item.title).font(.caption.weight(.semibold)).lineLimit(2).foregroundStyle(.white)
            if let year = item.year {
                Text(String(year)).font(.caption2).foregroundStyle(Theme.muted)
            }
        }
        .frame(width: width)
    }
}

struct ProgressBar: View {
    let value: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.white.opacity(0.25))
                Rectangle().fill(Theme.accent).frame(width: proxy.size.width * min(1, max(0, value)))
            }
        }
        .frame(height: 4)
    }
}

struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title).font(.title3.bold()).foregroundStyle(.white).padding(.horizontal, 16)
    }
}

/// Yatay raf.
struct PosterRow: View {
    @EnvironmentObject private var app: AppModel
    let title: String
    let items: [CatalogItem]

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: title)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(items, id: \.key) { item in
                            NavigationLink(value: item) { PosterCard(item: item, progress: app.position(item.kind, item.id)?.fraction, width: 118) }
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

struct CategoryChips: View {
    let categories: [ProviderCategory]
    @Binding var selected: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: "Tümü", isOn: selected == nil) { selected = nil }
                ForEach(categories) { category in
                    chip(title: category.name, isOn: selected == category.id) { selected = category.id }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func chip(title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(isOn ? Color.white : Theme.card, in: Capsule())
                .foregroundStyle(isOn ? Color.black : Color.white)
        }
        .buttonStyle(.plain)
    }
}

struct EmptyNote: View {
    let text: String

    var body: some View {
        Text(text).foregroundStyle(Theme.muted).multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(32)
    }
}

/// Katalog henüz yüklenmediyse ilk girişte gösterilen bekleme/hata.
struct CatalogStatus: View {
    @EnvironmentObject private var app: AppModel
    let kind: ContentKind

    var body: some View {
        if let error = app.catalogErrors[kind] {
            VStack(spacing: 12) {
                EmptyNote(text: error)
                Button("Tekrar dene") { Task { await app.loadCatalog(kind, force: true) } }.buttonStyle(.bordered)
            }
        } else if app.items(kind).isEmpty {
            VStack(spacing: 12) {
                ProgressView().tint(.white)
                Text("Katalog sağlayıcıdan alınıyor…").font(.footnote).foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 60)
        }
    }
}

/// Afişi basılı tutunca: Listeme ekle / çıkar (PC ile ortak liste).
private struct MyListMenu: ViewModifier {
    @EnvironmentObject private var app: AppModel
    let item: CatalogItem

    func body(content: Content) -> some View {
        content.contextMenu {
            let saved = app.isSaved(item)
            Button { app.toggleMyList(item) } label: {
                Label(saved ? "Listemden çıkar" : "Listeme ekle", systemImage: saved ? "minus.circle" : "plus.circle")
            }
        }
    }
}

extension View {
    func myListMenu(_ item: CatalogItem) -> some View {
        modifier(MyListMenu(item: item))
    }

    func fenotipNavigation() -> some View {
        navigationDestination(for: CatalogItem.self) { item in
            DetailView(item: item)
        }
    }
}
