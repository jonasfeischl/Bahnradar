import Foundation

// MARK: - Zugangsdaten
private let dbClientId = "bb2d56302fc6faac8ac204a28a58beda"
private let dbApiKey   = "e77347cdd2f22d6f600a4df38271f4af"

private let stationEVA = "8004158"
private let dbBase     = "https://apis.deutschebahn.com/db-api-marketplace/apis/timetables/v1"

// MARK: - Service

struct TrainAPIService {

    /// Liefert Abfahrten mit echten Ist-Zeiten (Plan + Echtzeit-Änderungen gemergt)
    func fetchDepartures() async throws -> [TrainEntry] {
        let now  = Date()
        let next = now.addingTimeInterval(3600)


        // Plan (aktuelle + nächste Stunde) und Echtzeit-Änderungen parallel laden
        async let batch1   = fetchPlan(for: now)
        async let batch2   = fetchPlan(for: next)
        async let changes  = fetchChanges()

        let (stops1, stops2, changeMap) = try await (batch1, batch2, changes)

        // Duplikate entfernen — selbe Stop-ID kann in beiden Stunden vorkommen
        var seen = Set<String>()
        let allStops = (stops1 + stops2).filter { seen.insert($0.id).inserted }

        // Plan-Stops mit Echtzeit-Daten anreichern
        let result = allStops.compactMap { stop -> TrainEntry? in
            var enriched = stop
            if let change = changeMap[stop.id] {
                enriched.applyChange(change)
            }
            return TrainEntry(from: enriched)
        }
        return result
    }

    // MARK: Plan

    private func fetchPlan(for date: Date) async throws -> [TimetableStop] {
        let url = URL(string: "\(dbBase)/plan/\(stationEVA)/\(date.yyMMdd)/\(date.HH)")!
        let data = try await dbRequest(url)
        return TimetableXMLParser.parse(data: data)
    }

    // MARK: Echtzeit-Änderungen

    /// Gibt ein Dictionary [stopId: ChangeInfo] zurück
    private func fetchChanges() async throws -> [String: ChangeInfo] {
        let url = URL(string: "\(dbBase)/rchg/\(stationEVA)")!
        let data = try await dbRequest(url)
        return ChangesXMLParser.parse(data: data)
    }

    // MARK: HTTP

    private func dbRequest(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(dbClientId, forHTTPHeaderField: "DB-Client-Id")
        request.setValue(dbApiKey,   forHTTPHeaderField: "DB-Api-Key")
        request.setValue("application/xml", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw APIError.httpError(code)
        }
        return data
    }
}

// MARK: - XML: Plan Parser

final class TimetableXMLParser: NSObject, XMLParserDelegate {
    private var stops: [TimetableStop] = []
    private var current: TimetableStop?

    static func parse(data: Data) -> [TimetableStop] {
        let h = TimetableXMLParser()
        let p = XMLParser(data: data)
        p.delegate = h
        p.parse()
        return h.stops
    }

    func parser(_ parser: XMLParser, didStartElement el: String,
                namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
        switch el {
        case "s":  current = TimetableStop(id: a["id"] ?? UUID().uuidString)
        case "dp": current?.dp = DeparturePoint(pt: a["pt"], line: a["l"], path: a["ppth"])
        case "ar": current?.ar = DeparturePoint(pt: a["pt"], line: a["l"], path: a["ppth"])
        case "tl": current?.category = a["c"]; current?.trainNumber = a["n"]
        default:   break
        }
    }

    func parser(_ parser: XMLParser, didEndElement el: String,
                namespaceURI: String?, qualifiedName: String?) {
        if el == "s", let s = current { stops.append(s); current = nil }
    }
}

// MARK: - XML: Changes Parser

final class ChangesXMLParser: NSObject, XMLParserDelegate {
    private var changes: [String: ChangeInfo] = [:]
    private var currentId: String?

    static func parse(data: Data) -> [String: ChangeInfo] {
        let h = ChangesXMLParser()
        let p = XMLParser(data: data)
        p.delegate = h
        p.parse()
        return h.changes
    }

    func parser(_ parser: XMLParser, didStartElement el: String,
                namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
        switch el {
        case "s":
            currentId = a["id"]
        case "dp" where currentId != nil:
            let cancelled = a["cs"] == "c"  // cs="c" bedeutet Ausfall
            changes[currentId!] = ChangeInfo(
                changedTime: a["ct"],
                changedPlatform: a["cp"],
                cancelled: cancelled
            )
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement el: String,
                namespaceURI: String?, qualifiedName: String?) {
        if el == "s" { currentId = nil }
    }
}

// MARK: - Models

struct TimetableStop {
    var id: String
    var dp: DeparturePoint?
    var ar: DeparturePoint?
    var category: String?
    var trainNumber: String?
    // Echtzeit-Felder (nach applyChange befüllt)
    var actualDepartureTime: Date?
    var isCancelled: Bool = false
    var changedPlatform: String?

