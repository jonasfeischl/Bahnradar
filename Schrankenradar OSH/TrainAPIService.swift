import Foundation

// MARK: - Zugangsdaten

private let dbClientId = "bb2d56302fc6faac8ac204a28a58beda"
private let dbApiKey   = "e77347cdd2f22d6f600a4df38271f4af"
private let stationEVA = "8004158"
private let dbBase     = "https://apis.deutschebahn.com/db-api-marketplace/apis/timetables/v1"

// MARK: - Haupt-Service

struct TrainAPIService {
    private let transportRest = TransportRestService()

    func fetchDepartures() async throws -> [TrainEntry] {
        let now  = Date()
        let next = now.addingTimeInterval(3600)

        async let batch1   = fetchPlan(for: now)
        async let batch2   = fetchPlan(for: next)
        async let changes  = fetchChanges()
        async let restData = transportRest.fetchDepartureData()

        let (stops1, stops2, changeMap, restMap) =
            try await (batch1, batch2, changes, restData)

        var seen = Set<String>()
        let allStops = (stops1 + stops2).filter { seen.insert($0.id).inserted }

        var entries = allStops.compactMap { stop -> TrainEntry? in
            var enriched = stop
            if let change = changeMap[stop.id] { enriched.applyChange(change) }
            return TrainEntry(from: enriched, restMap: restMap)
        }

        // Für Züge in den nächsten 15 Minuten: letzten Halt vor OSH prüfen
        let toRefine = entries
            .filter {
                let t = $0.actualTime.timeIntervalSinceNow
                return t > -120 && t < 900
            }
            .compactMap { entry -> (String, String)? in
                guard let info = restMap[entry.scheduledTime.roundedToMinute] else { return nil }
                return (entry.id, info.tripId)
            }

        if !toRefine.isEmpty {
            let refined = await withTaskGroup(of: (String, Date?).self) { group -> [String: Date] in
                for (entryId, tripId) in toRefine {
                    group.addTask {
                        let t = await self.transportRest.fetchEstimatedOSHTime(tripId: tripId)
                        return (entryId, t)
                    }
                }
                var result: [String: Date] = [:]
                for await (id, time) in group {
                    if let t = time { result[id] = t }
                }
                return result
            }

            entries = entries.map { entry in
                guard let refined = refined[entry.id] else { return entry }
                // Nur übernehmen wenn Abweichung > 30 Sekunden (Messrauschen vermeiden)
                guard abs(refined.timeIntervalSince(entry.actualTime)) > 30 else { return entry }
                return entry.with(actualTime: refined)
            }
        }

        return entries
    }

    // MARK: Plan

    private func fetchPlan(for date: Date) async throws -> [TimetableStop] {
        let url = URL(string: "\(dbBase)/plan/\(stationEVA)/\(date.yyMMdd)/\(date.HH)")!
        let data = try await dbRequest(url)
        return TimetableXMLParser.parse(data: data)
    }

    // MARK: Echtzeit-Änderungen

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

// MARK: - Transport REST (DB Echtzeit + Trip-Analyse)

struct DepartureInfo {
    let delay: Int      // Minuten
    let tripId: String
}

struct TransportRestService {
    private let stopId  = "8004158"
    private let baseURL = "https://v6.db.transport.rest"

    /// Abfahrten mit Verspätung und TripId — geplante Zeit (auf Minute) als Key
    func fetchDepartureData() async -> [Date: DepartureInfo] {
        guard let url = URL(string: "\(baseURL)/stops/\(stopId)/departures?duration=120&results=100") else { return [:] }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return [:] }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let deps = json["departures"] as? [[String: Any]] else { return [:] }

        var result: [Date: DepartureInfo] = [:]
        for dep in deps {
            guard let plannedStr = dep["plannedWhen"] as? String,
                  let planned    = Date.fromISO8601(plannedStr),
                  let tripId     = dep["tripId"] as? String else { continue }
            let delaySec = dep["delay"] as? Int ?? 0
            let key      = planned.roundedToMinute
            let existing = result[key]
            if existing == nil || delaySec > existing!.delay * 60 {
                result[key] = DepartureInfo(delay: delaySec / 60, tripId: tripId)
            }
        }
        return result
    }

