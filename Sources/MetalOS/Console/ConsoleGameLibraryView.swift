import SwiftUI

struct ConsoleLibraryGame: Identifiable {
    let id: String
    let title: String
    let developer: String
    let symbol: String
    let artworkPreset: WallpaperPreset
    let heroGameID: String
    let playtimeMinutes: Int
    let playedOrder: Int
    let isInstalled: Bool
    let isAvailable: Bool
    var tilePaths: [String] = []
    var heroPaths: [String] = []
    var summary: String? = nil
    var platforms: [String] = []
    var localLogoPath: String? = nil
}

struct ConsoleLibraryCollection: Identifiable, Codable {
    let id: String
    var title: String
    let symbol: String
}

@MainActor
final class ConsoleGameLibraryModel: ObservableObject {
    @Published var searchText = ""
    @Published private(set) var favoriteIDs: Set<String> = []
    @Published private(set) var collections: [ConsoleLibraryCollection] = ConsoleGameLibraryModel.loadCollections() {
        didSet { Self.saveCollections(collections) }
    }
    @Published private(set) var collectionMembers: [String: Set<String>] = [:]
    @Published private(set) var heroArtIndices: [String: Int] = [:]
    @Published var heroCustomizationGameID: String?

    @Published private(set) var games: [ConsoleLibraryGame] = []
    var onFavoriteChanged: ((String, Bool) -> Void)?
    var onCollectionChanged: ((String, String) -> Void)?

    func synchronize(with localGames: [Game]) {
        let libraryGames = localGames.filter { $0.isGame && !($0.isHidden ?? false) }
        games = libraryGames.map { game in
            let tiles = [game.tileArt?.path, game.boxArt?.path, game.artworkPath].compactMap { $0 }
            let heroes = [game.heroArt?.path].compactMap { $0 } + (game.metadata?.screenshots.map(\.path) ?? [])
            return ConsoleLibraryGame(
                id: game.id, title: game.displayTitle,
                developer: game.metadata?.developers.first ?? game.source.rawValue,
                symbol: game.source.symbol, artworkPreset: .metalOSHorizon, heroGameID: game.id,
                playtimeMinutes: Int((game.playedSeconds ?? 0) / 60),
                playedOrder: localGames.firstIndex(where: { $0.id == game.id }) ?? 0,
                isInstalled: true, isAvailable: game.isAvailable, tilePaths: tiles, heroPaths: heroes,
                summary: game.metadata?.summary, platforms: game.metadata?.platforms ?? [],
                localLogoPath: game.metadata?.localLogoPath
            )
        }
        favoriteIDs = Set(libraryGames.filter(\.favorite).map(\.id))
        let pairs = libraryGames.flatMap { game in (game.collectionIDs ?? []).map { ($0, game.id) } }
        collectionMembers = Dictionary(grouping: pairs, by: \.0).mapValues { Set($0.map(\.1)) }
    }

