import SwiftUI

enum ConsoleGlobalSearchFilter: Int, CaseIterable {
    case all, games, media, settings
    var title: String { ["All", "Games", "Media", "Settings"][rawValue] }
}

struct ConsoleGlobalSearchResult: Identifiable {
    enum Kind: String { case game = "GAME", video = "VIDEO", mediaApp = "MEDIA", setting = "SYSTEM" }
    let id: String
    let kind: Kind
    let title: String
    let subtitle: String
    let symbol: String
    var artworkPath: String? = nil
}

struct ConsoleGlobalSearchView: View {
    @ObservedObject var focus: FocusCoordinator
    @Binding var query: String
    let recentSearches: [String]
    let results: [ConsoleGlobalSearchResult]
    let onResult: (Int) -> Void
    let onKey: (String) -> Void
    let onRecent: (String) -> Void

    @FocusState private var queryFocused: Bool
    private let filters = ConsoleGlobalSearchFilter.allCases

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Rectangle().fill(.black.opacity(0.48))
                Rectangle().fill(.ultraThinMaterial.opacity(0.58))
                VStack(alignment: .leading, spacing: 0) {
                    searchBar
                    if focus.isGlobalSearchKeyboardVisible {
                        virtualKeyboard
                            .padding(.top, 28)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    filterRow.padding(.top, focus.isGlobalSearchKeyboardVisible ? 28 : 34)
                    resultShelf
                        .padding(.top, 28)
                    Spacer(minLength: 0)
                    HStack {
                        Label("Navigate", systemImage: "arrow.up.arrow.down")
                        Label("Select", systemImage: "return")
                        Label("Back", systemImage: "arrow.uturn.backward")
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.top, 22)
                }
                .padding(.horizontal, max(54, proxy.size.width * 0.07))
                .padding(.top, max(40, proxy.safeAreaInsets.top + 34))
                .padding(.bottom, max(32, proxy.safeAreaInsets.bottom + 30))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea()
        .onAppear { queryFocused = true; synchronizeResults() }
        .onChange(of: focus.isGlobalSearchPresented) { _, open in queryFocused = open }
        .onChange(of: results.count) { _, _ in synchronizeResults() }
        .onChange(of: query) { _, _ in synchronizeResults() }
        .onChange(of: recentSearches) { _, _ in synchronizeResults() }
        .animation(ConsoleMotion.zoneSpring, value: focus.globalSearchRegion)
        .animation(ConsoleMotion.zoneSpring, value: focus.isGlobalSearchKeyboardVisible)
    }

