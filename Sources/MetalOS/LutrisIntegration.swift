import CryptoKit
import SwiftUI

enum LutrisJSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: LutrisJSONValue])
    case array([LutrisJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: LutrisJSONValue].self) { self = .object(value) }
        else if let value = try? container.decode([LutrisJSONValue].self) { self = .array(value) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported Lutris JSON value") }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var stringValue: String? {
        switch self {
        case .string(let value): value
        case .number(let value): value.rounded() == value ? String(Int(value)) : String(value)
        case .bool(let value): String(value)
        default: nil
        }
    }
    var objectValue: [String: LutrisJSONValue]? { if case .object(let value) = self { value } else { nil } }
    var arrayValue: [LutrisJSONValue]? { if case .array(let value) = self { value } else { nil } }
}

struct LutrisGameResult: Codable, Hashable, Sendable, Identifiable {
    let id: Int
    let name: String
    let slug: String
    let year: Int?
    let coverart: String?
    let bannerURL: String?
    let iconURL: String?
    let aliases: [LutrisAlias]
    let platforms: [LutrisPlatform]?

    enum CodingKeys: String, CodingKey {
        case id, name, slug, year, coverart, aliases, platforms
        case bannerURL = "banner_url"
        case iconURL = "icon_url"
    }
    var coverURL: URL? {
        [coverart, bannerURL, iconURL].compactMap { value in
            guard let value, let url = URL(string: value), url.scheme == "https", url.host == "lutris.net" || url.host?.hasSuffix(".lutris.net") == true else { return nil }
            return url
        }.first
    }
}

struct LutrisPlatform: Codable, Hashable, Sendable { let name: String }

struct LutrisAlias: Codable, Hashable, Sendable {
    let slug: String
    let name: String
}

private struct LutrisSearchEnvelope: Decodable {
    let results: [LutrisGameResult]
}

private struct LutrisInstallerEnvelope: Decodable {
    let count: Int?
    let next: String?
    let results: [LutrisInstallerRecord]
}

struct LutrisInstallerRecord: Decodable, Identifiable {
    let id: Int?
    let name: String
    let runner: String
    let slug: String
    let version: String?
    let description: String?
    let notes: String?
    let draft: Bool?
    let published: Bool?
    let script: [String: LutrisJSONValue]?
    var identity: String { slug }

    private enum CodingKeys: String, CodingKey { case id, name, runner, slug, version, description, notes, draft, published, script }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try? values.decodeIfPresent(Int.self, forKey: .id)
        name = (try? values.decode(String.self, forKey: .name)) ?? ""
        runner = (try? values.decode(String.self, forKey: .runner)) ?? ""
        slug = (try? values.decode(String.self, forKey: .slug)) ?? ""
        version = try? values.decodeIfPresent(String.self, forKey: .version)
        description = try? values.decodeIfPresent(String.self, forKey: .description)
        notes = try? values.decodeIfPresent(String.self, forKey: .notes)
        draft = try? values.decodeIfPresent(Bool.self, forKey: .draft)
        published = try? values.decodeIfPresent(Bool.self, forKey: .published)
        script = try? values.decodeIfPresent([String: LutrisJSONValue].self, forKey: .script)
    }
}

struct LutrisWineProfile: Codable, Hashable, Sendable {
    var gameName: String
    var gameSlug: String
    var installerSlug: String
    var installerVersion: String
    var architecture: String
    var executable: String?
    var workingDirectory: String?
    var launchArguments: String
    var winetricks: [String]
    var overrides: [String: String]
    var environment: [String: String]
    var files: [LutrisFileSource]
    var installerSteps: [LutrisJSONValue]

