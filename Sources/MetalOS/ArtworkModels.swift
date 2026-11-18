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
}