    private var searchBar: some View {
        HStack(spacing: 18) {
            Image(systemName: "magnifyingglass").font(.system(size: 25, weight: .regular)).foregroundStyle(.white.opacity(0.78))
            TextField("Search games, media, settings", text: $query)
                .font(.system(size: 27, weight: .regular, design: .rounded))
                .textFieldStyle(.plain)
                .focused($queryFocused)
                .foregroundStyle(.white)
                .tint(.white)
                .onTapGesture { focus.focusGlobalSearchBar() }
                .onChange(of: query) { _, _ in UISoundManager.playFocusMove() }
            if !query.isEmpty {
                Button { query = ""; UISoundManager.playBack() } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 22)).foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
            if !focus.isGlobalSearchKeyboardVisible {
                Button {
                    focus.setGlobalSearchKeyboardVisible(true)
                    UISoundManager.playConfirm()
                } label: {
                    Label("Keyboard", systemImage: "keyboard").font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(.white.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 26)
        .frame(height: 76)
        .background(.ultraThinMaterial.opacity(0.92), in: RoundedRectangle(cornerRadius: 23, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 23, style: .continuous).stroke(.white.opacity(focus.globalSearchRegion == .searchBar ? 0.48 : 0.18), lineWidth: focus.globalSearchRegion == .searchBar ? 2 : 1))
        .shadow(color: focus.globalSearchRegion == .searchBar ? .white.opacity(0.12) : .clear, radius: 22)
    }

    private var virtualKeyboard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("ON-SCREEN KEYBOARD").font(.system(size: 12, weight: .semibold)).tracking(2).foregroundStyle(.white.opacity(0.45))
                Spacer()
                Text("Use the controller to type").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.42))
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: 10), spacing: 9) {
                ForEach(Array(Self.keys.enumerated()), id: \.offset) { index, key in
                    Button { focus.focusGlobalSearchKeyboard(); onKey(key); UISoundManager.playSliderTick() } label: {
                        Text(key == "Space" ? "␠" : key == "Backspace" ? "⌫" : key)
                            .font(.system(size: key.count > 1 ? 13 : 17, weight: .medium, design: .rounded))
                            .frame(maxWidth: .infinity).frame(height: 45)
                            .background(.white.opacity(index == focus.globalSearchKeyboardIndex ? 0.2 : 0.075), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(index == focus.globalSearchKeyboardIndex ? 0.78 : 0.1), lineWidth: index == focus.globalSearchKeyboardIndex ? 2 : 1))
                    }
                    .buttonStyle(.plain)
                    .gridCellColumns(key == "Space" ? 2 : key == "Done" ? 2 : 1)
                }
            }
        }
    }

    private var filterRow: some View {
        HStack(spacing: 12) {
            ForEach(filters, id: \.rawValue) { filter in
                let focused = focus.globalSearchRegion == .filters && focus.globalSearchFilterIndex == filter.rawValue
                let selected = focus.globalSearchFilterIndex == filter.rawValue
                Button {
                    focus.chooseGlobalSearchFilter(filter.rawValue)
                    UISoundManager.playTabSwitch()
                } label: {
                    Text(filter.title)
                        .font(.system(size: 16, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? .white : .white.opacity(0.58))
                        .padding(.horizontal, 22).padding(.vertical, 12)
                        .background(selected ? .white.opacity(0.12) : .clear, in: Capsule())
                        .overlay(Capsule().stroke(.white.opacity(focused ? 0.78 : 0.12), lineWidth: focused ? 2 : 1))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    private var resultShelf: some View {
        VStack(alignment: .leading, spacing: 18) {
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !recentSearches.isEmpty {
                Text("RECENT SEARCHES").font(.system(size: 12, weight: .semibold)).tracking(2).foregroundStyle(.white.opacity(0.5))
                ScrollView(.horizontal) {
                    HStack(spacing: 14) {
                        ForEach(Array(recentSearches.enumerated()), id: \.offset) { index, recent in
                            Button { onRecent(recent) } label: {
                                Label(recent, systemImage: "clock.arrow.circlepath")
                                    .font(.system(size: 15, weight: .medium))
                                    .padding(.horizontal, 20).padding(.vertical, 14)
                                    .background(.white.opacity(0.075), in: Capsule())
                                    .overlay(Capsule().stroke(.white.opacity(focus.globalSearchRegion == .results && focus.globalSearchResultIndex == index ? 0.8 : 0.15), lineWidth: focus.globalSearchRegion == .results && focus.globalSearchResultIndex == index ? 2 : 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            } else if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Search your games, media and system settings.")
                    .font(.system(size: 17, weight: .regular)).foregroundStyle(.white.opacity(0.54)).padding(.top, 10)
            } else if results.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No results found").font(.system(size: 25, weight: .medium, design: .rounded))
                    Text("Try another title or choose a different category.").font(.system(size: 16, weight: .regular)).foregroundStyle(.white.opacity(0.55))
                }
                .padding(.top, 12)
            } else {
                Text("\(results.count) RESULT\(results.count == 1 ? "" : "S")")
                    .font(.system(size: 12, weight: .semibold)).tracking(2).foregroundStyle(.white.opacity(0.5))
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 18) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                                resultCard(item, index: index)
                                    .id(index)
                            }
                        }
                        .padding(.vertical, 12)
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: focus.globalSearchResultIndex) { _, index in
                        withAnimation(ConsoleMotion.ribbonSpring) { proxy.scrollTo(index, anchor: .center) }
                    }
                }
            }
        }
    }

    private func resultCard(_ item: ConsoleGlobalSearchResult, index: Int) -> some View {
        let focused = focus.globalSearchRegion == .results && focus.globalSearchResultIndex == index
        return Button { onResult(index) } label: {
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 17, style: .continuous).fill(LinearGradient(colors: [.white.opacity(0.2), .white.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    if let path = item.artworkPath {
                        ConsoleHomeArtwork(paths: [path], maxPixelSize: 380)
                            .frame(width: 230, height: 112).clipped().clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                    } else {
                        Image(systemName: item.symbol).font(.system(size: 36, weight: .light)).foregroundStyle(.white.opacity(0.88))
                    }
                    VStack { HStack { Text(item.kind.rawValue).font(.system(size: 10, weight: .bold)).tracking(1.3).padding(.horizontal, 9).padding(.vertical, 6).background(.black.opacity(0.42), in: Capsule()); Spacer() }; Spacer() }.padding(10)
                }
                .frame(width: 230, height: 112)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                    Text(item.subtitle).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.57)).lineLimit(1)
                }
                .padding(.horizontal, 3)
            }
            .padding(8)
            .background(.white.opacity(focused ? 0.085 : 0.025), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(.white.opacity(focused ? 0.85 : 0.08), lineWidth: focused ? 2 : 1))
            .shadow(color: focused ? .white.opacity(0.12) : .clear, radius: 20)
            .scaleEffect(focused ? 1.035 : 1)
        }
        .buttonStyle(.plain)
    }

    private func synchronizeResults() {
        let isEmpty = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        focus.setGlobalSearchResultCount(isEmpty ? recentSearches.count : results.count)
    }

    private static let keys = ["Q","W","E","R","T","Y","U","I","O","P","A","S","D","F","G","H","J","K","L","Z","X","C","V","B","N","M","Space","Backspace","Clear","Done"]
}