    static func parse(game: LutrisGameResult, installer: LutrisInstallerRecord) -> LutrisWineProfile? {
        guard installer.runner.lowercased() == "wine", let script = installer.script else { return nil }
        let wine = script["wine"]?.objectValue ?? [:]
        let gameBlock = script["game"]?.objectValue ?? [:]
        let system = script["system"]?.objectValue ?? [:]
        var overrides = stringDictionary(wine["overrides"]) ?? [:]
        for (key, value) in stringDictionary(gameBlock["overrides"]) ?? [:] { overrides[key] = value }
        if let tasks = script["installer"]?.arrayValue {
            for item in tasks {
                guard let task = item.objectValue?["task"]?.objectValue else { continue }
                if let taskOverrides = stringDictionary(task["overrides"]) {
                    for (key, value) in taskOverrides { overrides[key] = value }
                }
            }
        }

        var dependencies = (wine["winetricks"]?.arrayValue ?? []).compactMap(\.stringValue)
        if let value = wine["winetricks"]?.stringValue { dependencies += value.split(whereSeparator: \.isWhitespace).map(String.init) }
        if let tasks = script["installer"]?.arrayValue {
            for item in tasks {
                guard let task = item.objectValue?["task"]?.objectValue,
                      task["name"]?.stringValue == "winetricks",
                      let apps = task["app"]?.stringValue else { continue }
                dependencies += apps.split(whereSeparator: \.isWhitespace).map(String.init)
            }
        }
        dependencies = Array(Set(dependencies.filter { $0.range(of: #"^[A-Za-z0-9_.+-]+$"#, options: .regularExpression) != nil })).sorted()

        var environment = stringDictionary(system["env"]) ?? [:]
        for (key, value) in stringDictionary(wine["env"]) ?? [:] { environment[key] = value }

        let createPrefixTaskArchitecture = script["installer"]?.arrayValue?.compactMap { $0.objectValue?["task"]?.objectValue }
            .first(where: { $0["name"]?.stringValue == "create_prefix" })?["arch"]?.stringValue
        let rawArchitecture = gameBlock["arch"]?.stringValue ?? createPrefixTaskArchitecture ?? wine["arch"]?.stringValue ?? "win64"
        let architecture = ["win32", "win64"].contains(rawArchitecture.lowercased()) ? rawArchitecture.lowercased() : "win64"
        let files = (script["files"]?.arrayValue ?? []).flatMap { item -> [LutrisFileSource] in
            guard let object = item.objectValue else { return [] }
            return object.compactMap { key, value in
                guard let source = value.stringValue else { return nil }
                return LutrisFileSource(id: key, source: source)
            }
        }
        return LutrisWineProfile(
            gameName: game.name,
            gameSlug: game.slug,
            installerSlug: installer.slug,
            installerVersion: installer.version ?? installer.name,
            architecture: architecture,
            executable: gameBlock["exe"]?.stringValue,
            workingDirectory: gameBlock["working_dir"]?.stringValue,
            launchArguments: gameBlock["args"]?.stringValue ?? "",
            winetricks: dependencies,
            overrides: overrides,
            environment: environment,
            files: files,
            installerSteps: script["installer"]?.arrayValue ?? []
        )
    }

    private static func stringDictionary(_ value: LutrisJSONValue?) -> [String: String]? {
        guard let object = value?.objectValue else { return nil }
        return object.compactMapValues(\.stringValue)
    }

    func resolveScriptPath(_ path: String, prefix: URL) -> URL {
        let expanded = expand(path, prefix: prefix)
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded).standardizedFileURL }
        let cleaned = expanded.hasPrefix("drive_c/") ? String(expanded.dropFirst("drive_c/".count)) : expanded
        return prefix.appendingPathComponent("drive_c", isDirectory: true).appendingPathComponent(cleaned).standardizedFileURL
    }

    func launchArgumentList(prefix: URL) -> [String] {
        Self.tokenize(expand(launchArguments, prefix: prefix))
    }

    func expand(_ value: String, prefix: URL) -> String {
        value.replacingOccurrences(of: "${GAMEDIR}", with: prefix.path)
            .replacingOccurrences(of: "$GAMEDIR", with: prefix.path)
            .replacingOccurrences(of: "${WINEPREFIX}", with: prefix.path)
            .replacingOccurrences(of: "$WINEPREFIX", with: prefix.path)
            .replacingOccurrences(of: "$HOME", with: FileManager.default.homeDirectoryForCurrentUser.path)
    }

    var wineDLLOverrides: String {
        overrides.sorted { $0.key < $1.key }.map { name, value in
            let converted = value.lowercased().split(separator: ",").map { part in
                switch part.trimmingCharacters(in: .whitespaces) {
                case "n": "native"
                case "b": "builtin"
                default: part.trimmingCharacters(in: .whitespaces)
                }
            }.joined(separator: ",")
            return "\(name)=\(converted)"
        }.joined(separator: ";")
    }

    var wineAppVersionOverrides: [String: String] {
        // Carbon's AutoRun checks Wine's DirectX version incorrectly. Lutris's
        // published recipe doesn't provide a Winetricks fix; Win2K mode bypasses
        // the legacy check while keeping the version override scoped to AutoRun.
        gameSlug.lowercased() == "need-for-speed-carbon" ? ["AutoRun.exe": "win2k"] : [:]
    }

    var preferredGraphicsBackend: WindowsGraphicsBackend? {
        // MetalSharp documents DXVK for x86_64 games; Carbon's executable is
        // 32-bit, so keep the runtime's native Metal backend as the default.
        nil
    }

    var compatibilityEnvironment: [String: String] {
        gameSlug.lowercased() == "need-for-speed-carbon"
            ? ["FEX_X87REDUCEDPRECISION": "1", "FEX_MULTIBLOCK": "1"]
            : [:]
    }

    private static func tokenize(_ value: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false
        var started = false
        for character in value {
            if escaping { current.append(character); escaping = false; started = true; continue }
            if character == "\\" { escaping = true; started = true; continue }
            if let activeQuote = quote {
                if character == activeQuote { quote = nil } else { current.append(character) }
                started = true
                continue
            }
            if character == "\"" || character == "'" { quote = character; started = true }
            else if character.isWhitespace {
                if started { result.append(current); current = ""; started = false }
            } else { current.append(character); started = true }
        }
        if escaping { current.append("\\") }
        if started { result.append(current) }
        return result
    }

    static func arguments(from value: String) -> [String] { tokenize(value) }
}

struct LutrisFileSource: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var source: String
}

@MainActor
final class LutrisAPI: ObservableObject {
    struct SearchOutcome {
        var games: [LutrisGameResult]
        var usedExecutableFallback: Bool
    }

