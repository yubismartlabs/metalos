import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

struct GameDBEnrichment: Sendable {
    let gameID: String
    let titleKey: String
    let matchedTitle: String?
    let metadata: GameMetadata?
    let tilePath: String?
    let heroPath: String?
    let artworkPaths: [String]
    let logoPath: String?
    let isNegativeLookup: Bool
    let errorMessage: String?
}

/// Zero-key client and persistent cache for LizardByte's static GameDB mirror.
actor GameDBService {
    static let shared = GameDBService()

    private struct BucketEntry: Codable { var name: String? }
    private struct BucketCache: Codable { var fetchedAt: Date; var entries: [String: BucketEntry] }
    private struct CachedEnrichment: Codable {
        var titleKey: String
        var fetchedAt: Date
        var matchedTitle: String?
        var metadata: GameMetadata?
        var tilePath: String?
        var heroPath: String?
        var artworkPaths: [String]
        var logoPath: String?
        var isNegativeLookup: Bool
    }
    private struct ImageRef {
        var url: String
        var width: Int
        var height: Int
    }

    private let baseURL = URL(string: "https://app.lizardbyte.dev/GameDB/")!
    private let root: URL
    private let session: URLSession
    private var platformNames: [Int: String] = [:]
    private let bucketTTL: TimeInterval = 7 * 24 * 60 * 60
    private let negativeTTL: TimeInterval = 30 * 24 * 60 * 60
    private let region = Locale.current.region?.identifier.lowercased()

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MetalOS/Cache", isDirectory: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 30
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    nonisolated static func sanitizeTitle(_ title: String) -> String {
        var value = GameTitleMatcher.searchTitle(title)
        value = value.replacingOccurrences(of: #"(?i)\s+\d+(?:\.\d+){1,4}\s*$"#, with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: #"(?i)\s*[\[(](?:rev(?:ision)?\s*\d+|v?\d+(?:\.\d+)+|usa|eur|europe|jpn|japan|world|ntsc[- ]?[uj]|pal)[^\])]*[\])]"#, with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: #"[™®©]"#, with: "", options: .regularExpression)
        return value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func bucketName(for title: String) -> String {
        let title = sanitizeTitle(title)
        let characters = Array(title.unicodeScalars)
        guard let first = characters.first, CharacterSet.alphanumerics.contains(first) else { return "@" }
        guard characters.count > 1 else { return String(first).lowercased() }
        let second = characters[1]
        if CharacterSet.whitespacesAndNewlines.contains(second) { return String(first).lowercased() }
        guard CharacterSet.alphanumerics.contains(second) else { return "@" }
        return (String(first) + String(second)).lowercased()
    }

    nonisolated private static func localizedBucketName(for title: String) -> String {
        let scalars = sanitizeTitle(title).unicodeScalars.filter(CharacterSet.alphanumerics.contains)
        guard !scalars.isEmpty else { return "@" }
        return String(String.UnicodeScalarView(scalars.prefix(2))).lowercased()
    }

    func enrich(_ game: Game) async -> GameDBEnrichment {
        let titleKey = Self.sanitizeTitle(game.normalizedTitle ?? game.displayTitle)
        let folder = gameFolder(game.id)
        let metadataURL = folder.appendingPathComponent("metadata.json")
        if let cached = read(CachedEnrichment.self, from: metadataURL), cached.titleKey == titleKey {
            let hasAssets = [cached.tilePath, cached.heroPath].compactMap { $0 }.allSatisfy { FileManager.default.fileExists(atPath: $0) }
            let fresh = Date().timeIntervalSince(cached.fetchedAt) < (cached.isNegativeLookup ? negativeTTL : bucketTTL)
            if hasAssets && (fresh || !cached.isNegativeLookup) {
                return result(game.id, cached)
            }
        }

        guard !titleKey.isEmpty else {
            return fallback(game, titleKey: titleKey, message: "Game title is empty after cleanup.")
        }

        do {
            let entries = try await mergedBucketEntries(title: titleKey)
            let candidates = entries.compactMap { key, entry -> ArtworkCandidate? in
                guard let id = Int(key), let name = entry.name else { return nil }
                return ArtworkCandidate(id: id, name: name)
            }
            guard let candidate = GameTitleMatcher.bestMatch(title: titleKey, candidates: candidates) else {
                let negative = CachedEnrichment(titleKey: titleKey, fetchedAt: .now, matchedTitle: nil, metadata: nil,
                    tilePath: nil, heroPath: nil, artworkPaths: [], logoPath: localLogoPath(game), isNegativeLookup: true)
                write(negative, to: metadataURL)
                return fallback(game, titleKey: titleKey, message: nil, negative: true)
            }

            let record = try await gameRecord(id: candidate.id, folder: folder)
            var metadata = makeMetadata(record, requestedRegion: region)
            let localizations = record["game_localizations"] as? [[String: Any]] ?? []
            let localizedCover = localizations.first(where: { localization in
                guard let region = region?.lowercased(),
                      let record = localization["region"] as? [String: Any],
                      let identifier = record["identifier"] as? String else { return false }
                return identifier.lowercased() == region && imageRef(localization["cover"]) != nil
            }).flatMap { imageRef($0["cover"]) }
            let coverRef = localizedCover ?? imageRef(record["cover"])
            let artworkRefs = (record["artworks"] as? [Any] ?? []).compactMap(imageRef)
            let screenshotRefs = (record["screenshots"] as? [Any] ?? []).compactMap(imageRef)
            let allHeroRefs = artworkRefs.isEmpty ? screenshotRefs : artworkRefs
            metadata.alternateArtworkURLs = (artworkRefs + screenshotRefs).compactMap { imageURL($0.url, size: "t_1080p")?.absoluteString }
            let orderedHeroRefs = allHeroRefs.sorted { lhs, rhs in
                let lhsRatio = Double(lhs.width) / Double(max(lhs.height, 1))
                let rhsRatio = Double(rhs.width) / Double(max(rhs.height, 1))
                let lhsScore = abs(lhsRatio - 16.0 / 9.0) + 1 / Double(max(lhs.width * lhs.height, 1)) * 100_000
                let rhsScore = abs(rhsRatio - 16.0 / 9.0) + 1 / Double(max(rhs.width * rhs.height, 1)) * 100_000
                return lhsScore < rhsScore
            }
            let heroRefs = orderedHeroRefs.isEmpty ? [] : Array(orderedHeroRefs.prefix(8))
            var tilePath: String?
            var heroPath: String?
            if let coverRef, let url = imageURL(coverRef.url, size: "t_cover_big_2x") {
                tilePath = try? await cacheImage(url, as: "tile.jpg", in: folder, maxPixelSize: 1024)
                if tilePath == nil, let fallbackURL = imageURL(coverRef.url, size: "t_cover_big") {
                    tilePath = try? await cacheImage(fallbackURL, as: "tile.jpg", in: folder, maxPixelSize: 1024)
                }
            }
            if let bestHero = heroRefs.first, let url = imageURL(bestHero.url, size: "t_1080p") {
                heroPath = try? await cacheImage(url, as: "hero.jpg", in: folder, maxPixelSize: 1920)
            }
            var paths: [String] = []
            let alternateRefs = Array(artworkRefs.prefix(8)) + Array(screenshotRefs.prefix(8))
            for (index, ref) in alternateRefs.enumerated() {
                guard let url = imageURL(ref.url, size: "t_1080p"),
                      let path = try? await cacheImage(url, as: "artwork-\(index).jpg", in: folder, maxPixelSize: 1920) else { continue }
                paths.append(path)
            }
            metadata.platforms = await resolveNames(record["platforms"])
            metadata.videos = await resolveVideos(metadata.videoIDs, in: folder)
            let logo = localLogoPath(game)
            metadata.localLogoPath = logo
            if tilePath == nil || heroPath == nil {
                let local = makeFallback(game: game, folder: folder)
                if tilePath == nil { tilePath = local.tile }
                if heroPath == nil { heroPath = local.hero }
            }
            let cached = CachedEnrichment(titleKey: titleKey, fetchedAt: .now,
                matchedTitle: record["name"] as? String ?? candidate.name, metadata: metadata,
                tilePath: tilePath, heroPath: heroPath, artworkPaths: paths, logoPath: logo, isNegativeLookup: false)
            write(cached, to: metadataURL)
            return result(game.id, cached)
        } catch {
            if let cached = read(CachedEnrichment.self, from: metadataURL), cached.titleKey == titleKey,
               cached.tilePath.map({ FileManager.default.fileExists(atPath: $0) }) == true {
                return result(game.id, cached)
            }
            return fallback(game, titleKey: titleKey, message: "GameDB unavailable; using local app artwork.", persist: false)
        }
    }

    private func mergedBucketEntries(title: String) async throws -> [String: BucketEntry] {
        let bucket = Self.bucketName(for: title)
        var result = try await loadBucket(path: "buckets/\(bucket).json", cacheName: bucket)
        if let region, !region.isEmpty, region.range(of: #"^[a-z0-9_-]+$"#, options: .regularExpression) != nil {
            let localizedBucket = Self.localizedBucketName(for: title)
            let localized = try? await loadBucket(path: "buckets/localized/\(region)/\(localizedBucket).json", cacheName: "localized-\(region)-\(localizedBucket)")
            for (id, entry) in localized ?? [:] { result[id] = entry }
        }
        return result
    }

    private func loadBucket(path: String, cacheName: String) async throws -> [String: BucketEntry] {
        let cacheURL = root.appendingPathComponent("Buckets/\(cacheName).json")
        if let cache = read(BucketCache.self, from: cacheURL), Date().timeIntervalSince(cache.fetchedAt) < bucketTTL { return cache.entries }
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else { throw URLError(.badURL) }
        do {
            let data = try await fetchJSON(url)
            let entries = try JSONDecoder().decode([String: BucketEntry].self, from: data)
            write(BucketCache(fetchedAt: .now, entries: entries), to: cacheURL)
            return entries
        } catch {
            if let cache = read(BucketCache.self, from: cacheURL) { return cache.entries }
            throw error
        }
    }

    private func gameRecord(id: Int, folder: URL) async throws -> [String: Any] {
        let cacheURL = folder.appendingPathComponent("record.json")
        if let data = try? Data(contentsOf: cacheURL), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return json }
        guard let url = URL(string: "games/\(id).json", relativeTo: baseURL)?.absoluteURL else { throw URLError(.badURL) }
        let data = try await fetchJSON(url)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: cacheURL, options: .atomic)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    private func fetchJSON(_ url: URL) async throws -> Data {
        guard url.scheme == "https", url.host == "app.lizardbyte.dev" else { throw URLError(.unsupportedURL) }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.url?.host == "app.lizardbyte.dev", data.count <= 16_000_000 else { throw URLError(.badServerResponse) }
        return data
    }

    private func makeMetadata(_ record: [String: Any], requestedRegion: String?) -> GameMetadata {
        let companies = record["involved_companies"] as? [[String: Any]] ?? []
        let genres = names(record["genres"])
        let developers = unique(companies.filter { $0["developer"] as? Bool == true }.flatMap { names($0["company"]) })
        let publishers = unique(companies.filter { $0["publisher"] as? Bool == true }.flatMap { names($0["company"]) })
        let releaseDates = record["release_dates"] as? [[String: Any]] ?? []
        let epoch = releaseDates.compactMap { number($0["date"]) }.min()
        let release = epoch.map { Date(timeIntervalSince1970: TimeInterval($0)).formatted(date: .abbreviated, time: .omitted) }
        let collections = names(record["collections"])
        let franchises = names(record["franchises"])
        let localizations = record["game_localizations"] as? [[String: Any]] ?? []
        let localizedName = localizations.first { item in
            guard let requestedRegion,
                  let region = item["region"] as? [String: Any],
                  let identifier = region["identifier"] as? String else { return false }
            return identifier.lowercased() == requestedRegion.lowercased()
        }?["name"] as? String
        let videoRefs = record["videos"] as? [Any] ?? []
        let videoIDs = videoRefs.compactMap { value -> String? in
            if let item = value as? [String: Any] {
                if let id = item["id"] as? Int { return String(id) }
                if let id = item["id"] as? String { return id }
                if let videoID = item["video_id"] as? String { return videoID }
            }
            if let id = value as? Int { return String(id) }
            if let id = value as? String { return id }
            return nil
        }
        let releaseYear = epoch.map { Calendar(identifier: .gregorian).component(.year, from: Date(timeIntervalSince1970: TimeInterval($0))) }
        return GameMetadata(summary: clean(record["summary"] as? String), storyline: clean(record["storyline"] as? String),
            genres: genres, platforms: [], releaseDate: release, developers: developers, publishers: publishers,
            screenshots: [], sourceURL: record["url"] as? String ?? (record["slug"] as? String).map { "https://www.igdb.com/games/\($0)" },
            localizedTitle: clean(localizedName), collections: collections, franchises: franchises,
            videoIDs: videoIDs, releaseYear: releaseYear)
    }

    private func resolveNames(_ value: Any?) async -> [String] {
        let values = value as? [Any] ?? []
        var result: [String] = []
        var platformIDs: [Int] = []
        for item in values {
            if let dictionary = item as? [String: Any], let name = clean(dictionary["name"] as? String) { result.append(name) }
            else if let id = number(item) { platformIDs.append(id) }
        }
        let baseURL = self.baseURL
        let unresolved = Array(Set(platformIDs).filter { platformNames[$0] == nil })
        var found: [Int: String] = [:]
        for start in stride(from: 0, to: unresolved.count, by: 4) {
            let batch = Array(unresolved[start..<min(start + 4, unresolved.count)])
            let batchNames = await withTaskGroup(of: (Int, String?).self, returning: [Int: String].self) { group in
                for id in batch {
                    group.addTask { [weak self] in
                        guard let self, let url = URL(string: "platforms/\(id).json", relativeTo: baseURL)?.absoluteURL,
                              let data = try? await self.fetchJSON(url),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (id, nil) }
                        let name = (json["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                        return (id, name?.isEmpty == false ? name : nil)
                    }
                }
                var batchFound: [Int: String] = [:]
                for await (id, name) in group { if let name { batchFound[id] = name } }
                return batchFound
            }
            found.merge(batchNames) { _, new in new }
        }
        platformNames.merge(found) { _, new in new }
        result.append(contentsOf: platformIDs.compactMap { platformNames[$0] })
        return unique(result)
    }

    private func imageRef(_ value: Any?) -> ImageRef? {
        guard let value = value as? [String: Any], let url = value["url"] as? String else { return nil }
        return ImageRef(url: url, width: number(value["width"]) ?? 0, height: number(value["height"]) ?? 0)
    }

    private func imageURL(_ raw: String, size: String) -> URL? {
        var value = raw.hasPrefix("//") ? "https:" + raw : raw
        value = value.replacingOccurrences(of: "/t_thumb/", with: "/\(size)/")
        guard let url = URL(string: value), url.scheme == "https", url.host == "images.igdb.com" else { return nil }
        return url
    }

    private func resolveVideos(_ ids: [String], in folder: URL) async -> [GameDBVideo] {
        let baseURL = self.baseURL
        var resolved: [String: GameDBVideo] = [:]
        let validIDs = ids.prefix(12).filter { $0.range(of: #"^[A-Za-z0-9_-]{1,64}$"#, options: .regularExpression) != nil }
        for start in stride(from: 0, to: validIDs.count, by: 4) {
            let batch = Array(validIDs[start..<min(start + 4, validIDs.count)])
            let videos = await withTaskGroup(of: GameDBVideo?.self, returning: [GameDBVideo].self) { group in
                for id in batch {
                    group.addTask { [weak self] in
                        guard let self else { return nil }
                        let cacheFolder = folder.appendingPathComponent("Videos", isDirectory: true)
                        let cacheFile = cacheFolder.appendingPathComponent("\(id).json")
                        var record: [String: Any]?
                        if let data = try? Data(contentsOf: cacheFile) {
                            record = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        }
                        if record == nil, let url = URL(string: "videos/\(id).json", relativeTo: baseURL)?.absoluteURL,
                           let data = try? await self.fetchJSON(url) {
                            try? FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
                            try? data.write(to: cacheFile, options: .atomic)
                            record = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        }
                        guard let record, let videoID = record["video_id"] as? String,
                              videoID.range(of: #"^[A-Za-z0-9_-]{6,32}$"#, options: .regularExpression) != nil else { return nil }
                        let title = (record["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                        let thumbnail = URL(string: "https://img.youtube.com/vi/\(videoID)/hqdefault.jpg")
                        var path: String?
                        if let thumbnail { path = try? await self.cacheImage(thumbnail, as: "video-\(id).jpg", in: folder, maxPixelSize: 640) }
                        return GameDBVideo(id: id, videoID: videoID, title: title?.isEmpty == false ? title! : "Game Trailer", thumbnailPath: path)
                    }
                }
                var batchResult: [GameDBVideo] = []
                for await video in group { if let video { batchResult.append(video) } }
                return batchResult
            }
            for video in videos { resolved[video.id] = video }
        }
        return validIDs.compactMap { resolved[$0] }
    }

    private func cacheImage(_ url: URL, as name: String, in folder: URL, maxPixelSize: Int) async throws -> String {
        guard url.scheme == "https", ["images.igdb.com", "img.youtube.com"].contains(url.host ?? "") else { throw URLError(.unsupportedURL) }
        let destination = folder.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: destination.path) { return destination.path }
        var request = URLRequest(url: url)
        request.timeoutInterval = 18
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              ["images.igdb.com", "img.youtube.com"].contains(response.url?.host ?? ""), data.count < 24_000_000 else { throw URLError(.badServerResponse) }
        let encoded = await GameArtworkImageCache.jpegThumbnail(data: data, maxPixelSize: maxPixelSize)
        guard let encoded else { throw URLError(.cannotDecodeContentData) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try encoded.write(to: destination, options: .atomic)
        return destination.path
    }

    private func gameFolder(_ id: String) -> URL {
        let safeID = id.range(of: #"^[A-Za-z0-9._-]{1,96}$"#, options: .regularExpression) != nil
            ? id : SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent("Games/\(safeID)", isDirectory: true)
    }

    private func localLogoPath(_ game: Game) -> String? {
        let bundle = URL(fileURLWithPath: game.installPath, isDirectory: true)
        guard bundle.pathExtension.lowercased() == "app" else { return nil }
        let path = bundle.appendingPathComponent("Contents/Resources/logo.png").path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    private func fallback(_ game: Game, titleKey: String, message: String?, negative: Bool = false, persist: Bool = true) -> GameDBEnrichment {
        let folder = gameFolder(game.id)
        let assets = makeFallback(game: game, folder: folder)
        let logo = localLogoPath(game)
        let metadata = logo.map { GameMetadata(localLogoPath: $0) }
        let cached = CachedEnrichment(titleKey: titleKey, fetchedAt: .now, matchedTitle: nil, metadata: metadata,
            tilePath: assets.tile, heroPath: assets.hero, artworkPaths: [], logoPath: logo, isNegativeLookup: negative)
        if persist { write(cached, to: folder.appendingPathComponent("metadata.json")) }
        return GameDBEnrichment(gameID: game.id, titleKey: titleKey, matchedTitle: nil, metadata: metadata,
            tilePath: assets.tile, heroPath: assets.hero, artworkPaths: [], logoPath: cached.logoPath,
            isNegativeLookup: negative, errorMessage: message)
    }

    private func makeFallback(game: Game, folder: URL) -> (tile: String?, hero: String?) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let tile = folder.appendingPathComponent("fallback-tile.jpg")
        let hero = folder.appendingPathComponent("fallback-hero.jpg")
        if !FileManager.default.fileExists(atPath: tile.path) {
            let icon = NSWorkspace.shared.icon(forFile: game.installPath)
            icon.size = NSSize(width: 512, height: 512)
            if let data = icon.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: data),
               let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) {
                try? jpeg.write(to: tile, options: .atomic)
            }
        }
        if !FileManager.default.fileExists(atPath: hero.path), let color = dominantColor(at: tile.path) {
            if let context = CGContext(data: nil, width: 1920, height: 1080, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
               let gradient = CGGradient(colorsSpace: context.colorSpace, colors: [color, CGColor(gray: 0.025, alpha: 1)] as CFArray, locations: [0, 1]) {
                context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 1080), end: CGPoint(x: 1920, y: 0), options: [])
                if let image = context.makeImage(), let data = jpegData(image) { try? data.write(to: hero, options: .atomic) }
            }
        }
        return (FileManager.default.fileExists(atPath: tile.path) ? tile.path : nil,
                FileManager.default.fileExists(atPath: hero.path) ? hero.path : nil)
    }

    private func dominantColor(at path: String) -> CGColor? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 24] as CFDictionary),
              let data = image.dataProvider?.data as Data? else { return nil }
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return nil }
        var red = 0.0, green = 0.0, blue = 0.0, samples = 0.0
        for index in stride(from: 0, to: bytes.count - 3, by: 4) {
            red += Double(bytes[index]) / 255; green += Double(bytes[index + 1]) / 255; blue += Double(bytes[index + 2]) / 255; samples += 1
        }
        guard samples > 0 else { return nil }
        return CGColor(red: red / samples, green: green / samples, blue: blue / samples, alpha: 1)
    }

    private func jpegData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private func result(_ id: String, _ cached: CachedEnrichment) -> GameDBEnrichment {
        GameDBEnrichment(gameID: id, titleKey: cached.titleKey, matchedTitle: cached.matchedTitle, metadata: cached.metadata,
            tilePath: cached.tilePath, heroPath: cached.heroPath, artworkPaths: cached.artworkPaths,
            logoPath: cached.logoPath, isNegativeLookup: cached.isNegativeLookup, errorMessage: nil)
    }

    private func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: url, options: .atomic)
        } catch { }
    }

    private func names(_ value: Any?) -> [String] {
        if let ids = value as? [Any] {
            return unique(ids.compactMap { ($0 as? [String: Any]).flatMap { clean($0["name"] as? String) } })
        }
        if let dictionary = value as? [String: Any], let name = clean(dictionary["name"] as? String) { return [name] }
        return []
    }

    private func number(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

actor GameArtworkImageCache {
    static let shared = GameArtworkImageCache()
    private let memory = NSCache<NSString, CGImage>()

    init() { memory.totalCostLimit = 96 * 1024 * 1024 }

    func image(path: String, maxPixelSize: Int) async -> CGImage? {
        let modified = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970) ?? 0
        let key = "\(maxPixelSize):\(modified):\(path)" as NSString
        if let cached = memory.object(forKey: key) { return cached }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let image = await Self.downsample(data: data, maxPixelSize: maxPixelSize) else { return nil }
        memory.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }

    static func jpegThumbnail(data: Data, maxPixelSize: Int) async -> Data? {
        guard let image = await downsample(data: data, maxPixelSize: maxPixelSize) else { return nil }
        return await Task.detached(priority: .utility) {
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return nil }
            return output as Data
        }.value
    }

    private static func downsample(data: Data, maxPixelSize: Int) async -> CGImage? {
        await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
            ] as CFDictionary)
        }.value
    }
}

