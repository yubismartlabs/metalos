import Foundation

struct ArtworkCredentials: Codable, Equatable, Sendable {
    var igdbClientID = ""
    var igdbClientSecret = ""
    var hasIGDB: Bool { !igdbClientID.isEmpty && !igdbClientSecret.isEmpty }
    var isConfigured: Bool { hasIGDB }

    init(igdbClientID: String = "", igdbClientSecret: String = "") {
        self.igdbClientID = igdbClientID
        self.igdbClientSecret = igdbClientSecret
    }

    // Older builds stored a single SteamGridDB key under the same Keychain item.
    // Ignore that payload instead of failing to load, then let the user enter IGDB credentials.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        igdbClientID = try container.decodeIfPresent(String.self, forKey: .igdbClientID) ?? ""
        igdbClientSecret = try container.decodeIfPresent(String.self, forKey: .igdbClientSecret) ?? ""
    }

    private enum CodingKeys: String, CodingKey { case igdbClientID, igdbClientSecret }
}
enum ArtworkKind: String, Sendable { case cover, tile, hero, screenshot }
struct ArtworkAsset: Sendable {
    var kind: ArtworkKind
    var url: URL
    var provider: String
    var sourceURL: URL?
    var credit: String?
}
struct ArtworkLookupResult: Sendable {
    var assets: [ArtworkAsset] = []
    var matchedTitle: String?
    var messages: [String] = []
    var metadata: GameMetadata?
}
struct ArtworkRecord: Codable, Hashable, Sendable {
    var path: String
    var provider: String
    var sourceURL: String?
    var credit: String?
}
struct ArtworkCandidate: Sendable {
    var id: Int
    var name: String
}

struct GameDBVideo: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var videoID: String
    var title: String
    var thumbnailPath: String?
    var thumbnailURL: String { "https://img.youtube.com/vi/\(videoID)/hqdefault.jpg" }
}

struct GameMetadata: Codable, Hashable, Sendable {
    var summary: String? = nil
    var storyline: String? = nil
    var genres: [String] = []
    var platforms: [String] = []
    var releaseDate: String? = nil
    var developers: [String] = []
    var publishers: [String] = []
    var screenshots: [ArtworkRecord] = []
    var sourceURL: String? = nil
    var localizedTitle: String? = nil
    var collections: [String] = []
    var franchises: [String] = []
    var videoIDs: [String] = []
    var alternateArtworkURLs: [String] = []
    var localLogoPath: String? = nil
    var videos: [GameDBVideo] = []
    var releaseYear: Int? = nil

    private enum CodingKeys: String, CodingKey {
        case summary, storyline, genres, platforms, releaseDate, developers, publishers, screenshots, sourceURL
        case localizedTitle, collections, franchises, videoIDs, alternateArtworkURLs, localLogoPath, videos, releaseYear
    }

    init(summary: String? = nil, storyline: String? = nil, genres: [String] = [], platforms: [String] = [],
         releaseDate: String? = nil, developers: [String] = [], publishers: [String] = [],
         screenshots: [ArtworkRecord] = [], sourceURL: String? = nil, localizedTitle: String? = nil,
         collections: [String] = [], franchises: [String] = [], videoIDs: [String] = [], alternateArtworkURLs: [String] = [],
         localLogoPath: String? = nil, videos: [GameDBVideo] = [], releaseYear: Int? = nil) {
        self.summary = summary
        self.storyline = storyline
        self.genres = genres
        self.platforms = platforms
        self.releaseDate = releaseDate
        self.developers = developers
        self.publishers = publishers
        self.screenshots = screenshots
        self.sourceURL = sourceURL
        self.localizedTitle = localizedTitle
        self.collections = collections
        self.franchises = franchises
        self.videoIDs = videoIDs
        self.alternateArtworkURLs = alternateArtworkURLs
        self.localLogoPath = localLogoPath
        self.videos = videos
        self.releaseYear = releaseYear
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        summary = try values.decodeIfPresent(String.self, forKey: .summary)
        storyline = try values.decodeIfPresent(String.self, forKey: .storyline)
        genres = try values.decodeIfPresent([String].self, forKey: .genres) ?? []
        platforms = try values.decodeIfPresent([String].self, forKey: .platforms) ?? []
        releaseDate = try values.decodeIfPresent(String.self, forKey: .releaseDate)
        developers = try values.decodeIfPresent([String].self, forKey: .developers) ?? []
        publishers = try values.decodeIfPresent([String].self, forKey: .publishers) ?? []
        screenshots = try values.decodeIfPresent([ArtworkRecord].self, forKey: .screenshots) ?? []
        sourceURL = try values.decodeIfPresent(String.self, forKey: .sourceURL)
        localizedTitle = try values.decodeIfPresent(String.self, forKey: .localizedTitle)
        collections = try values.decodeIfPresent([String].self, forKey: .collections) ?? []
        franchises = try values.decodeIfPresent([String].self, forKey: .franchises) ?? []
        videoIDs = try values.decodeIfPresent([String].self, forKey: .videoIDs) ?? []
        alternateArtworkURLs = try values.decodeIfPresent([String].self, forKey: .alternateArtworkURLs) ?? []
        localLogoPath = try values.decodeIfPresent(String.self, forKey: .localLogoPath)
        videos = try values.decodeIfPresent([GameDBVideo].self, forKey: .videos) ?? []
        releaseYear = try values.decodeIfPresent(Int.self, forKey: .releaseYear)
    }
}
