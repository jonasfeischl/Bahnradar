import Foundation
import SwiftUI

// MARK: - Geops Vehicle (trajectory-Kanal)

struct GeopsVehicle {
    let tripId: String
    let lineName: String
    let lat: Double
    let lon: Double
    let prevLat: Double?
    let prevLon: Double?
    let updatedAt: Date
    var inferredDirection: TrainDirection?
    // Rohe Trajektorie der aktuellen Nachricht — nur für die eng begrenzte
    // Live-Durchfahrtszeit-Korrektur in liveCrossingTime(tripId:crossing:) genutzt.
    let rawCoords: [[Double]]
    let timeIntervals: [[Any]]

    func computedDirection() -> TrainDirection? {
        if let dir = inferredDirection { return dir }
        guard let pLat = prevLat, let pLon = prevLon else { return nil }
        let dLat = lat - pLat
        let dLon = lon - pLon
        guard abs(dLat) > 0.00003 || abs(dLon) > 0.00003 else { return nil }
        return dLat < 0 ? .toMunich : .toFreising
    }
}

// MARK: - Geops Stop Departure (stopsequence-Kanal)

struct GeopsStopDeparture: Identifiable {
    let id: String
    let tripId: String
    let lineName: String
    let destination: String
    let plannedDeparture: Date
    let actualDeparture: Date
    let delaySec: Int
    var inferredDirection: TrainDirection?
    let updatedAt: Date
}

// MARK: - Pending Detection

private struct PendingDetection {
    let tripId: String
    let crossingId: String
    let passageTime: Date
    let toMunich: Bool
    let lineName: String
    let addedAt: Date = Date()
}

// MARK: - Geops Realtime Service

@Observable
@MainActor
final class GeopsRealtimeService {

    static let shared = GeopsRealtimeService()

    // MARK: Verbindungsstatus

    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected(trainCount: Int)
        case error(String)

        var label: String {
            switch self {
            case .disconnected:     return "Getrennt"
            case .connecting:       return "Verbinde…"
            case .connected(let n): return n > 0 ? "Verbunden · \(n) Züge" : "Verbunden"
            case .error:            return "Fehler"
            }
        }

        var color: Color {
            switch self {
            case .disconnected: return .secondary
            case .connecting:   return .orange
            case .connected:    return .green
            case .error:        return .red
            }
        }

