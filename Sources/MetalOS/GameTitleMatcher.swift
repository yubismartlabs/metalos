import Foundation

/// Cleans installation labels without discarding sequel, release-year, or edition information.
/// Ambiguous results are deliberately left unmatched so the user can refine the search title.
enum GameTitleMatcher {
    static func searchTitle(_ raw: String) -> String {
        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        title = replace(title, #"(?i)\.(app|nsp|xci|nsz|xcz|nup)$"#, "")
        title = replace(title, #"(?i)^nxnative\s*[-:–—]\s*"#, "")
        title = replace(title, #"(?i)\[[0-9a-f]{16}\]"#, " ")
        title = replace(title, #"(?i)\[(?:v\d+(?:\.\d+)*|version\s*\d+(?:\.\d+)*)\]"#, " ")
        // Package filenames commonly append the download size as `(3.98GB)`.
        // It is file metadata, never part of the game title.
        title = replace(title, #"(?i)\s*[\[(]\s*\d+(?:[.,]\d+)?\s*(?:bytes?|[kmgt]i?b)\s*[\])]"#, " ")
        // Strip only recognizable metadata. Unknown text in parentheses can be a real subtitle.
        let metadata = #"(?:base|update|patch|dlc|port|usa|eur|europe|jpn|japan|world|global|us|eu|jp|asia|uk|au|nintendo switch|switch|macos|mac|mac-app|nxnative(?:\s+build)?)"#
        title = replace(title, "(?i)\\[" + metadata + "\\]|\\(" + metadata + "\\)", " ")
        title = replace(title, #"(?i)\[(?:en|fr|de|es|it|ja|ko|zh|pt|ru)(?:\s*,\s*(?:en|fr|de|es|it|ja|ko|zh|pt|ru))*\]"#, " ")
        title = replace(title, #"(?i)\s*[-–—]\s*(?:nxnative(?:\s+build)?|mac-app)\s*$"#, "")
        title = replace(title, #"(?i)\s+v\d+(?:\.\d+)*\s*$"#, "")
        title = replace(title, #"[™®©]"#, "")
        return replace(title, #"\s+"#, " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func bestMatch(title: String, candidates: [ArtworkCandidate]) -> ArtworkCandidate? {
        let query = normalized(title)
        guard !query.isEmpty else { return nil }
        var ids = Set<Int>()
        let unique = candidates.filter { ids.insert($0.id).inserted }
        let exact = unique.filter { normalized($0.name) == query }
        if exact.count == 1 { return exact.first }
        if exact.count > 1 { return nil }

        let queryTokens = query.split(separator: " ").map(String.init)
        let queryImportant = significant(queryTokens)
        guard !queryImportant.isEmpty else { return nil }
        let ranked = unique.compactMap { candidate -> (ArtworkCandidate, Double)? in
            let candidateName = normalized(candidate.name)
            let candidateTokens = candidateName.split(separator: " ").map(String.init)
            // A close-looking sequel or remaster must never win over an absent original.
            guard numbers(queryTokens) == numbers(candidateTokens),
                  editions(queryTokens) == editions(candidateTokens) else { return nil }
            let candidateImportant = significant(candidateTokens)
            guard !candidateImportant.isEmpty else { return nil }
            if queryImportant == candidateImportant { return (candidate, 0.99) }
            // Fuzzy matching is reserved for minor spelling differences in longer titles.
            guard max(query.count, candidateName.count) >= 10 else { return nil }
            let overlap = Double(Set(queryImportant).intersection(Set(candidateImportant)).count) /
                Double(max(Set(queryImportant).count, Set(candidateImportant).count))
            guard overlap >= 0.5 else { return nil }
            let score = 1 - Double(distance(query, candidateName)) / Double(max(query.count, candidateName.count))
            return score >= 0.9 ? (candidate, score) : nil
        }.sorted { $0.1 > $1.1 }
        guard let winner = ranked.first else { return nil }
        if ranked.count > 1, winner.1 - ranked[1].1 < 0.07 { return nil }
        return winner.0
    }

    private static func normalized(_ title: String) -> String {
        let clean = searchTitle(title).folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        let words = replace(replace(clean, "&", " and "), #"[^\p{L}\p{N}]+"#, " ")
            .split(separator: " ").map(String.init)
        return words.enumerated().map { index, token in
            // Leading I/V/X can be words or initials; interior numerals commonly denote sequels.
            if index > 0, let number = romanNumerals[token] { return number }
            if let number = UInt64(token) { return String(number) }
            return token
        }.joined(separator: " ")
    }
    private static let romanNumerals = [
        "i": "1", "ii": "2", "iii": "3", "iv": "4", "v": "5", "vi": "6", "vii": "7", "viii": "8", "ix": "9", "x": "10",
        "xi": "11", "xii": "12", "xiii": "13", "xiv": "14", "xv": "15", "xvi": "16", "xvii": "17", "xviii": "18", "xix": "19", "xx": "20"
    ]
    private static let editionWords: Set<String> = ["remastered", "remaster", "remake", "definitive", "ultimate", "deluxe", "complete", "anniversary", "collection", "hd", "goty"]
    private static func significant(_ tokens: [String]) -> [String] {
        tokens.enumerated().compactMap { index, token in
            if ["the", "of", "and"].contains(token) || (index == 0 && ["a", "an"].contains(token)) { return nil }
            return token
        }
    }
    private static func numbers(_ tokens: [String]) -> [String] { tokens.filter { UInt64($0) != nil } }
    private static func editions(_ tokens: [String]) -> Set<String> { Set(tokens).intersection(editionWords) }
    private static func replace(_ text: String, _ pattern: String, _ replacement: String) -> String {
        text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }
    private static func distance(_ left: String, _ right: String) -> Int {
        let a = Array(left), b = Array(right)
        var previous = Array(0...b.count)
        for (i, lhs) in a.enumerated() {
            var current = [i + 1]
            for (j, rhs) in b.enumerated() {
                current.append(min(current[j] + 1, previous[j + 1] + 1, previous[j] + (lhs == rhs ? 0 : 1)))
            }
            previous = current
        }
        return previous[b.count]
    }
}
