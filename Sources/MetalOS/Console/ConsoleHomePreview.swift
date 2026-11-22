import SwiftUI

private struct ConsoleHomePreview: View {
    @State private var tab: ConsoleHomeTab = .games
    @State private var selectedID: String? = "horizon"

    private static let games: [ConsoleHomeGame] = [
        sample("horizon", "Horizon Relay", .metalOSHorizon, ["macOS", "Metal"], "cpu", 8_640),
        sample("descent", "The Last Descent", .godOfReboot, ["PS2", "ARMSX2"], "opticaldisc", 2_880),
        sample("circuit", "Copper Circuit", .superMetalBros, ["Nintendo Switch", "NXNative"], "gamecontroller", nil),
        sample("pilgrim", "Orbit Pilgrim", .blueHorizon, ["Windows", "D3DMetal"], "pc", 21_600)
    ]

    private static func sample(
        _ id: String, _ title: String, _ wallpaper: WallpaperPreset,
        _ badges: [String], _ symbol: String, _ seconds: TimeInterval?
    ) -> ConsoleHomeGame {
        let art = wallpaper.imageURL.map { [$0.path] } ?? []
        return ConsoleHomeGame(
            id: id, title: title, badges: badges, symbol: symbol,
            tilePaths: art, heroPaths: art, lastPlayed: seconds.map { _ in .now },
            playedSeconds: seconds
        )
    }

    var body: some View {
        ConsoleHomeHub(
            games: Self.games, wallpaperPaths: [], accent: Color(red: 0.46, green: 0.72, blue: 1),
            tab: $tab, selectedID: $selectedID, onAction: { _ in }
        ) {
            ConsoleHomeStatusView(status: ConsoleHomeStatus(
                batteryPercent: 82, batterySymbol: "battery.75percent",
                controllerDescription: "Wireless Controller, battery 82 percent",
                networkSymbol: "wifi", networkDescription: "Connected", metalAvailable: true
            ))
        }
    }
}

#Preview("Console Home · 1440 × 900") {
    ConsoleHomePreview().frame(width: 1440, height: 900)
}

#Preview("Console Home · Compact") {
    ConsoleHomePreview().frame(width: 1024, height: 680)
}