    func visibleGames(tab: ConsoleLibraryTab, sort: ConsoleLibrarySort, collectionID: String?) -> [ConsoleLibraryGame] {
        var result = games.filter { game in
            if let collectionID { return collectionMembers[collectionID, default: []].contains(game.id) }
            switch tab {
            case .installed: return true
            case .favorites: return favoriteIDs.contains(game.id)
            case .collections: return false
            }
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            result = result.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.developer.localizedCaseInsensitiveContains(query) }
        }
        switch sort {
        case .recentlyPlayed: result.sort { $0.playedOrder < $1.playedOrder }
        case .aToZ: result.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .zToA: result.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedDescending }
        case .playtime: result.sort { $0.playtimeMinutes > $1.playtimeMinutes }
        }
        return result
    }

    func visibleCollections() -> [ConsoleLibraryCollection] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return collections }
        return collections.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    func members(of collectionID: String) -> [ConsoleLibraryGame] {
        let ids = collectionMembers[collectionID, default: []]
        return games.filter { ids.contains($0.id) }
    }

    func isFavorite(_ game: ConsoleLibraryGame) -> Bool { favoriteIDs.contains(game.id) }

    func toggleFavorite(_ game: ConsoleLibraryGame) {
        if favoriteIDs.contains(game.id) { favoriteIDs.remove(game.id) }
        else { favoriteIDs.insert(game.id) }
        onFavoriteChanged?(game.id, favoriteIDs.contains(game.id))
    }

    @discardableResult
    func createCollection() -> ConsoleLibraryCollection {
        let next = ConsoleLibraryCollection(id: UUID().uuidString, title: "New Collection", symbol: "square.stack.3d.up.fill")
        collections.append(next)
        collectionMembers[next.id] = []
        return next
    }

    func add(_ game: ConsoleLibraryGame, to collectionID: String) {
        collectionMembers[collectionID, default: []].insert(game.id)
        onCollectionChanged?(game.id, collectionID)
    }

    private static func loadCollections() -> [ConsoleLibraryCollection] {
        guard let data = UserDefaults.standard.data(forKey: "console.library.collections"),
              let value = try? JSONDecoder().decode([ConsoleLibraryCollection].self, from: data) else { return [] }
        return value
    }

    private static func saveCollections(_ collections: [ConsoleLibraryCollection]) {
        guard let data = try? JSONEncoder().encode(collections) else { return }
        UserDefaults.standard.set(data, forKey: "console.library.collections")
    }

    func heroArtwork(for game: ConsoleLibraryGame) -> [String] {
        let paths = game.heroPaths + (game.artworkPreset.imageURL.map { [$0.path] } ?? [])
        guard !paths.isEmpty else { return [] }
        let index = heroArtIndices[game.id, default: 0] % paths.count
        return [paths[index]]
    }

    func cycleHeroArtwork(for game: ConsoleLibraryGame, by amount: Int) {
        let paths = game.heroPaths + (game.artworkPreset.imageURL.map { [$0.path] } ?? [])
        guard paths.count > 1 else { return }
        let current = heroArtIndices[game.id, default: 0]
        heroArtIndices[game.id] = (current + amount + paths.count) % paths.count
    }

    func cycleCustomHeroArtwork(by amount: Int) {
        guard let id = heroCustomizationGameID, let game = games.first(where: { $0.id == id }) else { return }
        cycleHeroArtwork(for: game, by: amount)
    }
}

struct ConsoleGameLibraryView: View {
    @ObservedObject var focus: FocusCoordinator
    @ObservedObject var model: ConsoleGameLibraryModel
    let onPlay: (ConsoleLibraryGame) -> Void
    let onDetails: (ConsoleLibraryGame) -> Void
    let onHide: (String) -> Void
    let onRemoveCustom: (String) -> Void

    @FocusState private var searchFieldFocused: Bool

