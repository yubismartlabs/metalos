import Foundation

struct NXSupportStatus: Codable, Hashable, Sendable {
    enum State: String, Codable, Sendable { case listed, unlisted, unknown }
    var state: State
    var checkedAt: Date?
    var note: String
    var notesURL: String?
    var latestProfileRevision: String? = nil
    var label: String {
        switch state {
        case .listed: "MetalOS engine profile"
        case .unlisted: "Not listed by NXNative"
        case .unknown: "NXNative support unknown"
        }
    }
}

/// Uses the MetalOS-selected Yubismartlabs fork's published table, never a custom local checkout's profiles.
struct NXSupportCatalog: Sendable {
    static let sourceURL = URL(string: "https://raw.githubusercontent.com/yubismartlabs/nxnative/main/dm/games/README.md")!
    static let tableURL = "https://github.com/yubismartlabs/nxnative/blob/main/dm/games/README.md"
    static let repositoryAPI = "https://api.github.com/repos/yubismartlabs/nxnative/commits?per_page=1&path=dm/games/"
    var entries: [String: String]

    init(markdown: String) throws {
        var entries: [String: String] = [:]
        for line in markdown.components(separatedBy: .newlines) where line.hasPrefix("|") {
            let columns = line.split(separator: "|", omittingEmptySubsequences: false)
            guard columns.count >= 7 else { continue }
            let id = columns[2].trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "`")))
            guard id.count == 16, SwitchGameDiscovery.titleIDs(in: id) == [id.uppercased()] else { continue }
            entries[id.uppercased()] = columns[3].trimmingCharacters(in: .whitespaces)
        }
        guard !entries.isEmpty else { throw StudioError.message("NXNative's official games table could not be read.") }
        self.entries = entries
    }

    static func fetch() async throws -> NXSupportCatalog {
        var request = URLRequest(url: sourceURL)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let markdown = String(data: data, encoding: .utf8) else {
            throw StudioError.message("NXNative's official games table is unavailable.")
        }
        return try NXSupportCatalog(markdown: markdown)
    }

    static func latestProfileRevision(titleID: String) async throws -> String? {
        guard let url = URL(string: repositoryAPI + titleID.uppercased()) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw StudioError.message("Could not check NXNative profile updates.")
        }
        struct Commit: Decodable { var sha: String }
        // Include the catalog identity: the same profile may have different Git SHAs
        // after MetalOS switches its default engine fork.
        return try JSONDecoder().decode([Commit].self, from: data).first.map { "yubismartlabs:\($0.sha)" }
    }

    func status(titleID: String?) -> NXSupportStatus {
        guard let titleID else {
            return NXSupportStatus(state: .unknown, checkedAt: Date(), note: "No unambiguous base title ID found. Include [title ID] in the base game's filename to check official support.")
        }
        let id = titleID.uppercased()
        if let build = entries[id] {
            return NXSupportStatus(state: .listed, checkedAt: Date(), note: "Listed in the MetalOS NXNative games table. Tested build: \(build). Check the game's notes for Mac progress and known issues.", notesURL: "https://github.com/yubismartlabs/nxnative/blob/main/dm/games/\(id)/README.md")
        }
        return NXSupportStatus(state: .unlisted, checkedAt: Date(), note: "This title ID is absent from the official NXNative games table. A provisional build may not run.", notesURL: Self.tableURL)
    }
}
