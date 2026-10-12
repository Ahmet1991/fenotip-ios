import Foundation

struct ServerError: LocalizedError {
    let status: Int
    let message: String
    let code: String?
    var errorDescription: String? { message }
}

/// Senkron sunucusu: yalnız giriş, profil ve izleme ilerlemesi (PC ile ortak "kaldığın yer").
/// Katalog ve yayınlar buradan geçmez; doğrudan sağlayıcıdan gelir.
final class ServerAPI {
    static let base = URL(string: "http://akentektv.dpdns.org")!

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = .shared
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .always
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    @discardableResult
    func send(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Data {
        guard let url = URL(string: path, relativeTo: ServerAPI.base)?.absoluteURL else { throw AppError.message("Geçersiz adres.") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "content-type")
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = payload?["error"] as? String ?? "Sunucu hatası (\(status))."
            throw ServerError(status: status, message: message, code: payload?["code"] as? String)
        }
        return data
    }

    func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await send(path))
    }

    /// Serbest biçimli JSON (profil durumu gibi).
    func object(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> [String: Any] {
        let data = try await send(path, method: method, body: body)
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    func login(pin: String) async throws {
        try await send("/api/login", method: "POST", body: ["pin": pin])
    }

    func logout() async {
        _ = try? await send("/api/logout", method: "POST")
    }

    func selectProfile(id: String) async throws {
        try await send("/api/profiles/select", method: "POST", body: ["id": id])
    }

    /// Çocuk profilinden çıkarken istenen profil kilit PIN'i.
    func unlockProfile(pin: String) async throws {
        try await send("/api/profiles/unlock", method: "POST", body: ["pin": pin])
    }

    func profileState() async throws -> (profile: Profile, state: ProfileState) {
        let data = try await send("/api/profile-state")
        let root = (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let profileData = try JSONSerialization.data(withJSONObject: root["profile"] ?? [:])
        let profile = try JSONDecoder().decode(Profile.self, from: profileData)
        return (profile, ProfileState(json: root["state"] as? [String: Any] ?? [:]))
    }

    func mutate(_ mutation: [String: Any]) async throws -> ProfileState {
        let root = try await object("/api/profile-state", method: "PATCH", body: ["mutation": mutation])
        guard let state = root["state"] as? [String: Any] else { throw AppError.message("Profil durumu okunamadı.") }
        return ProfileState(json: state)
    }

    // MARK: IMDb ve fragman (sunucu TMDB/OMDb anahtarlarıyla bakar)

    private func lookupQuery(kind: ContentKind, tmdbId: String?, title: String, year: Int?) -> String {
        var components = URLComponents()
        var items = [URLQueryItem(name: "kind", value: kind.rawValue)]
        if let tmdbId, !tmdbId.isEmpty, tmdbId.allSatisfy(\.isNumber) {
            items.append(URLQueryItem(name: "tmdb", value: tmdbId))
        } else {
            items.append(URLQueryItem(name: "title", value: title))
            if let year { items.append(URLQueryItem(name: "year", value: String(year))) }
        }
        components.queryItems = items
        return components.percentEncodedQuery ?? ""
    }

    /// IMDb puanı ve oy sayısı. Ağ hatasında hata fırlatır; IMDb'de yoksa nil.
    func imdbInfo(kind: ContentKind, tmdbId: String?, title: String, year: Int?) async throws -> ImdbInfo? {
        let root = try await object("/api/imdb?" + lookupQuery(kind: kind, tmdbId: tmdbId, title: title, year: year))
        guard let rating = (root["imdbRating"] as? NSNumber)?.doubleValue, rating > 0 else { return nil }
        return ImdbInfo(rating: rating, votes: (root["imdbVotes"] as? NSNumber)?.intValue ?? 0)
    }

    /// TMDB'nin en yüksek puanlı listesi (Türkçe ve özgün ad + yıl); puan sıralamasında aday seçimi için.
    func topRated(kind: ContentKind) async -> [(title: String, originalTitle: String, year: Int?)] {
        guard kind != .live, let root = try? await object("/api/top-rated?kind=\(kind.rawValue)") else { return [] }
        return (root["items"] as? [[String: Any]] ?? []).compactMap { row -> (title: String, originalTitle: String, year: Int?)? in
            guard let title = row["title"] as? String else { return nil }
            return (title, row["originalTitle"] as? String ?? title, (row["year"] as? NSNumber)?.intValue)
        }
    }

    func trailerKey(kind: ContentKind, tmdbId: String?, title: String, year: Int?) async -> String? {
        let root = try? await object("/api/trailer?" + lookupQuery(kind: kind, tmdbId: tmdbId, title: title, year: year))
        return root?["trailerKey"] as? String
    }
}
