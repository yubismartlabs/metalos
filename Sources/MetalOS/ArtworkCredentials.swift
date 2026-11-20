import Foundation
import LocalAuthentication
import Security
import Combine

@MainActor
final class ArtworkCredentialStore: ObservableObject {
    @Published var igdbClientID = ""
    @Published var igdbClientSecret = ""
    @Published private(set) var message: String?
    private var loaded = false
    private let service = "org.nxstudio.artwork"
    var values: ArtworkCredentials {
        ArtworkCredentials(
            igdbClientID: igdbClientID.trimmingCharacters(in: .whitespacesAndNewlines),
            igdbClientSecret: igdbClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "artwork-providers"]
    }
    func load() {
        guard !loaded else { return }; loaded = true
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        // A development build can have a different Keychain identity from the
        // installed app. Never interrupt launch with a Keychain access dialog.
        let authenticationContext = LAContext()
        authenticationContext.interactionNotAllowed = true
        request[kSecUseAuthenticationContext as String] = authenticationContext
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        guard status != errSecItemNotFound else { return }
        guard status != errSecInteractionNotAllowed else { return }
        guard status == errSecSuccess, let bytes = item as? Data else { message = "Could not load artwork credentials from Keychain."; return }
        do {
            let credentials = try JSONDecoder().decode(ArtworkCredentials.self, from: bytes)
            igdbClientID = credentials.igdbClientID
            igdbClientSecret = credentials.igdbClientSecret
            if credentials.igdbClientID.isEmpty, credentials.igdbClientSecret.isEmpty,
               let legacy = try? JSONDecoder().decode(LegacyArtworkCredentials.self, from: bytes),
               !(legacy.steamGridDBKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                message = "SteamGridDB is no longer used. Enter your IGDB Client ID and Secret to fetch artwork."
            }
        } catch { message = "The saved artwork credentials could not be read. Enter them again to replace them." }
    }
    @discardableResult func save() -> Bool {
        do {
            let bytes = try JSONEncoder().encode(values)
            let update = [kSecValueData as String: bytes]
            var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            if status == errSecItemNotFound {
                var add = query; add[kSecValueData as String] = bytes
                add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
                status = SecItemAdd(add as CFDictionary, nil)
            }
            guard status == errSecSuccess else { message = "Keychain could not save credentials (\(status))."; return false }
            loaded = true; message = "IGDB credentials saved in macOS Keychain."; return true
        } catch { message = "Could not encode artwork credentials."; return false }
    }
    func remove() {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { message = "Keychain could not remove credentials (\(status))."; return }
        igdbClientID = ""; igdbClientSecret = ""; loaded = true
        message = "Saved credentials removed. Cached artwork is still available."
    }
}

private struct LegacyArtworkCredentials: Decodable {
    var steamGridDBKey: String?
}
