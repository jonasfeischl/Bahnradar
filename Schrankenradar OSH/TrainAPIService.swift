import Foundation

// MARK: - Zugangsdaten DB Timetables

private let dbClientId = "bb2d56302fc6faac8ac204a28a58beda"
private let dbApiKey   = "e77347cdd2f22d6f600a4df38271f4af"
private let dbBase     = "https://apis.deutschebahn.com/db-api-marketplace/apis/timetables/v1"

// MARK: - TrainAPIService

struct TrainAPIService {

    /// Holt Abfahrten für den gewählten Bahnübergang.
    ///
    /// Quellen und Merge-Strategie:
    ///   1. DB Timetables API  → Fahrplan-Basis (90-Minuten-Fenster)
    ///   2. DB Realtime Changes API → offizielle Verspätung (in DB-Daten enthalten)
    ///   3. Geops stopsequence → Live-Abfahrtszeiten pro Haltestelle (haben immer Priorität)
    ///   4. Geops trajectory   → Delay-Fallback für Züge ohne stopsequence-Match
    ///   5. Züge die Geops kennt, DB aber nicht → werden als synthetische TrainEntry hinzugefügt
    func fetchDepartures(crossing: CrossingLocation) async throws -> [TrainEntry] {
        let now   = Date()
        let plus1 = now.addingTimeInterval(3600)
        let plus2 = now.addingTimeInterval(5400)  // +90 Min

        // 1 + 2: DB-Daten parallel laden (aktuelle Stunde + nächste Stunde + übernächste)
        async let batch1  = fetchPlan(for: now,   eva: crossing.stationEVA)
        async let batch2  = fetchPlan(for: plus1, eva: crossing.stationEVA)
        async let batch3  = fetchPlan(for: plus2, eva: crossing.stationEVA)
        async let changes = fetchChanges(eva: crossing.stationEVA)

        let (stops1, stops2, stops3, changeMap) = try await (batch1, batch2, batch3, changes)

        var seenDB = Set<String>()
        let allStops = (stops1 + stops2 + stops3).filter { seenDB.insert($0.id).inserted }

        // DB-Entries mit Change-Daten anreichern
        var dbEntries: [TrainEntry] = allStops.compactMap { stop -> TrainEntry? in
            var enriched = stop
            if let change = changeMap[stop.id] { enriched.applyChange(change) }
            return TrainEntry(from: enriched, onlyS1: crossing.onlyS1)
        }

        // 90-Min-Filter anwenden
        dbEntries = dbEntries.filter { $0.actualTime <= now.addingTimeInterval(5400) }

        // Geops-bestätigte Linien filtern:
        // Sobald Geops mindestens eine Linie für diese Schranke gesehen hat,
        // nur noch bestätigte Linien zeigen. Vorher: alles anzeigen.
        if let confirmed = crossing.confirmedLines, !confirmed.isEmpty {
            let confirmedSet = Set(confirmed)
            dbEntries = dbEntries.filter { confirmedSet.contains($0.lineName) }
        }

        // 3 + 4 + 5: Geops-Daten holen (MainActor)
        let (geopsStops, geopsVehicles) = await MainActor.run {
            (GeopsRealtimeService.shared.departures(forEva: crossing.stationEVA),
             GeopsRealtimeService.shared.vehicles)
        }

        // Merge
        var entries = merge(
            dbEntries: dbEntries,
            geopsStops: geopsStops,
            geopsVehicles: geopsVehicles,
            crossing: crossing
        )

        return entries.sorted { $0.actualTime < $1.actualTime }
    }

    // MARK: - Merge-Logik

    private func merge(dbEntries: [TrainEntry],
                       geopsStops: [GeopsStopDeparture],
                       geopsVehicles: [String: GeopsVehicle],
                       crossing: CrossingLocation) -> [TrainEntry] {

        var result: [TrainEntry] = []
        var matchedGeopsIds = Set<String>()

        // Schritt 1+2: DB-Einträge als Basis, Geops-Zeiten haben Priorität
        for dbEntry in dbEntries {
            if let geopsStop = bestGeopsMatch(for: dbEntry, in: geopsStops) {
                // Geops-Zeit übernehmen
                matchedGeopsIds.insert(geopsStop.tripId)
                let actualTime = geopsStop.actualDeparture
                let updated = dbEntry.with(actualTime: actualTime)
                result.append(updated)
            } else {
                // Kein Geops-stopsequence-Match: trajectory-Delay als Fallback
                var entry = dbEntry
                if let trajDelay = bestTrajectoryDelay(for: dbEntry,
                                                        vehicles: geopsVehicles) {
                    // Nur wenn trajectory mehr Delay zeigt als DB
                    if trajDelay > dbEntry.delayMinutes * 60, trajDelay <= 1800 {
                        let newTime = dbEntry.scheduledTime.addingTimeInterval(Double(trajDelay))
                        entry = dbEntry.with(actualTime: newTime)
                    }
                }
                result.append(entry)
            }
        }

        // Schritt 3: Geops-Züge ohne DB-Match → synthetische TrainEntry
        let now = Date()
        for geopsStop in geopsStops where !matchedGeopsIds.contains(geopsStop.tripId) {
            // Nur Einträge in den nächsten 90 Minuten
            guard geopsStop.actualDeparture >= now,
                  geopsStop.actualDeparture <= now.addingTimeInterval(5400) else { continue }

            // Richtung aus vehicles ableiten falls verfügbar
            let direction = geopsVehicles[geopsStop.tripId]?.computedDirection()
                         ?? geopsStop.inferredDirection
                         ?? .toMunich

            let synthetic = TrainEntry(fromGeopsStop: geopsStop, direction: direction)
            result.append(synthetic)
#if DEBUG
            print("[Geops] Synthetischer Eintrag: \(geopsStop.lineName) " +
                  "tripId=\(geopsStop.tripId) actual=\(geopsStop.actualDeparture)")
#endif
        }

        return result
    }