    mutating func applyChange(_ change: ChangeInfo) {
        isCancelled = change.cancelled
        changedPlatform = change.changedPlatform
        if let ct = change.changedTime {
            actualDepartureTime = DateFormatter.dbTime.date(from: ct)
        }
    }
}

struct DeparturePoint {
    let pt: String?
    let line: String?
    let path: String?
}

struct ChangeInfo {
    let changedTime: String?
    let changedPlatform: String?
    let cancelled: Bool
}

// MARK: - TrainEntry

struct TrainEntry: Identifiable {
    let id: String
    let lineName: String
    let direction: TrainDirection
    let scheduledTime: Date
    let actualTime: Date
    let delayMinutes: Int
    let isCancelled: Bool
    let platform: String?
    /// Hält der Zug an Oberschleißheim oder fährt er durch?
    let stopsAtStation: Bool

    init?(from stop: TimetableStop) {
        guard let dp = stop.dp,
              let pt = dp.pt,
              let planned = DateFormatter.dbTime.date(from: pt) else { return nil }

        let lineRaw = dp.line ?? stop.trainNumber ?? ""

        // Nur S-Bahnen die nicht durch Oberschleißheim fahren herausfiltern
        // Prüfen mit und ohne "S"-Prefix da die API beides liefern kann
        let blockedSBahnen: Set<String> = ["2", "3", "4", "5", "6", "7", "8", "20",
                                           "S2", "S3", "S4", "S5", "S6", "S7", "S8", "S20"]
        guard !blockedSBahnen.contains(lineRaw) else {
            return nil
        }

        // Linienname bestimmen:
        // "1" → "S1", große Zahlen (Fahrtnummern) → "S1", RB/RE bleiben wie sie sind
        let lineName: String
        if lineRaw == "1" {
            lineName = "S1"
        } else if lineRaw.hasPrefix("RB") || lineRaw.hasPrefix("RE") || lineRaw.hasPrefix("IC") {
            lineName = lineRaw  // echten Namen behalten
        } else if let nr = Int(lineRaw), nr > 9 {
            lineName = "S1"     // Fahrtnummer → ist eine S1
        } else {
            lineName = lineRaw.hasPrefix("S") ? lineRaw : "S\(lineRaw)"
        }


        let actual   = stop.actualDepartureTime ?? planned
        let delay    = Int(actual.timeIntervalSince(planned) / 60)

        // S1 hält immer — RE/RB fahren durch
        let stops = lineName == "S1"

        self.id             = stop.id
        self.lineName       = lineName
        self.scheduledTime  = planned
        self.actualTime     = actual
        self.delayMinutes   = max(0, delay)
        self.isCancelled    = stop.isCancelled
        self.platform       = stop.changedPlatform
        self.stopsAtStation = stops
        self.direction      = Self.detectDirection(path: dp.path ?? "")
    }

    private static func detectDirection(path: String) -> TrainDirection {
        let lower = path.lowercased()
        let stops = lower.components(separatedBy: "|")

        // Index von Oberschleißheim im Pfad finden
        let oshIndex = stops.firstIndex(where: { $0.contains("oberschlei") }) ?? -1

        // Nur die Stationen NACH Oberschleißheim prüfen (= Fahrtrichtung)
        let futureStops: [String]
        if oshIndex >= 0 && oshIndex + 1 < stops.count {
            futureStops = Array(stops[(oshIndex + 1)...])
        } else {
            futureStops = stops  // Fallback: ganzen Pfad prüfen
        }

        let freisungKeywords = ["freising", "flughafen", "neufahrn", "pulling", "eching", "lohhof", "unterschlei"]
        let munichKeywords   = ["feldmoching", "münchen", "ostbahnhof", "laim", "pasing", "moosach"]

        if futureStops.contains(where: { s in freisungKeywords.contains { s.contains($0) } }) {
            return .toFreising
        }
        if futureStops.contains(where: { s in munichKeywords.contains { s.contains($0) } }) {
            return .toMunich
        }
        return .toMunich  // Fallback
    }
}

// MARK: - Errors

enum APIError: LocalizedError {
    case httpError(Int)
    var errorDescription: String? {
        switch self {
        case .httpError(401): "Ungültige API-Keys."
        case .httpError(403): "Kein Zugriff – Timetables API abonniert?"
        case .httpError(let c): "API-Fehler (HTTP \(c))."
        }
    }
}

// MARK: - Date Helpers

private extension Date {
    var yyMMdd: String { DateFormatter.yyMMdd.string(from: self) }
    var HH: String     { DateFormatter.HH.string(from: self) }
}

extension DateFormatter {
    static let yyMMdd: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyMMdd"
        f.locale = Locale(identifier: "de_DE"); return f
    }()
    static let HH: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH"; return f
    }()
    static let dbTime: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyMMddHHmm"
        f.locale = Locale(identifier: "de_DE"); return f
    }()
}
