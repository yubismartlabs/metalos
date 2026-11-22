import AppKit
import Metal
import SwiftUI

struct ConsoleSystemPage: View {
    @EnvironmentObject var store: LibraryStore
    @ObservedObject var maintenance: ConsoleMaintenance
    @Binding var tab: ConsoleHomeTab
    @ObservedObject var appearance = StudioAppearance.shared
    @ObservedObject var feedback = ConsoleFeedback.shared
    @ObservedObject var preferences = ConsolePreferences.shared

    struct Section: Identifiable {
        var id: String { title }
        let title: String
        let symbol: String
        let rows: [Row]
    }

    struct Row: Identifiable {
        var id: String { key ?? title }
        let title: String
        var key: String? = nil
        var detail: String? = nil
        var value: String? = nil
        var symbol = "circle"
        var enabled = true
        var action: (() -> Void)? = nil
    }

    enum Sheet {
        case choices(String, [Choice])
        case reader(ConsoleUpdateNote)
        case confirm(String, String, String, () -> Void)
        case scanFolder
        case switchKeys
        case wallpaper
        case controllers
    }

    struct Choice: Identifiable {
        let id: String
        let selected: Bool
        let choose: () -> Void
    }

    private enum Focus: Hashable {
        case tab(ConsoleHomeTab), section(String), row(String)
    }
    @FocusState private var focus: Focus?
    @State private var selectedSection: String?
    @State var sheet: Sheet?
    @State private var lastFocus: Focus?

    private var sections: [Section] {
        switch tab {
        case .cores: coreSections
        case .updates: updateSections
        case .customize: customizationSections
        case .settings: settingsSections
        case .games: []
        }
    }
    private var currentSection: Section? {
        sections.first { $0.id == selectedSection } ?? sections.first
    }

