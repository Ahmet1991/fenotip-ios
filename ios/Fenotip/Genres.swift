import Foundation

/// Sitedeki film türleri (src/lib/movie-genres.ts): tür yalnız sağlayıcının kategori adından okunur,
/// başlıktaki kelimeden asla (yanlış sınıflar). Eşleşme tam kelime olmalı ("suç" başka kelimenin içinde sayılmaz).
struct MovieGenre: Identifiable, Hashable {
    let slug: String
    let label: String
    let pattern: String

    var id: String { slug }

    static let all: [MovieGenre] = [
        MovieGenre(slug: "action", label: "Aksiyon", pattern: "aksiyon|action"),
        MovieGenre(slug: "comedy", label: "Komedi", pattern: "komedi|comedy"),
        MovieGenre(slug: "drama", label: "Dram", pattern: "dramatik|drama?"),
        MovieGenre(slug: "thriller", label: "Gerilim", pattern: "gerilim|thriller"),
        MovieGenre(slug: "horror", label: "Korku", pattern: "korku|horror"),
        MovieGenre(slug: "sci-fi", label: "Bilim Kurgu", pattern: "bilim[\\s-]*kurgu|sci[\\s-]*fi|science[\\s-]*fiction"),
        MovieGenre(slug: "fantasy", label: "Fantastik", pattern: "fantastik|fantasy|fantazi"),
        MovieGenre(slug: "adventure", label: "Macera", pattern: "macera|adventure"),
        MovieGenre(slug: "animation", label: "Animasyon", pattern: "animasyon|animation|anime|cizgi\\s*film"),
        MovieGenre(slug: "crime", label: "Suç", pattern: "suc|crime"),
        MovieGenre(slug: "romance", label: "Romantik", pattern: "romantik|romance|romantic"),
        MovieGenre(slug: "mystery", label: "Gizem", pattern: "gizem|mystery"),
        MovieGenre(slug: "documentary", label: "Belgesel", pattern: "belgesel|documentary"),
        MovieGenre(slug: "family", label: "Aile", pattern: "aile|family"),
    ]

    private static let expressions: [String: NSRegularExpression] = {
        var result: [String: NSRegularExpression] = [:]
        for genre in all {
            result[genre.slug] = try? NSRegularExpression(pattern: "(?<![a-z0-9])(?:\(genre.pattern))(?![a-z0-9])")
        }
        return result
    }()

    func matches(categoryName: String) -> Bool {
        let text = TextFold.fold(categoryName)
        guard let expression = MovieGenre.expressions[slug] else { return false }
        return expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Kategori kimliği → o kategorinin türleri.
    static func index(_ categories: [ProviderCategory]) -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for category in categories {
            let slugs = Set(all.filter { $0.matches(categoryName: category.name) }.map(\.slug))
            if !slugs.isEmpty { result[category.id] = slugs }
        }
        return result
    }
}