/// Prioritized bounded worker queue: selected game, adjacent games, then the rest.
actor MetadataEnrichmentQueue {
    typealias Completion = @MainActor @Sendable (GameDBEnrichment) -> Void
    private struct Job { let game: Game; var priority: Int }
    private let service: GameDBService
    private let completion: Completion
    private let maxConcurrent: Int
    private var pending: [String: Job] = [:]
    private var running: Set<String> = []

    init(service: GameDBService = .shared, maxConcurrent: Int = 3, completion: @escaping Completion) {
        self.service = service
        self.maxConcurrent = min(max(maxConcurrent, 1), 4)
        self.completion = completion
    }

    func enqueue(_ games: [Game], focusedGameID: String?) {
        let ids = games.map(\.id)
        for (index, game) in games.enumerated() {
            let priority: Int
            if game.id == focusedGameID { priority = 0 }
            else if let focusedGameID, let focusIndex = ids.firstIndex(of: focusedGameID), abs(index - focusIndex) == 1 { priority = 1 }
            else { priority = index + 2 }
            if running.contains(game.id) { continue }
            if let existing = pending[game.id] { pending[game.id] = Job(game: game, priority: min(priority, existing.priority)) }
            else { pending[game.id] = Job(game: game, priority: priority) }
        }
        pump()
    }

    private func pump() {
        while running.count < maxConcurrent,
              let next = pending.min(by: { lhs, rhs in
                  lhs.value.priority == rhs.value.priority ? lhs.key < rhs.key : lhs.value.priority < rhs.value.priority
              }) {
            pending[next.key] = nil
            running.insert(next.key)
            Task { [service, completion] in
                let result = await service.enrich(next.value.game)
                await completion(result)
                self.finished(next.key)
            }
        }
    }

    private func finished(_ id: String) {
        running.remove(id)
        pump()
    }
}
