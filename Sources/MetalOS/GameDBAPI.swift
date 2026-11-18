import Foundation

private final class GameDBRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(GameDBAPI.isGameDBURL) == true ? request : nil)
    }
}

/// Public, read-only client for LizardByte's static IGDB-backed database.
actor GameDBAPI {
    private let session: URLSession
    private var platformNames: [Int: String] = [:]
    private let baseURL = URL(string: "https://app.lizardbyte.dev/GameDB/")!

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: GameDBRedirectGuard(), delegateQueue: nil)
    }

    nonisolated static func isGameDBURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host?.lowercased() == "app.lizardbyte.dev" && url.port == nil && url.user == nil && url.password == nil
    }

    func lookup(title: String) async -> ArtworkLookupResult {
        let search = GameTitleMatcher.searchTitle(title)
        guard !search.isEmpty else { return ArtworkLookupResult(messages: ["The game title is empty after parsing."]) }
        do {
            let bucket = try await loadBucket(for: search)
            let candidates = bucket.compactMap { key, value -> ArtworkCandidate? in
                guard let id = Int(key), let name = value.name else { return nil }
                return ArtworkCandidate(id: id, name: name)
            }
            guard let best = GameTitleMatcher.bestMatch(title: search, candidates: candidates) else {
                return ArtworkLookupResult(messages: ["GameDB found no confident title match."])
            }
            let record = try await loadGame(id: best.id)
            return await makeResult(record, matchedTitle: record.name ?? best.name)
        } catch is CancellationError {
            return ArtworkLookupResult(messages: ["GameDB lookup was cancelled."])
        } catch let error as DecodingError {
            return ArtworkLookupResult(messages: ["GameDB returned data MetalOS could not read: \(error.localizedDescription)"])
        } catch let error as URLError {
            return ArtworkLookupResult(messages: ["GameDB could not be reached (\(error.localizedDescription))."])
        } catch {
            return ArtworkLookupResult(messages: ["GameDB lookup failed: \(error.localizedDescription)"])
        }
    }

    private func loadBucket(for title: String) async throws -> [String: BucketEntry] {
        let bucket = Self.bucketName(title)
        guard let url = URL(string: "buckets/\(bucket).json", relativeTo: baseURL)?.absoluteURL else { throw GameDBError.invalidResponse }
        return try await get(url, as: [String: BucketEntry].self)
    }

    private func loadGame(id: Int) async throws -> GameRecord {
        guard let url = URL(string: "games/\(id).json", relativeTo: baseURL)?.absoluteURL else { throw GameDBError.invalidResponse }
        return try await get(url, as: GameRecord.self)
    }

    private func loadPlatform(id: Int) async -> String? {
        if let cached = platformNames[id] { return cached }
        guard let url = URL(string: "platforms/\(id).json", relativeTo: baseURL) else { return nil }
        let name = try? await get(url, as: PlatformRecord.self).name
        if let name { platformNames[id] = name }
        return name
    }

    private func makeResult(_ game: GameRecord, matchedTitle: String) async -> ArtworkLookupResult {
        var metadata = GameMetadata(
            summary: game.summary?.nilIfBlank,
            storyline: game.storyline?.nilIfBlank,
            genres: uniqueNames(game.genres),
            releaseDate: game.releaseDates?.compactMap(\.date).min().map { Date(timeIntervalSince1970: TimeInterval($0)).formatted(date: .abbreviated, time: .omitted) },
            developers: uniqueNames(game.involvedCompanies?.filter { $0.developer == true }.compactMap(\.company)),
            publishers: uniqueNames(game.involvedCompanies?.filter { $0.publisher == true }.compactMap(\.company)),
            sourceURL: game.url ?? game.slug.map { "https://www.igdb.com/games/\($0)" }
        )
        for id in (game.platforms ?? []).prefix(10) {
            if let name = await loadPlatform(id: id) { metadata.platforms.append(name) }
        }

        var result = ArtworkLookupResult(matchedTitle: matchedTitle, metadata: metadata)
        let coverURL = game.cover?.url ?? game.gameLocalizations?.first(where: { $0.cover?.url != nil })?.cover?.url
        if let coverURL, let url = imageURL(coverURL, size: "t_cover_big_2x") {
            result.assets.append(ArtworkAsset(kind: .cover, url: url, provider: "GameDB", sourceURL: sourceURL(for: game), credit: nil))
            // IGDB covers are portrait. Keep the full cover for details and create a square crop for library rails.
            result.assets.append(ArtworkAsset(kind: .tile, url: url, provider: "GameDB", sourceURL: sourceURL(for: game), credit: nil))
        } else {
            result.messages.append("GameDB has no box art for the matched title.")
        }
        if let artwork = game.artworks?.first, let url = imageURL(artwork.url, size: "t_1080p") {
            result.assets.append(ArtworkAsset(kind: .hero, url: url, provider: "GameDB", sourceURL: sourceURL(for: game), credit: nil))
        }
        for image in (game.screenshots ?? []).prefix(8) {
            guard let url = imageURL(image.url, size: "t_1080p") else { continue }
            result.assets.append(ArtworkAsset(kind: .screenshot, url: url, provider: "GameDB", sourceURL: url, credit: nil))
        }
        return result
    }

    private func sourceURL(for game: GameRecord) -> URL? {
        if let raw = game.url, let url = URL(string: raw), url.scheme == "https", url.host == "www.igdb.com" { return url }
        return game.slug.flatMap { URL(string: "https://www.igdb.com/games/\($0)") }
    }

    private func imageURL(_ raw: String?, size: String) -> URL? {
        guard var raw, !raw.isEmpty else { return nil }
        if raw.hasPrefix("//") { raw = "https:" + raw }
        raw = raw.replacingOccurrences(of: "/t_thumb/", with: "/\(size)/")
        guard let url = URL(string: raw), url.scheme == "https", url.host == "images.igdb.com" else { return nil }
        return url
    }

    private func uniqueNames(_ values: [NamedRecord]?) -> [String] {
        var seen = Set<String>()
        return (values ?? []).compactMap { $0.name?.nilIfBlank }.filter { seen.insert($0).inserted }
    }

    private func get<T: Decodable>(_ url: URL, as type: T.Type) async throws -> T {
        guard Self.isGameDBURL(url) else { throw GameDBError.invalidResponse }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.url.map(Self.isGameDBURL) == true,
              (200..<300).contains(http.statusCode), data.count <= 12_000_000 else { throw GameDBError.invalidResponse }
        return try JSONDecoder().decode(type, from: data)
    }

    private static func bucketName(_ title: String) -> String {
        let scalars = Array(title.unicodeScalars)
        guard let firstIndex = scalars.firstIndex(where: CharacterSet.alphanumerics.contains) else { return "@" }
        let first = scalars[firstIndex]
        var index = scalars.index(after: firstIndex)
        if index < scalars.endIndex, CharacterSet.whitespacesAndNewlines.contains(scalars[index]) { return String(first).lowercased() }
        while index < scalars.endIndex, !CharacterSet.alphanumerics.contains(scalars[index]) { index = scalars.index(after: index) }
        guard index < scalars.endIndex else { return String(first).lowercased() }
        return (String(first) + String(scalars[index])).lowercased()
    }
}