    /// Gibt die geschätzte Abfahrtszeit des Zugs an Oberschleißheim zurück,
    /// berechnet aus dem letzten bekannten Ist-Halt davor.
    func fetchEstimatedOSHTime(tripId: String) async -> Date? {
        let encoded = tripId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? tripId
        guard let url = URL(string: "\(baseURL)/trips/\(encoded)?stopovers=true&polyline=false") else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        // Response kann "trip" als Key haben oder direkt das Objekt sein
        let root = (json["trip"] as? [String: Any]) ?? json
        guard let stopovers = root["stopovers"] as? [[String: Any]] else { return nil }

        // Oberschleißheim im Trip finden
        guard let oshIdx = stopovers.firstIndex(where: { stop in
            guard let s = stop["stop"] as? [String: Any] else { return false }
            let name = (s["name"] as? String ?? "").lowercased()
            let id   = s["id"] as? String ?? ""
            return name.contains("oberschlei") || id == stationEVA
        }) else { return nil }

        let oshStop = stopovers[oshIdx]

        // Fall 1: OSH hat bereits eine Ist-Abfahrtszeit → direkt verwenden
        let oshActualStr = oshStop["departure"] as? String ?? oshStop["when"] as? String
        if let str = oshActualStr, let actual = Date.fromISO8601(str), actual > Date() {
            return actual
        }

        // Fall 2: letzten Halt vor OSH mit Ist-Zeit suchen
        for i in stride(from: oshIdx - 1, through: 0, by: -1) {
            let prev = stopovers[i]
            guard let prevPlannedStr = prev["plannedDeparture"] as? String ?? prev["plannedWhen"] as? String,
                  let prevPlanned    = Date.fromISO8601(prevPlannedStr) else { continue }

            // Nur Halte die der Zug bereits verlassen hat
            let prevActualStr = prev["departure"] as? String ?? prev["when"] as? String
            guard let prevActual = prevActualStr.flatMap({ Date.fromISO8601($0) }),
                  prevActual <= Date() else { continue }

            let delayAtPrev = prevActual.timeIntervalSince(prevPlanned)

            // OSH geplante Abfahrtszeit + Verzögerung vom letzten bekannten Halt
            guard let oshPlannedStr = oshStop["plannedDeparture"] as? String ?? oshStop["plannedWhen"] as? String,
                  let oshPlanned    = Date.fromISO8601(oshPlannedStr) else { return nil }

            return oshPlanned.addingTimeInterval(delayAtPrev)
        }

        return nil
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
            changes[currentId!] = ChangeInfo(
                changedTime: a["ct"],
                changedPlatform: a["cp"],
                cancelled: a["cs"] == "c"
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
    let stopsAtStation: Bool

    /// Gibt eine Kopie mit aktualisierter Ist-Zeit zurück (für Trip-Verfeinerung)
    func with(actualTime newTime: Date) -> TrainEntry {
        TrainEntry(
            id: id, lineName: lineName, direction: direction,
            scheduledTime: scheduledTime, actualTime: newTime,
            delayMinutes: max(0, Int(newTime.timeIntervalSince(scheduledTime) / 60)),
            isCancelled: isCancelled, platform: platform, stopsAtStation: stopsAtStation
        )
    }

    private init(id: String, lineName: String, direction: TrainDirection,
                 scheduledTime: Date, actualTime: Date, delayMinutes: Int,
                 isCancelled: Bool, platform: String?, stopsAtStation: Bool) {
        self.id = id; self.lineName = lineName; self.direction = direction
        self.scheduledTime = scheduledTime; self.actualTime = actualTime
        self.delayMinutes = delayMinutes; self.isCancelled = isCancelled
        self.platform = platform; self.stopsAtStation = stopsAtStation
    }

    init?(from stop: TimetableStop, restMap: [Date: DepartureInfo]) {
        guard let dp = stop.dp,
              let pt = dp.pt,
              let planned = DateFormatter.dbTime.date(from: pt) else { return nil }

        let lineRaw = dp.line ?? stop.trainNumber ?? ""

        let blockedSBahnen: Set<String> = ["2", "3", "4", "5", "6", "7", "8", "20",
                                           "S2", "S3", "S4", "S5", "S6", "S7", "S8", "S20"]
        guard !blockedSBahnen.contains(lineRaw) else { return nil }

        // RB und RE fahren nicht durch Oberschleißheim → herausfiltern
        guard !lineRaw.hasPrefix("RB") && !lineRaw.hasPrefix("RE") && !lineRaw.hasPrefix("IC") else {
            return nil
        }

        let lineName: String
        if lineRaw == "1" {
            lineName = "S1"
        } else if let nr = Int(lineRaw), nr > 9 {
            lineName = "S1"
        } else {
            lineName = lineRaw.hasPrefix("S") ? lineRaw : "S\(lineRaw)"
        }

        let dbActual  = stop.actualDepartureTime ?? planned
        let dbDelay   = max(0, Int(dbActual.timeIntervalSince(planned) / 60))

        // Verspätung aus transport.rest mergen — nur wenn plausibel
        // Max 10 min mehr als DB-Wert und insgesamt max 30 min → verhindert falsche Daten
        let restDelay     = restMap[planned.roundedToMinute]?.delay ?? 0
        let restPlausibel = restDelay <= dbDelay + 10 && restDelay <= 30
        let bestDelay     = restPlausibel ? max(dbDelay, restDelay) : dbDelay
        let actual    = planned.addingTimeInterval(Double(bestDelay) * 60)

        self.id             = stop.id
        self.lineName       = lineName
        self.scheduledTime  = planned
        self.actualTime     = actual
        self.delayMinutes   = bestDelay
        self.isCancelled    = stop.isCancelled
        self.platform       = stop.changedPlatform
        self.stopsAtStation = lineName == "S1"
        self.direction = Self.detectDirection(
            departurePath: dp.path ?? "",
            arrivalPath:   stop.ar?.path ?? ""
        )
    }

    private static func detectDirection(departurePath: String, arrivalPath: String) -> TrainDirection {
        let freisungKeywords = ["freising", "flughafen", "neufahrn", "pulling", "eching",
                                "lohhof", "unterschlei", "hallbergmoos"]
        let munichKeywords   = ["feldmoching", "münchen", "ostbahnhof", "laim", "pasing",
                                "moosach", "petershausen", "dachau", "karlsfeld"]

        // 1. Abfahrtspfad: wo fährt der Zug NACH OSH hin?
        let depStops = departurePath.lowercased().components(separatedBy: "|")
        if depStops.contains(where: { s in freisungKeywords.contains { s.contains($0) } }) { return .toFreising }
        if depStops.contains(where: { s in munichKeywords.contains   { s.contains($0) } }) { return .toMunich }

        // 2. Ankunftspfad: woher kam der Zug VOR OSH? (umgekehrte Logik)
        if !arrivalPath.isEmpty {
            let arrStops = arrivalPath.lowercased().components(separatedBy: "|")
            // Kam von München → fährt nach Freising
            if arrStops.contains(where: { s in munichKeywords.contains   { s.contains($0) } }) { return .toFreising }
            // Kam von Freising → fährt nach München
            if arrStops.contains(where: { s in freisungKeywords.contains { s.contains($0) } }) { return .toMunich }
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

extension Date {
    var roundedToMinute: Date {
        let secs = (timeIntervalSinceReferenceDate / 60).rounded() * 60
        return Date(timeIntervalSinceReferenceDate: secs)
    }

    static func fromISO8601(_ string: String) -> Date? {
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: string) { return d }
        return ISO8601DateFormatter().date(from: string)
    }
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
