import Foundation
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

private final class ArtworkDownloadDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(ArtworkCache.isTrustedImageURL) == true ? request : nil)
    }
}
actor ArtworkCache {
    private let root: URL
    private let session: URLSession
    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NXStudio/Artwork", isDirectory: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 90
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: ArtworkDownloadDelegate(), delegateQueue: nil)
    }
    nonisolated static func isTrustedImageURL(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        return ["images.igdb.com", "img-eshop.cdn.nintendo.net", "assets.nintendo.com"].contains(host)
    }
    nonisolated static func folderName(for gameID: String) -> String {
        SHA256.hash(data: Data(gameID.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func fetch(_ asset: ArtworkAsset, gameID: String, replacing: Bool = false) async throws -> ArtworkRecord {
        guard Self.isTrustedImageURL(asset.url) else { throw StudioError.message("Artwork provider returned an unsupported image host.") }
        let folder = root.appendingPathComponent(Self.folderName(for: gameID), isDirectory: true)
        let digest = SHA256.hash(data: Data(asset.url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        let target = folder.appendingPathComponent("\(asset.kind.rawValue)-\(digest).jpg")
        if !replacing, FileManager.default.fileExists(atPath: target.path) {
            return ArtworkRecord(path: target.path, provider: asset.provider, sourceURL: asset.sourceURL?.absoluteString, credit: asset.credit)
        }
        let (temporary, response) = try await session.download(from: asset.url)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, let final = http.url, Self.isTrustedImageURL(final) else { throw StudioError.message("Artwork image download failed.") }
        try Self.storeImage(input: temporary, target: target, kind: asset.kind)
        return ArtworkRecord(path: target.path, provider: asset.provider, sourceURL: asset.sourceURL?.absoluteString, credit: asset.credit)
    }
    /// Artwork is kept in Application Support for as long as the game remains in the library.
    func removeArtwork(for gameID: String) {
        try? FileManager.default.removeItem(at: root.appendingPathComponent(Self.folderName(for: gameID), isDirectory: true))
    }
    /// Deletes files superseded by the game's current cover and hero records.
    func retainArtwork(for gameID: String, paths: Set<String>) {
        let folder = root.appendingPathComponent(Self.folderName(for: gameID), isDirectory: true)
        let keep = Set(paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        guard let contents = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        for url in contents where !keep.contains(url.standardizedFileURL.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }
    /// Removes artwork belonging to games that are no longer in the library.
    func prune(keeping gameIDs: Set<String>) {
        let keep = Set(gameIDs.map(Self.folderName))
        guard let contents = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for url in contents where !keep.contains(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
        }
    }
    /// Best-effort cleanup for artwork downloaded by builds that used SteamGridDB's evictable cache.
    nonisolated static func removeLegacyCachedFile(atPath path: String) {
        let legacy = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NXStudio/Artwork", isDirectory: true).standardizedFileURL
        let file = URL(fileURLWithPath: path).standardizedFileURL
        guard file.path.hasPrefix(legacy.path + "/") else { return }
        try? FileManager.default.removeItem(at: file)
    }
    /// Validates and downsizes downloaded images before they enter the persistent cache.
    nonisolated static func storeImage(input: URL, target: URL, kind: ArtworkKind) throws {
        let size = try input.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 25_000_000, let source = CGImageSourceCreateWithURL(input as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 16_384, height <= 16_384, width * height <= 80_000_000 else {
            throw StudioError.message("The artwork download is not a supported image.")
        }
        let maxSize = kind == .cover || kind == .tile ? 1000 : 1920
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: maxSize]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw StudioError.message("Could not decode artwork image.") }
        let image: CGImage
        if kind == .tile {
            let side = min(thumbnail.width, thumbnail.height)
            let crop = CGRect(x: (thumbnail.width - side) / 2, y: (thumbnail.height - side) / 2, width: side, height: side)
            guard let square = thumbnail.cropping(to: crop) else { throw StudioError.message("Could not make square game artwork.") }
            image = square
        } else {
            image = thumbnail
        }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = target.deletingLastPathComponent().appendingPathComponent("\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: staging) }
        guard let output = CGImageDestinationCreateWithURL(staging as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { throw StudioError.message("Could not create artwork cache file.") }
        CGImageDestinationAddImage(output, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        guard CGImageDestinationFinalize(output) else { throw StudioError.message("Could not save artwork image.") }
        // This actor serializes cache writes; each URL has a stable destination.
        if FileManager.default.fileExists(atPath: target.path) { _ = try FileManager.default.replaceItemAt(target, withItemAt: staging) }
        else { try FileManager.default.moveItem(at: staging, to: target) }
    }
}
