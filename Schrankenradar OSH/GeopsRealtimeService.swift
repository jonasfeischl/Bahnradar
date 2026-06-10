import Foundation
import SwiftUI

// MARK: - Geops Vehicle (trajectory-Kanal)

struct GeopsVehicle {
    let tripId: String
    let lineName: String
    let delaySec: Int
    let lat: Double
    let lon: Double
    let prevLat: Double?
    let prevLon: Double?
    let updatedAt: Date
    var inferredDirection: TrainDirection?

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

    private(set) var connectionState: ConnectionState = .disconnected
    private(set) var vehicles: [String: GeopsVehicle] = [:]
    private(set) var stopDepartures: [String: [String: GeopsStopDeparture]] = [:]

    // MARK: Privat

    private var wsTask: URLSessionWebSocketTask?
    private var pingTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectDelay: Double = 5

    private var subscribedTrips: Set<String> = []
    private var measuredPassages: Set<String> = []
    private var pendingDetections: [PendingDetection] = []
    private var trajectoryUpdateCount = 0

    private let apiKey = "5cc87b12d7c5370001c1d655e67b22d1967d4799a6d23b1e92b9e24a"

    // EPSG:3857 Bounding Box: S1-Korridor München ↔ Flughafen
    // Entspricht WGS84: [11.40, 48.12, 11.85, 48.40]
    private let bboxCmd = "BBOX 1269042 6126841 1319135 6173660 14 mots=rail"

    // Station-Namen für Stop-Matching (Name → EVA)
    private static let knownStationNames: [String: [String]] = [
        "8004158": ["oberschleißheim", "oberschleissheim"],
        "8004159": ["feldmoching", "münchen-feldmoching", "munich-feldmoching",
                    "muenchen-feldmoching"]
    ]
    private var stationNames: [String: [String]]

    private init() {
        var result = Self.knownStationNames
        for crossing in CrossingLocation.all {
            let eva = crossing.stationEVA
            guard result[eva] == nil else { continue }
            let sub   = crossing.subtitle.lowercased()
            let ascii = sub.folding(options: .diacriticInsensitive, locale: .current)
            result[eva] = [sub, ascii].filter { !$0.isEmpty }
        }
        stationNames = result
    }

    // MARK: - Verbindung

