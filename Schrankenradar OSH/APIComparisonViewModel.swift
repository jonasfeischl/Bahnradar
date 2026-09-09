import Foundation
import Observation

// MARK: - API-Vergleich (Admin-Tab)
//
// Komplett unabhängig von CrossingViewModel — zeigt die drei Datenquellen (DB, Geops, MVG) auf
// eigenen Seiten roh/ungemergt, damit man beurteilen kann welche am zuverlässigsten ist. Die
// Kombiniert-Seite gleicht die ausgewählten Quellen dagegen WIE im Radar-Tab ab (echte
// Zuordnung/Deduplizierung über TrainAPIService.combineForComparison), zeigt also bewusst etwas
// anderes als die drei Einzel-Seiten. Berührt die fein kalibrierte Produktions-Pipeline
// (CrossingViewModel.buildEvents, Kalman-Offsets, Stabilisierung) nicht — combineForComparison
// nutzt nur die Zuordnungs-/Dedup-Bausteine (merge/deduplicate/bestMVGMatch), nicht die
// Kalibrierung/Glättung.

/// Datenquelle im Admin-Vergleichs-Tab.
enum APISource: String, CaseIterable, Identifiable {
    case db = "DB"
    case geops = "Geops"
    case mvg = "MVG"

    var id: String { rawValue }
}

/// Einheitliche Anzeige-Zeile für alle drei Quellen-Seiten + die Kombiniert-Seite. Auf den drei
/// Einzel-Seiten stammt jede Zeile von genau einer Quelle; auf der Kombiniert-Seite kann eine
/// Zeile bereits mehrere Quellen (DB+Geops+MVG) zusammengeführt darstellen (siehe combinedRows).
struct ComparisonRow: Identifiable {
    let id: String
    let source: APISource
    let lineName: String
    let direction: String?
    let scheduledTime: Date
    let actualTime: Date
    let delayMinutes: Int
    let note: String?
    /// Schranken-Offset in Sekunden (Bahnhofs- → geschätzte Übergangs-Durchfahrtszeit), nil wenn
    /// die Richtung dieser Zeile nicht bekannt ist (z.B. MVG-Zeilen, die kein Richtungsfeld
    /// liefern). Nutzt NUR CrossingLocation.bestOffset (GPS-gelernt/statisch) — bewusst OHNE
    /// Community-Werte (kein JSONBin-Zugriff hier) und OHNE die zusätzliche Feedback-/Hardcode-
    /// Korrektur aus CrossingViewModel.finalOffset, um unabhängig von der Produktions-Pipeline zu
    /// bleiben. Daher nur eine grobe Näherung an die tatsächliche Radar-Tab-Anzeige.
    let offsetSeconds: Double?

    /// `base` (scheduledTime oder actualTime) plus Offset, falls `applyOffset` an ist und ein
    /// Offset bekannt ist — sonst unverändert.
    func crossingTime(_ base: Date, applyOffset: Bool) -> Date {
        guard applyOffset, let offsetSeconds else { return base }
        return base.addingTimeInterval(offsetSeconds)
    }
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
    var enabledSources: Set<APISource> = Set(APISource.allCases) {
        didSet {
            guard oldValue != enabledSources else { return }
            recomputeCombinedRows()
        }
    }