private struct BucketEntry: Decodable { var name: String? }
private struct GameRecord: Decodable {
    var name: String?
    var slug: String?
    var url: String?
    var summary: String?
    var storyline: String?
    var cover: ImageRecord?
    var artworks: [ImageRecord]?
    var screenshots: [ImageRecord]?
    var genres: [NamedRecord]?
    var platforms: [Int]?
    var releaseDates: [ReleaseDateRecord]?
    var involvedCompanies: [CompanyRecord]?
    var gameLocalizations: [LocalizationRecord]?
    enum CodingKeys: String, CodingKey {
        case name, slug, url, summary, storyline, cover, artworks, screenshots, genres, platforms
        case releaseDates = "release_dates"
        case involvedCompanies = "involved_companies"
        case gameLocalizations = "game_localizations"
    }
}
private struct ImageRecord: Decodable { var url: String? }
private struct NamedRecord: Decodable { var name: String? }
private struct PlatformRecord: Decodable { var name: String? }
private struct ReleaseDateRecord: Decodable { var date: Int64? }
private struct CompanyRecord: Decodable {
    var developer: Bool?
    var publisher: Bool?
    var company: NamedRecord?
}
private struct LocalizationRecord: Decodable { var cover: ImageRecord? }
private enum GameDBError: Error { case invalidResponse }

private extension String {
    var nilIfBlank: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}