    /// Sucht den besten Geops-stopDeparture für einen DB-TrainEntry.
    /// Priorität: gleiche Linie + enge Zeitübereinstimmung > nur Zeit.
    private func bestGeopsMatch(for entry: TrainEntry,
                                 in stops: [GeopsStopDeparture]) -> GeopsStopDeparture? {
        let tightTol: TimeInterval = 60    // 1 Minute (gleiche Linie)
        let wideTol:  TimeInterval = 120   // 2 Minuten (Fallback)

        // 1. Gleiche Linie + enge Zeit
        if let exact = stops.first(where: {
            $0.lineName == entry.lineName &&
            abs($0.plannedDeparture.timeIntervalSince(entry.scheduledTime)) < tightTol
        }) { return exact }

        // 2. Gleiche Linie + weite Zeit
        if let loose = stops.first(where: {
            $0.lineName == entry.lineName &&
            abs($0.plannedDeparture.timeIntervalSince(entry.scheduledTime)) < wideTol
        }) { return loose }

        // 3. Nur Zeit (Fallback wenn Linie unbekannt)
        return stops.first {
            abs($0.plannedDeparture.timeIntervalSince(entry.scheduledTime)) < tightTol
        }
    }

    /// Bester Trajectory-Delay für einen DB-TrainEntry aus den Live-Vehicles.
    /// Bevorzugt Fahrzeuge der gleichen Linie in der richtigen Fahrtrichtung.
    private func bestTrajectoryDelay(for entry: TrainEntry,
                                     vehicles: [String: GeopsVehicle]) -> Int? {
        let now = Date()
        guard abs(entry.actualTime.timeIntervalSince(now)) < 900 else { return nil }

        let fresh = vehicles.values.filter { now.timeIntervalSince($0.updatedAt) < 180 }
        guard !fresh.isEmpty else { return nil }

        // Gleiche Linie + gleiche Richtung → höchste Konfidenz
        let byLineDir = fresh.filter {
            $0.lineName == entry.lineName && $0.computedDirection() == entry.direction
        }
        if let best = byLineDir.max(by: { $0.updatedAt < $1.updatedAt }) {
            return best.delaySec
        }

        // Nur Richtung
        let byDir = fresh.filter { $0.computedDirection() == entry.direction }
        let pool  = byDir.isEmpty ? Array(fresh) : byDir
        return pool.max(by: { $0.updatedAt < $1.updatedAt })?.delaySec
    }

    // MARK: - DB API

    private func fetchPlan(for date: Date, eva: String) async throws -> [TimetableStop] {
        let url = URL(string: "\(dbBase)/plan/\(eva)/\(date.yyMMdd)/\(date.HH)")!
        let data = try await dbRequest(url)
        return TimetableXMLParser.parse(data: data)
    }

    private func fetchChanges(eva: String) async throws -> [String: ChangeInfo] {
        let url = URL(string: "\(dbBase)/rchg/\(eva)")!
        let data = try await dbRequest(url)
        return ChangesXMLParser.parse(data: data)
    }

    // MARK: - HTTP

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

    func with(actualTime newTime: Date) -> TrainEntry {
        TrainEntry(
            id: id, lineName: lineName, direction: direction,
            scheduledTime: scheduledTime, actualTime: newTime,
            delayMinutes: max(0, Int(newTime.timeIntervalSince(scheduledTime) / 60)),
            isCancelled: isCancelled, platform: platform, stopsAtStation: stopsAtStation
        )
    }