    private(set) var dbRows: [ComparisonRow] = []
    private(set) var geopsRows: [ComparisonRow] = []
    private(set) var mvgRows: [ComparisonRow] = []
    /// Wie im Radar-Tab: ECHTER Abgleich (Zuordnung + Deduplizierung, siehe
    /// TrainAPIService.combineForComparison) aus den oben ausgewählten Quellen — DB dient dabei
    /// zwingend als Anker (wie überall in der Produktions-Pipeline), da bestGeopsMatch/
    /// bestMVGMatch beide auf einen DB-TrainEntry matchen. Ist DB abgewählt, gibt es dafür keine
    /// bestehende Zuordnungslogik zwischen Geops/MVG — dann Fallback auf eine einfache,
    /// unabgeglichene Konkatenation (klar als solche erkennbar, da hier weiterhin jede Zeile nur
    /// von einer Quelle stammt statt einer gemergten).
    ///
    /// BEWUSST ein gespeicherter statt berechneter Wert, nur in refresh()/recomputeCombinedRows()
    /// aktualisiert: eine COMPUTED Property hätte GeopsRealtimeService.shared.vehicles (selbst
    /// @Observable, ändert sich alle paar Sekunden per Live-GPS) bei jedem Lesezugriff live
    /// abgefragt — jede View, die combinedRows liest, wäre dadurch automatisch Beobachter dieser
    /// Live-Daten geworden und hätte bei JEDEM GPS-Update neu gerendert (inkl. vollem
    /// merge/deduplicate-Durchlauf). Bei einer .page-TabView, die alle Seiten im Hintergrund
    /// vorhält, führte das zu einer Dauerschleife aus Re-Renders → beobachteter "Severe Hang"
    /// beim Umschalten (Instruments Time Profiler, 2026-09-09).
    private(set) var combinedRows: [ComparisonRow] = []
    /// Feste Kombination (nicht über enabledSources steuerbar): DB liefert Soll-Zeit + Zug/
    /// Richtung, MVG überlagert wo verfügbar die Verspätung — exakt dieselbe Überlagerung wie
    /// `combinedRows` mit nur DB+MVG ausgewählt (kein Geops), aber als eigene, immer sichtbare
    /// Seite, unabhängig von den Kombiniert-Chips oben.
    private(set) var dbMvgRows: [ComparisonRow] = []

    private(set) var isLoading = false
    private(set) var dbError: String?
    private(set) var mvgError: String?
    private(set) var lastRefreshAt: Date?

    // Rohdaten hinter dbRows/geopsRows/mvgRows — für combinedRows gebraucht, das den echten
    // Abgleich (TrainAPIService.combineForComparison) auf den Original-Typen aufruft statt auf
    // den bereits auf ComparisonRow vereinheitlichten Anzeige-Zeilen. geopsVehiclesRaw ist ein
    // Snapshot aus refresh() (NICHT live gelesen, siehe combinedRows-Kommentar oben).
    private var dbEntries: [TrainEntry] = []
    private var geopsStopsRaw: [GeopsStopDeparture] = []
    private var geopsVehiclesRaw: [String: GeopsVehicle] = [:]
    private var mvgDeparturesRaw: [MVGService.Departure] = []

    private let service = TrainAPIService()
    private var refreshTask: Task<Void, Never>?

    private func recomputeCombinedRows() {
        guard enabledSources.contains(.db) else {
            var rows: [ComparisonRow] = []
            if enabledSources.contains(.geops) { rows += geopsRows }
            if enabledSources.contains(.mvg)   { rows += mvgRows }
            combinedRows = rows.sorted { $0.actualTime < $1.actualTime }
            return
        }
        let merged = service.combineForComparison(
            dbEntries: dbEntries,
            geopsStops: enabledSources.contains(.geops) ? geopsStopsRaw : nil,
            geopsVehicles: geopsVehiclesRaw,
            mvgDepartures: enabledSources.contains(.mvg) ? mvgDeparturesRaw : nil
        )
        combinedRows = merged.map { Self.combinedRow(from: $0, crossing: selectedCrossing) }
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }

        async let dbFetch = service.fetchDBEntriesRaw(crossing: selectedCrossing)
        async let mvgFetch = service.fetchMVGEntriesRaw(crossing: selectedCrossing)

        let crossing = selectedCrossing

        do {
            let entries = try await dbFetch
            dbEntries = entries
            dbRows = entries.map { Self.row(from: $0, crossing: crossing) }.sorted { $0.actualTime < $1.actualTime }
            dbError = nil
        } catch {
            dbEntries = []
            dbError = error.localizedDescription
        }

