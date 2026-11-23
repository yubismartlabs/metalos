import SwiftUI

private enum ConsoleWelcomeDestination: String, CaseIterable, Identifiable {
    case store = "PlayStation Store"
    case explore = "Explore"
    case welcome = "Welcome"
    case gallery = "Media Gallery"
    case library = "Game Library"

    var id: Self { self }
    var symbol: String {
        switch self {
        case .store: "bag.fill"
        case .explore: "safari.fill"
        case .welcome: "house.fill"
        case .gallery: "photo.on.rectangle.angled"
        case .library: "square.grid.2x2.fill"
        }
    }
    var tint: Color {
        switch self {
        case .store: Color(red: 0.19, green: 0.42, blue: 0.86)
        case .explore: Color(red: 0.24, green: 0.68, blue: 0.89)
        case .welcome: Color(red: 0.34, green: 0.49, blue: 0.84)
        case .gallery: Color(red: 0.68, green: 0.36, blue: 0.72)
        case .library: Color(red: 0.37, green: 0.58, blue: 0.83)
        }
    }
}

/// Console mode landing surface. Keeps the game runtime actions owned by LibraryView
/// while providing the welcome, library, media, and profile destinations around them.
struct ConsoleWelcomeExperience: View {
    let games: [ConsoleHomeGame]
    let wallpaperPaths: [String]
    let accent: Color
    let storageAvailable: String
    let captures: [URL]
    let onAction: (ConsoleHomeAction) -> Void
    let onSettings: () -> Void
    let onSearch: () -> Void
    @Binding var selectedID: String?
    @State private var destination: ConsoleWelcomeDestination = .welcome
    @State private var mode: Mode = .games
    @State private var showingProfile = false
    @State private var showingGameHub = false
    @State private var galleryFilter = "All"
    @StateObject private var network = NetworkPathStatus()
    @ObservedObject private var controller = ControllerManager.shared

    private enum Mode: String, CaseIterable { case games = "Games", media = "Media" }

