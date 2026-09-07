import Foundation
import Observation

/// Zentrales In-App-Log für die gesamte Vorhersage-Pipeline (DB-Fetch, Geops-WebSocket,
/// Matching, Zeitberechnung) — sichtbar direkt am Gerät unter Einstellungen → Diagnose,
/// auch ohne angeschlossenes Xcode. Zweck: der Nutzer kann den Log-Text kopieren und
/// direkt weitergeben, um einen gemeldeten Fehler ohne Rückfragen einordnen zu können.
@Observable
final class DebugLog {
    static let shared = DebugLog()

    enum Level: String, Codable {
        case info, warn, error

        var prefix: String {
            switch self {
            case .info:  return ""
            case .warn:  return "⚠️ "
            case .error: return "🛑 "
            }
        }
    }

    struct Entry: Codable, Identifiable {
        let id: UUID
        let date: Date
        let level: Level
        let message: String

        init(date: Date, level: Level, message: String) {
            self.id = UUID(); self.date = date; self.level = level; self.message = message
        }
    }

    private(set) var entries: [Entry] = []
    /// Anzahl warn/error-Einträge seit dem letzten `markSeen()` — für ein Hinweis-Badge in den Einstellungen.
    private(set) var unseenIssueCount: Int = 0

    // War 500 — bei dichtem Polling (Zug < 10min entfernt → alle 10-20s, siehe
    // CrossingViewModel.nextRefreshInterval) erzeugt jeder Zyklus ~30-40 Zeilen ([DB]/[MVG]/
    // [DEDUP]/[CALC]), der Puffer rotierte dadurch schon nach ~3-5 Minuten komplett durch.
    // Genau das hat verhindert, den tatsächlich interessanten Moment (z.B. die ersten Minuten
    // nach App-Start) im exportierten Log zu sehen, wenn erst später exportiert wurde.
    private static let maxEntries = 3000
    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
    private static let persistenceURL: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return dir.appendingPathComponent("debugLog_v1.json")
    }()

    private var lastPersistAt: Date = .distantPast

    private init() {
        loadFromDisk()
    }

    func add(_ message: String, level: Level = .info) {
        let entry = Entry(date: Date(), level: level, message: message)
        entries.append(entry)
        if entries.count > Self.maxEntries { entries.removeFirst(entries.count - Self.maxEntries) }
        if level != .info { unseenIssueCount += 1 }
#if DEBUG
        print("[DebugLog] \(Self.timeFmt.string(from: entry.date)) — \(level.prefix)\(message)")
#endif
        persistThrottled()
    }

    func markSeen() { unseenIssueCount = 0 }

    func clear() {
        entries = []
        unseenIssueCount = 0
        persist()
    }

    /// Formatierter Volltext zum Kopieren/Teilen — neueste Einträge zuerst.
    var exportText: String {
        entries.reversed().map { e in
            "[\(Self.timeFmt.string(from: e.date))] \(e.level.prefix)\(e.message)"
        }.joined(separator: "\n")
    }

    // MARK: - Persistenz (überlebt App-Neustart)

    private func persistThrottled() {
        guard Date().timeIntervalSince(lastPersistAt) > 5 else { return }
        persist()
    }

    private func persist() {
        lastPersistAt = Date()
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: Self.persistenceURL, options: .atomic)
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: Self.persistenceURL),
              let saved = try? JSONDecoder().decode([Entry].self, from: data) else { return }
        entries = saved
    }
}