    private struct CacheEntry: Codable {
        let savedAt: Date
        let data: Data
    }
    private let cacheDirectory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MetalOS/Lutris", isDirectory: true)

    func search(title: String, executableName: String?) async throws -> SearchOutcome {
        let normalizedTitle = Self.normalized(title)
        guard !normalizedTitle.isEmpty else { return SearchOutcome(games: [], usedExecutableFallback: false) }
        let first = try await searchEndpoint(title)
        if first.contains(where: { Self.matchesExactly($0, normalized: normalizedTitle) }) {
            return SearchOutcome(games: Self.rank(first, query: title), usedExecutableFallback: false)
        }
        guard let executableName, !Self.normalized(executableName).isEmpty,
              Self.normalized(executableName) != normalizedTitle else {
            return SearchOutcome(games: Self.rank(first, query: title), usedExecutableFallback: false)
        }
        let fallback = try await searchEndpoint(executableName)
        let merged = Dictionary((first + fallback).map { ($0.slug, $0) }, uniquingKeysWith: { first, _ in first }).map(\.value)
        return SearchOutcome(games: Self.rank(merged, query: executableName), usedExecutableFallback: !fallback.isEmpty)
    }

    func wineInstallers(for game: LutrisGameResult) async throws -> [(title: String, description: String, notes: String, profile: LutrisWineProfile)] {
        let direct = try await wineInstallers(for: game, slug: game.slug)
        guard direct.isEmpty else { return direct }

        // Lutris can publish duplicate title entries for different platforms. If the
        // selected row has no Wine recipe, try exact-title aliases/platform variants.
        let candidates = try await searchEndpoint(game.name).filter {
            Self.normalized($0.name) == Self.normalized(game.name) && $0.slug != game.slug
        }
        for candidate in Self.rank(candidates, query: game.name) {
            let alternatives = try await wineInstallers(for: candidate, slug: candidate.slug)
            if !alternatives.isEmpty { return alternatives }
        }
        return []
    }

