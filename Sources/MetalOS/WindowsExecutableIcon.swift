import AppKit
import CryptoKit
import Foundation

enum WindowsExecutableIcon {
    struct ExecutableDetails: Sendable {
        let title: String?
        let artworkPath: String?
    }

    static func suggestedTitle(for executable: URL) -> String {
        var stem = executable.deletingPathExtension().lastPathComponent
        let suffixes = ["-win64-shipping", "_win64_shipping", "-win64", "_win64", "-x64", "_x64", "-shipping", "_shipping"]
        var changed = true
        while changed {
            changed = false
            for suffix in suffixes where stem.lowercased().hasSuffix(suffix) {
                stem = String(stem.dropLast(suffix.count))
                changed = true
                break
            }
        }
        let title = stem.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? executable.deletingPathExtension().lastPathComponent : title
    }

    static func cachedPath(gameID: String, provider: WindowsStorefront, workspace: URL) -> URL {
        let key = SHA256.hash(data: Data("\(provider.rawValue):\(gameID)".utf8)).map { String(format: "%02x", $0) }.joined()
        return WindowsRuntimeLayout.root(in: workspace).appendingPathComponent("Artwork/Windows/\(key).png")
    }

    static func inspect(executable: URL, gameID: String, workspace: URL) async -> ExecutableDetails {
        let key = SHA256.hash(data: Data(gameID.utf8)).map { String(format: "%02x", $0) }.joined()
        let target = WindowsRuntimeLayout.root(in: workspace).appendingPathComponent("Artwork/Standalone/\(key).png")
        return await Task.detached(priority: .utility) {
            let data = try? Data(contentsOf: executable, options: .mappedIfSafe)
            let title = data.flatMap(Self.productTitle(from:))
            let image = data.flatMap(Self.embeddedIcon(from:)) ?? NSWorkspace.shared.icon(forFile: executable.path)
            var artworkPath: String?
            if let tiff = image.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiff),
               let png = bitmap.representation(using: .png, properties: [:]) {
                do {
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try png.write(to: target, options: .atomic)
                    artworkPath = target.path
                } catch { }
            }
            return ExecutableDetails(title: title, artworkPath: artworkPath)
        }.value
    }

    static func extract(game: WindowsStoreGame, provider: WindowsStorefront, workspace: URL) async -> String? {
        guard let installedPath = game.installedPath else { return nil }
        let target = cachedPath(gameID: game.id, provider: provider, workspace: workspace)
        if FileManager.default.fileExists(atPath: target.path) { return target.path }
        return await Task.detached(priority: .utility) {
            guard let executable = Self.findExecutable(in: URL(fileURLWithPath: installedPath, isDirectory: true), title: game.title),
                  let icon = Self.iconImage(from: executable),
                  let tiff = icon.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
            do {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try png.write(to: target, options: .atomic)
                return target.path
            } catch {
                return nil
            }
        }.value
    }

    private static func findExecutable(in root: URL, title: String) -> URL? {
        let ignored = ["unins", "setup", "crash", "redist", "launcher", "updater", "vc_redist", "dxsetup"]
        let tokens = title.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 2 }
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        var candidates: [(url: URL, score: Int, size: Int64)] = []
        var scanned = 0
        while let url = enumerator.nextObject() as? URL, scanned < 30_000 {
            scanned += 1
            guard url.pathExtension.caseInsensitiveCompare("exe") == .orderedSame,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let name = url.deletingPathExtension().lastPathComponent.lowercased()
            guard !ignored.contains(where: name.contains) else { continue }
            let matchScore = tokens.reduce(0) { $0 + (name.contains($1) ? 100 : 0) }
            let depth = url.pathComponents.count - root.pathComponents.count
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            candidates.append((url, matchScore - depth * 2, size))
        }
        return candidates.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.size != $1.size { return $0.size > $1.size }
            return $0.url.lastPathComponent.localizedCaseInsensitiveCompare($1.url.lastPathComponent) == .orderedAscending
        }.first?.url
    }

    private static func iconImage(from executable: URL) -> NSImage? {
        if let data = try? Data(contentsOf: executable, options: .mappedIfSafe), let ico = extractICO(from: data), let image = NSImage(data: ico) {
            return image
        }
        return NSWorkspace.shared.icon(forFile: executable.path)
    }

    private static func embeddedIcon(from data: Data) -> NSImage? {
        guard let ico = extractICO(from: data) else { return nil }
        return NSImage(data: ico)
    }

    private static func productTitle(from data: Data) -> String? {
        let strings = versionResources(from: data)
        for key in ["ProductName", "FileDescription", "InternalName"] {
            for resource in strings {
                if let value = versionString(key, in: resource),
                   !value.isEmpty, value.count < 180,
                   !value.localizedCaseInsensitiveContains("setup"),
                   !value.localizedCaseInsensitiveContains("uninstaller") {
                    return value
                }
            }
        }
        return nil
    }

    private static func versionString(_ key: String, in data: Data) -> String? {
        var needle = Data()
        for unit in key.utf16 {
            needle.append(UInt8(unit & 0xff)); needle.append(UInt8(unit >> 8))
        }
        needle.append(contentsOf: [0, 0])
        guard let range = data.range(of: needle), range.lowerBound >= 6 else { return nil }
        let block = range.lowerBound - 6
        guard let valueLength = data.u16(block + 2), valueLength > 0, valueLength < 512 else { return nil }
        let valueStart = (range.upperBound + 3) & ~3
        let valueEnd = valueStart + Int(valueLength) * 2
        guard valueEnd <= data.count else { return nil }
        let valueData = data.subdata(in: valueStart..<valueEnd)
        let codeUnits = stride(from: 0, to: valueData.count - 1, by: 2).map { offset in
            UInt16(valueData[offset]) | (UInt16(valueData[offset + 1]) << 8)
        }
        let value = String(decoding: codeUnits, as: UTF16.self)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
        return value.unicodeScalars.contains(where: { !CharacterSet.controlCharacters.contains($0) }) ? value : nil
    }

    private static func versionResources(from data: Data) -> [Data] {
        guard data.count > 0x40,
              let peValue = data.u32(0x3c), peValue <= UInt32(data.count - 24) else { return [] }
        let pe = Int(peValue)
        guard data.u32(pe) == 0x00004550,
              let sectionCount = data.u16(pe + 6),
              let optionalSize = data.u16(pe + 20) else { return [] }
        let optional = pe + 24
        guard let magic = data.u16(optional) else { return [] }
        let directories = optional + (magic == 0x20b ? 112 : 96)
        guard let resourceRVA = data.u32(directories + 16), resourceRVA != 0 else { return [] }
        let sectionStart = optional + Int(optionalSize)
        var sections: [(address: UInt32, virtualSize: UInt32, rawSize: UInt32, rawOffset: UInt32)] = []
        for index in 0..<Int(sectionCount) {
            let base = sectionStart + index * 40
            guard let virtualSize = data.u32(base + 8), let address = data.u32(base + 12),
                  let rawSize = data.u32(base + 16), let rawOffset = data.u32(base + 20) else { return [] }
            sections.append((address, virtualSize, rawSize, rawOffset))
        }
        func fileOffset(_ rva: UInt32) -> Int? {
            guard let section = sections.first(where: { rva >= $0.address && rva < $0.address + max($0.virtualSize, $0.rawSize) }) else { return nil }
            let offset = UInt64(section.rawOffset) + UInt64(rva - section.address)
            guard offset < UInt64(data.count) else { return nil }
            return Int(offset)
        }
        guard let root = fileOffset(resourceRVA) else { return [] }
        func entries(at relative: Int) -> [(id: Int?, directory: Bool, offset: Int)]? {
            let base = root + relative
            guard let named = data.u16(base + 12), let ids = data.u16(base + 14) else { return nil }
            let count = Int(named) + Int(ids)
            guard count <= 4096, base + 16 + count * 8 <= data.count else { return nil }
            return (0..<count).compactMap { index in
                let position = base + 16 + index * 8
                guard let rawName = data.u32(position), let rawOffset = data.u32(position + 4) else { return nil }
                return (rawName & 0x8000_0000 == 0 ? Int(rawName & 0xffff) : nil,
                        rawOffset & 0x8000_0000 != 0, Int(rawOffset & 0x7fff_ffff))
            }
        }
        guard let types = entries(at: 0), let version = types.first(where: { $0.id == 16 && $0.directory }),
              let names = entries(at: version.offset) else { return [] }
        var results: [Data] = []
        func collect(_ relative: Int, depth: Int) {
            guard depth < 4, let children = entries(at: relative) else { return }
            for child in children {
                if child.directory { collect(child.offset, depth: depth + 1); continue }
                let record = root + child.offset
                guard let rva = data.u32(record), let size = data.u32(record + 4), size > 0,
                      let offset = fileOffset(rva), UInt64(offset) + UInt64(size) <= UInt64(data.count) else { continue }
                results.append(data.subdata(in: offset..<(offset + Int(size))))
            }
        }
        for name in names where name.directory { collect(name.offset, depth: 1) }
        return results
    }

    private static func extractICO(from data: Data) -> Data? {
        guard data.count > 0x40, data.u16(0) == 0x5a4d,
              let peOffsetValue = data.u32(0x3c), peOffsetValue <= UInt32(data.count - 24) else { return nil }
        let peOffset = Int(peOffsetValue)
        guard data.u32(peOffset) == 0x00004550,
              let sectionCount = data.u16(peOffset + 6),
              let optionalSize = data.u16(peOffset + 20) else { return nil }
        let optional = peOffset + 24
        guard let magic = data.u16(optional) else { return nil }
        let directoriesOffset = optional + (magic == 0x20b ? 112 : 96)
        guard let resourceRVA = data.u32(directoriesOffset + 16), resourceRVA != 0 else { return nil }
        let sectionStart = optional + Int(optionalSize)
        var sections: [(virtualAddress: UInt32, virtualSize: UInt32, rawSize: UInt32, rawOffset: UInt32)] = []
        for index in 0..<Int(sectionCount) {
            let base = sectionStart + index * 40
            guard let virtualSize = data.u32(base + 8), let virtualAddress = data.u32(base + 12),
                  let rawSize = data.u32(base + 16), let rawOffset = data.u32(base + 20) else { return nil }
            sections.append((virtualAddress, virtualSize, rawSize, rawOffset))
        }
        func fileOffset(_ rva: UInt32) -> Int? {
            guard let section = sections.first(where: { rva >= $0.virtualAddress && rva < $0.virtualAddress + max($0.virtualSize, $0.rawSize) }) else { return nil }
            let offset = UInt64(section.rawOffset) + UInt64(rva - section.virtualAddress)
            guard offset < UInt64(data.count) else { return nil }
            return Int(offset)
        }
        guard let resourceOffset = fileOffset(resourceRVA) else { return nil }
        func entries(at relative: Int) -> [(id: Int?, directory: Bool, offset: Int)]? {
            let base = resourceOffset + relative
            guard let named = data.u16(base + 12), let ids = data.u16(base + 14) else { return nil }
            let count = Int(named) + Int(ids)
            guard count <= 4096, base + 16 + count * 8 <= data.count else { return nil }
            return (0..<count).compactMap { index in
                let position = base + 16 + index * 8
                guard let rawName = data.u32(position), let rawOffset = data.u32(position + 4) else { return nil }
                return (rawName & 0x8000_0000 == 0 ? Int(rawName & 0xffff) : nil,
                        rawOffset & 0x8000_0000 != 0,
                        Int(rawOffset & 0x7fff_ffff))
            }
        }
        func resourceData(type: Int) -> [(ids: [Int], bytes: Data)] {
            guard let rootEntries = entries(at: 0), let typeEntry = rootEntries.first(where: { $0.id == type && $0.directory }) else { return [] }
            var found: [(ids: [Int], bytes: Data)] = []
            func walk(_ relative: Int, ids: [Int], depth: Int) {
                guard depth < 4, let children = entries(at: relative) else { return }
                for child in children {
                    let childIDs = child.id.map { ids + [$0] } ?? ids
                    if child.directory { walk(child.offset, ids: childIDs, depth: depth + 1) }
                    else {
                        let entry = resourceOffset + child.offset
                        guard let rva = data.u32(entry), let size = data.u32(entry + 4), size > 0,
                              let offset = fileOffset(rva), UInt64(offset) + UInt64(size) <= UInt64(data.count) else { continue }
                        found.append((childIDs, data.subdata(in: offset..<(offset + Int(size)))))
                    }
                }
            }
            walk(typeEntry.offset, ids: [type], depth: 1)
            return found
        }
        for group in resourceData(type: 14) where group.bytes.count >= 20 {
            guard let count = group.bytes.u16(4), count > 0, count <= 64, 6 + Int(count) * 14 <= group.bytes.count else { continue }
            let iconResources = resourceData(type: 3)
            let entries = (0..<Int(count)).compactMap { index -> (offset: Int, id: Int, area: Int)? in
                let offset = 6 + index * 14
                guard let resourceID = group.bytes.u16(offset + 12) else { return nil }
                let width = group.bytes[offset] == 0 ? 256 : Int(group.bytes[offset])
                let height = group.bytes[offset + 1] == 0 ? 256 : Int(group.bytes[offset + 1])
                return (offset, Int(resourceID), width * height)
            }.sorted { $0.area > $1.area }
            for iconEntry in entries {
                guard let icon = iconResources.first(where: { $0.ids.dropFirst().first == iconEntry.id })?.bytes,
                      icon.count <= Int(UInt32.max), icon.count > 0 else { continue }
                var ico = Data([0, 0, 1, 0, 1, 0])
                ico.append(group.bytes.subdata(in: iconEntry.offset..<(iconEntry.offset + 8)))
                ico.appendUInt32(UInt32(icon.count))
                ico.appendUInt32(22)
                ico.append(icon)
                return ico
            }
        }
        return nil
    }
}

private extension Data {
    func u16(_ offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        return UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }
    func u32(_ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        return UInt32(self[offset]) | (UInt32(self[offset + 1]) << 8) | (UInt32(self[offset + 2]) << 16) | (UInt32(self[offset + 3]) << 24)
    }
    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8(value & 0xff)); append(UInt8((value >> 8) & 0xff)); append(UInt8((value >> 16) & 0xff)); append(UInt8((value >> 24) & 0xff))
    }
}
