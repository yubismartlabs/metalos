import Foundation
import Combine

struct PlaySession: Codable, Hashable, Sendable {
    var startDate: Date
    var durationSeconds: TimeInterval
}

struct PlaytimeRecord: Codable, Hashable, Sendable {
    var totalSecondsPlayed: TimeInterval = 0
    var lastPlayedDate: Date?
    var launchCount = 0
    var recentSessions: [PlaySession] = []

    var lastSession: PlaySession? { recentSessions.last }
    var weeklySeconds: TimeInterval {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .distantPast
        return recentSessions.filter { $0.startDate >= cutoff }.reduce(0) { $0 + $1.durationSeconds }
    }
}

@MainActor
final class PlaytimeTracker: ObservableObject {
    @Published private(set) var records: [String: PlaytimeRecord]
    let profileID: String

    private let fileURL: URL
    private var activeSessions: [String: Date] = [:]

    init(profileID: String = "player-1", fileURL: URL? = nil) {
        self.profileID = profileID
        let profileComponent = profileID.range(of: #"^[A-Za-z0-9._-]{1,96}$"#, options: .regularExpression) == nil
            ? "player-1" : profileID
        let profileDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MetalOS/Profiles/\(profileComponent)", isDirectory: true)
        self.fileURL = fileURL ?? profileDirectory.appendingPathComponent("playtime.json")
        if let data = try? Data(contentsOf: self.fileURL), let decoded = try? JSONDecoder().decode([String: PlaytimeRecord].self, from: data) {
            records = decoded
        } else {
            records = [:]
        }
    }

    func recordSessionStart(gameId: String) {
        guard activeSessions[gameId] == nil else { return }
        activeSessions[gameId] = .now
        var record = records[gameId] ?? PlaytimeRecord()
        record.launchCount += 1
        record.lastPlayedDate = .now
        records[gameId] = record
        persist()
    }

    func recordSessionEnd(gameId: String) {
        guard let started = activeSessions.removeValue(forKey: gameId) else { return }
        var record = records[gameId] ?? PlaytimeRecord()
        let duration = max(0, Date().timeIntervalSince(started))
        record.totalSecondsPlayed += duration
        record.lastPlayedDate = started
        record.recentSessions.append(PlaySession(startDate: started, durationSeconds: duration))
        if record.recentSessions.count > 30 { record.recentSessions.removeFirst(record.recentSessions.count - 30) }
        records[gameId] = record
        persist()
    }

    func recordAllSessionEnds() {
        for id in Array(activeSessions.keys) { recordSessionEnd(gameId: id) }
    }

    func stats(for gameID: String, fallbackSeconds: TimeInterval = 0, fallbackLastPlayed: Date? = nil) -> PlaytimeRecord {
        if let record = records[gameID] { return record }
        if fallbackSeconds > 0 || fallbackLastPlayed != nil {
            return PlaytimeRecord(totalSecondsPlayed: fallbackSeconds, lastPlayedDate: fallbackLastPlayed,
                launchCount: fallbackSeconds > 0 ? 1 : 0,
                recentSessions: fallbackSeconds > 0 ? [PlaySession(startDate: fallbackLastPlayed ?? .now, durationSeconds: min(fallbackSeconds, 3_600))] : [])
        }
        return Self.previewRecords[gameID] ?? PlaytimeRecord()
    }

    func totalLabel(for gameID: String, fallbackSeconds: TimeInterval = 0) -> String {
        let hours = Int(stats(for: gameID, fallbackSeconds: fallbackSeconds).totalSecondsPlayed / 3_600)
        return "\(hours)h Played"
    }

    func lastPlayedLabel(for gameID: String, fallback: String = "Not played") -> String {
        guard let date = stats(for: gameID).lastPlayedDate else { return "Last Played \(fallback)" }
        let day = Calendar.current.startOfDay(for: date)
        let today = Calendar.current.startOfDay(for: .now)
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)
        let label = day == today ? "Today" : (day == yesterday ? "Yesterday" : date.formatted(date: .abbreviated, time: .omitted))
        return "Last Played \(label)"
    }

    private func persist() {
        let snapshot = records
        let url = fileURL
        Task.detached(priority: .utility) {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: url, options: .atomic)
            } catch { }
        }
    }

    private static let previewRecords: [String: PlaytimeRecord] = [
        "horizon": PlaytimeRecord(totalSecondsPlayed: 42 * 3_600 + 18 * 60, lastPlayedDate: .now, launchCount: 26,
            recentSessions: [PlaySession(startDate: .now.addingTimeInterval(-86_400), durationSeconds: 5_040), PlaySession(startDate: .now.addingTimeInterval(-172_800), durationSeconds: 2_880)]),
        "returnal": PlaytimeRecord(totalSecondsPlayed: 18 * 3_600 + 4 * 60, lastPlayedDate: .now.addingTimeInterval(-86_400), launchCount: 12,
            recentSessions: [PlaySession(startDate: .now.addingTimeInterval(-86_400), durationSeconds: 3_600)]),
        "ghost": PlaytimeRecord(totalSecondsPlayed: 31 * 3_600 + 52 * 60, lastPlayedDate: .now.addingTimeInterval(-4 * 86_400), launchCount: 18),
        "stray": PlaytimeRecord(totalSecondsPlayed: 7 * 3_600 + 26 * 60, lastPlayedDate: .now.addingTimeInterval(-10 * 86_400), launchCount: 9),
        "astro": PlaytimeRecord(totalSecondsPlayed: 5 * 3_600 + 10 * 60, lastPlayedDate: .now.addingTimeInterval(-14 * 86_400), launchCount: 7)
    ]
}