    var body: some View {
        GeometryReader { geometry in
            let inset: CGFloat = geometry.size.width < 1200 ? 32 : ConsoleDesign.Space.screenInset
            ZStack {
                ConsoleHomeBackdrop(paths: [], video: nil, accent: appearance.accent)
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if let currentSection {
                        HStack(alignment: .top, spacing: 30) {
                            sidebar
                                .frame(width: geometry.size.width < 1200 ? 248 : 304)
                            controls(currentSection)
                        }
                        .frame(maxHeight: .infinity, alignment: .topLeading)
                    }
                    ConsoleHomePromptBar(confirmTitle: "Select", showsGameOptions: false, backTitle: "Games")
                }
                .padding(.horizontal, inset)
                .padding(.vertical, 20)
            }
        }
        .foregroundStyle(ConsoleDesign.Palette.text)
        .preferredColorScheme(.dark)
        .consoleNavigation { command in
            graph.handle(command, focus: $focus, activate: activate, perform: shortcut)
        }
        .task(id: tab) {
            guard let first = sections.first else { return }
            selectedSection = first.id
            focus = .section(first.id)
        }
        .task(id: store.workspacePath) { await maintenance.refresh(store) }
        .onChange(of: focus) { _, next in
            if let next { lastFocus = next }
            if case .section(let id) = next { selectedSection = id }
        }
        .onChange(of: currentSection?.rows.filter(\.enabled).map(\.id)) { _, _ in
            if let focus, !graph.enabled.contains(focus) { self.focus = graph.entry }
        }
        .onChange(of: maintenance.requirementsConfirmation, initial: true) { _, requested in
            if requested {
                sheet = .confirm(
                    "Install NXNative requirements?",
                    "MetalOS will install the supported dependencies required to build Switch games.",
                    "Install Requirements"
                ) { maintenance.confirmRequirements(store) }
            }
        }
        .onChange(of: maintenance.requirementsHelp, initial: true) { _, requested in
            if requested {
                sheet = .reader(.init(title: "NXNative requirements", body: requirementsText))
                maintenance.requirementsHelp = false
            }
        }
        .consolePage(
            isPresented: Binding(get: { sheet != nil }, set: { if !$0 { sheet = nil } }),
            onDismiss: {
                maintenance.requirementsConfirmation = false
                focus = graph.restoredFocus(lastFocus)
            }
        ) {
            if let sheet { sheetContent(sheet) }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("MetalOS")
                .font(.system(size: 21, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                ForEach(ConsoleHomeTab.allCases, id: \.self) { candidate in
                    let target = Focus.tab(candidate)
                    Button { changeTab(candidate) } label: {
                        Text(candidate.rawValue)
                            .font(.system(size: 17, weight: candidate == tab ? .semibold : .medium))
                            .foregroundStyle(candidate == tab ? ConsoleDesign.Palette.text : ConsoleDesign.Palette.secondaryText)
                            .padding(.horizontal, 12)
                            .frame(minHeight: ConsoleDesign.Space.minimumControlHeight)
                            .background(alignment: .bottom) {
                                if candidate == tab {
                                    Capsule().fill(appearance.accent).frame(width: 24, height: 3).padding(.bottom, 5)
                                }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(ConsoleButtonStyle())
                    .focusable()
                    .focused($focus, equals: target)
                    .focusEffectDisabled()
                    .consoleFocusEffect(focus == target && sheet == nil, accent: appearance.accent)
                    .accessibilityAddTraits(candidate == tab ? [.isSelected] : [])
                }
            }
            .padding(4)
            .background(.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            Spacer(minLength: 0)
            ConsoleLiveHomeStatus()
        }
    }

    private var sidebar: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(tab.rawValue)
                        .font(ConsoleDesign.Typography.title)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(sections) { section in
                        let target = Focus.section(section.id)
                        FocusableButton(id: target, focus: $focus, isScopeActive: sheet == nil,
                                        accent: appearance.accent, horizontalPadding: 14,
                                        action: { activate(target) }) {
                            HStack(spacing: 10) {
                                Image(systemName: section.symbol)
                                    .foregroundStyle(section.id == currentSection?.id ? appearance.accent : .secondary)
                                    .frame(width: 24)
                                Text(section.title).lineLimit(2)
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .accessibilityAddTraits(section.id == currentSection?.id ? [.isSelected] : [])
                        .id(target)
                    }
                }
                .padding(8)
            }
            .scrollIndicators(.hidden)
            .onChange(of: focus) { _, next in
                if let next, case .section = next { proxy.scrollTo(next, anchor: .center) }
            }
        }
    }

    private func controls(_ section: Section) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(section.title).font(ConsoleDesign.Typography.heading).accessibilityAddTraits(.isHeader)
                    if [.updates, .cores].contains(tab), let live = maintenance.liveStatus {
                        ConsoleCard(padding: 14) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(live).font(ConsoleDesign.Typography.metadata)
                                if let progress = maintenance.progress { ProgressView(value: progress).tint(appearance.accent) }
                                else { ProgressView().controlSize(.small) }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    ForEach(section.rows) { row in
                        if let action = row.action {
                            FocusableButton(id: .row(row.id), focus: $focus, isScopeActive: sheet == nil,
                                            accent: appearance.accent, horizontalPadding: 16, action: action) {
                                rowLabel(row, actionable: true)
                            }
                            .disabled(!row.enabled)
                            .id(Focus.row(row.id))
                        } else {
                            ConsoleCard(cornerRadius: ConsoleDesign.Radius.control, padding: 16) {
                                rowLabel(row, actionable: false)
                            }
                        }
                    }
                }
                .padding(8)
                .id(section.id)
            }
            .scrollIndicators(.hidden)
            .onChange(of: section.id) { _, id in proxy.scrollTo(id, anchor: .top) }
            .onChange(of: focus) { _, next in
                if let next, case .row = next {
                    withAnimation(feedback.pageAnimation) { proxy.scrollTo(next, anchor: .center) }
                }
            }
        }
    }

    private func rowLabel(_ row: Row, actionable: Bool) -> some View {
        HStack(spacing: 14) {
            Image(systemName: row.symbol).foregroundStyle(appearance.accent)
                .frame(width: 26).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(row.title).font(ConsoleDesign.Typography.action)
                if let detail = row.detail {
                    Text(detail).font(.system(size: 16)).foregroundStyle(ConsoleDesign.Palette.secondaryText)
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 8)
            if let value = row.value {
                Text(value)
                    .font(ConsoleDesign.Typography.metadata)
                    .foregroundStyle(ConsoleDesign.Palette.secondaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 224, alignment: .trailing)
            }
            if actionable { Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)) }
        }
        .padding(.vertical, actionable ? 10 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var graph: GamepadNavigationManager<Focus> {
        let tabIDs = ConsoleHomeTab.allCases.map { Focus.tab($0) }
        let sectionIDs = sections.map { Focus.section($0.id) }
        let active = currentSection.map { Focus.section($0.id) }
        let rowIDs = currentSection?.rows.compactMap { $0.action != nil && $0.enabled ? Focus.row($0.id) : nil } ?? []
        var links = consoleGridNeighbors([tabIDs])
        links.merge(consoleGridNeighbors(sectionIDs.map { [$0] })) { previous, _ in previous }
        links.merge(consoleGridNeighbors(rowIDs.map { [$0] })) { previous, _ in previous }
        for id in tabIDs { links[id, default: [:]][.down] = active }
        if let first = sectionIDs.first { links[first, default: [:]][.up] = .tab(tab) }
        for id in sectionIDs { links[id, default: [:]][.right] = rowIDs.first }
        for id in rowIDs { links[id, default: [:]][.left] = active }
        if let first = rowIDs.first { links[first, default: [:]][.up] = .tab(tab) }
        return .init(entry: active, enabled: Set(tabIDs + sectionIDs + rowIDs), neighbors: links)
    }

    private func activate(_ target: Focus) {
        switch target {
        case .tab(let tab): changeTab(tab)
        case .section(let id):
            selectedSection = id
            if let row = sections.first(where: { $0.id == id })?.rows.first(where: { $0.enabled && $0.action != nil }) {
                focus = .row(row.id)
            }
        case .row(let id):
            if let row = currentSection?.rows.first(where: { $0.id == id && $0.enabled }) { row.action?() }
        }
    }

    private func shortcut(_ command: ConsoleCommand) {
        switch command {
        case .back: changeTab(.games)
        case .previousTab: changeTab(tab.offset(by: -1))
        case .nextTab: changeTab(tab.offset(by: 1))
        case .guide: GameOverlayController.shared.toggle()
        default: break
        }
    }

    private func changeTab(_ destination: ConsoleHomeTab) {
        if tab == destination, let currentSection { focus = .section(currentSection.id) }
        else { tab = destination }
    }

    @ViewBuilder
    private func sheetContent(_ sheet: Sheet) -> some View {
        switch sheet {
        case .choices(let title, let choices):
            ConsoleSystemSheet(title: title, choices: choices)
        case .reader(let note):
            ConsoleSystemSheet(title: note.title, note: note)
        case .confirm(let title, let description, let label, let action):
            ConsoleSystemSheet(title: title, note: .init(title: title, body: description),
                               choices: [.init(id: label, selected: false, choose: action)])
        case .scanFolder:
            ConsoleFilePicker(title: "Add a Scan Folder", mode: .directory, startingPath: store.workspacePath) {
                let selected = $0.standardizedFileURL.path
                if selected != store.workspacePath && !store.data.settings.scanRoots.contains(selected) {
                    store.data.settings.scanRoots.append(selected)
                    store.save()
                }
            }
        case .switchKeys:
            ConsoleFilePicker(title: "Choose Your Switch Keys File", mode: .file, startingPath: store.workspacePath,
                              allowedExtensions: ["keys"]) {
                guard NXBuildEnvironment.isKeysFile($0.path) else {
                    store.notice = "Choose a readable Switch keys file."
                    return
                }
                store.data.settings.keysPath = $0.path
                store.save()
            }
        case .wallpaper:
            ConsoleFilePicker(title: "Choose a Background", mode: .file, startingPath: store.workspacePath,
                              allowedExtensions: ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp", "mov", "mp4", "m4v", "qt"]) {
                store.importConsoleWallpaper($0)
            }
        case .controllers:
            ControllerStatusView()
        }
    }
}