    func connect() {
        guard wsTask == nil else { return }
        reconnectTask?.cancel()
        connectionState = .connecting

        guard let url = URL(string: "wss://api.geops.io/tracker-ws/v1/?key=\(apiKey)") else {
            connectionState = .error("URL ungültig"); return
        }

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

    func trajectoryDelay(for entry: TrainEntry) -> Int? {
        let now = Date()
        let fresh = vehicles.values.filter { now.timeIntervalSince($0.updatedAt) < 180 }
        guard !fresh.isEmpty else { return nil }
        let byDir = fresh.filter { $0.computedDirection() == entry.direction }
        let pool  = byDir.isEmpty ? Array(fresh) : byDir
        return pool.max(by: { $0.updatedAt < $1.updatedAt })?.delaySec
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
                    if case .string(let text) = msg { self.handleMessage(text) }
                    self.receiveLoop()
                case .failure(let err):
                    self.handleDisconnect(reason: err.localizedDescription)
                }
            }
        }
    }

    private func handleMessage(_ text: String) {
#if DEBUG
        print("[Geops] ← \(text.prefix(400))")
#endif
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        let source = root["source"] as? String ?? ""

        // Verbindungs-Bestätigung vom Server
        if source == "websocket" {
            if let content = root["content"] as? [String: Any],
               content["status"] as? String == "open" {
                if case .connecting = connectionState {
                    connectionState = .connected(trainCount: 0)
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
        guard !lineRaw.isEmpty, lineRaw.uppercased().hasPrefix("S") else { return }

        let tripId = props["train_id"] as? String ?? ""
        guard !tripId.isEmpty else { return }

        // Delay in Millisekunden → Sekunden
        let delayMs  = props["delay"] as? Int ?? 0
        let delaySec = delayMs / 1000

        // Aktuelle Position aus EPSG:3857-Geometrie interpolieren
        let geometry    = content["geometry"] as? [String: Any]
        let rawCoords   = geometry?["coordinates"] as? [[Double]] ?? []
        let timeIntervals = props["time_intervals"] as? [[Any]] ?? []
        let (lat, lon)  = currentPosition(rawCoords: rawCoords, timeIntervals: timeIntervals)
        guard lat != 0, lon != 0 else { return }

        let previous = vehicles[tripId]

        let vehicle = GeopsVehicle(
            tripId:    tripId,
            lineName:  lineRaw,
            delaySec:  delaySec,
            lat:       lat,
            lon:       lon,
            prevLat:   previous?.lat,
            prevLon:   previous?.lon,
            updatedAt: Date(),
            inferredDirection: nil
        )
        vehicles[tripId] = vehicle

        let cutoff = Date().addingTimeInterval(-300)
        vehicles = vehicles.filter { $0.value.updatedAt > cutoff }
        connectionState = .connected(trainCount: vehicles.count)

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

        // time_intervals: [[timestamp_ms, stop_index, null], ...]
        var parsed: [(ts: Double, progress: Double)] = []
        for (i, entry) in timeIntervals.enumerated() {
            guard let ts = (entry.first as? Double) ?? (entry.first as? Int).map(Double.init)
            else { continue }
            // stop_index als Fortschrittsindex: 0 = Start, letzte Gruppe = Ende
            let maxIdx = max(1, (timeIntervals.compactMap { $0.count > 1 ? $0[1] as? Int : nil }).max() ?? 1)
            let stopIdx = (entry.count > 1 ? entry[1] as? Int : nil) ?? i
            let progress = Double(stopIdx) / Double(maxIdx)
            parsed.append((ts: ts, progress: progress))
        }

        guard !parsed.isEmpty else {
            return mercatorToWGS84(rawCoords[0][0], rawCoords[0][1])
        }

        let sorted = parsed.sorted { $0.ts < $1.ts }

        if nowMs <= sorted.first!.ts {
            return mercatorToWGS84(rawCoords[0][0], rawCoords[0][1])
        }
        if nowMs >= sorted.last!.ts {
            let c = rawCoords.last!
            return mercatorToWGS84(c[0], c[1])
        }

        for i in 0..<(sorted.count - 1) {
            let t1 = sorted[i].ts,   t2 = sorted[i+1].ts
            let p1 = sorted[i].progress, p2 = sorted[i+1].progress
            guard t1 <= nowMs, nowMs <= t2 else { continue }
            let frac = (nowMs - t1) / max(1, t2 - t1)
            let progress = p1 + frac * (p2 - p1)
            let idx = min(Int(progress * Double(rawCoords.count - 1)), rawCoords.count - 1)
            return mercatorToWGS84(rawCoords[idx][0], rawCoords[idx][1])
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
        // content ist ein Array von Trip-Objekten
        guard let trips = root["content"] as? [[String: Any]],
              let tripData = trips.first
        else { return }

        let lineObj  = tripData["line"] as? [String: Any]
        let lineName = vehicles[tripId]?.lineName
                    ?? lineObj?["name"] as? String
                    ?? "S1"
        let destination = tripData["destination"] as? String ?? ""

        let stops: [[String: Any]] = (tripData["stations"] as? [[String: Any]])
                                  ?? (tripData["stops"]    as? [[String: Any]])
                                  ?? []
        guard !stops.isEmpty else { return }

        for (evaId, names) in stationNames {
            guard let stop = findStop(in: stops, evaId: evaId, names: names) else { continue }

            // Zeiten als Unix-Millisekunden
            guard let plannedMs = msValue(stop["aimedDepartureTime"]) else { continue }
            let actualMs = msValue(stop["departureTime"]) ?? plannedMs

            let planned = Date(timeIntervalSince1970: plannedMs / 1000.0)
            let actual  = Date(timeIntervalSince1970: actualMs  / 1000.0)

            let delayMs  = (stop["departureDelay"] as? Int) ?? 0
            let delaySec = delayMs / 1000

            let departure = GeopsStopDeparture(
                id:               tripId,
                tripId:           tripId,
                lineName:         lineName,
                destination:      destination,
                plannedDeparture: planned,
                actualDeparture:  actual,
                delaySec:         delaySec,
                inferredDirection: inferDirection(from: destination),
                updatedAt:        Date()
            )

            if stopDepartures[evaId] == nil { stopDepartures[evaId] = [:] }
            stopDepartures[evaId]![tripId] = departure

#if DEBUG
            print("[Geops] stopsequence: EVA \(evaId) ← \(lineName) planned=\(planned) delay=\(delaySec)s")
#endif
        }

        processPendingDetections(for: tripId)

        let cutoff = Date().addingTimeInterval(-5400)
        for evaId in stopDepartures.keys {
            stopDepartures[evaId] = stopDepartures[evaId]?.filter { $0.value.updatedAt > cutoff }
        }
    }

    private func msValue(_ any: Any?) -> Double? {
        if let d = any as? Double, d > 0 { return d }
        if let i = any as? Int, i > 0 { return Double(i) }
        return nil
    }

    // MARK: - Stop finden

    private func findStop(in stops: [[String: Any]],
                          evaId: String,
                          names: [String]) -> [String: Any]? {
        for stop in stops {
            // Per stationId (EVA)
            let stId = stop["stationId"] as? String ?? ""
            if !stId.isEmpty {
                let s1 = String(stId.drop(while: { $0 == "0" }))
                let s2 = String(evaId.drop(while: { $0 == "0" }))
                if stId == evaId || s1 == evaId || stId == s2 || s1 == s2
                   || stId.hasSuffix(evaId) || evaId.hasSuffix(stId) {
                    return stop
                }
            }
            // Per stationName (neues Format)
            let name = (stop["stationName"] as? String ?? "").lowercased()
            if !name.isEmpty, names.contains(where: { name.contains($0) }) {
                return stop
            }
        }
        return nil
    }

    // MARK: - Richtungserkennung

    private func inferDirection(from destination: String) -> TrainDirection? {
        let d = destination.lowercased()
        let toFreising = ["freising","flughafen","neufahrn","airport","muc",
                          "hallbergmoos","lohhof","eching","pulling","erding"]
        let toMunich   = ["münchen","munchen","muenchen","ostbahnhof","pasing",
                          "laim","petershausen","dachau","karlsfeld","moosach"]
        if toFreising.contains(where: { d.contains($0) }) { return .toFreising }
        if toMunich.contains(where:   { d.contains($0) }) { return .toMunich   }
        return nil
    }

    // MARK: - Automatische Offset-Messung (2D Closest-Approach)

    private func detectCrossingPassage(current: GeopsVehicle, previous: GeopsVehicle) {
        guard let prevLon = previous.prevLon ?? Optional(previous.lon) else { return }
        let timeDiff = max(1, current.updatedAt.timeIntervalSince(previous.updatedAt))

        let moved   = haversineMeters(lat1: previous.lat, lon1: previous.lon,
                                       lat2: current.lat, lon2: current.lon)
        let speedKmh = (moved / timeDiff) * 3.6
        guard speedKmh >= 5, speedKmh <= 200 else { return }

        let toMunich = current.lat < previous.lat
        let dLat = current.lat - previous.lat
        let dLon = current.lon - prevLon
        let lenSq = dLat * dLat + dLon * dLon

        for crossing in CrossingLocation.all {
            let key = "\(current.tripId)_\(crossing.id)"
            guard !measuredPassages.contains(key) else { continue }

            let t = max(0, min(1,
                ((crossing.latitude  - previous.lat) * dLat +
                 (crossing.longitude - prevLon)       * dLon) / lenSq
            ))

            let closestLat = previous.lat + t * dLat
            let closestLon = prevLon       + t * dLon
            let dist = haversineMeters(lat1: closestLat, lon1: closestLon,
                                        lat2: crossing.latitude, lon2: crossing.longitude)
            guard dist < 200 else { continue }

            let passageTime = previous.updatedAt.addingTimeInterval(t * timeDiff)

            guard let stationStop = stopDepartures[crossing.stationEVA]?[current.tripId] else {
                pendingDetections.append(PendingDetection(
                    tripId: current.tripId, crossingId: crossing.id,
                    passageTime: passageTime, toMunich: toMunich, lineName: current.lineName
                ))
                continue
            }

            let offset = passageTime.timeIntervalSince(stationStop.actualDeparture)
            guard offset > -300, offset < 300 else { continue }

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
            guard offset > -300, offset < 300 else { continue }
            measuredPassages.insert(key)
#if DEBUG
            print("[Geops] ✓ PendingDetection \(d.crossingId): \(Int(offset))s")
#endif
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

        let delay = min(reconnectDelay, 60)
        reconnectDelay = min(reconnectDelay * 2, 60)

        reconnectTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.reconnectDelay = 5
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
