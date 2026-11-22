import AppKit

enum WallpaperPreset: String, CaseIterable, Equatable {
    case blueHorizon = "blue-horizon"
    case superMetalBros = "super-metal-bros"
    case metalOSHorizon = "metalos-horizon"
    case godOfReboot = "god-of-reboot"

    private static let storagePrefix = "builtin-wallpaper:"

    var title: String {
        switch self {
        case .blueHorizon: "MetalOS Blue Horizon"
        case .superMetalBros: "Super Metal Bros. · Green Edition"
        case .metalOSHorizon: "MetalOS Horizon"
        case .godOfReboot: "God of Reboot · The Crash"
        }
    }

    private var resourceName: String {
        switch self {
        case .blueHorizon: "MetalOS-Default-Wallpaper"
        case .superMetalBros: "Wallpaper-Super-Metal-Bros"
        case .metalOSHorizon: "Wallpaper-MetalOS-Horizon"
        case .godOfReboot: "Wallpaper-God-of-Reboot"
        }
    }

    private var fileExtension: String { self == .blueHorizon ? "png" : "jpg" }

    var imageURL: URL? {
        Bundle.module.url(forResource: resourceName, withExtension: fileExtension)
    }

    static func fromStorageValue(_ value: String?) -> WallpaperPreset? {
        guard let value, value.hasPrefix(storagePrefix) else { return nil }
        return WallpaperPreset(rawValue: String(value.dropFirst(storagePrefix.count)))
    }

    var storageValue: String? {
        self == .blueHorizon ? nil : Self.storagePrefix + rawValue
    }
}