    private func wineInstallers(for game: LutrisGameResult, slug: String) async throws -> [(title: String, description: String, notes: String, profile: LutrisWineProfile)] {
        guard let firstURL = URL(string: "https://lutris.net/api/installers/\(slug)") else { return [] }
        var url: URL? = firstURL
        var visited = Set<String>()
        var records: [LutrisInstallerRecord] = []
        // Popular Lutris games can have enough installer variants to span multiple pages.
        for _ in 0..<30 {
            guard let pageURL = url,
                  pageURL.scheme == "https", pageURL.host == "lutris.net",
                  visited.insert(pageURL.absoluteString).inserted else { break }
            let data = try await cachedData(for: pageURL, lifetime: 12 * 60 * 60)
            let response = try JSONDecoder().decode(LutrisInstallerEnvelope.self, from: data)
            records.append(contentsOf: response.results)
            guard let next = response.next, let nextURL = URL(string: next, relativeTo: pageURL)?.absoluteURL,
                  nextURL.scheme == "https", nextURL.host == "lutris.net" else { url = nil; break }
            url = nextURL
        }
        return records.compactMap { record in
            guard record.runner.lowercased() == "wine", record.published != false, record.draft != true,
                  let profile = LutrisWineProfile.parse(game: game, installer: record) else { return nil }
            let title = [record.version, record.name].compactMap { $0 }.first(where: { !$0.isEmpty }) ?? record.slug
            return (title, record.description ?? "", record.notes ?? "", profile)
        }
    }

    private func searchEndpoint(_ query: String) async throws -> [LutrisGameResult] {
        var components = URLComponents(string: "https://lutris.net/api/games")!
        components.queryItems = [URLQueryItem(name: "search", value: String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(255))),
                                 URLQueryItem(name: "with-installers", value: "True")]
        guard let url = components.url else { return [] }
        let data = try await cachedData(for: url, lifetime: 6 * 60 * 60)
        return try JSONDecoder().decode(LutrisSearchEnvelope.self, from: data).results
    }

