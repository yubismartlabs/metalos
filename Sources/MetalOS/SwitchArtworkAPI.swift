import Foundation

/// NX Play-style Switch artwork lookup: community title database first, Nintendo US store second.
actor SwitchArtworkAPI {
    private struct Entry: Decodable {
        var id: String?
        var name: String?
        var bannerUrl: String?
        var iconUrl: String?
        var banner: String?
        var icon: String?
    }
    private let session: URLSession
    private let cacheURL: URL
    private var entries: [String: Entry] = [:]
    private var loadedAt: Date?
    private var didLoad = false

    init(cacheURL: URL? = nil) {
        self.cacheURL = cacheURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NXStudio/Artwork/titledb-US.en.json")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 60
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    func lookup(titleID: String?) async -> ArtworkLookupResult {
        guard let titleID, titleID.range(of: #"(?i)^(?:01|04)[0-9a-f]{14}$"#, options: .regularExpression) != nil else {
            return ArtworkLookupResult(messages: ["A Switch title ID is needed for the official artwork lookup."])
        }
        var result = ArtworkLookupResult()
        do {
            do { try await loadTitleDatabase() }
            catch where !entries.isEmpty { result.messages.append("Using the cached titledb artwork list while offline.") }
            let id = titleID.uppercased()
            if let entry = entries[id] {
                result.matchedTitle = entry.name
                if let url = trustedImageURL(entry.iconUrl ?? entry.icon) {
                    result.assets.append(ArtworkAsset(kind: .cover, url: url, provider: "Nintendo eShop · titledb", sourceURL: URL(string: "https://github.com/blawar/titledb"), credit: nil))
                }
                if let url = trustedImageURL(entry.bannerUrl ?? entry.banner) {
                    result.assets.append(ArtworkAsset(kind: .hero, url: url, provider: "Nintendo eShop · titledb", sourceURL: URL(string: "https://github.com/blawar/titledb"), credit: nil))
                }
            }
            if result.assets.count < 2 {
                let fallback = try await lookupNintendoStore(titleID: titleID)
                for asset in fallback.assets where !result.assets.contains(where: { $0.kind == asset.kind }) {
                    result.assets.append(asset)
                }
                if result.matchedTitle == nil { result.matchedTitle = fallback.matchedTitle }
                result.messages += fallback.messages
            }
            if result.assets.isEmpty { result.messages.append("No Nintendo eShop artwork was found for this title ID.") }
        } catch {
            result.messages.append("Switch artwork lookup failed: \(error.localizedDescription)")
        }
        return result
    }

    func titleName(titleID: String?) async -> String? {
        guard let titleID, titleID.range(of: #"(?i)^(?:01|04)[0-9a-f]{14}$"#, options: .regularExpression) != nil else { return nil }
        do { try await loadTitleDatabase() } catch { return nil }
        return entries[titleID.uppercased()]?.name
    }

    private func loadTitleDatabase() async throws {
        if !didLoad {
            didLoad = true
            if let attrs = try? FileManager.default.attributesOfItem(atPath: cacheURL.path),
               let date = attrs[.modificationDate] as? Date,
               let data = try? Data(contentsOf: cacheURL), data.count <= 40_000_000,
               let cached = try? JSONDecoder().decode([String: Entry].self, from: data) {
                entries = cached
                loadedAt = date
            }
        }
        if let loadedAt, Date().timeIntervalSince(loadedAt) < 7 * 86_400, !entries.isEmpty { return }
        guard let url = URL(string: "https://raw.githubusercontent.com/blawar/titledb/master/US.en.json") else {
            throw StudioError.message("Could not form the titledb request.")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 40
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count <= 40_000_000 else {
            throw StudioError.message("The titledb artwork list is unavailable.")
        }
        let fetched = try JSONDecoder().decode([String: Entry].self, from: data)
        entries = fetched
        loadedAt = Date()
        try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: cacheURL, options: .atomic)
    }

    private func lookupNintendoStore(titleID: String) async throws -> ArtworkLookupResult {
        guard let url = URL(string: "https://ec.nintendo.com/apps/\(titleID.uppercased())/US") else {
            throw StudioError.message("Could not form the Nintendo eShop request.")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0 MetalOS", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode), data.count <= 6_000_000,
              let html = String(data: data, encoding: .utf8) else {
            throw StudioError.message("Nintendo's US store did not return this title page.")
        }
        let normalized = html.replacingOccurrences(of: #"\\/"#, with: "/", options: .regularExpression)
            .replacingOccurrences(of: #"\\u002[fF]"#, with: "/", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
        let pattern = "https?://(?:assets\\.nintendo\\.com|img-eshop\\.cdn\\.nintendo\\.net)/[^\\s\"'<>\\\\]+"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return ArtworkLookupResult() }
        let source = normalized as NSString
        let urls = regex.matches(in: normalized, range: NSRange(location: 0, length: source.length)).compactMap {
            URL(string: source.substring(with: $0.range).removingPercentEncoding ?? source.substring(with: $0.range))
        }.filter(ArtworkCache.isTrustedImageURL)
        var unique: [URL] = []
        for url in urls where !unique.contains(url) { unique.append(url) }
        var result = ArtworkLookupResult(matchedTitle: "Nintendo eShop")
        let square = unique.first { url in
            let text = url.absoluteString.lowercased()
            return text.contains("square") || text.contains("icon") || text.contains("1024x1024") || text.contains("shape=square")
        }
        let banner = unique.first { url in
            let text = url.absoluteString.lowercased()
            return text.contains("banner") || text.contains("1920x1080") || text.contains("shape=wide")
        } ?? unique.first(where: { $0 != square })
        if let square { result.assets.append(ArtworkAsset(kind: .cover, url: square, provider: "Nintendo eShop", sourceURL: url, credit: nil)) }
        if let banner { result.assets.append(ArtworkAsset(kind: .hero, url: banner, provider: "Nintendo eShop", sourceURL: url, credit: nil)) }
        if result.assets.isEmpty { result.messages.append("Nintendo's store page did not expose artwork images.") }
        return result
    }

    private func trustedImageURL(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value), ArtworkCache.isTrustedImageURL(url) else { return nil }
        return url
    }
}
