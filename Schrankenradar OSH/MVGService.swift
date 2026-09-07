import Foundation
import SwiftUI

/// Zugriff auf die (inoffizielle, aber öffentlich von der MVG-Website genutzte) Abfahrtsmonitor-
/// API unter www.mvg.de — dieselbe Datenquelle, die auch die offizielle MVGO/MVV-App anzeigt.
///
/// Warum eine zweite Quelle neben DB: Live-Vergleich (User, 2026-07-19) zeigte wiederholt, dass
/// die MVV/MVG-Anzeige eine tatsächliche Verspätung korrekt zeigte, während DBs Realtime-Changes-
/// API sie entweder gar nicht meldete oder nach kurzer Zeit kommentarlos wieder auf 0 zurücksetzte
/// (siehe CrossingViewModel.stabilizeDelays-Kommentar). MVG scheint eine unabhängige Datenpipeline
/// zu sein (nicht einfach ein Reexport der DB-Marketplace-API), daher wird sie in TrainAPIService
/// als bevorzugte Verspätungsquelle genutzt, DBs eigene Verspätung bleibt Fallback.
///
/// @Observable statt struct, damit die API-Status-Leiste (ContentView.disclaimer) den
/// Verbindungsstatus direkt anzeigen kann — analog zu GeopsRealtimeService.connectionDisplayColor.
/// MVGService fängt alle Netzwerkfehler intern (siehe TrainAPIService.fetchMVGDepartures) und
/// wirft sonst nie nach oben durch, ohne diesen Zustand gäbe es also keine sichtbare Fehleranzeige.
@Observable
final class MVGService {
    static let shared = MVGService()

    private let base = "https://www.mvg.de/api/bgw-pt/v3"

    private(set) var lastSuccessAt: Date?
    private(set) var lastAttemptFailed: Bool = false

    /// Stabilisierte Anzeige-Farbe: grau = noch nie abgefragt, grün = letzter Versuch
    /// erfolgreich (oder Fehlschlag liegt <20s nach dem letzten Erfolg, kurzer Aussetzer),
    /// rot = anhaltender Fehler.
    var connectionDisplayColor: Color {
        guard let lastSuccessAt else { return .gray }
        if !lastAttemptFailed { return .green }
        if Date().timeIntervalSince(lastSuccessAt) < 20 { return .green }
        return .red
    }

    struct Departure {
        let scheduledTime: Date
        let realtimeTime: Date
        let delayMinutes: Int
        let destination: String
        let label: String
        let cancelled: Bool
        /// true = delayMinutes/realtimeTime kommen von einer echten Live-Meldung, nicht nur vom
        /// unveränderten Fahrplan — nur dann wird der Wert übernommen (sonst wäre ein fehlendes
        /// Live-Signal fälschlich als "pünktlich" interpretiert).
        let isRealtime: Bool
    }

    /// Liefert die nächsten Abfahrten für eine MVG-Stations-ID (Format "de:09184:2000",
    /// ermittelbar über https://www.mvg.de/api/bgw-pt/v3/locations?query=<Stationsname>).
    /// `transportTypes` per curl-Test verifiziert (2026-07-20): "SBAHN" deckt S1 ab, "BAHN" ist
    /// MVGs Typ für Regionalzüge (RE/RB — bestätigt an Feldmoching per RB33 Richtung Landshut,
    /// mit echtem `realtime`/`delayInMinutes`). Kombinierte Query (Komma ODER wiederholter
    /// Parameter) liefert nachweislich NUR den ersten Typ zurück (per curl getestet) — deshalb
    /// zwei getrennte Aufrufe nötig, siehe TrainAPIService.fetchMVGDepartures.
    func fetchDepartures(globalId: String, limit: Int = 20, transportTypes: String = "SBAHN") async throws -> [Departure] {
        var components = URLComponents(string: "\(base)/departures")!
        components.queryItems = [
            URLQueryItem(name: "globalId", value: globalId),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "transportTypes", value: transportTypes)
        ]
        var request = URLRequest(url: components.url!)
        // Ohne einen browserähnlichen User-Agent liefert www.mvg.de teils eine 404-Fehlerseite
        // statt der JSON-Antwort (beobachtet beim Testen der API vor dieser Integration).
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw MVGError.badResponse
            }
            let raw = try JSONDecoder().decode([RawDeparture].self, from: data)
            lastSuccessAt = Date()
            lastAttemptFailed = false
            return raw.compactMap { $0.toDeparture() }
        } catch {
            lastAttemptFailed = true
            throw error
        }
    }

    enum MVGError: Error { case badResponse }

    private struct RawDeparture: Decodable {
        let plannedDepartureTime: Int64
        let realtime: Bool
        let delayInMinutes: Int?
        let realtimeDepartureTime: Int64?
        let transportType: String
        let label: String
        let destination: String
        let cancelled: Bool

        func toDeparture() -> Departure? {
            // Server filtert bereits per transportTypes-Query — dieser Guard ist nur eine
            // zusätzliche Absicherung gegen unerwartete Typen (z.B. BUS), falls die Query mal
            // versehentlich zu weit gefasst wird. SBAHN + BAHN (Regionalzüge), siehe fetchDepartures.
            guard transportType == "SBAHN" || transportType == "BAHN" else { return nil }
            let scheduled = Date(timeIntervalSince1970: Double(plannedDepartureTime) / 1000)
            let realtimeTime = realtimeDepartureTime.map { Date(timeIntervalSince1970: Double($0) / 1000) } ?? scheduled
            return Departure(
                scheduledTime: scheduled,
                realtimeTime: realtimeTime,
                delayMinutes: delayInMinutes ?? 0,
                destination: destination,
                label: label,
                cancelled: cancelled,
                isRealtime: realtime
            )
        }
    }
}
