import Foundation
import Observation

// MARK: - API-Vergleich (Admin-Tab)
//
// Komplett unabhängig von CrossingViewModel/TrainAPIService.merge — zeigt die drei Datenquellen
// (DB, Geops, MVG) bewusst UNGEMERGT nebeneinander, damit man beurteilen kann welche am
// zuverlässigsten ist. Berührt die fein kalibrierte Produktions-Pipeline nicht.

/// Datenquelle im Admin-Vergleichs-Tab.
enum APISource: String, CaseIterable, Identifiable {
    case db = "DB"
    case geops = "Geops"
    case mvg = "MVG"

    var id: String { rawValue }
}

/// Einheitliche Anzeige-Zeile für alle drei Quellen + die Kombiniert-Seite. Jede Zeile bleibt
/// klar einer einzigen Quelle zugeordnet — anders als in der Produktions-Pipeline gibt es hier
/// keine Quellen-übergreifende Zuordnung/Deduplizierung (siehe combinedRows unten).
struct ComparisonRow: Identifiable {
    let id: String
    let source: APISource
    let lineName: String
    let direction: String?
    let scheduledTime: Date
    let actualTime: Date
    let delayMinutes: Int
    let note: String?
}

@Observable
@MainActor
final class APIComparisonViewModel {

    var selectedCrossing: CrossingLocation = CrossingLocation.all[0] {
        didSet {
            guard oldValue.id != selectedCrossing.id else { return }
            Task { await refresh() }
        }
    }
    /// Steuert NUR combinedRows — die drei Einzel-Listen sind davon unabhängig immer sichtbar.
    var enabledSources: Set<APISource> = Set(APISource.allCases)

    private(set) var dbRows: [ComparisonRow] = []
    private(set) var geopsRows: [ComparisonRow] = []
    private(set) var mvgRows: [ComparisonRow] = []

    private(set) var isLoading = false
    private(set) var dbError: String?
    private(set) var mvgError: String?
    private(set) var lastRefreshAt: Date?

    private let service = TrainAPIService()
    private var refreshTask: Task<Void, Never>?

    /// Einfache Vereinigung der ausgewählten Einzel-Listen, nach Zeit sortiert — bewusst KEINE
    /// Zuordnung/Deduplizierung zwischen Quellen (das übernimmt in der echten App
    /// TrainAPIService.merge/deduplicate, hier soll aber jede Zeile erkennbar von genau einer
    /// Quelle bleiben, damit der Vergleich ehrlich bleibt).
    var combinedRows: [ComparisonRow] {
        var rows: [ComparisonRow] = []
        if enabledSources.contains(.db)    { rows += dbRows }
        if enabledSources.contains(.geops) { rows += geopsRows }
        if enabledSources.contains(.mvg)   { rows += mvgRows }
        return rows.sorted { $0.actualTime < $1.actualTime }
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }

        async let dbFetch = service.fetchDBEntriesRaw(crossing: selectedCrossing)
        async let mvgFetch = service.fetchMVGEntriesRaw(crossing: selectedCrossing)

        do {
            let entries = try await dbFetch
            dbRows = entries.map(Self.row(from:)).sorted { $0.actualTime < $1.actualTime }
            dbError = nil
        } catch {
            dbError = error.localizedDescription
        }

        let departures = await mvgFetch
        mvgRows = departures.map(Self.row(from:)).sorted { $0.actualTime < $1.actualTime }
        mvgError = (departures.isEmpty && selectedCrossing.mvgGlobalId == nil)
            ? "MVG nicht konfiguriert für diesen Übergang"
            : nil

        // .departures(forEva:) liefert Dictionary-Values (Geops-interne Speicherung) — ohne
        // definierte Reihenfolge, deshalb hier explizit sortieren (anders als DB/MVG, die schon
        // näherungsweise zeitlich aus der jeweiligen API kommen).
        geopsRows = GeopsRealtimeService.shared
            .departures(forEva: selectedCrossing.stationEVA)
            .map(Self.row(from:))
            .sorted { $0.actualTime < $1.actualTime }

        lastRefreshAt = Date()
    }

    /// Läuft nur solange der Tab sichtbar ist (siehe APIComparisonView .task/.onDisappear) —
    /// vermeidet unnötige Netzwerklast/MVG-Anfragen im Hintergrund.
    func startAutoRefresh(intervalSeconds: UInt64 = 15) {
        stopAutoRefresh()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(intervalSeconds))
            }
        }
    }

    func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    // MARK: - Mapping auf ComparisonRow

    private static func row(from entry: TrainEntry) -> ComparisonRow {
        ComparisonRow(
            id: entry.id,
            source: .db,
            lineName: entry.lineName,
            direction: entry.direction.label,
            scheduledTime: entry.scheduledTime,
            actualTime: entry.actualTime,
            delayMinutes: entry.delayMinutes,
            note: entry.isCancelled ? "ausgefallen" : entry.platform.map { "Gleis \($0)" }
        )
    }

    private static func row(from stop: GeopsStopDeparture) -> ComparisonRow {
        ComparisonRow(
            id: stop.id,
            source: .geops,
            lineName: stop.lineName,
            direction: stop.inferredDirection?.label,
            scheduledTime: stop.plannedDeparture,
            actualTime: stop.actualDeparture,
            delayMinutes: max(0, stop.delaySec / 60),
            note: "Ziel \(stop.destination) · \(stop.delaySec)s"
        )
    }

    private static func row(from dep: MVGService.Departure) -> ComparisonRow {
        ComparisonRow(
            id: "\(dep.label)_\(Int(dep.scheduledTime.timeIntervalSince1970))_\(dep.destination)",
            source: .mvg,
            lineName: dep.label,
            direction: nil,
            scheduledTime: dep.scheduledTime,
            actualTime: dep.realtimeTime,
            delayMinutes: dep.delayMinutes,
            note: [dep.isRealtime ? "live" : "nur Fahrplan", dep.cancelled ? "ausgefallen" : nil]
                .compactMap { $0 }
                .joined(separator: ", ")
        )
    }
}
