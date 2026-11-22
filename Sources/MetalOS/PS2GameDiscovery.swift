import Foundation

enum PS2GameDiscovery {
    static let extensions: Set<String> = ["iso", "chd", "cso", "zso", "cue", "bin", "mdf", "nrg"]
    private static let maximumFiles = 100_000

    static func game(at image: URL) -> Game? {
        let image = image.standardizedFileURL.resolvingSymlinksInPath()
        guard extensions.contains(image.pathExtension.lowercased()),
              (try? image.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              FileManager.default.isReadableFile(atPath: image.path) else { return nil }
        return Game(id: "ps2:\(image.path)", title: image.deletingPathExtension().lastPathComponent,
                    source: .ps2, launchURL: "", installPath: image.path)
    }

    static func scan(root: URL) -> DiscoveryResult {
        let fileManager = FileManager.default
        let standardizedRoot = root.standardizedFileURL
        if standardizedRoot.pathExtension.lowercased() == "app" { return DiscoveryResult() }
        if extensions.contains(standardizedRoot.pathExtension.lowercased()) {
            return DiscoveryResult(games: game(at: standardizedRoot).map { [$0] } ?? [])
        }
        guard let values = try? standardizedRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true else { return DiscoveryResult() }

        var result = DiscoveryResult()
        guard let enumerator = fileManager.enumerator(
            at: standardizedRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            result.warnings.append("Could not read PS2 library folder \(standardizedRoot.path).")
            return result
        }

        var images: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            if enumerator.level > 7 {
                enumerator.skipDescendants()
                continue
            }
            guard let item = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey]),
                  item.isSymbolicLink != true else {
                enumerator.skipDescendants()
                continue
            }
            if item.isPackage == true || (item.isDirectory == true && url.pathExtension.lowercased() == "app") {
                enumerator.skipDescendants()
                continue
            }
            guard item.isRegularFile == true, extensions.contains(url.pathExtension.lowercased()) else { continue }
            images.append(url.standardizedFileURL.resolvingSymlinksInPath())
            if images.count >= maximumFiles {
                result.warnings.append("PS2 scan stopped after \(maximumFiles) disc images.")
                break
            }
        }

        let cueBasenames = Set(images.filter { $0.pathExtension.lowercased() == "cue" }.map {
            $0.deletingPathExtension().path.lowercased()
        })
        result.games = images
            .filter { image in
                image.pathExtension.lowercased() != "bin" || !cueBasenames.contains(image.deletingPathExtension().path.lowercased())
            }
            .compactMap(game(at:))
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return result
    }
}
