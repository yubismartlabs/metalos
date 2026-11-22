import SwiftUI
import AppKit

struct ConsoleBrowserEntry: Identifiable, Sendable {
    let url: URL
    let isDirectory: Bool
    let isApplication: Bool
    let isPackage: Bool
    var id: String { url.path }
    var name: String { url.lastPathComponent }
}
struct ConsoleBrowserListing: Sendable {
    var entries: [ConsoleBrowserEntry] = []
    var message: String?
}
enum ConsoleBrowser {
    static func list(_ directory: URL, showHidden: Bool, mode: ConsoleFilePicker.Mode, allowedExtensions: Set<String>, query: String = "") -> ConsoleBrowserListing {
        do {
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isReadableKey]
            let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys), options: showHidden ? [] : [.skipsHiddenFiles])
            var entries: [ConsoleBrowserEntry] = []
            for url in urls {
                let values = try? url.resourceValues(forKeys: keys)
                let isApp = url.pathExtension.lowercased() == "app" && values?.isDirectory == true
                let entry = ConsoleBrowserEntry(url: url, isDirectory: values?.isDirectory == true, isApplication: isApp, isPackage: values?.isPackage == true)
                if permits(entry, mode: mode, allowedExtensions: allowedExtensions), query.isEmpty || entry.name.localizedCaseInsensitiveContains(query) { entries.append(entry) }
            }
            entries.sort {
                let leftFolder = $0.isDirectory && !$0.isApplication
                let rightFolder = $1.isDirectory && !$1.isApplication
                if leftFolder != rightFolder { return leftFolder }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            return ConsoleBrowserListing(entries: Array(entries.prefix(2000)), message: entries.count > 2000 ? "Showing the first 2,000 items. Use Find in folder to narrow the list." : nil)
        } catch {
            return ConsoleBrowserListing(message: "This folder is unavailable or cannot be read. Choose another location or reconnect its drive.")
        }
    }
    static func permits(_ entry: ConsoleBrowserEntry, mode: ConsoleFilePicker.Mode, allowedExtensions: Set<String>) -> Bool {
        if entry.isApplication { return mode == .application || mode == .file }
        if entry.isDirectory { return !entry.isPackage || mode == .file }
        guard mode == .file else { return false }
        return allowedExtensions.isEmpty || allowedExtensions.contains(entry.url.pathExtension.lowercased())
    }
}

/// A controller-operated file browser; it never edits or deletes the selected files.
struct ConsoleFilePicker: View {
    enum Mode: Equatable, Sendable { case directory, application, file }
    let title: String
    let mode: Mode
    let startingPath: String?
    let allowedExtensions: Set<String>
    let onSelect: (URL) -> Void
    @Environment(\.consolePageClose) private var closePage
    @State private var directory: URL
    @State private var listing = ConsoleBrowserListing()
    @State private var showHidden = false
    @State private var filter = ""
    @State private var searchOpen = false
    @State private var loading = false
    @State private var zone = 1
    @State private var entryIndex = 0
    @State private var locationIndex = 0
    @State private var actionIndex = 0
    @State private var history: [URL] = []
    @State private var requestID = UUID()