    // Designated init (privat, alle Felder)
    private init(id: String, lineName: String, direction: TrainDirection,
                 scheduledTime: Date, actualTime: Date, delayMinutes: Int,
                 isCancelled: Bool, platform: String?, stopsAtStation: Bool) {
        self.id = id; self.lineName = lineName; self.direction = direction
        self.scheduledTime = scheduledTime; self.actualTime = actualTime
        self.delayMinutes = delayMinutes; self.isCancelled = isCancelled
        self.platform = platform; self.stopsAtStation = stopsAtStation
    }

    /// Erstellt einen TrainEntry aus einem TimetableStop (DB-Quelle).
    /// Verspätung kommt aus der DB Realtime Changes API.
    /// Geops-Verfeinerung passiert nachgelagert in fetchDepartures().
    init?(from stop: TimetableStop, onlyS1: Bool = true) {
        guard let dp = stop.dp,
              let pt = dp.pt,
              let planned = DateFormatter.dbTime.date(from: pt) else { return nil }

        let lineRaw = dp.line ?? stop.trainNumber ?? ""

        // RB, RE, IC fahren nicht an diesen Übergängen vorbei
        guard !lineRaw.hasPrefix("RB"),
              !lineRaw.hasPrefix("RE"),
              !lineRaw.hasPrefix("IC") else { return nil }

        // Bei onlyS1: andere S-Bahn-Linien filtern
        if onlyS1 {
            let blocked: Set<String> = ["2","3","4","5","6","7","8","20",
                                        "S2","S3","S4","S5","S6","S7","S8","S20"]
            guard !blocked.contains(lineRaw) else { return nil }
        }

        let lineName: String
        if lineRaw == "1" {
            lineName = "S1"
        } else if let nr = Int(lineRaw), nr > 9 {
            lineName = "S1"
        } else {
            lineName = lineRaw.hasPrefix("S") ? lineRaw : "S\(lineRaw)"
        }

        let actual  = stop.actualDepartureTime ?? planned
        let dbDelay = max(0, Int(actual.timeIntervalSince(planned) / 60))

        self.id             = stop.id
        self.lineName       = lineName
        self.scheduledTime  = planned
        self.actualTime     = actual
        self.delayMinutes   = dbDelay
        self.isCancelled    = stop.isCancelled
        self.platform       = stop.changedPlatform
        self.stopsAtStation = lineName == "S1"
        self.direction = Self.detectDirection(
            departurePath: dp.path ?? "",
            arrivalPath:   stop.ar?.path ?? ""
        )
    }

    /// Erstellt einen synthetischen TrainEntry aus einem Geops-StopDeparture.
    /// Wird für Züge verwendet, die Geops kennt, DB aber nicht (im 90-Min-Fenster).
    init(fromGeopsStop stop: GeopsStopDeparture, direction: TrainDirection) {
        self.id             = "geops_\(stop.tripId)"
        self.lineName       = stop.lineName
        self.direction      = direction
        self.scheduledTime  = stop.plannedDeparture
        self.actualTime     = stop.actualDeparture
        self.delayMinutes   = max(0, Int(stop.actualDeparture.timeIntervalSince(stop.plannedDeparture) / 60))
        self.isCancelled    = false
        self.platform       = nil
        self.stopsAtStation = stop.lineName == "S1"
    }

    private static func detectDirection(departurePath: String,
                                        arrivalPath: String) -> TrainDirection {
        let freisungKeywords = ["freising", "flughafen", "neufahrn", "pulling", "eching",
                                "lohhof", "unterschlei", "hallbergmoos"]
        let munichKeywords   = ["feldmoching", "münchen", "ostbahnhof", "laim", "pasing",
                                "moosach", "petershausen", "dachau", "karlsfeld"]

        let depStops = departurePath.lowercased().components(separatedBy: "|")
        if depStops.contains(where: { s in freisungKeywords.contains { s.contains($0) } }) { return .toFreising }
        if depStops.contains(where: { s in munichKeywords.contains   { s.contains($0) } }) { return .toMunich }

        if !arrivalPath.isEmpty {
            let arrStops = arrivalPath.lowercased().components(separatedBy: "|")
            if arrStops.contains(where: { s in munichKeywords.contains   { s.contains($0) } }) { return .toFreising }
            if arrStops.contains(where: { s in freisungKeywords.contains { s.contains($0) } }) { return .toMunich }
        }

        return .toMunich
    }
}

// MARK: - Errors

enum APIError: LocalizedError {
    case httpError(Int)
    var errorDescription: String? {
        switch self {
        case .httpError(401): "Ungültige DB API-Keys."
        case .httpError(403): "Kein Zugriff – DB Timetables API abonniert?"
        case .httpError(let c): "DB API-Fehler (HTTP \(c))."
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
        if let d = _iso8601WithFractional.date(from: string) { return d }
        return _iso8601Standard.date(from: string)
    }

    private static let _iso8601WithFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let _iso8601Standard = ISO8601DateFormatter()
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
