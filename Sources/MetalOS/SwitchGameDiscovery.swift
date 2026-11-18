import Foundation

/// Identifies inputs without opening encrypted containers or modifying game content.
enum SwitchGameDiscovery {
    static let extensions: Set<String> = ["nsp", "xci", "nsz", "xcz", "nup"]

    static func titleIDs(in name: String) -> [String] {
        let pattern = #"(?i)(?<![a-z0-9])(?:01|04)[0-9a-f]{14}(?![a-z0-9])"#
        let regex = try! NSRegularExpression(pattern: pattern)
        return regex.matches(in: name, range: NSRange(name.startIndex..., in: name)).compactMap {
            Range($0.range, in: name).map { String(name[$0]).uppercased() }
        }
    }

    static func extractedIcon(in gameFolder: String?) -> String? {
        guard let gameFolder, !gameFolder.isEmpty else { return nil }
        let game = URL(fileURLWithPath: gameFolder, isDirectory: true)
        let workspaces = [
            game.appendingPathComponent("NXNative/Work", isDirectory: true),
            game.appendingPathComponent(".nxstudio/Work", isDirectory: true)
        ]
        var visited = 0
        for work in workspaces {
            guard let iterator = FileManager.default.enumerator(at: work, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            while let url = iterator.nextObject() as? URL {
                visited += 1
                if visited > 20_000 { return nil }
                if url.lastPathComponent.lowercased() == "icon.jpg",
                   (try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])).map({ $0.isRegularFile == true && $0.isSymbolicLink != true }) == true {
                    return url.path
                }
            }
        }
        return nil
    }

    static func scan(root: URL) -> DiscoveryResult {
        guard (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true else { return DiscoveryResult() }
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let fm = FileManager.default
        var result = DiscoveryResult()
        // NX Play treats each immediate child directory as one game, with its NSP/XCI/NSZ/XCZ
        // files beside one another. When the user picks a game's own folder, inspect that folder.
        let rootInputs = packageFiles(in: root, fileManager: fm, warnings: &result.warnings)
        let children: [URL]
        do {
            children = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
                .map(\.standardizedFileURL)
                .filter { url in
                    guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
                    return values.isDirectory == true && values.isSymbolicLink != true && url.pathExtension.lowercased() != "app"
                }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        } catch {
            result.warnings.append("Could not read library folder \(root.path): \(error.localizedDescription)")
            return result
        }
        var gameFolders: [(URL, [URL])] = []
        if !rootInputs.isEmpty { gameFolders.append((root, rootInputs)) }
        for child in children where ![".nxstudio", "NXNative", "Work", "Builds", "node_modules", "Library", "System", "Windows", "drive_c", "vendor"].contains(child.lastPathComponent) {
            let inputs = packageFiles(in: child, fileManager: fm, warnings: &result.warnings)
            if !inputs.isEmpty { gameFolders.append((child, inputs)) }
        }
        for (folder, inputs) in gameFolders {
            let ids = Set(inputs.flatMap { titleIDs(in: $0.lastPathComponent) })
            let baseIDs = ids.filter { $0.hasSuffix("000") }
            let folderIDs = titleIDs(in: folder.lastPathComponent).filter { $0.hasSuffix("000") }
            let id = baseIDs.count == 1 ? baseIDs.first : (folderIDs.count == 1 ? folderIDs.first : nil)
            result.games.append(Game(id: "switch:\(folder.path)", title: folder.lastPathComponent,
                                     source: .nxnative, launchURL: "", installPath: folder.path, buildInput: folder.path, titleID: id))
        }
        return result
    }

    private static func packageFiles(in folder: URL, fileManager: FileManager, warnings: inout [String]) -> [URL] {
        do {
            return try fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
                .map(\.standardizedFileURL)
                .filter { url in
                    guard extensions.contains(url.pathExtension.lowercased()),
                          let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
                    return values.isRegularFile == true && values.isSymbolicLink != true
                }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        } catch {
            warnings.append("Could not read game folder \(folder.path): \(error.localizedDescription)")
            return []
        }
    }
}
