import Foundation

/// IGDB v4 client using Twitch application credentials. Image downloads are handled separately.
actor ArtworkAPI {
    private let session: URLSession
    private let redirectGuard = ArtworkAPIRedirectGuard()
    private var accessToken: String?
    private var tokenExpiry: Date?
    private var tokenClientID: String?
    private var retryAfter: Date?

    init(session: URLSession = .shared) { self.session = session }

    func lookup(title: String, credentials: ArtworkCredentials) async -> ArtworkLookupResult {
        if let retryAfter, retryAfter > Date() {
            return ArtworkLookupResult(messages: ["IGDB rate limit reached; try again later."])
        }
        let search = GameTitleMatcher.searchTitle(title)
        guard !search.isEmpty else { return ArtworkLookupResult(messages: ["The game title is empty after parsing."]) }
        guard credentials.isConfigured else {
            return ArtworkLookupResult(messages: ["Add your IGDB Client ID and Client Secret in Settings → Artwork."])
        }
        var result = ArtworkLookupResult()
        do {
            let games = try await searchGames(search, credentials: credentials)
            let candidates = games.map { ArtworkCandidate(id: $0.id, name: $0.name) }
            guard let best = GameTitleMatcher.bestMatch(title: search, candidates: candidates),
                  let game = games.first(where: { $0.id == best.id }) else {
                result.messages.append("IGDB found no confident title match.")
                return result
            }
            result.matchedTitle = best.name
            let source = game.slug.flatMap { URL(string: "https://www.igdb.com/games/\($0)") }
            if let imageID = game.cover?.imageID, let url = imageURL(imageID, size: "t_cover_big_2x") {
                result.assets.append(ArtworkAsset(kind: .cover, url: url, provider: "IGDB", sourceURL: source, credit: nil))
                result.assets.append(ArtworkAsset(kind: .tile, url: url, provider: "IGDB", sourceURL: source, credit: nil))
            } else {
                result.messages.append("No box art is available for the matched title.")
            }
            if let image = heroImage(for: game), let imageID = image.imageID,
               let url = imageURL(imageID, size: "t_1080p") {
                result.assets.append(ArtworkAsset(kind: .hero, url: url, provider: "IGDB", sourceURL: source, credit: nil))
            } else {
                result.messages.append("No hero banner is available for the matched title.")
            }
            if result.assets.isEmpty { result.messages.append("No supported artwork is available for the matched title.") }
        } catch {
            result.messages.append("IGDB: \(safeMessage(error))")
        }
        return result
    }

    private func searchGames(_ search: String, credentials: ArtworkCredentials) async throws -> [IGDBGame] {
        let query = """
        fields name,slug,cover.image_id,artworks.image_id,artworks.width,artworks.height,artworks.alpha_channel,screenshots.image_id,screenshots.width,screenshots.height; search "\(escaped(search))"; where version_parent = null; limit 20;
        """
        let bearer = try await token(for: credentials)
        do {
            return try await sendSearch(query, credentials: credentials, token: bearer)
        } catch APIError.http(401) {
            invalidateToken()
            let refreshed = try await token(for: credentials, force: true)
            return try await sendSearch(query, credentials: credentials, token: refreshed)
        }
    }

    private func sendSearch(_ query: String, credentials: ArtworkCredentials, token: String) async throws -> [IGDBGame] {
        guard let url = URL(string: "https://api.igdb.com/v4/games") else { throw APIError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(query.utf8)
        request.setValue(credentials.igdbClientID, forHTTPHeaderField: "Client-ID")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try await decoded(request)
    }

    private func token(for credentials: ArtworkCredentials, force: Bool = false) async throws -> String {
        if !force, let accessToken, let tokenExpiry, tokenExpiry > Date(), tokenClientID == credentials.igdbClientID {
            return accessToken
        }
        guard let url = URL(string: "https://id.twitch.tv/oauth2/token") else { throw APIError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(formBody([
            ("client_id", credentials.igdbClientID),
            ("client_secret", credentials.igdbClientSecret),
            ("grant_type", "client_credentials")
        ]).utf8)
        request.timeoutInterval = 25
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request, delegate: redirectGuard)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        if http.statusCode == 429 { noteRateLimit(http) }
        guard (200..<300).contains(http.statusCode) else {
            if [400, 401, 403].contains(http.statusCode) { throw APIError.credentialsRejected }
            throw APIError.http(http.statusCode)
        }
        guard data.count <= 1_000_000 else { throw APIError.invalidResponse }
        let payload: IGDBToken
        do { payload = try JSONDecoder().decode(IGDBToken.self, from: data) }
        catch { throw APIError.invalidResponse }
        guard !payload.accessToken.isEmpty else { throw APIError.invalidResponse }
        accessToken = payload.accessToken
        tokenExpiry = Date().addingTimeInterval(TimeInterval(max(payload.expiresIn - 300, 60)))
        tokenClientID = credentials.igdbClientID
        return payload.accessToken
    }

    private func invalidateToken() {
        accessToken = nil
        tokenExpiry = nil
        tokenClientID = nil
    }

    private func decoded<T: Decodable>(_ original: URLRequest) async throws -> T {
        try Task.checkCancellation()
        var request = original
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request, delegate: redirectGuard)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        if http.statusCode == 429 { noteRateLimit(http) }
        guard (200..<300).contains(http.statusCode) else { throw APIError.http(http.statusCode) }
        guard data.count <= 8_000_000 else { throw APIError.invalidResponse }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw APIError.invalidResponse }
    }

    private func noteRateLimit(_ response: HTTPURLResponse) {
        let wait = min(max(Double(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 60, 1), 3600)
        retryAfter = Date().addingTimeInterval(wait)
    }

    private func heroImage(for game: IGDBGame) -> IGDBImage? {
        if let artwork = sortedLandscape(game.artworks).first { return artwork }
        return sortedLandscape(game.screenshots).first
    }

    /// Official key art wins when it is landscape; screenshots fill in for games without one.
    private func sortedLandscape(_ images: [IGDBImage]?) -> [IGDBImage] {
        (images ?? []).filter { image in
            guard image.imageID != nil, let width = image.width, let height = image.height, width > 0, height > 0 else { return false }
            return Double(width) / Double(height) >= 1.3
        }.sorted {
            let left = $0.alphaChannel == true ? 0 : 1
            let right = $1.alphaChannel == true ? 0 : 1
            if left != right { return left > right }
            return area($0) > area($1)
        }
    }

    private func area(_ image: IGDBImage) -> Int { (image.width ?? 0) * (image.height ?? 0) }

    private func imageURL(_ imageID: String, size: String) -> URL? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        guard !imageID.isEmpty, imageID.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return URL(string: "https://images.igdb.com/igdb/image/upload/\(size)/\(imageID).jpg")
    }

    private func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private func formBody(_ values: [(String, String)]) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return values.map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            return "\(encodedKey)=\(encodedValue)"
        }.joined(separator: "&")
    }

    private func safeMessage(_ error: Error) -> String {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return "Request cancelled." }
        switch error {
        case APIError.credentialsRejected: return "IGDB/Twitch credentials were rejected; check Artwork settings."
        case APIError.http(401), APIError.http(403): return "IGDB credentials were rejected; check Artwork settings."
        case APIError.http(429): return "Rate limit reached; try again later."
        case APIError.http(let code): return "IGDB returned HTTP \(code)."
        case APIError.invalidResponse: return "IGDB returned an invalid response."
        default: return "Could not reach IGDB. Check your connection and try again."
        }
    }
}

private enum APIError: Error { case http(Int), invalidResponse, credentialsRejected }
private struct IGDBToken: Decodable {
    var accessToken: String
    var expiresIn: Int
    enum CodingKeys: String, CodingKey { case accessToken = "access_token", expiresIn = "expires_in" }
}
private struct IGDBGame: Decodable {
    var id: Int
    var name: String
    var slug: String?
    var cover: IGDBImage?
    var artworks: [IGDBImage]?
    var screenshots: [IGDBImage]?
}
private struct IGDBImage: Decodable {
    var imageID: String?
    var width: Int?
    var height: Int?
    var alphaChannel: Bool?
    enum CodingKeys: String, CodingKey {
        case imageID = "image_id", width, height, alphaChannel = "alpha_channel"
    }
}

/// Never forward Twitch credentials or IGDB tokens through API redirects, even to another service origin.
private final class ArtworkAPIRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