        let departures = await mvgFetch
        mvgDeparturesRaw = departures
        mvgRows = departures.map { Self.row(from: $0, crossing: crossing) }.sorted { $0.actualTime < $1.actualTime }
        mvgError = (departures.isEmpty && selectedCrossing.mvgGlobalId == nil)
            ? "MVG nicht konfiguriert für diesen Übergang"
            : nil

        // .departures(forEva:)/.vehicles liefern den AKTUELLEN Geops-Stand als einmaliger
        // Snapshot (kein Netz-Call, Daten liegen bereits im Speicher) — bewusst nicht live in
        // combinedRows gelesen, siehe Kommentar dort.
        let stops = GeopsRealtimeService.shared.departures(forEva: selectedCrossing.stationEVA)
        geopsStopsRaw = stops
        geopsRows = stops.map { Self.row(from: $0, crossing: crossing) }.sorted { $0.actualTime < $1.actualTime }
        geopsVehiclesRaw = GeopsRealtimeService.shared.vehicles

        let dbMvgMerged = service.combineForComparison(
            dbEntries: dbEntries, geopsStops: nil, geopsVehicles: [:], mvgDepartures: mvgDeparturesRaw
        )
        dbMvgRows = dbMvgMerged.map { Self.combinedRow(from: $0, crossing: crossing) }

        recomputeCombinedRows()
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

    private static func row(from entry: TrainEntry, crossing: CrossingLocation) -> ComparisonRow {
        ComparisonRow(
            id: entry.id,
            source: .db,
            lineName: entry.lineName,
            direction: entry.direction.label,
            scheduledTime: entry.scheduledTime,
            actualTime: entry.actualTime,
            delayMinutes: entry.delayMinutes,
            note: entry.isCancelled ? "ausgefallen" : entry.platform.map { "Gleis \($0)" },
            offsetSeconds: crossing.bestOffset(toMunich: entry.direction == .toMunich, at: Date())
        )
    }

    /// Für combinedRows: wie row(from:) oben, aber mit einem Hinweis ob Geops den Zug per
    /// Live-GPS bestätigt hat — auf der Kombiniert-Seite ist das (anders als auf der reinen
    /// DB-Seite) eine relevante Zusatzinfo, weil hier tatsächlich mehrere Quellen abgeglichen
    /// wurden.
    private static func combinedRow(from entry: TrainEntry, crossing: CrossingLocation) -> ComparisonRow {
        var noteParts: [String] = []
        if entry.geopsMatchedTripId != nil { noteParts.append("Geops ✓") }
        if entry.isCancelled { noteParts.append("ausgefallen") }
        else if let platform = entry.platform { noteParts.append("Gleis \(platform)") }
        return ComparisonRow(
            id: entry.id,
            source: .db,
            lineName: entry.lineName,
            direction: entry.direction.label,
            scheduledTime: entry.scheduledTime,
            actualTime: entry.actualTime,
            delayMinutes: entry.delayMinutes,
            note: noteParts.isEmpty ? nil : noteParts.joined(separator: ", "),
            offsetSeconds: crossing.bestOffset(toMunich: entry.direction == .toMunich, at: Date())
        )
    }

    private static func row(from stop: GeopsStopDeparture, crossing: CrossingLocation) -> ComparisonRow {
        ComparisonRow(
            id: stop.id,
            source: .geops,
            lineName: stop.lineName,
            direction: stop.inferredDirection?.label,
            scheduledTime: stop.plannedDeparture,
            actualTime: stop.actualDeparture,
            delayMinutes: max(0, stop.delaySec / 60),
            note: "Ziel \(stop.destination) · \(stop.delaySec)s",
            offsetSeconds: stop.inferredDirection.map { crossing.bestOffset(toMunich: $0 == .toMunich, at: Date()) }
        )
    }

    private static func row(from dep: MVGService.Departure, crossing: CrossingLocation) -> ComparisonRow {
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
                .joined(separator: ", "),
            // MVG liefert kein Richtungsfeld — ohne Richtung ist kein Offset (offsetToMunich vs.
            // offsetToFreising sind unterschiedlich) bestimmbar.
            offsetSeconds: nil
        )
    }
}
