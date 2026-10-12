import Foundation

/// Ana sayfa raf düzeni bu cihaza özeldir; profil durumuna yazılmaz.
enum HomeShelfID: String, CaseIterable, Identifiable, Hashable {
    case continueWatching
    case almostDone
    case upNext
    case myList
    case forYou
    case liveNow
    case favoriteChannels
    case replay
    case top10
    case newMovies
    case newSeries
    case topMovies
    case topSeries
    case dailyGenres

    static let orderKey = "fenotip.homeShelfOrder"
    static let hiddenKey = "fenotip.homeShelfHidden"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .continueWatching: return "İzlemeye devam et"
        case .almostDone: return "Bitmek üzere"
        case .upNext: return "Sıradaki bölümler"
        case .myList: return "Listem"
        case .forYou: return "Senin için"
        case .liveNow: return "Canlı şimdi"
        case .favoriteChannels: return "Favori kanallar"
        case .replay: return "Yeniden izle"
        case .top10: return "Yeni filmlerde Top 10"
        case .newMovies: return "Yeni eklenen filmler"
        case .newSeries: return "Yeni eklenen diziler"
        case .topMovies: return "IMDb'de yüksek puanlı filmler"
        case .topSeries: return "IMDb'de yüksek puanlı diziler"
        case .dailyGenres: return "Günün türleri"
        }
    }

    static func ordered(from raw: String) -> [HomeShelfID] {
        var seen = Set<HomeShelfID>()
        var result = raw.split(separator: ",").compactMap { HomeShelfID(rawValue: String($0)) }
            .filter { seen.insert($0).inserted }
        for shelf in HomeShelfID.allCases where seen.insert(shelf).inserted {
            result.append(shelf)
        }
        return result
    }

    static func hidden(from raw: String) -> Set<HomeShelfID> {
        Set(raw.split(separator: ",").compactMap { HomeShelfID(rawValue: String($0)) })
    }

    static func encode(_ shelves: [HomeShelfID]) -> String {
        shelves.map(\.rawValue).joined(separator: ",")
    }

    static func encode(_ shelves: Set<HomeShelfID>) -> String {
        allCases.filter { shelves.contains($0) }.map(\.rawValue).joined(separator: ",")
    }
}

struct HomeItemMetadata: Hashable {
    let genre: String?
    let plot: String?
}

/// Ana sayfadaki pahalı süzme/sıralamalar tek sefer hesaplanır; View.body yalnız hazır dizileri okur.
struct HomeDashboard {
    var featuredFallback: [CatalogItem] = []
    var continueWatching: [ContinueItem] = []
    var almostDone: [ContinueItem] = []
    var replay: [CatalogItem] = []
    var myList: [CatalogItem] = []
    var favorites: [CatalogItem] = []
    var newMovies: [CatalogItem] = []
    var newSeries: [CatalogItem] = []
    var dailyGenres: [HomeShelf] = []
    var todayMovieCount = 0
    var luckyMovie: CatalogItem?

    static let empty = HomeDashboard()
}

extension Notification.Name {
    static let fenotipHomeTabReselected = Notification.Name("fenotip.homeTabReselected")
}