    init(title: String, mode: Mode, startingPath: String? = nil, allowedExtensions: Set<String> = [], onSelect: @escaping (URL) -> Void) {
        self.title = title; self.mode = mode; self.startingPath = startingPath
        self.allowedExtensions = Set(allowedExtensions.map { $0.lowercased() }); self.onSelect = onSelect
        let path = (startingPath ?? "" as String) as NSString
        let candidate = path.length > 0 ? URL(fileURLWithPath: path.expandingTildeInPath) : FileManager.default.homeDirectoryForCurrentUser
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue, candidate.pathExtension.lowercased() != "app" {
            _directory = State(initialValue: candidate)
        } else if FileManager.default.fileExists(atPath: candidate.deletingLastPathComponent().path) {
            _directory = State(initialValue: candidate.deletingLastPathComponent())
        } else { _directory = State(initialValue: FileManager.default.homeDirectoryForCurrentUser) }
    }
    private var locations: [(String, String, URL)] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var items: [(String, String, URL)] = [
            ("Home", "house", home),
            ("Applications", "app.dashed", URL(fileURLWithPath: "/Applications")),
            ("Downloads", "arrow.down.circle", home.appendingPathComponent("Downloads")),
            ("External drives", "externaldrive", URL(fileURLWithPath: "/Volumes")),
            ("Computer", "desktopcomputer", URL(fileURLWithPath: "/"))
        ]
        for volume in FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? [] where volume.path.hasPrefix("/Volumes/") {
            items.append((volume.lastPathComponent, "externaldrive.fill", volume))
        }
        return items
    }
    private var actions: [String] { mode == .directory ? ["Use this folder", "Find in folder", showHidden ? "Hide hidden items" : "Show hidden items", "Cancel"] : ["Find in folder", showHidden ? "Hide hidden items" : "Show hidden items", "Cancel"] }
    private var selectedID: String? { listing.entries.indices.contains(entryIndex) ? listing.entries[entryIndex].id : nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 7) {
                    Text("BROWSE").font(.system(size: 9, weight: .semibold)).tracking(3).foregroundStyle(studioAccent)
                    Text(title).font(.system(size: 26, weight: .light)).lineLimit(1)
                }
                Spacer()
                Button { closePage() } label: { Image(systemName: "xmark").padding(10).background(.white.opacity(0.07), in: Circle()) }
                    .buttonStyle(ConsoleButtonStyle()).accessibilityLabel("Cancel file selection")
            }
            HStack(spacing: 12) {
                Button { goBack() } label: { Image(systemName: "chevron.left").frame(width: 25, height: 28) }.buttonStyle(ConsoleButtonStyle()).help("Parent folder · B")
                Text(directory.path + (filter.isEmpty ? "" : " · Find: " + filter)).font(.system(size: 12)).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
            }.padding(10).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
            HStack(alignment: .top, spacing: 18) {
                ScrollView {
                    VStack(spacing: 5) {
                        ForEach(Array(locations.enumerated()), id: \.element.2.path) { index, location in
                            Button { locationIndex = index; zone = 0; open(location.2) } label: {
                                Label(location.0, systemImage: location.1).font(.system(size: 12)).lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                    .foregroundStyle(zone == 0 && locationIndex == index ? studioBackground : .white.opacity(0.7))
                                    .background(zone == 0 && locationIndex == index ? studioAccent : .clear, in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(ConsoleButtonStyle()).consoleFocus(zone == 0 && locationIndex == index, cornerRadius: 8, scale: 1.025)
                        }
                    }.padding(5)
                }.frame(width: 175)
                Rectangle().fill(.white.opacity(0.06)).frame(width: 1)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            if listing.entries.isEmpty && !loading {
                                VStack(spacing: 12) {
                                    Image(systemName: "folder").font(.system(size: 35, weight: .ultraLight))
                                    Text(listing.message == nil ? "No selectable items here" : "Folder unavailable")
                                }.foregroundStyle(.secondary).font(.callout).frame(maxWidth: .infinity, minHeight: 230)
                            }
                            ForEach(Array(listing.entries.enumerated()), id: \.element.id) { index, entry in
                                Button { entryIndex = index; zone = 1; activate(entry) } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: entry.isApplication ? "app" : entry.isDirectory ? "folder.fill" : "doc").frame(width: 22)
                                        Text(entry.name).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                                        Spacer(minLength: 0)
                                        if entry.isDirectory && !entry.isApplication { Image(systemName: "chevron.right").font(.system(size: 10)) }
                                    }.padding(.horizontal, 12).frame(height: 39)
                                        .foregroundStyle(zone == 1 && entryIndex == index ? studioBackground : .white.opacity(0.8))
                                        .background(zone == 1 && entryIndex == index ? studioAccent : .white.opacity(0.025), in: RoundedRectangle(cornerRadius: 7))
                                }.buttonStyle(ConsoleButtonStyle()).consoleFocus(zone == 1 && entryIndex == index, cornerRadius: 7, scale: 1.015).id(entry.id)
                            }
                        }
                    }.onChange(of: selectedID) { _, id in if let id { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .center) } } }
                }
            }.frame(height: 320)
            if let message = listing.message { Text(message).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(2) }
            HStack(spacing: 12) {
                ForEach(Array(actions.enumerated()), id: \.offset) { index, title in
                    Button { actionIndex = index; performAction(index) } label: {
                        Text(title).font(.system(size: 12, weight: .semibold)).padding(.horizontal, 18).frame(height: 38)
                            .foregroundStyle(zone == 2 && actionIndex == index ? studioBackground : .white.opacity(0.85))
                            .background(zone == 2 && actionIndex == index ? studioAccent : .white.opacity(0.06), in: Capsule())
                    }.buttonStyle(ConsoleButtonStyle()).consoleFocus(zone == 2 && actionIndex == index, cornerRadius: 19)
                }
                Spacer()
            }
            Text(mode == .directory ? "A  Open folder     X  Use current folder     B  Parent     Y  Hidden     LB / RB  Locations" : "A  Open / select     B  Parent     Y  Hidden     LB / RB  Locations")
                .font(.system(size: 9)).foregroundStyle(.secondary)
        }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(studioBackground.ignoresSafeArea()).preferredColorScheme(.dark).tint(studioAccent)
            .task { await reload() }
            .animation(ConsoleFeedback.shared.focusAnimation, value: selectedID)
            .consoleInput(onCommand: navigate)
            .consolePage(isPresented: $searchOpen) {
                SearchKeyboardView(query: $filter, title: "Find in folder", subtitle: "Search the names in this folder.", doneTitle: "Find") {
                    searchOpen = false; entryIndex = 0; Task { await reload() }
                }
            }
    }
    private func activate(_ entry: ConsoleBrowserEntry) {
        guard !loading else { return }
        if entry.isDirectory && (mode != .application || !entry.isApplication) { open(entry.url) }
        else { onSelect(entry.url); closePage() }
    }
    private func open(_ url: URL) {
        history.append(directory); directory = url.standardizedFileURL; entryIndex = 0; filter = ""
        Task { await reload() }
    }
    private func goBack() {
        if !history.isEmpty { directory = history.removeLast(); entryIndex = 0; Task { await reload() }; return }
        let parent = directory.deletingLastPathComponent()
        if parent.path == directory.path { closePage() }
        else { directory = parent; entryIndex = 0; Task { await reload() } }
    }
    private func reload() async {
        let id = UUID(); requestID = id; loading = true
        let path = directory, hidden = showHidden, extensions = allowedExtensions, mode = mode, query = filter
        let result = await Task.detached(priority: .userInitiated) { ConsoleBrowser.list(path, showHidden: hidden, mode: mode, allowedExtensions: extensions, query: query) }.value
        guard requestID == id else { return }
        listing = result; loading = false; entryIndex = min(entryIndex, max(listing.entries.count - 1, 0))
    }
    private func performAction(_ index: Int) {
        if mode == .directory && index == 0 {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else { listing.message = "This folder is no longer available."; return }
            onSelect(directory); closePage()
        } else if index == actions.count - 1 { closePage() }
        else if index == (mode == .directory ? 1 : 0) { searchOpen = true }
        else { showHidden.toggle(); Task { await reload() } }
    }
    private func navigate(_ command: String) {
        switch command {
        case "back": goBack()
        case "details": if mode == .directory { performAction(0) } else { searchOpen = true }
        case "favorite": showHidden.toggle(); Task { await reload() }
        case "menu", "context": zone = 2; actionIndex = 0
        case "previous", "next":
            locationIndex = (locationIndex + (command == "previous" ? -1 : 1) + locations.count) % locations.count
            zone = 0; open(locations[locationIndex].2)
        case "left": if zone == 2 { actionIndex = max(actionIndex - 1, 0) } else { zone = 0 }
        case "right": if zone == 2 { actionIndex = min(actionIndex + 1, actions.count - 1) } else { zone = 1 }
        case "up":
            if zone == 2 { zone = 1 }
            else if zone == 0 { locationIndex = max(locationIndex - 1, 0) }
            else { entryIndex = max(entryIndex - 1, 0) }
        case "down":
            if zone == 0 { locationIndex = min(locationIndex + 1, locations.count - 1) }
            else if zone == 1 && entryIndex < listing.entries.count - 1 { entryIndex += 1 }
            else { zone = 2 }
        case "confirm":
            if zone == 0 { open(locations[locationIndex].2); zone = 1 }
            else if zone == 2 { performAction(actionIndex) }
            else if listing.entries.indices.contains(entryIndex) { activate(listing.entries[entryIndex]) }
            else { zone = 2 }
        default: break
        }
    }
}