private struct ConsoleSystemSheet: View {
    let title: String
    var note: ConsoleUpdateNote? = nil
    var choices: [ConsoleSystemPage.Choice] = []
    @Environment(\.consolePageClose) private var close
    @FocusState private var focus: String?
    @State private var page = 0
    @State private var viewingRelease = false

    private let backID = "console.modal.back"
    private let releaseID = "console.modal.release"
    private let previousID = "console.modal.previous"
    private let nextID = "console.modal.next"

    private var pages: [String] {
        guard let note else { return [] }
        let lines = note.body.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .flatMap { line -> [String] in
                if line.isEmpty { return [""] }
                let text = String(line)
                var chunks: [String] = []
                var index = text.startIndex
                while index < text.endIndex {
                    let end = text.index(index, offsetBy: 76, limitedBy: text.endIndex) ?? text.endIndex
                    chunks.append(String(text[index..<end]))
                    index = end
                }
                return chunks
            }
        return stride(from: 0, to: lines.count, by: 13).map { lines[$0..<min($0 + 13, lines.count)].joined(separator: "\n") }
    }

    private var ids: [String] {
        [backID] + choices.map(\.id) + (pages.count > 1 ? [previousID, nextID] : []) + (note?.url == nil ? [] : [releaseID])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            button(backID, "Back")
            Text(title).font(ConsoleDesign.Typography.title).accessibilityAddTraits(.isHeader)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if !pages.isEmpty {
                            ConsoleCard {
                                Text(pages[min(page, pages.count - 1)])
                                    .font(ConsoleDesign.Typography.metadata)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                        }
                        ForEach(choices) { choice in
                            button(choice.id, choice.id, selected: choice.selected).id(choice.id)
                        }
                        if pages.count > 1 {
                            HStack(spacing: 14) {
                                button(previousID, "Previous Page").id(previousID)
                                button(nextID, "Next Page").id(nextID)
                                Text("\(page + 1) / \(pages.count)").font(ConsoleDesign.Typography.metadata)
                            }
                        }
                        if note?.url != nil { button(releaseID, "Open Release Page").id(releaseID) }
                    }
                    .padding(8)
                }
                .onChange(of: focus) { _, target in if let target { proxy.scrollTo(target, anchor: .center) } }
            }
            HStack(spacing: 20) {
                HStack { ConsolePromptGlyph(control: .confirm, fallbackLabel: "↵"); Text("Select") }
                HStack { ConsolePromptGlyph(control: .back, fallbackLabel: "Esc"); Text("Back") }
            }
            .font(ConsoleDesign.Typography.metadata)
            .foregroundStyle(ConsoleDesign.Palette.secondaryText)
        }
        .padding(30)
        .frame(maxWidth: 1000, maxHeight: .infinity, alignment: .topLeading)
        .consoleNavigation { command in
            let rows = ids.map { [$0] }
            let router = GamepadNavigationManager(entry: backID, enabled: Set(ids), neighbors: consoleGridNeighbors(rows))
            router.handle(command, focus: $focus, activate: activate) { command in
                switch command {
                case .back: close()
                case .previousTab: page = max(page - 1, 0)
                case .nextTab: page = min(page + 1, max(0, pages.count - 1))
                default: break
                }
            }
            if command == .move(.left) { page = max(page - 1, 0) }
            if command == .move(.right) { page = min(page + 1, max(0, pages.count - 1)) }
        }
        .task { focus = choices.first(where: \.selected)?.id ?? backID }
        .consolePage(isPresented: $viewingRelease, onDismiss: { focus = releaseID }) {
            if let url = note?.url { ConsoleReleaseBrowser(url: url, onClose: { viewingRelease = false }) }
        }
    }

    private func button(_ id: String, _ title: String, selected: Bool = false) -> some View {
        FocusableButton(id: id, focus: $focus, action: { activate(id) }) {
            HStack {
                Text(title)
                if selected { Image(systemName: "checkmark.circle.fill") }
            }
        }
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func activate(_ id: String) {
        switch id {
        case backID: close()
        case previousID: page = max(page - 1, 0)
        case nextID: page = min(page + 1, max(0, pages.count - 1))
        case releaseID:
            if let url = note?.url, url.scheme == "https", url.host == "github.com" { viewingRelease = true }
        default:
            if let choice = choices.first(where: { $0.id == id }) { close(); choice.choose() }
        }
    }
}

private struct ConsoleReleaseBrowser: View {
    @StateObject private var session: InAppBrowserSession
    let onClose: () -> Void

    init(url: URL, onClose: @escaping () -> Void) {
        _session = StateObject(wrappedValue: InAppBrowserSession(startingAt: url))
        self.onClose = onClose
    }

    var body: some View {
        InAppBrowserView(session: session, close: onClose, closeTitle: "Changelog", showAddressBar: false)
    }
}