    private func cachedData(for url: URL, lifetime: TimeInterval) async throws -> Data {
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let key = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        let cacheURL = cacheDirectory.appendingPathComponent("\(key).json")
        let stale = (try? Data(contentsOf: cacheURL)).flatMap { try? JSONDecoder().decode(CacheEntry.self, from: $0) }
        if let stale, Date().timeIntervalSince(stale.savedAt) < lifetime { return stale.data }
        do {
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.setValue("MetalOS Lutris integration", forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let cached = try JSONEncoder().encode(CacheEntry(savedAt: Date(), data: data))
            try cached.write(to: cacheURL, options: .atomic)
            return data
        } catch {
            if let stale { return stale.data }
            throw error
        }
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: #"\.exe$"#, with: "", options: .regularExpression)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func matchesExactly(_ game: LutrisGameResult, normalized query: String) -> Bool {
        let candidates = [game.name, game.slug] + game.aliases.flatMap { [$0.name, $0.slug] }
        return candidates.contains(where: { Self.normalized($0) == query })
    }

    private static func rank(_ games: [LutrisGameResult], query: String) -> [LutrisGameResult] {
        let needle = normalized(query)
        return games.sorted { left, right in
            let leftScore = score(left, query: needle), rightScore = score(right, query: needle)
            if leftScore != rightScore { return leftScore > rightScore }
            let leftWindows = left.platforms?.contains(where: { $0.name.localizedCaseInsensitiveContains("windows") }) == true
            let rightWindows = right.platforms?.contains(where: { $0.name.localizedCaseInsensitiveContains("windows") }) == true
            if leftWindows != rightWindows { return leftWindows }
            let leftDesktopSlug = !left.slug.hasSuffix("--2")
            let rightDesktopSlug = !right.slug.hasSuffix("--2")
            if leftDesktopSlug != rightDesktopSlug { return leftDesktopSlug }
            if (left.coverURL != nil) != (right.coverURL != nil) { return left.coverURL != nil }
            return left.slug < right.slug
        }
    }

    private static func score(_ game: LutrisGameResult, query: String) -> Double {
        let candidates = ([game.name, game.slug] + game.aliases.flatMap { [$0.name, $0.slug] }).map { Self.normalized($0) }
        return candidates.map { candidate in
            if candidate == query { return 1.0 }
            if candidate.contains(query) || query.contains(candidate) { return 0.8 }
            let left = Set(candidate.split(separator: " "))
            let right = Set(query.split(separator: " "))
            let overlap = left.union(right).isEmpty ? 0 : Double(left.intersection(right).count) / Double(left.union(right).count)
            let distance = levenshtein(Array(candidate), Array(query))
            let editScore = 1 - Double(distance) / Double(max(max(candidate.count, query.count), 1))
            return max(overlap, editScore)
        }.max() ?? 0
    }

    private static func levenshtein(_ lhs: [Character], _ rhs: [Character]) -> Int {
        var previous = Array(0...rhs.count)
        for (leftIndex, left) in lhs.enumerated() {
            var current = [leftIndex + 1] + Array(repeating: 0, count: rhs.count)
            for (rightIndex, right) in rhs.enumerated() {
                current[rightIndex + 1] = min(current[rightIndex] + 1, previous[rightIndex + 1] + 1,
                                              previous[rightIndex] + (left == right ? 0 : 1))
            }
            previous = current
        }
        return previous[rhs.count]
    }
}

struct LutrisSearchPage: View {
    let onChoose: (LutrisWineProfile) -> Void
    @Environment(\.consolePageClose) private var closePage
    @StateObject private var api = LutrisAPI()
    @State private var titleQuery = ""
    @State private var executableFallback = ""
    @State private var games: [LutrisGameResult] = []
    @State private var selectedGame: LutrisGameResult?
    @State private var installers: [(title: String, description: String, notes: String, profile: LutrisWineProfile)] = []
    @State private var status = "Search Lutris.net for a game, then choose one of its published Wine installers."
    @State private var isSearching = false
    @State private var isLoadingInstallers = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "globe.americas.fill").foregroundStyle(studioAccent)
                VStack(alignment: .leading, spacing: 5) {
                    Text("LUTRIS INSTALLERS").font(.system(size: 10, weight: .bold)).tracking(2).foregroundStyle(studioAccent)
                    Text("Find a game setup profile").font(.system(size: 27, weight: .light))
                }
                Spacer()
                Button { closePage() } label: { Image(systemName: "xmark").padding(10).background(.white.opacity(0.07), in: Circle()) }
                    .buttonStyle(ConsoleButtonStyle()).accessibilityLabel("Close Lutris search")
            }
            HStack(spacing: 10) {
                TextField("Game title", text: $titleQuery).textFieldStyle(.roundedBorder).onSubmit { Task { await search() } }
                Button("Search") { Task { await search() } }.buttonStyle(.borderedProminent).tint(studioAccent).disabled(isSearching)
            }
            HStack(spacing: 10) {
                Image(systemName: "arrow.counterclockwise.circle").foregroundStyle(.white.opacity(0.5))
                TextField("Optional executable name for fallback matching", text: $executableFallback)
                    .textFieldStyle(.roundedBorder).onSubmit { Task { await search() } }
            }
            Text(status).font(.system(size: 11)).foregroundStyle(.white.opacity(0.56)).fixedSize(horizontal: false, vertical: true)
            if isSearching || isLoadingInstallers { ProgressView().controlSize(.small).tint(studioAccent) }
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("MATCHING GAMES").font(.system(size: 9, weight: .bold)).tracking(1.5).foregroundStyle(.white.opacity(0.48))
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(games) { game in
                                gameRow(game)
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Rectangle().fill(.white.opacity(0.08)).frame(width: 1)
                VStack(alignment: .leading, spacing: 8) {
                    Text(selectedGame.map { "WINE INSTALLERS · \($0.name.uppercased())" } ?? "WINE INSTALLERS")
                        .font(.system(size: 9, weight: .bold)).tracking(1.2).foregroundStyle(.white.opacity(0.48)).lineLimit(1)
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(Array(installers.enumerated()), id: \.element.profile.installerSlug) { _, item in
                                Button { onChoose(item.profile); closePage() } label: {
                                    VStack(alignment: .leading, spacing: 7) {
                                        HStack {
                                            Text(item.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                                            Spacer()
                                            Text(item.profile.architecture.uppercased()).font(.system(size: 8, weight: .bold)).foregroundStyle(studioAccent)
                                        }
                                        Text(item.description.isEmpty ? "Wine installer profile" : item.description)
                                            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.58)).lineLimit(3)
                                        if !item.notes.isEmpty { Text(item.notes).font(.system(size: 9)).foregroundStyle(.orange.opacity(0.82)).lineLimit(3) }
                                        Text("\(item.profile.winetricks.count) Winetricks · \(item.profile.overrides.count) DLL overrides · \(item.profile.environment.count) environment values")
                                            .font(.system(size: 9)).foregroundStyle(.white.opacity(0.4))
                                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
                                }.buttonStyle(ConsoleButtonStyle())
                            }
                        }
                    }
                    if selectedGame != nil && installers.isEmpty && !isLoadingInstallers {
                        Text("No published Wine installers were found for this game.").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }.frame(maxHeight: .infinity)
            Text("MetalOS creates a new bottle and follows the selected Lutris installation recipe. Some recipes may ask for original game media.")
                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.4)).fixedSize(horizontal: false, vertical: true)
            Text("A / ×  Choose installer     B / ○  Back").font(.system(size: 9)).foregroundStyle(.white.opacity(0.36))
        }
        .padding(32).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(studioBackground.ignoresSafeArea()).preferredColorScheme(.dark).tint(studioAccent)
        .consoleInput { command in if command == "back" || command == "menu" { closePage() } }
    }

    private func gameRow(_ game: LutrisGameResult) -> some View {
        Button { Task { await loadInstallers(for: game) } } label: {
            HStack(spacing: 12) {
                AsyncImage(url: game.coverURL) { image in image.resizable().scaledToFill() }
                    placeholder: { RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.06)).overlay(Image(systemName: "gamecontroller").foregroundStyle(.white.opacity(0.2))) }
                    .frame(width: 86, height: 54).clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 5) {
                    Text(game.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).lineLimit(2)
                    Text([game.year.map(String.init), game.slug].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.48)).lineLimit(1)
                }
                Spacer(minLength: 0)
                if selectedGame?.id == game.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(studioAccent) }
            }.padding(9).background(selectedGame?.id == game.id ? .white.opacity(0.08) : .white.opacity(0.025), in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(ConsoleButtonStyle())
    }

    private func search() async {
        guard !isSearching else { return }
        isSearching = true
        defer { isSearching = false }
        selectedGame = nil
        installers = []
        do {
            let outcome = try await api.search(title: titleQuery, executableName: executableFallback.isEmpty ? nil : executableFallback)
            games = outcome.games
            status = outcome.games.isEmpty ? "No Lutris matches found." : outcome.usedExecutableFallback
                ? "No exact title match; showing fuzzy matches for the executable name."
                : "\(outcome.games.count) matching game\(outcome.games.count == 1 ? "" : "s"). Choose a game to fetch its Wine installers."
        } catch {
            status = "Lutris search failed: \(error.localizedDescription)"
        }
    }

    private func loadInstallers(for game: LutrisGameResult) async {
        selectedGame = game
        installers = []
        isLoadingInstallers = true
        status = "Fetching installer scripts for \(game.name)…"
        defer { isLoadingInstallers = false }
        do {
            installers = try await api.wineInstallers(for: game)
            status = "Loaded \(installers.count) published Wine installer\(installers.count == 1 ? "" : "s") for \(game.name)."
        } catch {
            status = "Could not fetch Lutris installer scripts: \(error.localizedDescription)"
        }
    }
}