        var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }
    }

    // MARK: Öffentlicher Zustand

    private(set) var connectionState: ConnectionState = .disconnected {
        didSet {
            if case .connected = connectionState { lastConnectedAt = Date() }
        }
    }
    private var lastConnectedAt: Date?
    private(set) var vehicles: [String: GeopsVehicle] = [:]
    private(set) var stopDepartures: [String: [String: GeopsStopDeparture]] = [:]

    /// Stabilisierte Anzeige-Farbe: zeigt während kurzer Reconnects (≤ 20s nach letztem
    /// Verbunden-Status) weiter Grün statt grau/rot zu flackern.
    var connectionDisplayColor: Color {
        if connectionState.isConnected { return .green }
        if let last = lastConnectedAt, Date().timeIntervalSince(last) < 20 {
            return .green   // kurzer Aussetzer → weiter als verbunden anzeigen
        }
        return connectionState.color
    }

    /// Geschätzte Durchfahrt für Nicht-S-Bahn-Züge (Güterzüge, RB, RE…)
    /// Schlüssel = "crossingId_tripId" (NICHT nur crossingId — sonst überschreibt ein zweiter
    /// gleichzeitig anfahrender RB/RE-Zug am selben Übergang den ersten, und einer der beiden
    /// verschwindet aus der Liste. Mit tripId im Schlüssel werden mehrere Nicht-S-Bahn-Züge am
    /// selben Übergang gleichzeitig gehalten, genau wie es für S-Bahn-Züge schon funktioniert).
    /// Werden wie normale Züge behandelt (echte Richtung + Name).
    struct FreightApproach {
        let crossingId: String
        let tripId: String
        let crossingTime: Date
        let lineName: String
        let toMunich: Bool
        let updatedAt: Date
    }
    private(set) var freightApproaches: [String: FreightApproach] = [:]

    // MARK: Privat

    private var wsTask: URLSessionWebSocketTask?
    private var pingTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectDelay: Double = 5

    private var subscribedTrips: Set<String> = []
    private var measuredPassages: Set<String> = []
    private var pendingDetections: [PendingDetection] = []
    // Begrenzt die Diagnose-Logs für nicht gefundene Stationszuordnungen (z.B. Oberschleißheim)
    // auf die ersten paar Treffer pro EVA, damit das Debug-Log nicht zuspammt.
    private var stopMatchFailureLogCount: [String: Int] = [:]
    private var lastNearMissLog: [String: Date] = [:]
    private var trajectoryUpdateCount = 0
    private var nonSBahnLastPos: [String: (lat: Double, lon: Double, updatedAt: Date)] = [:]
    // Bestätigungszähler pro "tripId_crossingId" — Approach erst ab 2 Treffern gültig
    private var nonSBahnConfirm: [String: Int] = [:]
    // Throttle (max. alle 60s pro Übergang) für die beiden Diagnose-Logs unten —
    // Nicht-S-Bahn-Annäherung ist sonst deutlich häufiger als der S-Bahn-Near-Miss-Log.
    private var lastNonSBahnRangeLog: [String: Date] = [:]
    private var lastNonSBahnGeometryMissLog: [String: Date] = [:]

    // MARK: - Robuste Richtungserkennung (pro Trip eingerastet)
    //
    // Ein einzelnes GPS-Delta (aktueller Punkt − letzter Punkt) ist anfällig für Rauschen,
    // Kurven im Streckenverlauf und Stillstand am Bahnsteig → die Richtung konnte pro Zug
    // zwischen Updates flackern. Stattdessen: sobald eine Richtung mit ausreichender
    // Konfidenz bestimmt wurde, wird sie für die gesamte Sichtbarkeit des Trips "eingerastet"
    // und nicht mehr neu berechnet.
    private var confirmedDirections: [String: TrainDirection] = [:]
    private var firstSeenPosition: [String: (lat: Double, lon: Double, at: Date)] = [:]

    /// Liefert die Zielrichtung aus der Stopsequence (Zieldestination des ganzen Trips) —
    /// das zuverlässigste verfügbare Signal, weil es für die komplette Fahrt gilt und nicht
    /// von einzelnen GPS-Punkten abhängt.
    private func destinationDirection(tripId: String) -> TrainDirection? {
        for perStation in stopDepartures.values {
            if let dep = perStation[tripId] { return dep.inferredDirection }
        }
        return nil
    }

    /// Zentrale Richtungsauflösung für S-Bahn UND Nicht-S-Bahn-Züge.
    /// Priorität: 1) bereits eingerastete Richtung  2) Stopsequence-Zieldestination
    /// 3) GPS-Nettobewegung seit der ersten gesehenen Position (>25m, filtert Jitter)
    /// 4) Einzel-Delta zum letzten Punkt (alte Methode, nur als letzter Ausweg).
    private func resolveDirection(tripId: String,
                                   prevLat: Double?, prevLon: Double?,
                                   lat: Double, lon: Double) -> TrainDirection? {
        // Zieldestination hat immer Vorrang — überschreibt ggf. eine vorläufige GPS-Sperre,
        // sobald die Stopsequence-Antwort (etwas später) eintrifft.
        if let destDir = destinationDirection(tripId: tripId) {
            confirmedDirections[tripId] = destDir
            return destDir
        }

        if let locked = confirmedDirections[tripId] { return locked }

        if let first = firstSeenPosition[tripId] {
            let movedMeters = haversineMeters(lat1: first.lat, lon1: first.lon, lat2: lat, lon2: lon)
            if movedMeters > 25 {
                let dir: TrainDirection = lat < first.lat ? .toMunich : .toFreising
                confirmedDirections[tripId] = dir
                return dir
            }
        } else {
            firstSeenPosition[tripId] = (lat: lat, lon: lon, at: Date())
        }

        guard let pLat = prevLat, let pLon = prevLon else { return nil }
        let dLat = lat - pLat, dLon = lon - pLon
        guard abs(dLat) > 0.00003 || abs(dLon) > 0.00003 else { return nil }
        return dLat < 0 ? .toMunich : .toFreising
    }

    /// Räumt Richtungs-Caches für Trips auf, die nicht mehr aktiv verfolgt werden.
    private func pruneDirectionCaches(activeTripIds: Set<String>) {
        confirmedDirections = confirmedDirections.filter { activeTripIds.contains($0.key) }
        firstSeenPosition   = firstSeenPosition.filter   { activeTripIds.contains($0.key) }
    }

    // Drosselung für .geopsDataChanged — verhindert Event-Rebuild-Sturm bei vielen Updates
    private var lastDataChangeNotify = Date.distantPast

    // Diagnose: einmalig das rohe time_intervals-Format loggen (klärt ob [i][1]
    // ein Vertex-Index, Stop-Index oder 0–1-Streckenanteil ist).
    private var didLogSampleIntervals = false

    /// Postet .geopsDataChanged (max. alle 3s) → CrossingViewModel baut Events sofort neu.
    /// Damit erscheinen frische Geops-Daten ohne dass der Nutzer den Tab wechseln muss.
    /// Gedrosselt (max alle 3s) — für häufige Trajectory-Updates.
    private func notifyDataChangedThrottled() {
        guard Date().timeIntervalSince(lastDataChangeNotify) > 3 else { return }
        notifyDataChangedImmediate(source: "Trajektorie")
    }

    /// Sofort, ohne Throttle — für Stopsequence-Updates unserer Stationen.
    /// Stopsequence ist das kritische Event das den Geops-Match ermöglicht.
    /// Es darf NICHT vom Trajectory-Throttle geblockt werden.
    private func notifyDataChangedImmediate(source: String = "Stopsequence") {
        lastDataChangeNotify = Date()
#if DEBUG
        print("[Geops] → .geopsDataChanged gepostet (\(source))")
#endif
        NotificationCenter.default.post(name: .geopsDataChanged, object: nil)
    }

    private let apiKey = "5cc87b12d7c5370001c1d655e67b22d1967d4799a6d23b1e92b9e24a"

    // EPSG:3857 Bounding Box: S1-Korridor München ↔ Flughafen
    // Entspricht WGS84: [11.40, 48.12, 11.85, 48.40]
    private let bboxCmd = "BBOX 1269042 6126841 1319135 6173660 14 mots=rail"

    // Station-Namen für Stop-Matching (Name → EVA). Die EVAs waren früher fälschlich
    // "8004158"/"8004159" (falsche Stationen) — korrekt laut DB-API-Stationssuche:
    // Oberschleißheim = 8004580, München-Feldmoching = 8004147.
    private static let knownStationNames: [String: [String]] = [
        "8004580": ["oberschleißheim", "oberschleissheim"],
        "8004147": ["feldmoching", "münchen-feldmoching", "munich-feldmoching",
                    "muenchen-feldmoching"]
    ]
    private var stationNames: [String: [String]]

    private init() {
        var result = Self.knownStationNames
        for crossing in CrossingLocation.all {
            let eva = crossing.stationEVA
            guard result[eva] == nil else { continue }
            let sub   = crossing.subtitle.lowercased()
            let ascii = sub.folding(options: [.diacriticInsensitive], locale: .current)
            result[eva] = [sub, ascii].filter { !$0.isEmpty }
        }
        stationNames = result
    }

    // MARK: - Verbindung

    func connect() {
        guard wsTask == nil else {
#if DEBUG
            print("[Geops] connect() übersprungen — wsTask läuft bereits")
#endif
            return
        }
        reconnectTask?.cancel()
        connectionState = .connecting

        guard let url = URL(string: "wss://api.geops.io/tracker-ws/v1/?key=\(apiKey)") else {
            connectionState = .error("URL ungültig"); return
        }

#if DEBUG
        print("[Geops] connect() → öffne WebSocket")
#endif
        wsTask = URLSession.shared.webSocketTask(with: url)
        wsTask?.resume()
        sendTrajectorySubscription()
        receiveLoop()
        startPing()
    }

    func disconnect() {
        reconnectTask?.cancel()
        pingTask?.cancel()
        wsTask?.cancel(with: .normalClosure, reason: nil)
        wsTask = nil
        pingTask = nil
        vehicles = [:]
        stopDepartures = [:]
        freightApproaches = [:]
        nonSBahnLastPos = [:]
        nonSBahnConfirm = [:]
        subscribedTrips = []
        measuredPassages = []
        pendingDetections = []
        connectionState = .disconnected
        reconnectDelay = 5
    }

    // MARK: - Öffentliche Abfragen

    func departures(forEva eva: String) -> [GeopsStopDeparture] {
        Array((stopDepartures[eva] ?? [:]).values)
    }

    /// true wenn für diesen Trip gerade eine frische (< 90s) Live-GPS-Position vorliegt —
    /// rein informativ für das "Live-GPS bestätigt"-Badge, beeinflusst NICHT die angezeigte
    /// Zeit (die kommt ausschließlich von der DB, siehe TrainAPIService).
    func hasFreshVehicle(tripId: String) -> Bool {
        guard let vehicle = vehicles[tripId] else { return false }
        return Date().timeIntervalSince(vehicle.updatedAt) < 90
    }

    /// Ergebnis einer Live-GPS-Interpolation: Zeitpunkt + wie nah die Trajektorie am
    /// Übergang vorbeikam (Konfidenz-Maß) + wie alt die zugrunde liegende Position ist.
    struct LiveCrossingEstimate {
        let time: Date
        let distanceMeters: Double
        let vehicleAgeSeconds: Double
    }

    /// Live aus der GPS-Trajektorie interpolierte Durchfahrtszeit für einen Trip an einem
    /// Übergang, falls eine frische (< 90s) Position vorliegt. Das ist die einzige Quelle mit
    /// Sekundengenauigkeit (die DB-Fahrplandaten sind strukturell nur minutengenau) — wird von
    /// CrossingViewModel deshalb als PRIMÄRE Zeit übernommen, sobald verfügbar, statt nur als
    /// eng geklemmte Korrektur der DB-Zeit. Das 140m-Distanz-Gate filtert Fehlzuordnungen auf
    /// Parallelgleisen aus; `distanceMeters` wird zusätzlich fürs Debug-Log durchgereicht.
    func liveCrossingEstimate(tripId: String, crossing: CrossingLocation) -> LiveCrossingEstimate? {
        guard let vehicle = vehicles[tripId] else { return nil }
        let age = Date().timeIntervalSince(vehicle.updatedAt)
        guard age < 90 else { return nil }

        let crossingX: Double = crossing.longitude * 20037508.34 / 180.0
        let crossingLatRad: Double = Double.pi / 4 + crossing.latitude * Double.pi / 360
        let crossingY: Double = log(tan(crossingLatRad)) * 6378137.0

        guard let result = interpolatedTime(targetX: crossingX, targetY: crossingY,
                                            rawCoords: vehicle.rawCoords,
                                            timeIntervals: vehicle.timeIntervals,
                                            maxMeters: 140) else { return nil }
        return LiveCrossingEstimate(time: result.time, distanceMeters: result.distanceMeters,
                                     vehicleAgeSeconds: age)
    }

    // MARK: - Subscriptions (Text-Protokoll)

    private func sendTrajectorySubscription() {
        wsTask?.send(.string(bboxCmd)) { _ in }
#if DEBUG
        print("[Geops] → BBOX subscription: \(bboxCmd)")
#endif
    }

    private func sendStopsequenceSubscription(tripId: String) {
        guard !subscribedTrips.contains(tripId) else { return }
        subscribedTrips.insert(tripId)
        wsTask?.send(.string("GET stopsequence_\(tripId)")) { _ in }
        wsTask?.send(.string("SUB stopsequence_\(tripId)")) { _ in }
#if DEBUG
        print("[Geops] → SUB stopsequence_\(tripId)")
#endif
    }

    // MARK: - Empfangsloop

    private func receiveLoop() {
        wsTask?.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.wsTask != nil else { return }
                switch result {
                case .success(let msg):
                    if case .string(let text) = msg { await self.handleMessage(text) }
                    self.receiveLoop()
                case .failure(let err):
                    self.handleDisconnect(reason: err.localizedDescription)
                }
            }
        }
    }

    /// Parsing läuft nonisolated (Hintergrund-Thread) — bei einem Schub an Trajectory-
    /// Nachrichten kurz nach Verbindungsaufbau blockierte das synchrone JSONSerialization
    /// sonst den Main Thread mehrfach hintereinander (siehe Instruments: Hang-Cluster
    /// kurz nach App-Start).
    nonisolated private static func parseJSON(_ text: String) async -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func handleMessage(_ text: String) async {
#if DEBUG
        print("[Geops] ← \(text.prefix(400))")
#endif
        guard let root = await Self.parseJSON(text) else { return }

        let source = root["source"] as? String ?? ""

        // Verbindungs-Bestätigung vom Server
        if source == "websocket" {
            if let content = root["content"] as? [String: Any],
               content["status"] as? String == "open" {
                reconnectDelay = 5   // erfolgreiche Verbindung → Backoff zurücksetzen
                if case .connecting = connectionState {
                    connectionState = .connected(trainCount: 0)
                    DebugLog.shared.add("[GEOPS] ✓ verbunden (WebSocket 'open')")
                }
            }
            return
        }

        if source == "trajectory" {
            handleTrajectoryMessage(root)
        } else if source.hasPrefix("stopsequence_") {
            let tripId = String(source.dropFirst("stopsequence_".count))
            handleStopsequenceMessage(root, forTripId: tripId)
        }
    }

    // MARK: - Trajectory-Parsing (neues Format)

    private func handleTrajectoryMessage(_ root: [String: Any]) {
        let content = root["content"] as? [String: Any] ?? root
        guard let props = content["properties"] as? [String: Any] else { return }

        // Linienname aus verschachteltem line-Objekt
        let lineObj  = props["line"] as? [String: Any]
        let lineRaw  = lineObj?["name"] as? String ?? ""
        guard !lineRaw.isEmpty else { return }

        let tripId = props["train_id"] as? String ?? ""
        guard !tripId.isEmpty else { return }

        // Aktuelle Position aus EPSG:3857-Geometrie interpolieren
        let geometry      = content["geometry"] as? [String: Any]
        let rawCoords     = geometry?["coordinates"] as? [[Double]] ?? []
        let timeIntervals = props["time_intervals"] as? [[Any]] ?? []

#if DEBUG
        // Einmalige Format-Diagnose: zeigt Roh-time_intervals + Vertex-Anzahl.
        // Damit lässt sich klären, ob time_intervals[i][1] ein Vertex-Index ist
        // (dann ist die Progress-Berechnung korrekt) oder ein 0–1-Streckenanteil.
        if !didLogSampleIntervals, timeIntervals.count >= 3, rawCoords.count >= 3 {
            didLogSampleIntervals = true
            let second = timeIntervals.prefix(5).map { entry -> String in
                guard entry.count > 1 else { return "—" }
                return "\(type(of: entry[1]))=\(entry[1])"
            }
            print("[Geops][DIAG] line=\(lineRaw) vertices=\(rawCoords.count) " +
                  "intervals=\(timeIntervals.count) maxIndexSlot=[\(second.joined(separator: ", "))]")
            print("[Geops][DIAG] firstEntry=\(timeIntervals.first ?? []) lastEntry=\(timeIntervals.last ?? [])")
        }
#endif
        let (lat, lon)    = currentPosition(rawCoords: rawCoords, timeIntervals: timeIntervals)
        guard lat != 0, lon != 0 else { return }

        // Nicht-S-Bahn (Güterzug, RB, RE…): nur auf Übergangs-Annäherung prüfen. ICE/IC/EC/WB
        // ausgeschlossen — fahren laut Vor-Ort-Beobachtung nicht über diese Übergänge (andere
        // Strecke), genau wie im DB-Zweig in TrainAPIService.
        guard lineRaw.uppercased().hasPrefix("S") else {
            let excluded: Set<String> = ["ICE", "IC", "EC", "WB"]
            if !excluded.contains(lineRaw.uppercased()) {
                detectNonSBahnApproach(tripId: tripId, lineName: lineRaw, rawCoords: rawCoords,
                                       timeIntervals: timeIntervals, lat: lat, lon: lon)
            }
            return
        }

        let previous = vehicles[tripId]

        let resolvedDirection = resolveDirection(tripId: tripId,
                                                  prevLat: previous?.lat, prevLon: previous?.lon,
                                                  lat: lat, lon: lon)

        let vehicle = GeopsVehicle(
            tripId:    tripId,
            lineName:  lineRaw,
            lat:       lat,
            lon:       lon,
            prevLat:   previous?.lat,
            prevLon:   previous?.lon,
            updatedAt: Date(),
            inferredDirection: resolvedDirection,
            rawCoords: rawCoords,
            timeIntervals: timeIntervals
        )
        vehicles[tripId] = vehicle

        let cutoff = Date().addingTimeInterval(-300)
        vehicles = vehicles.filter { $0.value.updatedAt > cutoff }
        pruneDirectionCaches(activeTripIds: Set(vehicles.keys).union(nonSBahnLastPos.keys))
        connectionState = .connected(trainCount: vehicles.count)

        // WICHTIG: Auch Trajektorien-Updates (Live-GPS-Position → Durchfahrtszeit +
        // Live-Verspätung) müssen ein Event-Rebuild auslösen. Früher tat das nur der
        // Stopsequence-Handler → GPS-Daten kamen erst beim fetchData/Tab-Wechsel.
        // Gedrosselt auf 3s, damit die vielen Trajektorien-Nachrichten nicht spammen.
        notifyDataChangedThrottled()

        sendStopsequenceSubscription(tripId: tripId)

        // Periodisches Cleanup
        trajectoryUpdateCount += 1
        if trajectoryUpdateCount % 100 == 0 {
            let activeTrips = Set(vehicles.keys)
            measuredPassages = measuredPassages.filter { key in
                activeTrips.contains(where: { key.hasPrefix($0) })
            }
            subscribedTrips = subscribedTrips.intersection(activeTrips)
        }

        // Crossing-Erkennung
        guard let prev = previous else { return }
        let moved = haversineMeters(lat1: prev.lat, lon1: prev.lon, lat2: lat, lon2: lon)
        guard moved > 10, moved < 5000 else { return }
        detectCrossingPassage(current: vehicle, previous: prev)
    }

    // MARK: - Position aus Trajectory interpolieren

    private func currentPosition(rawCoords: [[Double]], timeIntervals: [[Any]]) -> (Double, Double) {
        guard !rawCoords.isEmpty else { return (0, 0) }

        if timeIntervals.isEmpty {
            return mercatorToWGS84(rawCoords[0][0], rawCoords[0][1])
        }

        let nowMs = Date().timeIntervalSince1970 * 1000.0
        let sorted = parseTimeIntervals(timeIntervals)

        guard !sorted.isEmpty else {
            return mercatorToWGS84(rawCoords[0][0], rawCoords[0][1])
        }

        if nowMs <= sorted.first!.ts {
            return mercatorToWGS84(rawCoords[0][0], rawCoords[0][1])
        }
        if nowMs >= sorted.last!.ts {
            let c = rawCoords.last!
            return mercatorToWGS84(c[0], c[1])
        }

        for i in 0..<(sorted.count - 1) {
            let t1 = sorted[i].ts, t2 = sorted[i+1].ts
            let p1 = sorted[i].progress, p2 = sorted[i+1].progress
            guard t1 <= nowMs, nowMs <= t2 else { continue }
            let frac     = (nowMs - t1) / max(1, t2 - t1)
            let progress = p1 + frac * (p2 - p1)
            // Sub-Index-Interpolation: zwischen zwei benachbarten Koordinaten interpolieren
            let fidx = progress * Double(rawCoords.count - 1)
            let lo   = min(Int(fidx), rawCoords.count - 2)
            let hi   = lo + 1
            let t    = fidx - Double(lo)
            let x    = rawCoords[lo][0] + t * (rawCoords[hi][0] - rawCoords[lo][0])
            let y    = rawCoords[lo][1] + t * (rawCoords[hi][1] - rawCoords[lo][1])
            return mercatorToWGS84(x, y)
        }

        return mercatorToWGS84(rawCoords[0][0], rawCoords[0][1])
    }

    // MARK: - EPSG:3857 → WGS84

    private func mercatorToWGS84(_ x: Double, _ y: Double) -> (Double, Double) {
        let lat = (2.0 * atan(exp(y / 6378137.0)) - .pi / 2.0) * 180.0 / .pi
        let lon = x / 20037508.34 * 180.0
        return (lat, lon)
    }

    // MARK: - Stopsequence-Parsing (neues Format)

    private func handleStopsequenceMessage(_ root: [String: Any], forTripId tripId: String) {
        // content kann ein Array von Trip-Objekten ODER ein einzelnes Objekt sein
        let tripData: [String: Any]
        if let arr = root["content"] as? [[String: Any]], let first = arr.first {
            tripData = first
        } else if let single = root["content"] as? [String: Any] {
            tripData = single
        } else {
#if DEBUG
            print("[Geops][StopSeq] \(tripId): content nicht parsierbar – \(String(describing: root["content"]).prefix(120))")
#endif
            return
        }

        let lineObj  = tripData["line"] as? [String: Any]
        let lineName = vehicles[tripId]?.lineName
                    ?? lineObj?["name"] as? String
                    ?? "S1"
        let destination = tripData["destination"] as? String ?? ""

        let stops: [[String: Any]] = (tripData["stations"] as? [[String: Any]])
                                  ?? (tripData["stops"]    as? [[String: Any]])
                                  ?? []
        guard !stops.isEmpty else { return }

        var didUpdateDeparture = false
        for (evaId, names) in stationNames {
            guard let stop = findStop(in: stops, evaId: evaId, names: names) else {
                logStopMatchFailureIfNeeded(evaId: evaId, tripId: tripId, stops: stops)
                continue
            }

            // Zeiten: mehrere Feldnamen probieren (API-Versionen nutzen camelCase oder snake_case)
            let plannedMs = msValue(stop["aimedDepartureTime"])
                         ?? msValue(stop["aimed_departure_time"])
                         ?? msValue(stop["plannedDepartureTime"])
                         ?? msValue(stop["departure"])
            guard let plannedMs else {
#if DEBUG
                print("[Geops][StopSeq] \(tripId) EVA \(evaId): kein aimedDepartureTime – keys=\(stop.keys.sorted())")
#endif
                continue
            }
            let actualMs = msValue(stop["departureTime"])
                        ?? msValue(stop["actual_departure_time"])
                        ?? msValue(stop["realtime_departure"])
                        ?? plannedMs

            let planned = Date(timeIntervalSince1970: plannedMs / 1000.0)
            let actual  = Date(timeIntervalSince1970: actualMs  / 1000.0)

            // departureDelay: manche API-Versionen liefern Sekunden, andere Millisekunden.
            // WICHTIG: abs() für den Schwellwert-Check verwenden — ein Zug, der zu früh ist,
            // hat einen NEGATIVEN Rohwert, und "rawDelay > 3600" ist für negative Zahlen immer
            // false, selbst wenn der Rohwert eigentlich Millisekunden waren. Das führte zu
            // absurden Anzeigen wie "delay=-540000s" (statt korrekt -540s = 9 Min. zu früh).
            let rawDelay = (stop["departureDelay"] as? Int) ?? (stop["departure_delay"] as? Int) ?? 0
            let delaySec = abs(rawDelay) > 3600 ? rawDelay / 1000 : rawDelay

            // Plausibilitäts-Check: eine S-Bahn mit >30 Minuten Verspätung gibt es praktisch
            // nie — ein solcher Wert bedeutet fast immer, dass geOps dieses GPS-Signal
            // fälschlich mit einer falschen/alten Fahrplan-Instanz verknüpft hat ("Trip-
            // Drift"), nicht dass der Zug wirklich so verspätet ist. VERFRÜHUNG (negativer
            // delay) ist noch enger begrenzt: Dispatcher halten Züge planmäßig zurück, ein
            // S-Bahn fährt so gut wie nie mehrere Minuten VOR Fahrplan. Beobachtet wurde
            // sogar dieselbe Fahrt innerhalb weniger Sekunden abwechselnd mit delay=0 und
            // delay=-600s ("Flackern") — klares Zeichen für Trip-Drift statt echter
            // Verfrühung.
            //
            // WICHTIG: Trotzdem NICHT den ganzen Stop verwerfen (continue) — das ließ einen
            // Zug komplett aus der Liste verschwinden, wenn seine EINZIGE bisher empfangene
            // Meldung schon den unplausiblen Wert hatte (kein früherer guter Wert zum
            // Zurückfallen vorhanden). Stattdessen: Verspätung auf 0 setzen und die
            // Fahrplanzeit verwenden — der Zug bleibt sichtbar (nur ohne Live-Korrektur),
            // statt komplett zu fehlen. Kalman-Filter/Anzeige bekommen so nie den
            // unplausiblen Wert, aber der Zug selbst geht nicht verloren.
            let plausible = delaySec >= -180 && delaySec <= 1800
            if !plausible {
                DebugLog.shared.add("[GEOPS] Unplausibler delay=\(delaySec)s für \(lineName) (Trip \(tripId), EVA \(evaId)) — auf Fahrplanzeit zurückgefallen", level: .warn)
            }
            let safeDelay  = plausible ? delaySec : 0
            let safeActual = plausible ? actual   : planned

            let departure = GeopsStopDeparture(
                id:               tripId,
                tripId:           tripId,
                lineName:         lineName,
                destination:      destination,
                plannedDeparture: planned,
                actualDeparture:  safeActual,
                delaySec:         safeDelay,
                inferredDirection: inferDirection(from: destination),
                updatedAt:        Date()
            )

            if stopDepartures[evaId] == nil { stopDepartures[evaId] = [:] }
            stopDepartures[evaId]![tripId] = departure
            didUpdateDeparture = true

#if DEBUG
            print("[Geops] stopsequence: EVA \(evaId) ← \(lineName) planned=\(planned) delay=\(delaySec)s")
#endif
        }

        // Relevante S-Bahn-Abfahrt für UNSERE Station aktualisiert → SOFORT Rebuild,
        // ohne Throttle. Das ist das kritische Event das den Geops-Match ermöglicht
        // und darf nicht vom Trajectory-Throttle geblockt werden.
        if didUpdateDeparture { notifyDataChangedImmediate() }

        processPendingDetections(for: tripId)

        let cutoff = Date().addingTimeInterval(-5400)
        for evaId in stopDepartures.keys {
            stopDepartures[evaId] = stopDepartures[evaId]?.filter { $0.value.updatedAt > cutoff }
        }
    }

    private func msValue(_ any: Any?) -> Double? {
        let raw: Double?
        if let d = any as? Double, d > 0 { raw = d }
        else if let i = any as? Int, i > 0 { raw = Double(i) }
        else if let s = any as? String {
            // Geops liefert manchmal ISO-8601-Strings statt Unix-Timestamps
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: s) { return d.timeIntervalSince1970 * 1000.0 }
            f.formatOptions = [.withInternetDateTime]
            if let d = f.date(from: s) { return d.timeIntervalSince1970 * 1000.0 }
            return nil
        } else { return nil }
        guard let v = raw else { return nil }
        // Sekunden vs. Millisekunden auto-erkennen: aktueller Unix-Timestamp in s ≈ 1.7e9,
        // in ms ≈ 1.7e12. Schwelle 1e11 trennt beide Bereiche sicher.
        return v > 1e11 ? v : v * 1000.0
    }

    // MARK: - Stop finden

    private func findStop(in stops: [[String: Any]],
                          evaId: String,
                          names: [String]) -> [String: Any]? {
        for stop in stops {
            // Per stationId (EVA) — String oder Int
            let stId = (stop["stationId"] as? String)
                    ?? (stop["stationId"] as? Int).map(String.init)
                    ?? (stop["station_id"] as? String)
                    ?? (stop["station_id"] as? Int).map(String.init)
                    ?? ""
            if !stId.isEmpty {
                let s1 = String(stId.drop(while: { $0 == "0" }))
                let s2 = String(evaId.drop(while: { $0 == "0" }))
                if stId == evaId || s1 == evaId || stId == s2 || s1 == s2
                   || stId.hasSuffix(evaId) || evaId.hasSuffix(stId) {
                    return stop
                }
            }
            // Per stationName — mehrere Feldnamen probieren. Diakritik-unabhängig, damit
            // z.B. "Oberschleißheim" (ß) vs. eine vom Server evtl. anders normalisierte
            // Schreibweise trotzdem matcht.
            let name = ((stop["stationName"] as? String)
                     ?? (stop["name"] as? String)
                     ?? (stop["station_name"] as? String)
                     ?? "").lowercased().folding(options: [.diacriticInsensitive], locale: .current)
            if !name.isEmpty, names.contains(where: { name.contains($0) }) {
                return stop
            }
        }
        return nil
    }

    /// Loggt (max. 3× pro EVA) welche Stations-IDs/-Namen tatsächlich in der Stopsequence-
    /// Antwort steckten, wenn eine erwartete Station (z.B. Oberschleißheim, EVA 8004158) nicht
    /// gefunden wurde — hilft zu klären, ob geOps eine andere ID/Schreibweise nutzt.
    private func logStopMatchFailureIfNeeded(evaId: String, tripId: String, stops: [[String: Any]]) {
        let count = stopMatchFailureLogCount[evaId] ?? 0
        guard count < 3 else { return }
        stopMatchFailureLogCount[evaId] = count + 1

        let seen = stops.map { stop -> String in
            let id = (stop["stationId"] as? String)
                  ?? (stop["stationId"] as? Int).map(String.init)
                  ?? (stop["station_id"] as? String)
                  ?? (stop["station_id"] as? Int).map(String.init)
                  ?? "?"
            let name = (stop["stationName"] as? String)
                    ?? (stop["name"] as? String)
                    ?? (stop["station_name"] as? String)
                    ?? "?"
            return "\(id):\(name)"
        }.joined(separator: ", ")

        DebugLog.shared.add("Geops-Stopsequence: EVA \(evaId) (Trip \(tripId)) nicht gefunden. Enthaltene Stationen: \(seen.isEmpty ? "keine" : seen)")
    }

    /// Loggt (max. alle 60s pro Übergang) wenn ein Zug nahe an einem Übergang vorbeifährt,
    /// aber knapp außerhalb der 200m-Erfassungsschwelle bleibt — hilft zu erkennen ob
    /// hinterlegte Koordinaten für einen Übergang leicht daneben liegen.
    private func logNearMissIfNeeded(crossing: CrossingLocation, dist: Double) {
        if let last = lastNearMissLog[crossing.id], Date().timeIntervalSince(last) < 60 { return }
        lastNearMissLog[crossing.id] = Date()
        DebugLog.shared.add("GPS-Near-Miss \(crossing.name): Zug kam bis auf \(Int(dist))m ran (Schwelle 200m) — evtl. Koordinaten leicht ungenau.")
    }

    // MARK: - Richtungserkennung

    private func inferDirection(from destination: String) -> TrainDirection? {
        // Diakritik-unabhängig vergleichen — robust gegen unterschiedliche Unicode-
        // Normalform (vorkomponiertes vs. zusammengesetztes ü) je nach Geops-Antwort.
        let d = destination.lowercased().folding(options: [.diacriticInsensitive], locale: .current)
        let toFreising = ["freising","flughafen","neufahrn","airport","muc",
                          "hallbergmoos","lohhof","eching","pulling","erding"]
        // "Leuchtenbergring" ist neben Ostbahnhof der zweite offizielle südliche S1-Endpunkt —
        // fehlte hier, wodurch diese sehr häufigen Züge kein Ziel-Signal bekamen und auf die
        // unsichere reine GPS-Bewegungsschätzung zurückfielen (Ursache für falsch angezeigte
        // Richtung kurz nach erster Erfassung eines Zuges).
        let toMunich   = ["munchen","ostbahnhof","leuchtenbergring","pasing",
                          "laim","petershausen","dachau","karlsfeld","moosach"]
        if toFreising.contains(where: { d.contains($0) }) { return .toFreising }
        if toMunich.contains(where:   { d.contains($0) }) { return .toMunich   }
        return nil
    }

    // MARK: - Automatische Offset-Messung (2D Closest-Approach)

    private func detectCrossingPassage(current: GeopsVehicle, previous: GeopsVehicle) {
        // Konsistentes EIN-Schritt-Segment previous → current verwenden.
        // (Früher: dLat aus previous.lat, dLon aber aus previous.prevLon — zwei
        //  unterschiedliche Basispunkte → verzerrtes t + falsche Distanz + falsche
        //  passageTime, da timeDiff nur einen Schritt umfasst.)
        let prevLat  = previous.lat
        let prevLon  = previous.lon
        let timeDiff = max(1, current.updatedAt.timeIntervalSince(previous.updatedAt))

        let moved   = haversineMeters(lat1: prevLat, lon1: prevLon,
                                       lat2: current.lat, lon2: current.lon)
        let speedKmh = (moved / timeDiff) * 3.6
        guard speedKmh >= 5, speedKmh <= 200 else { return }

        // Robuste, pro Trip eingerastete Richtung bevorzugen (Ziel-Destination/Netto-GPS-
        // Bewegung) statt des reinen Einzel-Delta — wichtig, da dieser Wert direkt die
        // Auto-Kalibrierung (München/Freising-Offset) füttert.
        let toMunich = (current.computedDirection() ?? (current.lat < prevLat ? .toMunich : .toFreising)) == .toMunich
        let dLat = current.lat - prevLat
        let dLon = current.lon - prevLon
        let lenSq = dLat * dLat + dLon * dLon
        guard lenSq > 0 else { return }

        for crossing in CrossingLocation.all {
            let key = "\(current.tripId)_\(crossing.id)"
            guard !measuredPassages.contains(key) else { continue }

            let t = max(0, min(1,
                ((crossing.latitude  - prevLat) * dLat +
                 (crossing.longitude - prevLon) * dLon) / lenSq
            ))

            let closestLat = prevLat + t * dLat
            let closestLon = prevLon + t * dLon
            let dist = haversineMeters(lat1: closestLat, lon1: closestLon,
                                        lat2: crossing.latitude, lon2: crossing.longitude)
            guard dist < crossing.gpsToleranceMeters else {
                // Nahe dran, aber knapp über der Schwelle — throttled loggen, hilft zu
                // klären ob z.B. Oberschleißheims hinterlegte Koordinaten leicht daneben liegen.
                if dist < crossing.gpsToleranceMeters + 600 { logNearMissIfNeeded(crossing: crossing, dist: dist) }
                continue
            }

            let passageTime = previous.updatedAt.addingTimeInterval(t * timeDiff)

            guard let stationStop = stopDepartures[crossing.stationEVA]?[current.tripId] else {
                DebugLog.shared.add("GPS-Offset \(crossing.name): dist=\(Int(dist))m → PendingDetection (kein StopSeq für Trip \(current.tripId) yet)")
                pendingDetections.append(PendingDetection(
                    tripId: current.tripId, crossingId: crossing.id,
                    passageTime: passageTime, toMunich: toMunich, lineName: current.lineName
                ))
                continue
            }

            let offset = passageTime.timeIntervalSince(stationStop.actualDeparture)
            DebugLog.shared.add("GPS-Offset \(crossing.name): dist=\(Int(dist))m offset=\(Int(offset))s dep=\(stationStop.actualDeparture)")
            guard offset > -300, offset < 300 else {
                DebugLog.shared.add("GPS-Offset \(crossing.name): ⚠️ \(Int(offset))s außerhalb ±300s – verworfen")
                continue
            }

            measuredPassages.insert(key)
#if DEBUG
            print("[Geops] ✓ Crossing \(crossing.name) (\(toMunich ? "→ München" : "→ Freising")): \(Int(offset))s dist=\(Int(dist))m")
#endif
            NotificationCenter.default.post(
                name: .trainAutoOffsetMeasured,
                object: nil,
                userInfo: [
                    "crossingId": crossing.id,
                    "offset":     offset,
                    "toMunich":   toMunich,
                    "lineName":   current.lineName
                ]
            )
        }
    }

    // MARK: - Pending Detection Auflösung

    private func processPendingDetections(for tripId: String) {
        let now = Date()
        pendingDetections.removeAll { now.timeIntervalSince($0.addedAt) > 300 }
        let matches = pendingDetections.filter { $0.tripId == tripId }
        guard !matches.isEmpty else { return }
        pendingDetections.removeAll { $0.tripId == tripId }

        for d in matches {
            guard let crossing = CrossingLocation.all.first(where: { $0.id == d.crossingId }),
                  let stop = stopDepartures[crossing.stationEVA]?[tripId]
            else { continue }
            let key = "\(tripId)_\(d.crossingId)"
            guard !measuredPassages.contains(key) else { continue }
            let offset = d.passageTime.timeIntervalSince(stop.actualDeparture)
            print("[Geops][Offset] PendingResolved \(d.crossingId) \(d.tripId) offset=\(Int(offset))s dep=\(stop.actualDeparture)")
            guard offset > -300, offset < 300 else {
                print("[Geops][Offset] ⚠️ Pending-Offset \(Int(offset))s außerhalb ±300s – verworfen")
                continue
            }
            measuredPassages.insert(key)
            NotificationCenter.default.post(
                name: .trainAutoOffsetMeasured,
                object: nil,
                userInfo: [
                    "crossingId": d.crossingId,
                    "offset":     offset,
                    "toMunich":   d.toMunich,
                    "lineName":   d.lineName
                ]
            )
        }
    }

    /// Interpoliert den Zeitstempel für eine Zielposition entlang der Trajektorie. Wird nur
    /// noch von detectNonSBahnApproach (Güterzüge/durchfahrende RE/RB ohne DB-Halt) genutzt —
    /// die S-Bahn-Durchfahrtszeit kommt seit dem DB-first-Umbau ausschließlich aus der DB.
    /// `maxMeters`: maximaler ECHTER Abstand (Meter) des Übergangs zur Zugroute — verhindert
    /// Fehlalarme auf Parallelgleisen.
    private func interpolatedTime(targetX: Double, targetY: Double,
                                  rawCoords: [[Double]],
                                  timeIntervals: [[Any]],
                                  maxMeters: Double,
                                  onNearMiss: ((Double) -> Void)? = nil) -> (time: Date, distanceMeters: Double)? {
        guard rawCoords.count >= 2 else { return nil }

        // Gesamtlänge des Pfades berechnen (Mercator-Koordinaten)
        var segLengths = [Double]()
        var totalDist = 0.0
        for i in 0..<(rawCoords.count - 1) {
            let dx = rawCoords[i+1][0] - rawCoords[i][0]
            let dy = rawCoords[i+1][1] - rawCoords[i][1]
            let l  = sqrt(dx*dx + dy*dy)
            segLengths.append(l)
            totalDist += l
        }
        guard totalDist > 0 else { return nil }

        // Nächstes Segment-Stück via Projektion finden.
        // WICHTIG: bestProgress wird als VERTEX-INDEX-Anteil (0…1 über count-1 Vertices)
        // berechnet, NICHT als Distanz-Anteil. Das muss konsistent sein mit
        // parseTimeIntervals (progress = idx/maxIdx) und currentPosition
        // (fidx = progress * (count-1)). Distanz-basierter Anteil würde bei
        // ungleich langen Segmenten (dicht vor Stationen, weit auf freier Strecke)
        // die Zeit-Interpolation verschieben.
        var bestDist     = Double.infinity
        var bestProgress = 0.0
        let vertexSpan   = Double(rawCoords.count - 1)

        for i in 0..<(rawCoords.count - 1) {
            let ax = rawCoords[i][0],   ay = rawCoords[i][1]
            let bx = rawCoords[i+1][0], by = rawCoords[i+1][1]
            let dx = bx - ax, dy = by - ay
            let segLen = segLengths[i]

            // Projektion des Zielpunkts auf das Segment
            let t: Double
            if segLen < 1e-9 {
                t = 0
            } else {
                t = max(0, min(1, ((targetX - ax) * dx + (targetY - ay) * dy) / (segLen * segLen)))
            }

            let px = ax + t * dx, py = ay + t * dy
            let d  = sqrt((targetX - px) * (targetX - px) + (targetY - py) * (targetY - py))

            if d < bestDist {
                bestDist     = d
                bestProgress = (Double(i) + t) / vertexSpan
            }
        }

        // Mercator-Distanz → echte Meter: bei Breitengrad φ ist Mercator um 1/cos(φ) gestreckt.
        // φ aus targetY zurückrechnen.
        let latRad = 2.0 * atan(exp(targetY / 6378137.0)) - .pi / 2.0
        let bestDistMeters = bestDist * cos(latRad)
        guard bestDistMeters < maxMeters else {
            onNearMiss?(bestDistMeters)
            return nil
        }

        // Zeitstempel aus time_intervals für diesen Fortschritt interpolieren
        let sorted = parseTimeIntervals(timeIntervals)
        guard !sorted.isEmpty else { return nil }

        func result(_ ts: Double) -> (time: Date, distanceMeters: Double) {
            (Date(timeIntervalSince1970: ts / 1000), bestDistMeters)
        }

        if bestProgress <= sorted.first!.progress { return result(sorted.first!.ts) }
        if bestProgress >= sorted.last!.progress  { return result(sorted.last!.ts) }
        for i in 0..<(sorted.count - 1) {
            let p1 = sorted[i].progress, p2 = sorted[i+1].progress
            guard p1 <= bestProgress, bestProgress <= p2 else { continue }
            let frac = p2 > p1 ? (bestProgress - p1) / (p2 - p1) : 0.5
            let ts   = sorted[i].ts + frac * (sorted[i+1].ts - sorted[i].ts)
            return result(ts)
        }
        return nil
    }

    /// Gemeinsames Parsen der time_intervals für currentPosition und interpolatedTime.
    /// Unterstützt zwei Formate:
    ///   • [timestamp_ms, vertex_index (Int), ...]  → Index / maxIndex als Progress
    ///   • [timestamp_ms, progress_fraction (Double 0…1), ...]  → direkt als Progress
    private func parseTimeIntervals(_ timeIntervals: [[Any]]) -> [(ts: Double, progress: Double)] {
        // Format-Erkennung: gibt es Integer-Werte > 1 in Slot [1]? → Vertex-Index-Format
        let intIndices = timeIntervals.compactMap { entry -> Int? in
            guard entry.count > 1 else { return nil }
            return entry[1] as? Int
        }
        let useIndexMode = !intIndices.isEmpty
        let maxStopIdx   = Double(max(1, intIndices.max() ?? 1))

        var result: [(ts: Double, progress: Double)] = []
        for entry in timeIntervals {
            guard let ts = (entry.first as? Double) ?? (entry.first as? Int).map(Double.init)
            else { continue }

            let progress: Double
            if useIndexMode {
                let idx = (entry.count > 1 ? entry[1] as? Int : nil) ?? 0
                progress = Double(idx) / maxStopIdx
            } else if entry.count > 1, let d = entry[1] as? Double {
                progress = max(0, min(1, d))   // 0-1-Fraktion direkt nutzen
            } else {
                progress = 0
            }
            result.append((ts: ts, progress: progress))
        }
        return result.sorted { $0.ts < $1.ts }
    }

    // MARK: - Nicht-S-Bahn Annäherungserkennung (Güterzüge, RB, RE …)

    private func detectNonSBahnApproach(tripId: String, lineName: String,
                                         rawCoords: [[Double]],
                                         timeIntervals: [[Any]],
                                         lat: Double, lon: Double) {
        guard lat != 0, lon != 0 else { return }

        let prev = nonSBahnLastPos[tripId]
        if let prev {
            let moved    = haversineMeters(lat1: prev.lat, lon1: prev.lon, lat2: lat, lon2: lon)
            let timeDiff = max(1, Date().timeIntervalSince(prev.updatedAt))
            let speedKmh = (moved / timeDiff) * 3.6
            guard speedKmh > 15 else {
                nonSBahnLastPos[tripId] = (lat: lat, lon: lon, updatedAt: Date())
                return
            }
        }
        nonSBahnLastPos[tripId] = (lat: lat, lon: lon, updatedAt: Date())

        // Robuste, pro Trip eingerastete Richtung statt Einzel-Delta mit riskantem Default.
        // Noch keine verlässliche Richtung bestimmbar (z.B. allererster Sample) → lieber
        // eine Runde warten als einen falschen Pfeil anzeigen.
        guard let direction = resolveDirection(tripId: tripId,
                                                prevLat: prev?.lat, prevLon: prev?.lon,
                                                lat: lat, lon: lon) else { return }
        let toMunich = direction == .toMunich

        var didDetect = false
        for crossing in CrossingLocation.all {
            // Grobfilter: aktueller GPS-Abstand < 8 km
            let distNow = haversineMeters(lat1: lat, lon1: lon,
                                           lat2: crossing.latitude, lon2: crossing.longitude)
            guard distNow < 8000 else { continue }

            // Diagnose: bestätigt, dass geOps diesen Zug überhaupt in Übergangsnähe trackt —
            // unabhängig davon, ob die feinere Geometrie-Prüfung unten anschlägt. Max. alle 60s
            // pro Übergang, sonst spammt ein durchfahrender Zug über mehrere Trajektorie-Updates.
            if lastNonSBahnRangeLog[crossing.id].map({ Date().timeIntervalSince($0) > 60 }) ?? true {
                lastNonSBahnRangeLog[crossing.id] = Date()
                DebugLog.shared.add("[NonSBahn] \(lineName) \(Int(distNow))m von \(crossing.name) entfernt (Grobfilter, geOps trackt den Zug)")
            }

            let crossingX: Double = crossing.longitude * 20037508.34 / 180.0
            let crossingLatRad: Double = Double.pi / 4 + crossing.latitude * Double.pi / 360
        let crossingY: Double = log(tan(crossingLatRad)) * 6378137.0

            // Enge Toleranz (110m): Übergang muss wirklich auf der Zugroute liegen,
            // sonst Fehlalarm durch Parallelgleise (z.B. Strecke 5500 bei Feldmoching).
            guard let arrivalResult = interpolatedTime(targetX: crossingX, targetY: crossingY,
                                                       rawCoords: rawCoords,
                                                       timeIntervals: timeIntervals,
                                                       maxMeters: 110,
                                                       onNearMiss: { [weak self] dist in
                guard let self else { return }
                if self.lastNonSBahnGeometryMissLog[crossing.id].map({ Date().timeIntervalSince($0) > 60 }) ?? true {
                    self.lastNonSBahnGeometryMissLog[crossing.id] = Date()
                    DebugLog.shared.add(
                        "[NonSBahn] \(lineName) nahe \(crossing.name), aber Zugroute liegt \(Int(dist))m vom Übergang " +
                        "entfernt (Schwelle 110m) — evtl. eigenes Gleis/eigene Trasse.", level: .warn
                    )
                }
            })
            else { continue }
            let arrival = arrivalResult.time

            let secondsUntil = arrival.timeIntervalSinceNow
            // Fenster: bis zu 12 min voraus, max. 90s vergangen (enger = weniger Fehlalarme)
            guard secondsUntil > -90, secondsUntil < 720 else { continue }

            // Konsistenz-Bestätigung: erst ab dem 2. Treffer für denselben Zug+Übergang
            // als echter Approach werten (filtert einmalige GPS-Ausreißer).
            let confirmKey = "\(tripId)_\(crossing.id)"
            let count = (nonSBahnConfirm[confirmKey] ?? 0) + 1
            nonSBahnConfirm[confirmKey] = count
            guard count >= 2 else { continue }

            // Echten Liniennamen von geOps übernehmen (z.B. "RE", "RB") statt pauschal "Gz" —
            // nur wenn geOps gar keinen Namen liefert (echte Güterzüge) auf "Gz" zurückfallen.
            freightApproaches["\(crossing.id)_\(tripId)"] = FreightApproach(
                crossingId: crossing.id, tripId: tripId,
                crossingTime: arrival, lineName: lineName.isEmpty ? "Gz" : lineName,
                toMunich: toMunich, updatedAt: Date()
            )
            didDetect = true
            DebugLog.shared.add("[NonSBahn] ✓ erkannt: \(lineName) an \(crossing.name) \(toMunich ? "→München" : "→Freising") in \(Int(secondsUntil))s (Bestätigung \(count))")
#if DEBUG
            print("[NonSBahn] \(crossing.name) Gz (\(lineName)) \(toMunich ? "→Mchn" : "→Frsg") in \(Int(secondsUntil))s ✓\(count)")
#endif
        }

        // Abgelaufene Einträge bereinigen
        let now = Date()
        freightApproaches = freightApproaches.filter { $0.value.crossingTime.timeIntervalSince(now) > -120 }

        // Alten nonSBahn-Positions-Cache bereinigen (> 10 min unberührt)
        nonSBahnLastPos = nonSBahnLastPos.filter {
            now.timeIntervalSince($0.value.updatedAt) < 600
        }
        pruneDirectionCaches(activeTripIds: Set(vehicles.keys).union(nonSBahnLastPos.keys))
        // Bestätigungszähler begrenzen (nur aktive Trips behalten)
        if nonSBahnConfirm.count > 200 {
            let activeTrips = Set(nonSBahnLastPos.keys)
            nonSBahnConfirm = nonSBahnConfirm.filter { entry in
                activeTrips.contains(where: { entry.key.hasPrefix($0) })
            }
        }

        // Auto-Update auslösen: damit der Zug sofort erscheint statt erst beim nächsten Reload
        if didDetect {
            NotificationCenter.default.post(name: .geopsDataChanged, object: nil)
        }
    }

    // MARK: - Haversine

    private func haversineMeters(lat1: Double, lon1: Double,
                                  lat2: Double, lon2: Double) -> Double {
        let R  = 6_371_000.0
        let φ1 = lat1 * .pi / 180, φ2 = lat2 * .pi / 180
        let Δφ = (lat2 - lat1) * .pi / 180
        let Δλ = (lon2 - lon1) * .pi / 180
        let a  = sin(Δφ/2) * sin(Δφ/2) + cos(φ1) * cos(φ2) * sin(Δλ/2) * sin(Δλ/2)
        return R * 2 * atan2(sqrt(a), sqrt(1 - a))
    }

    // MARK: - Ping / Reconnect

    private func startPing() {
        pingTask?.cancel()
        pingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                wsTask?.send(.string("PING")) { _ in }
            }
        }
    }

    private func handleDisconnect(reason: String) {
        wsTask?.cancel(with: .abnormalClosure, reason: nil)
        wsTask = nil
        pingTask?.cancel()
        pingTask = nil
        let clean = reason.count > 60 ? String(reason.prefix(60)) + "…" : reason
        connectionState = .error(clean)
        DebugLog.shared.add("[GEOPS] ✗ Verbindung verloren: \(clean) — Reconnect in \(Int(min(reconnectDelay, 60)))s", level: .warn)

        let delay = min(reconnectDelay, 60)
        reconnectDelay = min(reconnectDelay * 2, 60)

        // reconnectDelay NICHT hier zurücksetzen — sonst greift der exponentielle
        // Backoff nie. Reset passiert erst bei erfolgreicher Verbindung (handleMessage).
        reconnectTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.connect()
        }
    }
}

// MARK: - Backward Compatibility

typealias GeopsTrainInfo = GeopsVehicle

// MARK: - Private Helpers

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