    private var visibleGames: [ConsoleLibraryGame] {
        model.visibleGames(tab: focus.libraryTab, sort: focus.librarySort, collectionID: focus.activeLibraryCollectionID)
    }
    private var visibleCollections: [ConsoleLibraryCollection] { model.visibleCollections() }
    private var focusedGame: ConsoleLibraryGame? {
        visibleGames.indices.contains(focus.libraryFocusIndex) ? visibleGames[focus.libraryFocusIndex] : nil
    }
    private var focusedCollection: ConsoleLibraryCollection? {
        visibleCollections.indices.contains(focus.libraryFocusIndex) ? visibleCollections[focus.libraryFocusIndex] : nil
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let columnsCount = size.width > 1600 ? 6 : 5
            let horizontalInset = max(46, size.width * 0.052)
            let gridColumns = Array(repeating: GridItem(.flexible(), spacing: 25, alignment: .top), count: columnsCount)
            ZStack {
                ambientBackground(game: focusedGame)
                VStack(alignment: .leading, spacing: 0) {
                    header
                    utilityStrip
                        .padding(.top, 16)
                    if let focusedGame {
                        focusedGameHeading(focusedGame)
                            .padding(.top, 24)
                    } else if let focusedCollection {
                        focusedCollectionHeading(focusedCollection)
                            .padding(.top, 24)
                    } else if focus.libraryTab == .collections && focus.activeLibraryCollectionID == nil {
                        Text("Choose a collection or create a new one")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(.white.opacity(0.66))
                            .padding(.top, 27)
                    } else {
                        Text("No games found")
                            .font(.system(size: 24, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.75))
                            .padding(.top, 28)
                    }
                    if focus.isCustomizingLibraryHero {
                        Text("CUSTOMIZE HERO ART  ·  LEFT / RIGHT TO CYCLE  ·  BACK TO FINISH")
                            .font(.system(size: 11, weight: .semibold)).tracking(1.2)
                            .foregroundStyle(.white.opacity(0.76)).padding(.top, 8)
                    }

                    grid(columnsCount: columnsCount, gridColumns: gridColumns, size: size)
                        .padding(.top, 12)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, horizontalInset)
                .padding(.top, max(30, size.height * 0.045))
                .padding(.bottom, 30)

                if let menu = focus.libraryMenu {
                    menuOverlay(menu, width: size.width, height: size.height)
                        .transition(.scale(scale: 0.94).combined(with: .opacity))
                        .zIndex(2)
                }
            }
            .frame(width: size.width, height: size.height)
            .onAppear {
                configureLibraryActions()
                synchronizeGrid(columns: columnsCount)
            }
            .onChange(of: focus.libraryTab) { _, _ in synchronizeGrid(columns: columnsCount) }
            .onChange(of: focus.librarySort) { _, _ in synchronizeGrid(columns: columnsCount) }
            .onChange(of: focus.activeLibraryCollectionID) { _, _ in synchronizeGrid(columns: columnsCount) }
            .onChange(of: model.searchText) { _, _ in synchronizeGrid(columns: columnsCount) }
            .onChange(of: model.favoriteIDs) { _, _ in synchronizeGrid(columns: columnsCount) }
            .onChange(of: model.collections.count) { _, _ in synchronizeGrid(columns: columnsCount) }
            .onChange(of: focus.isLibrarySearchActive) { _, isActive in
                searchFieldFocused = isActive
            }
            .onChange(of: focus.libraryMenu) { _, menu in
                if menu == .collectionPicker {
                    focus.setLibraryMenuItemCount(model.collections.count + 1)
                }
            }
            .animation(ConsoleMotion.zoneSpring, value: focus.libraryTab)
            .animation(ConsoleMotion.zoneSpring, value: focus.activeLibraryCollectionID)
            .animation(ConsoleMotion.focusSpring, value: focus.libraryFocusIndex)
            .animation(ConsoleMotion.zoneSpring, value: focus.libraryMenu)
        }
        .ignoresSafeArea()
        .foregroundStyle(.white)
        .background(.black)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 30) {
            ForEach(ConsoleLibraryTab.allCases, id: \.rawValue) { tab in
                let active = focus.libraryTab == tab
                Button { focus.focusLibraryTab(tab) } label: {
                    VStack(spacing: 9) {
                        Text(tab.title)
                            .font(.system(size: 23, weight: active ? .semibold : .medium))
                            .foregroundStyle(.white.opacity(active ? 1 : 0.58))
                        Capsule()
                            .fill(.white.opacity(active ? 0.95 : 0))
                            .frame(width: active ? 34 : 0, height: 2)
                            .shadow(color: .white.opacity(active ? 0.4 : 0), radius: 7)
                    }
                    .padding(.horizontal, 6)
                    .frame(height: 48)
                    .overlay { ConsoleSignatureFocusRing(shape: Capsule(), isFocused: active && focus.libraryFocusRegion == .tabs).padding(-5) }
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            }
            Spacer()
            Text("GAME LIBRARY")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(2.3)
                .foregroundStyle(.white.opacity(0.45))
        }
        .frame(height: 54)
    }

    private var utilityStrip: some View {
        HStack(spacing: 13) {
            if focus.isLibrarySearchActive {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").font(.system(size: 15, weight: .medium))
                    TextField("Search your games", text: $model.searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15, weight: .medium))
                        .focused($searchFieldFocused)
                        .frame(width: 260)
                        .accessibilityLabel("Search games")
                        .onAppear {
                            DispatchQueue.main.async { searchFieldFocused = true }
                        }
                    if !model.searchText.isEmpty {
                        Button { model.searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.68))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 17)
                .frame(height: 42)
                .background(.ultraThinMaterial.opacity(0.62), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.18)))
                .overlay { ConsoleSignatureFocusRing(shape: Capsule(), isFocused: true).padding(-3) }
            } else {
                Button {
                    focus.focusLibraryUtility(0)
                    focus.handle(.confirm)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").font(.system(size: 15, weight: .medium))
                        Text("Search").font(.system(size: 14, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 17)
                    .frame(height: 42)
                    .background(.ultraThinMaterial.opacity(0.62), in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.18)))
                    .overlay { ConsoleSignatureFocusRing(shape: Capsule(), isFocused: focus.libraryFocusRegion == .utilities && focus.libraryUtilityIndex == 0).padding(-3) }
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            }

            Button {
                focus.focusLibraryUtility(1)
                focus.handle(.confirm)
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "arrow.up.arrow.down").font(.system(size: 13, weight: .semibold))
                    Text(focus.librarySort.title).font(.system(size: 14, weight: .medium))
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).opacity(0.62)
                }
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 15)
                .frame(height: 42)
                .background(.ultraThinMaterial.opacity(0.62), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.18)))
                .overlay { ConsoleSignatureFocusRing(shape: Capsule(), isFocused: focus.libraryFocusRegion == .utilities && focus.libraryUtilityIndex == 1).padding(-3) }
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()

            Spacer()
            Text(itemCountText)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.54))
        }
        .frame(height: 46)
    }

    private var itemCountText: String {
        if focus.libraryTab == .collections && focus.activeLibraryCollectionID == nil {
            return "\(visibleCollections.count) Collections"
        }
        return "\(visibleGames.count) Games"
    }

    private func focusedGameHeading(_ game: ConsoleLibraryGame) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: 15) {
            Text(game.title)
                .font(.system(size: 28, weight: .medium, design: .rounded))
                .tracking(-0.6)
                .lineLimit(1)
                .contentTransition(.opacity)
            Text(game.developer.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(1.6)
                .foregroundStyle(.white.opacity(0.55))
            if let summary = game.summary {
                Text(summary).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.46)).lineLimit(1)
            }
            if focus.libraryTab == .favorites || model.isFavorite(game) {
                Image(systemName: "heart.fill").font(.system(size: 12)).foregroundStyle(.white.opacity(0.75))
            }
            Spacer()
            Text(game.isInstalled ? "INSTALLED" : "IN YOUR LIBRARY")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1.2)
                .foregroundStyle(.white.opacity(0.48))
        }
    }

    private func focusedCollectionHeading(_ collection: ConsoleLibraryCollection) -> some View {
        HStack(alignment: .lastTextBaseline) {
            Image(systemName: collection.symbol).font(.system(size: 18, weight: .medium))
            Text(collection.title).font(.system(size: 28, weight: .medium, design: .rounded)).tracking(-0.6)
            Spacer()
            Text("\(model.members(of: collection.id).count) GAMES")
                .font(.system(size: 10, weight: .bold, design: .rounded)).tracking(1.2).foregroundStyle(.white.opacity(0.5))
        }
    }

    @ViewBuilder
    private func grid(columnsCount: Int, gridColumns: [GridItem], size: CGSize) -> some View {
        ScrollViewReader { reader in
            ScrollView(.vertical) {
                LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 27) {
                    if focus.libraryTab == .collections && focus.activeLibraryCollectionID == nil {
                        ForEach(Array(visibleCollections.enumerated()), id: \.element.id) { entry in
                            collectionTile(entry.element, index: entry.offset, side: tileSide(width: size.width, columns: columnsCount))
                                .id("collection-\(entry.element.id)")
                        }
                        createCollectionTile(index: visibleCollections.count, side: tileSide(width: size.width, columns: columnsCount))
                            .id("collection-create")
                    } else if visibleGames.isEmpty {
                        emptyGridTile
                            .id("empty-library")
                    } else {
                        ForEach(Array(visibleGames.enumerated()), id: \.element.id) { entry in
                            gameTile(entry.element, index: entry.offset, side: tileSide(width: size.width, columns: columnsCount))
                                .id(entry.element.id)
                        }
                    }
                }
                .padding(.top, 16)
                .padding(.bottom, 52)
            }
            .scrollIndicators(.hidden)
            .onChange(of: focus.libraryFocusIndex) { _, index in
                let id = gridID(at: index)
                withAnimation(ConsoleMotion.ribbonSpring) { reader.scrollTo(id, anchor: .center) }
            }
            .onChange(of: visibleGames.map(\.id)) { _, _ in
                let id = gridID(at: focus.libraryFocusIndex)
                withAnimation(ConsoleMotion.ribbonSpring) { reader.scrollTo(id, anchor: .center) }
            }
            .onChange(of: visibleCollections.map(\.id)) { _, _ in
                let id = gridID(at: focus.libraryFocusIndex)
                withAnimation(ConsoleMotion.ribbonSpring) { reader.scrollTo(id, anchor: .center) }
            }
        }
        .onAppear { synchronizeGrid(columns: columnsCount) }
    }

    private func gameTile(_ game: ConsoleLibraryGame, index: Int, side: CGFloat) -> some View {
        let isFocused = focus.libraryFocusRegion == .grid && focus.libraryFocusIndex == index
        return Button {
            focus.focusLibraryIndex(index)
            focus.handle(.confirm)
        } label: {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.08))
                ConsoleHomeArtwork(paths: game.tilePaths + (game.artworkPreset.imageURL.map { [$0.path] } ?? []), maxPixelSize: 760)
                LinearGradient(colors: [.clear, .black.opacity(0.56)], startPoint: .center, endPoint: .bottom)
                Image(systemName: game.symbol)
                    .font(.system(size: side * 0.29, weight: .ultraLight))
                    .foregroundStyle(.white.opacity(0.83))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if model.isFavorite(game) {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(10)
                }
                if !game.isInstalled {
                    Image(systemName: "icloud.and.arrow.down.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
                if !game.isAvailable {
                    Label("DRIVE NOT CONNECTED", systemImage: "externaldrive.badge.xmark")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .tracking(0.6)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(.black.opacity(0.58), in: Capsule())
                        .padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(isFocused ? .clear : .white.opacity(0.16), lineWidth: 1))
            .overlay { ConsoleSignatureFocusRing(shape: RoundedRectangle(cornerRadius: 18, style: .continuous), isFocused: isFocused) }
            .shadow(color: isFocused ? .white.opacity(0.22) : .black.opacity(0.2), radius: isFocused ? 17 : 8, y: 6)
            .scaleEffect(isFocused ? 1.08 : 1)
            .opacity(game.isAvailable ? (isFocused ? 1 : 0.78) : (isFocused ? 0.76 : 0.54))
            .animation(ConsoleMotion.focusSpring, value: isFocused)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityLabel(game.title)
    }

    private func collectionTile(_ collection: ConsoleLibraryCollection, index: Int, side: CGFloat) -> some View {
        let isFocused = focus.libraryFocusRegion == .grid && focus.libraryFocusIndex == index
        let members = model.members(of: collection.id).prefix(4)
        return Button {
            focus.focusLibraryIndex(index)
            focus.openLibraryCollection(collection.id)
        } label: {
            VStack(alignment: .leading, spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.08))
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)], spacing: 4) {
                        ForEach(Array(members), id: \.id) { game in
                            ConsoleHomeArtwork(paths: game.tilePaths + (game.artworkPreset.imageURL.map { [$0.path] } ?? []), maxPixelSize: 300)
                                .frame(height: (side - 20) / 2)
                                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                    }
                    .padding(12)
                    if members.isEmpty {
                        Image(systemName: collection.symbol).font(.system(size: side * 0.28, weight: .light)).foregroundStyle(.white.opacity(0.78))
                    }
                }
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay { ConsoleSignatureFocusRing(shape: RoundedRectangle(cornerRadius: 18, style: .continuous), isFocused: isFocused) }
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(collection.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                        Text("\(model.members(of: collection.id).count) games").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.55))
                }
            }
            .frame(width: side)
            .scaleEffect(isFocused ? 1.04 : 1)
            .animation(ConsoleMotion.focusSpring, value: isFocused)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    private func createCollectionTile(index: Int, side: CGFloat) -> some View {
        let isFocused = focus.libraryFocusRegion == .grid && focus.libraryFocusIndex == index
        return Button {
            focus.focusLibraryIndex(index)
            createCollection()
        } label: {
            VStack(spacing: 16) {
                Image(systemName: "plus")
                    .font(.system(size: 28, weight: .medium))
                    .frame(width: 60, height: 60)
                    .background(.white.opacity(0.09), in: Circle())
                Text("Create Collection").font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(0.87))
            .frame(width: side, height: side)
            .background(.ultraThinMaterial.opacity(0.55), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.17), lineWidth: 1))
            .overlay { ConsoleSignatureFocusRing(shape: RoundedRectangle(cornerRadius: 18, style: .continuous), isFocused: isFocused) }
            .scaleEffect(isFocused ? 1.04 : 1)
            .animation(ConsoleMotion.focusSpring, value: isFocused)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    private var emptyGridTile: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "square.grid.2x2").font(.system(size: 28, weight: .light))
            Text("No games match your search").font(.system(size: 16, weight: .semibold))
            Text("Try another title or clear the search.").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.6))
        }
        .padding(23)
        .frame(width: 250, height: 160, alignment: .leading)
        .background(.ultraThinMaterial.opacity(0.48), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay { ConsoleSignatureFocusRing(shape: RoundedRectangle(cornerRadius: 18, style: .continuous), isFocused: true) }
    }

    private func ambientBackground(game: ConsoleLibraryGame?) -> some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.014, green: 0.023, blue: 0.053), Color(red: 0.025, green: 0.047, blue: 0.105)], startPoint: .topLeading, endPoint: .bottomTrailing)
            if let game {
                ConsoleHomeArtwork(paths: model.heroArtwork(for: game), maxPixelSize: 2200)
                    .id(game.id)
                    .scaleEffect(1.08)
                    .blur(radius: 62)
                    .opacity(0.19)
                    .animation(.easeInOut(duration: ConsoleMotion.crossfadeDuration), value: game.id)
            }
            LinearGradient(colors: [.black.opacity(0.38), .clear, .black.opacity(0.72)], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [.clear, .black.opacity(0.28)], center: .center, startRadius: 260, endRadius: 1150)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func menuOverlay(_ menu: ConsoleLibraryMenu, width: CGFloat, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(menuTitle(menu))
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .padding(.horizontal, 10)
                .padding(.bottom, 3)
            ForEach(0..<focus.libraryMenuItemCount, id: \.self) { index in
                let title = menuItemTitle(menu, index: index)
                Button {
                    focus.focusLibraryMenuIndex(index)
                    focus.handle(.confirm)
                } label: {
                    HStack(spacing: 11) {
                        Image(systemName: menuItemSymbol(menu, index: index))
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 20)
                        Text(title).font(.system(size: 13, weight: focus.libraryMenuIndex == index ? .semibold : .medium))
                        Spacer()
                        if menu == .sort, focus.librarySort.rawValue == index {
                            Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                        }
                    }
                    .padding(.horizontal, 11)
                    .frame(height: 38)
                    .background(focus.libraryMenuIndex == index ? .white.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay { ConsoleSignatureFocusRing(shape: RoundedRectangle(cornerRadius: 11, style: .continuous), isFocused: focus.libraryMenuIndex == index).padding(-2) }
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            }
        }
        .padding(15)
        .frame(width: 320, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.2), lineWidth: 1))
        .shadow(color: .black.opacity(0.42), radius: 26, y: 12)
        .position(x: width / 2, y: height * 0.52)
    }

    private func menuTitle(_ menu: ConsoleLibraryMenu) -> String {
        switch menu {
        case .sort: "Sort by"
        case .gameOptions: focusedGame?.title ?? "Game options"
        case .collectionPicker: "Add to Collection"
        }
    }

    private func menuItemTitle(_ menu: ConsoleLibraryMenu, index: Int) -> String {
        switch menu {
        case .sort: ConsoleLibrarySort(rawValue: index)?.title ?? "Sort"
        case .gameOptions:
            switch index {
            case 0: "Play Game"
            case 1: focusedGame.map { model.isFavorite($0) ? "Remove from Favorites" : "Add to Favorites" } ?? "Favorites"
            case 2: "Add to Collection"
            case 3: "View Game Details"
            case 4: "Customize Hero Art"
            case 5: "Hide Game"
            default: "Remove Custom Entry"
            }
        case .collectionPicker:
            index < model.collections.count ? model.collections[index].title : "+ Create Collection"
        }
    }

    private func menuItemSymbol(_ menu: ConsoleLibraryMenu, index: Int) -> String {
        switch menu {
        case .sort: focus.librarySort.rawValue == index ? "checkmark.circle.fill" : "circle"
        case .gameOptions:
            switch index {
            case 0: "play.fill"
            case 1: "heart"
            case 2: "folder.badge.plus"
            case 3: "info.circle"
            case 5: "eye.slash"
            case 6: "trash"
            default: "photo"
            }
        case .collectionPicker: index < model.collections.count ? "folder.fill" : "plus"
        }
    }

    private func tileSide(width: CGFloat, columns: Int) -> CGFloat {
        min(174, (width - max(46, width * 0.052) * 2 - CGFloat(columns - 1) * 25) / CGFloat(columns))
    }

    private func gridID(at index: Int) -> String {
        if focus.libraryTab == .collections && focus.activeLibraryCollectionID == nil {
            return visibleCollections.indices.contains(index) ? "collection-\(visibleCollections[index].id)" : "collection-create"
        }
        return visibleGames.indices.contains(index) ? visibleGames[index].id : "empty-library"
    }

    private func synchronizeGrid(columns: Int) {
        let isCollectionList = focus.libraryTab == .collections && focus.activeLibraryCollectionID == nil
        let count = isCollectionList ? visibleCollections.count + 1 : visibleGames.count
        focus.synchronizeLibraryGrid(itemCount: count, columns: columns)
    }

    private func createCollection() {
        let collection = model.createCollection()
        focus.synchronizeLibraryGrid(itemCount: visibleCollections.count + 1, columns: 5)
        focus.focusLibraryIndex(visibleCollections.firstIndex(where: { $0.id == collection.id }) ?? visibleCollections.count - 1)
    }

    private func activateGridItem(_ index: Int) {
        if focus.libraryTab == .collections && focus.activeLibraryCollectionID == nil {
            if visibleCollections.indices.contains(index) {
                focus.openLibraryCollection(visibleCollections[index].id)
            } else {
                createCollection()
            }
            return
        }
        guard visibleGames.indices.contains(index) else { return }
        onPlay(visibleGames[index])
    }

    private func performMenuAction(_ menu: ConsoleLibraryMenu, index: Int) {
        guard let game = focusedGame else { return }
        switch (menu, index) {
        case (.gameOptions, 0): onPlay(game)
        case (.gameOptions, 1): model.toggleFavorite(game)
        case (.gameOptions, 3): onDetails(game)
        case (.gameOptions, 4):
            model.heroCustomizationGameID = game.id
            focus.beginLibraryHeroCustomization()
        case (.gameOptions, 5): onHide(game.id)
        case (.gameOptions, 6): onRemoveCustom(game.id)
        case (.collectionPicker, let collectionIndex):
            let collection = collectionIndex < model.collections.count ? model.collections[collectionIndex] : model.createCollection()
            model.add(game, to: collection.id)
            UISoundManager.playConfirm()
        default: break
        }
    }

    private func configureLibraryActions() {
        focus.onLibraryConfirm = activateGridItem
        focus.onLibraryMenuAction = performMenuAction
        focus.onLibrarySearchBack = {
            guard !model.searchText.isEmpty else { return false }
            model.searchText = ""
            UISoundManager.playBack()
            return true
        }
        focus.onLibraryArtworkStep = { [weak model] amount in
            model?.cycleCustomHeroArtwork(by: amount)
            UISoundManager.playFocusMove()
        }
        focus.onLibraryHeroCustomizationFinished = { ConsoleToastManager.shared.notifyHeroArtworkUpdated() }
    }
}