    private var selectedGame: ConsoleHomeGame? {
        games.first(where: { $0.id == selectedID }) ?? games.first
    }
    private var status: ConsoleHomeStatus {
        .live(controller: controller, activeID: nil, network: network.snapshot)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ConsoleHomeBackdrop(
                    paths: destination == .welcome ? wallpaperPaths : (selectedGame?.heroPaths ?? wallpaperPaths),
                    video: nil,
                    accent: accent
                )
                VStack(alignment: .leading, spacing: 0) {
                    header
                    if showingProfile {
                        profilePage
                    } else if mode == .media {
                        galleryPage
                    } else {
                        ribbon
                        destinationContent(compact: proxy.size.height < 780)
                    }
                }
                .padding(.horizontal, proxy.size.width < 1200 ? 32 : ConsoleDesign.Space.screenInset)
                .padding(.top, 24)
                .padding(.bottom, 22)
            }
        }
        .foregroundStyle(ConsoleDesign.Palette.text)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 22) {
            HStack(spacing: 4) {
                ForEach(Mode.allCases, id: \.self) { candidate in
                    Button {
                        mode = candidate
                        showingProfile = false
                        showingGameHub = false
                        if candidate == .games { destination = .welcome }
                    } label: {
                        Text(candidate.rawValue)
                            .font(.system(size: 19, weight: mode == candidate ? .semibold : .medium))
                            .foregroundStyle(mode == candidate ? .white : .white.opacity(0.62))
                            .padding(.horizontal, 16)
                            .frame(height: 48)
                            .background {
                                if mode == candidate {
                                    Capsule().fill(.white.opacity(0.14))
                                }
                            }
                    }
                    .buttonStyle(ConsoleButtonStyle())
                    .accessibilityAddTraits(mode == candidate ? [.isSelected] : [])
                }
            }
            Spacer(minLength: 20)
            utilityButton("magnifyingglass", label: "Search", action: onSearch)
            utilityButton("gearshape", label: "Settings", action: onSettings)
            Button {
                showingProfile = true
                mode = .games
                showingGameHub = false
            } label: {
                ZStack(alignment: .bottomTrailing) {
                    Circle()
                        .fill(LinearGradient(colors: [accent, accent.opacity(0.48)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .overlay { Image(systemName: "person.fill").font(.system(size: 18)).foregroundStyle(.white) }
                        .frame(width: 40, height: 40)
                    Circle().fill(Color.green).frame(width: 10, height: 10).overlay(Circle().stroke(.black, lineWidth: 2))
                }
                .padding(.horizontal, 3)
            }
            .buttonStyle(ConsoleButtonStyle())
            .accessibilityLabel("Player profile, online")
            HStack(spacing: 8) {
                Image(systemName: status.batterySymbol)
                if let battery = status.batteryPercent { Text("\(battery)%") }
                Image(systemName: status.networkSymbol)
            }
            .font(.system(size: 13, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.76))
            .accessibilityLabel("\(status.controllerDescription), \(status.networkDescription)")
            TimelineView(.everyMinute) { context in
                Text(context.date, format: .dateTime.hour().minute())
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .padding(.leading, 5)
            }
        }
        .padding(.bottom, 22)
    }

    private func utilityButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 42, height: 42)
                .background(.black.opacity(0.18), in: Circle())
        }
        .buttonStyle(ConsoleButtonStyle())
        .accessibilityLabel(label)
    }

    private var ribbon: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 14) {
                ForEach(ConsoleWelcomeDestination.allCases) { item in
                    let isSelected = destination == item && !showingProfile
                    Button {
                        destination = item
                        showingProfile = false
                        showingGameHub = false
                    } label: {
                        ZStack(alignment: .bottomLeading) {
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .fill(LinearGradient(colors: [item.tint.opacity(0.95), item.tint.opacity(0.45), .black.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing))
                            Image(systemName: item.symbol)
                                .font(.system(size: 32, weight: .light))
                                .foregroundStyle(.white.opacity(0.88))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            Text(item.rawValue)
                                .font(.system(size: 14, weight: .semibold))
                                .lineLimit(1)
                                .padding(.horizontal, 12)
                                .padding(.bottom, 12)
                        }
                        .frame(width: 138, height: 128)
                        .overlay {
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .strokeBorder(isSelected ? .white : .white.opacity(0.13), lineWidth: isSelected ? 2 : 1)
                        }
                        .shadow(color: isSelected ? accent.opacity(0.3) : .clear, radius: 14, y: 5)
                    }
                    .buttonStyle(ConsoleButtonStyle())
                    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                }
                ForEach(games) { game in
                    let isSelected = selectedID == game.id && destination == .welcome && !showingProfile
                    Button {
                        selectedID = game.id
                        destination = .welcome
                        showingProfile = false
                        showingGameHub = true
                    } label: {
                        ConsoleWelcomeGameTile(game: game, selected: isSelected)
                    }
                    .buttonStyle(ConsoleButtonStyle())
                    .accessibilityLabel(game.title)
                    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 4)
        }
        .scrollIndicators(.hidden)
        .padding(.bottom, 12)
    }

    @ViewBuilder private func destinationContent(compact: Bool) -> some View {
        if showingGameHub, let game = selectedGame {
            gameHub(game, compact: compact)
        } else { switch destination {
        case .welcome: welcomePage(compact: compact)
        case .store: editorialPage(title: "PlayStation Store", subtitle: "Discover your next favorite game.", symbol: "bag.fill", cards: ["Featured", "New releases", "Deals for you"])
        case .explore: editorialPage(title: "Explore", subtitle: "News, updates, and stories from your games.", symbol: "sparkles", cards: ["Latest news", "Your weekly roundup", "Community highlights"])
        case .gallery: galleryPage
        case .library: libraryPage
        } }
    }

    private func gameHub(_ game: ConsoleHomeGame, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 26) {
                VStack(alignment: .leading, spacing: 11) {
                    Text(game.badges.joined(separator: "  ·  ").uppercased())
                        .font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(.white.opacity(0.7))
                    Text(game.title).font(.system(size: compact ? 41 : 54, weight: .light)).tracking(-1.4).lineLimit(2)
                    HStack(spacing: 10) {
                        Button { onAction(.play(game.id)) } label: { Label("Play", systemImage: "play.fill") }
                            .buttonStyle(.borderedProminent).tint(accent)
                        Button { onAction(.gameHub(game.id)) } label: { Label("Options", systemImage: "ellipsis") }
                            .buttonStyle(.bordered)
                    }
                }
                Spacer(minLength: 0)
                ConsoleHomeArtwork(paths: game.heroPaths, maxPixelSize: 1300)
                    .frame(maxWidth: compact ? 380 : 530, maxHeight: compact ? 220 : 295)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            HStack(spacing: 14) {
                ConsoleCard(padding: 16) {
                    Label("Trophy Progress", systemImage: "trophy.fill").font(.system(size: 15, weight: .semibold))
                    ProgressView(value: 0.68).tint(accent).padding(.top, 8)
                    Text("68% complete · 14 of 21 trophies").font(.system(size: 12)).foregroundStyle(.white.opacity(0.68)).padding(.top, 4)
                }
                .frame(maxWidth: 280)
                gameInfoCard("Official News", "The latest updates from the developers.", "newspaper.fill")
                gameInfoCard("Add-ons", "Browse downloadable content and updates.", "square.stack.3d.up.fill")
            }
            Spacer(minLength: 0)
            footerPrompts
        }
        .padding(.top, 8)
    }

    private func gameInfoCard(_ title: String, _ detail: String, _ symbol: String) -> some View {
        ConsoleCard(padding: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: symbol).font(.system(size: 15, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.68)).lineLimit(2)
            }
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        }
    }

    private func welcomePage(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 16 : 22) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Good evening")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.68))
                    Text("Welcome back")
                        .font(.system(size: compact ? 39 : 48, weight: .light))
                        .tracking(-1.5)
                }
                Spacer()
                HStack(spacing: 10) {
                    Label("Connected", systemImage: "wifi")
                    Text("•")
                    Label("Online", systemImage: "circle.fill").foregroundStyle(Color.green)
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(.black.opacity(0.2), in: Capsule())
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                dashboardCard("Console Storage", storageAvailable, "externaldrive.fill", detail: "Games, captures, and saved data", progress: 0.62)
                dashboardCard("Controller", status.batteryPercent.map { "\($0)%" } ?? "Ready", status.batterySymbol, detail: status.controllerDescription, progress: status.batteryPercent.map { Double($0) / 100 })
                dashboardCard("Trophy Progress", "Level 18", "trophy.fill", detail: "42% toward next level", progress: 0.42)
                dashboardCard("Friends Online", "3 online", "person.2.fill", detail: "2 playing now · 1 in a party", progress: nil)
            }
            HStack(spacing: 14) {
                if let game = selectedGame {
                    featuredGame(game, compact: compact)
                } else {
                    ConsoleCard(padding: 20) { Label("Add a game to start your collection", systemImage: "plus.circle") }
                }
                ConsoleCard(padding: 20) {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Wishlist", systemImage: "heart.fill").font(.system(size: 17, weight: .semibold))
                        Text("3 games on your wishlist").font(.system(size: 23, weight: .medium))
                        Text("One new offer is waiting for you.").font(.system(size: 14)).foregroundStyle(.white.opacity(0.68))
                        Spacer(minLength: 0)
                        Button { destination = .store } label: { Label("View wishlist", systemImage: "arrow.right") }
                            .buttonStyle(.borderedProminent).tint(accent)
                    }
                    .frame(maxWidth: .infinity, minHeight: compact ? 148 : 184, alignment: .leading)
                }
                .frame(maxWidth: 280)
            }
            footerPrompts
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 8)
    }

    private func dashboardCard(_ title: String, _ value: String, _ symbol: String, detail: String, progress: Double?) -> some View {
        ConsoleCard(cornerRadius: 18, padding: 15) {
            VStack(alignment: .leading, spacing: 10) {
                Label(title, systemImage: symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.73)).lineLimit(1)
                Text(value).font(.system(size: 23, weight: .medium)).lineLimit(1).minimumScaleFactor(0.7)
                Text(detail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                if let progress { ProgressView(value: progress).tint(accent) }
            }
            .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        }
    }

    private func featuredGame(_ game: ConsoleHomeGame, compact: Bool) -> some View {
        ConsoleCard(cornerRadius: 20, padding: 18) {
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Continue playing").font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.65))
                    Text(game.title).font(.system(size: compact ? 24 : 30, weight: .medium)).lineLimit(1)
                    Text(game.badges.joined(separator: "  ·  ")).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.7))
                    Spacer(minLength: 0)
                    HStack(spacing: 9) {
                        Button { onAction(.play(game.id)) } label: { Label("Play", systemImage: "play.fill") }
                            .buttonStyle(.borderedProminent).tint(accent)
                        Button { onAction(.gameHub(game.id)) } label: { Image(systemName: "ellipsis") }
                            .buttonStyle(.bordered).help("Game options")
                    }
                }
                Spacer(minLength: 0)
                ConsoleHomeArtwork(paths: game.heroPaths, maxPixelSize: 720)
                    .frame(width: compact ? 190 : 275, height: compact ? 118 : 148)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .frame(maxWidth: .infinity, minHeight: compact ? 138 : 164, alignment: .leading)
        }
    }

    private var libraryPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            pageHeading("Game Library", subtitle: "Your collection")
            HStack(spacing: 8) {
                pageChip("Your Collection", selected: true)
                pageChip("Installed", selected: false)
                pageChip("PlayStation Plus", selected: false)
                Spacer()
                Label("Sort: Recently played", systemImage: "arrow.up.arrow.down").font(.system(size: 13)).foregroundStyle(.white.opacity(0.7))
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 16)], spacing: 16) {
                    ForEach(games) { game in
                        Button {
                            selectedID = game.id
                            destination = .welcome
                        } label: {
                            VStack(alignment: .leading, spacing: 9) {
                                ConsoleHomeArtwork(paths: game.tilePaths, maxPixelSize: 500)
                                    .frame(height: 150)
                                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                Text(game.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                                Text(game.badges.first ?? "Game").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.62))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(ConsoleButtonStyle())
                    }
                }
            }
        }
        .padding(.top, 8)
    }

    private var galleryPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            pageHeading("Media Gallery", subtitle: "Your screenshots and video clips")
            HStack(spacing: 8) {
                ForEach(["Favorites", "All", "Trophies"], id: \.self) { filter in
                    Button(filter) { galleryFilter = filter }
                        .buttonStyle(.borderedProminent)
                        .tint(galleryFilter == filter ? accent : Color.white.opacity(0.1))
                }
                Spacer()
                Button { } label: { Label("Edit clips", systemImage: "scissors") }.buttonStyle(.bordered)
                Button { } label: { Label("Share", systemImage: "square.and.arrow.up") }.buttonStyle(.bordered)
            }
            if captures.isEmpty {
                ConsoleCard(padding: 26) {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("No captures yet", systemImage: "photo.on.rectangle.angled").font(.system(size: 21, weight: .medium))
                        Text("Screenshots and clips you capture during a session will appear here.")
                            .font(.system(size: 14)).foregroundStyle(.white.opacity(0.68))
                    }
                    .frame(maxWidth: .infinity, minHeight: 125, alignment: .leading)
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 14)], spacing: 14) {
                        ForEach(captures, id: \.path) { capture in
                            ConsoleCard(cornerRadius: 16, padding: 9) {
                                VStack(alignment: .leading, spacing: 8) {
                                    ConsoleHomeArtwork(paths: [capture.path], maxPixelSize: 640).frame(height: 125).clipShape(RoundedRectangle(cornerRadius: 10))
                                    Text(capture.lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(.top, 8)
    }

    private var profilePage: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 20) {
                Circle().fill(LinearGradient(colors: [accent, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 94, height: 94).overlay { Image(systemName: "person.fill").font(.system(size: 36)) }
                VStack(alignment: .leading, spacing: 7) {
                    Text("Player 1").font(.system(size: 39, weight: .light))
                    Label("Online", systemImage: "circle.fill").font(.system(size: 13, weight: .medium)).foregroundStyle(.green)
                    Text("Trophy Level 18 · Member since 2021").font(.system(size: 13)).foregroundStyle(.white.opacity(0.68))
                }
                Spacer()
                Button { showingProfile = false } label: {
                    Label("Back to Home", systemImage: "chevron.left")
                }
                .buttonStyle(.bordered)
            }
            HStack(spacing: 12) {
                trophyCard("Platinum", "4", "trophy.fill", .cyan)
                trophyCard("Gold", "18", "trophy.fill", .yellow)
                trophyCard("Silver", "37", "trophy.fill", .gray)
                trophyCard("Bronze", "112", "trophy.fill", .orange)
            }
            HStack(spacing: 12) {
                ConsoleCard(padding: 20) { Label("About", systemImage: "person.text.rectangle").font(.system(size: 17, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 64, alignment: .leading) }
                ConsoleCard(padding: 20) { Label("Friends", systemImage: "person.2.fill").font(.system(size: 17, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 64, alignment: .leading) }
                ConsoleCard(padding: 20) { Label("Privacy settings", systemImage: "hand.raised.fill").font(.system(size: 17, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 64, alignment: .leading) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 16)
    }

    private func trophyCard(_ title: String, _ count: String, _ symbol: String, _ color: Color) -> some View {
        ConsoleCard(cornerRadius: 18, padding: 17) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: symbol).foregroundStyle(color).font(.system(size: 20))
                Text(count).font(.system(size: 26, weight: .semibold))
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.68))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func editorialPage(title: String, subtitle: String, symbol: String, cards: [String]) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            pageHeading(title, subtitle: subtitle)
            HStack(spacing: 15) {
                ForEach(Array(cards.enumerated()), id: \.offset) { index, title in
                    ConsoleCard(cornerRadius: 22, padding: 18) {
                        VStack(alignment: .leading, spacing: 12) {
                            Image(systemName: symbol).font(.system(size: 28, weight: .light)).foregroundStyle(accent)
                            Text(title).font(.system(size: 20, weight: .medium))
                            Text(index == 0 ? "Selected for you" : "Explore what’s new").font(.system(size: 13)).foregroundStyle(.white.opacity(0.65))
                        }
                        .frame(maxWidth: .infinity, minHeight: 145, alignment: .leading)
                    }
                }
            }
            Spacer()
        }
        .padding(.top, 8)
    }

    private func pageHeading(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 37, weight: .light)).tracking(-0.8)
            Text(subtitle).font(.system(size: 14)).foregroundStyle(.white.opacity(0.66))
        }
    }

    private func pageChip(_ title: String, selected: Bool) -> some View {
        Button(title) { }
            .buttonStyle(.borderedProminent)
            .tint(selected ? accent : Color.white.opacity(0.1))
    }

    private var footerPrompts: some View {
        HStack(spacing: 20) {
            Label("Select", systemImage: "circle.inset.filled")
            Label("Options", systemImage: "ellipsis.circle")
            Spacer()
            Label(status.batteryPercent.map { "Controller \($0)%" } ?? "Controller ready", systemImage: status.batterySymbol).lineLimit(1)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.white.opacity(0.6))
        .padding(.top, 12)
    }
}

private struct ConsoleWelcomeGameTile: View {
    let game: ConsoleHomeGame
    let selected: Bool

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 20, style: .continuous).fill(ConsoleDesign.Palette.panel)
            ConsoleHomeArtwork(paths: game.tilePaths, maxPixelSize: 500)
            LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .center, endPoint: .bottom)
            Text(game.title).font(.system(size: 14, weight: .semibold)).lineLimit(1).padding(12)
        }
        .frame(width: 138, height: 128)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(selected ? .white : .white.opacity(0.13), lineWidth: selected ? 2 : 1) }
    }
}
