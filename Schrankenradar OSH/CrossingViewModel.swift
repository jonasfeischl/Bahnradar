import SwiftUI
import Observation
import WidgetKit
import ActivityKit

// Abstand zwischen Station Oberschleißheim und Bahnübergang Dachauer Str. (in Sekunden)
// Südlich gelegener Übergang:
//   → München: Zug fährt ab, kreuzt danach  → + offset
//   → Freising: Zug kommt an, kreuzte davor → - offset
private let crossingOffsetSeconds: Double = 180   // S1: Zeit von Abfahrt bis Übergang
private let openingDelaySeconds:   Double = 10    // Schranke öffnet ~10s nach Zug
                                                  // Bleibt zu wenn nächster Zug < 2 min

@Observable
final class CrossingViewModel {
    var nextEvents: [CrossingEvent] = []
    var isLoading = false
    var errorMessage: String? = nil
    var lastUpdated: Date? = nil

    var store: CrossingsStore = CrossingsStore()
    private var learners: [String: FeedbackLearner] = [:]
    private let jsonBin = JSONBinService()

    // Community-GPS-Offsets aller Geräte (geräteübergreifend aus JSONBin)
    private(set) var communityOffsets: [String: CommunityGPSOffsets] = [:]
    private(set) var gpsCloudSynced: Bool = false

    // API-Verbindungsstatus (für UI)
    var dbConnected: Bool = true

    // Fahrt- und Standortstatus — werden von ContentView gesetzt
    var isDriving: Bool = false
    var isNearCrossing: Bool = false
    private weak var voiceAnnouncer: VoiceAnnouncer?
    private var voiceTasks: [Task<Void, Never>] = []
    private var calibrationObserver: Any?
    private var autoOffsetObserver: Any?

    func setup(voiceAnnouncer: VoiceAnnouncer) {
        self.voiceAnnouncer = voiceAnnouncer
        setupCalibrationListener()
    }

    private func setupCalibrationListener() {
        // Manuelle Kalibrierung (Schranken-Modus)
        calibrationObserver = NotificationCenter.default.addObserver(
            forName: .crossingCalibrationUpdated,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let id = note.userInfo?["crossingId"] as? String,
                  id == self.selectedCrossing.id else { return }

            var crossing = self.selectedCrossing
            if let m = note.userInfo?["munichOffset"]   as? Double { crossing.measuredOffsetToMunich   = m }
            if let f = note.userInfo?["freisingOffset"] as? Double { crossing.measuredOffsetToFreising = f }
            if let c = note.userInfo?["count"]          as? Int    { crossing.gpsOffsetMeasurements   = c }
            self.store.update(crossing)
        }

        // Automatische Geops-GPS-Messung (jede Zugdurchfahrt)
        autoOffsetObserver = NotificationCenter.default.addObserver(
            forName: .trainAutoOffsetMeasured,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let crossingId = note.userInfo?["crossingId"] as? String,
                  let newOffset  = note.userInfo?["offset"]     as? Double,
                  let toMunich   = note.userInfo?["toMunich"]   as? Bool,
                  abs(newOffset) < 300
            else { return }

            let lineName = note.userInfo?["lineName"] as? String
            self.applyAutoOffset(crossingId: crossingId, offset: newOffset,
                                 toMunich: toMunich, lineName: lineName)
        }
    }

    // Rollierender Puffer für letzte 10 Rohwerte (im Speicher, nicht persistiert)
    // Wird für adaptive Messrauschen-Schätzung genutzt
    private var recentMeasurements: [String: (munich: [Double], freising: [Double])] = [:]

    /// Speichert einen automatisch gemessenen Geops-Offset mit Kalman-Filter.
    /// Zusätzlich: Tageszeit-spezifischer Offset (Stoßzeit vs. Nebenzeit).
    private func applyAutoOffset(crossingId: String, offset: Double,
                                 toMunich: Bool, lineName: String?) {
        guard let idx = store.crossings.firstIndex(where: { $0.id == crossingId }) else { return }
        var crossing = store.crossings[idx]

        // Tageszeit-Schlüssel ("08", "17", …)
        let hour    = Calendar.current.component(.hour, from: Date())
        let hourKey = String(format: "%02d", hour)

        // Rollierenden Puffer aktualisieren
        var buf = recentMeasurements[crossingId] ?? ([], [])

        if toMunich {
            // Ausreißer-Schutz
            if let existing = crossing.measuredOffsetToMunich, abs(offset - existing) > 120 {
                print("[AutoOffset] \(crossingId) München: Ausreißer \(Int(offset))s ignoriert")
                return
            }

            buf.munich.append(offset)
            if buf.munich.count > 10 { buf.munich.removeFirst() }
            recentMeasurements[crossingId] = buf

            // Adaptives Messrauschen R aus Varianz der letzten Messungen
            let R = adaptiveMeasurementNoise(buf.munich)

            // Kalman-Update: allgemeiner Offset
            let (x, P) = kalmanUpdate(
                x: crossing.measuredOffsetToMunich ?? offset,
                P: crossing.kalmanVarianceMunich,
                measurement: offset, R: R,
                isFirst: crossing.measuredOffsetToMunich == nil
            )
            crossing.measuredOffsetToMunich  = x
            crossing.kalmanVarianceMunich    = P
            crossing.autoMeasurementsMunich += 1

            // Kalman-Update: Tageszeit-spezifischer Offset
            let (xH, _) = kalmanUpdate(
                x: crossing.hourlyOffsetsMunich[hourKey] ?? offset,
                P: 80.0,    // höhere Startkovarianz pro Stunde
                measurement: offset, R: R,
                isFirst: crossing.hourlyOffsetsMunich[hourKey] == nil
            )
            crossing.hourlyOffsetsMunich[hourKey] = xH

        } else {
            if let existing = crossing.measuredOffsetToFreising, abs(offset - existing) > 120 {
                print("[AutoOffset] \(crossingId) Freising: Ausreißer \(Int(offset))s ignoriert")
                return
            }

            buf.freising.append(offset)
            if buf.freising.count > 10 { buf.freising.removeFirst() }
            recentMeasurements[crossingId] = buf

            let R = adaptiveMeasurementNoise(buf.freising)

            let (x, P) = kalmanUpdate(
                x: crossing.measuredOffsetToFreising ?? offset,
                P: crossing.kalmanVarianceFreising,
                measurement: offset, R: R,
                isFirst: crossing.measuredOffsetToFreising == nil
            )
            crossing.measuredOffsetToFreising  = x
            crossing.kalmanVarianceFreising    = P
            crossing.autoMeasurementsFreising += 1

            let (xH, _) = kalmanUpdate(
                x: crossing.hourlyOffsetsFreising[hourKey] ?? offset,
                P: 80.0,
                measurement: offset, R: R,
                isFirst: crossing.hourlyOffsetsFreising[hourKey] == nil
            )
            crossing.hourlyOffsetsFreising[hourKey] = xH
        }
        crossing.gpsOffsetMeasurements += 1

        if let line = lineName, !line.isEmpty {
            var confirmed = crossing.confirmedLines ?? []
            if !confirmed.contains(line) {
                confirmed.append(line)
                crossing.confirmedLines = confirmed
            }
        }

        store.update(crossing)
        let variance = toMunich ? crossing.kalmanVarianceMunich : crossing.kalmanVarianceFreising
        print("[AutoOffset] \(crossingId) \(toMunich ? "Mchn" : "Fsg") \(hourKey)h: \(Int(offset))s → Schätzung \(Int(toMunich ? crossing.measuredOffsetToMunich ?? 0 : crossing.measuredOffsetToFreising ?? 0))s ±\(Int(sqrt(variance)))s")

        Task {
            await jsonBin.submitGPSOffset(
                crossingId:    crossingId,
                munichOffset:   toMunich ? offset : nil,
                freisingOffset: toMunich ? nil : offset
            )
        }
    }

    // MARK: - Kalman-Filter (1D stationäres Modell)

    /// Ein Kalman-Filter Update Schritt.
    /// - Q: Prozessrauschen (~1s² – Offset driftet leicht)
    /// - R: Messrauschen (adaptiv, typ. 5–100 s²)
    private func kalmanUpdate(x: Double, P: Double, measurement: Double,
                               Q: Double = 1.0, R: Double = 25.0,
                               isFirst: Bool = false) -> (x: Double, P: Double) {
        if isFirst { return (x: measurement, P: R) }
        let P_pred = P + Q
        let K      = P_pred / (P_pred + R)
        return (x: x + K * (measurement - x),
                P: (1 - K) * P_pred)
    }

    /// Adaptives Messrauschen R aus der Varianz der letzten N Messungen.
    /// Wenige/konsistente Messungen → R klein (vertraue neuer Messung mehr).
    /// Viele/streuende Messungen → R groß (konservativer).
    private func adaptiveMeasurementNoise(_ values: [Double]) -> Double {
        guard values.count >= 3 else { return 25.0 }
        let mean     = values.reduce(0, +) / Double(values.count)
        let variance = values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)
        return max(4.0, min(100.0, variance))
    }

    // MARK: - Community GPS Sync

    /// Lädt GPS-Offsets aller Geräte aus JSONBin (ein API-Call für alle Übergänge).
    /// Setzt communityOffsets und initialisiert fehlende Messungen aus Community-Daten.
    @MainActor
    func syncCommunityGPSOffsets() async {
        let all = await jsonBin.loadAllCommunityGPSOffsets()
        communityOffsets = all
        gpsCloudSynced = true

        // Fehlende lokale Messungen mit Community-Daten vorbelegen
        for (crossingId, community) in all {
            guard let idx = store.crossings.firstIndex(where: { $0.id == crossingId }) else { continue }
            var c = store.crossings[idx]
            var changed = false

            if c.autoMeasurementsMunich < 3, let cm = community.munich {
                // Community-Wert als Startwert – erster lokaler Messwert überschreibt ihn
                if c.measuredOffsetToMunich == nil {
                    c.measuredOffsetToMunich = cm
                    changed = true
                }
            }
            if c.autoMeasurementsFreising < 3, let cf = community.freising {
                if c.measuredOffsetToFreising == nil {
                    c.measuredOffsetToFreising = cf
                    changed = true
                }
            }
            if changed { store.update(c) }
        }
    }

    /// FeedbackLearner für den aktuell gewählten Übergang
    var feedback: FeedbackLearner {
        let id = store.selectedId
        if let existing = learners[id] { return existing }
        let new = FeedbackLearner(crossingId: id)
        learners[id] = new
        return new
    }
    private let service = TrainAPIService()
    private var refreshTask: Task<Void, Never>?
    private var liveActivity: Activity<CrossingActivityAttributes>?

    var selectedCrossing: CrossingLocation { store.selected }

    /// Vollständiger Start: Geops verbinden + DB-Fetch + Cloud-Sync.
    /// Nur beim ersten App-Start oder nach Background aufrufen.
    func startAutoRefresh() {
        Task { await GeopsRealtimeService.shared.connect() }
        Task { await syncCommunityGPSOffsets() }
        startDBFetch()
    }

    /// Nur DB-Fetch neu starten (Tab-Wechsel zurück zum Radar).
    /// Geops bleibt unberührt.
    func resumeRefresh() {
        startDBFetch()
    }

    /// Nur DB-Fetch pausieren (Tab-Wechsel weg vom Radar).
    /// Geops bleibt verbunden.
    func pauseRefresh() {
        refreshTask?.cancel()
        cancelVoiceTasks()
    }

    private func startDBFetch() {
        refreshTask?.cancel()
        isLoading = false
        refreshTask = Task {
            while !Task.isCancelled {
                await fetchData()
                let interval = nextRefreshInterval()
                try? await Task.sleep(for: .seconds(interval))
                if Task.isCancelled { break }
            }
        }
    }

    /// Passt das Refresh-Intervall dynamisch an:
    /// - 10s wenn ein Zug in < 3 Minuten kommt (kritische Phase)
    /// - 20s wenn ein Zug in < 10 Minuten kommt
    /// - 60s wenn kein Zug in absehbarer Zeit kommt
    private func nextRefreshInterval() -> Double {
        let now = Date()
        // Nur zukünftige Events berücksichtigen — veraltete nach Fehler ignorieren
        let nextMinutes = nextEvents
            .map { $0.minutesUntil(from: now) }
            .filter { $0 > 0 }
            .min()

        guard let minutes = nextMinutes else { return 60 }
        if minutes < 3  { return 10 }
        if minutes < 10 { return 20 }
        return 60
    }

    func stopAutoRefresh() {
        refreshTask?.cancel()
        cancelVoiceTasks()
        Task { await GeopsRealtimeService.shared.disconnect() }
    }

    @MainActor
    func fetchData() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let trains = try await service.fetchDepartures(crossing: selectedCrossing)
            dbConnected = true
            nextEvents = buildEvents(from: trains)
            lastUpdated = Date()
            WidgetCenter.shared.reloadAllTimelines()
            updateLiveActivity(events: nextEvents)
            scheduleVoiceAnnouncements()
            // Daten für Siri-Intents + Widget speichern
            let id = selectedCrossing.id
            UserDefaults.standard.set(worstUpcomingStatus.rawString, forKey: "lastStatus_\(id)")
            saveSelectedCrossingForWidget()

            if let next = nextEvents.first(where: { $0.minutesUntil > 0 }) {
                UserDefaults.standard.set(next.train.lineName,               forKey: "nextTrain_line_\(id)")
                UserDefaults.standard.set(next.train.direction,              forKey: "nextTrain_direction_\(id)")
                UserDefaults.standard.set(next.estimatedCrossingTime,        forKey: "nextTrain_time_\(id)")
            } else {
                UserDefaults.standard.removeObject(forKey: "nextTrain_line_\(id)")
                UserDefaults.standard.removeObject(forKey: "nextTrain_direction_\(id)")
                UserDefaults.standard.removeObject(forKey: "nextTrain_time_\(id)")
            }
        } catch {
            dbConnected = false
            errorMessage = error.localizedDescription
        }
    }

    private func buildEvents(from trains: [TrainEntry]) -> [CrossingEvent] {
        let community = communityOffsets[selectedCrossing.id]
        let hour      = Calendar.current.component(.hour, from: Date())
        return trains
            .filter { !$0.isCancelled }
            .compactMap { train -> CrossingEvent? in
                // Priorität: Tageszeit-GPS > allg. GPS (≥3) > Community > statisch
                let toMunich = train.direction == .toMunich
                let base: Double = selectedCrossing.bestOffset(
                    toMunich:          toMunich,
                    communityMunich:   community?.munich,
                    communityFreising: community?.freising,
                    hour:              hour
                )
                let offset = feedback.totalClosingOffset(base: base, toMunich: toMunich)

                let crossingTime = train.actualTime.addingTimeInterval(offset)
                let keepWindow = openingDelaySeconds + 30
                guard crossingTime.timeIntervalSinceNow > -keepWindow else { return nil }

                let departure = TrainDeparture(
                    id: train.id,
                    lineName: train.lineName,
                    direction: train.direction == .toMunich ? "München" : "Freising/Flughafen",
                    resolvedDirection: train.direction,
                    scheduledTime: train.scheduledTime,
                    actualTime: train.actualTime,
                    delayMinutes: train.delayMinutes,
                    isArrival: false
                )
                return CrossingEvent(
                    id: train.id,
                    train: departure,
                    estimatedCrossingTime: crossingTime,
                    openingDelayMinutes: openingDelaySeconds / 60
                )
            }
            .sorted { $0.estimatedCrossingTime < $1.estimatedCrossingTime }
    }

    // MARK: - Sicherheits-Properties

    /// True wenn die letzte Datenaktualisierung > 2 Minuten her ist.
    var dataIsStale: Bool {
        guard let updated = lastUpdated else { return false }
        return !isLoading && Date().timeIntervalSince(updated) > 120
    }

    // S-Bahn ~4 Wagen × 50m = 200m bei ~80 km/h (22 m/s) → ~9 Sekunden Durchfahrtszeit
    private let trainPassageDurationSeconds: Double = 9.0

    /// Frühestmögliche Öffnungszeit nach Ende der aktuellen Zugkette.
    /// Berücksichtigt die physikalische Zugdurchfahrtsdauer.
    func estimatedOpeningTime(at date: Date) -> Date? {
        let relevant = nextEvents.filter {
            let s = $0.status(at: date)
            return s == .closed || s == .opening || s == .warning
        }
        guard let first = relevant.min(by: { $0.estimatedCrossingTime < $1.estimatedCrossingTime })
        else { return nil }

        let sorted = nextEvents
            .filter { $0.estimatedCrossingTime >= first.estimatedCrossingTime }
            .sorted { $0.estimatedCrossingTime < $1.estimatedCrossingTime }

        // Kette: Folgezug kommt bevor Schranke nach vorherigem Zug öffnen würde
        var last = first.estimatedCrossingTime
        for ev in sorted {
            let barrierWouldOpen = last + trainPassageDurationSeconds + openingDelaySeconds
            if ev.estimatedCrossingTime <= barrierWouldOpen + 30 { // +30s Puffer
                last = ev.estimatedCrossingTime
            } else { break }
        }
        return last.addingTimeInterval(trainPassageDurationSeconds + openingDelaySeconds)
    }

    /// Anzahl Züge in der aktuellen Zugkette.
    func chainedTrainCount(at date: Date) -> Int {
        let relevant = nextEvents.filter {
            let s = $0.status(at: date)
            return s == .closed || s == .opening || s == .warning
        }
        guard let first = relevant.min(by: { $0.estimatedCrossingTime < $1.estimatedCrossingTime })
        else { return 0 }

        let sorted = nextEvents
            .filter { $0.estimatedCrossingTime >= first.estimatedCrossingTime }
            .sorted { $0.estimatedCrossingTime < $1.estimatedCrossingTime }

        var last  = first.estimatedCrossingTime
        var count = 0
        for ev in sorted {
            let barrierWouldOpen = last + trainPassageDurationSeconds + openingDelaySeconds
            if ev.estimatedCrossingTime <= barrierWouldOpen + 30 {
                last = ev.estimatedCrossingTime
                count += 1
            } else { break }
        }
        return count
    }

    // Wird von der View mit dem aktuellen Datum aufgerufen → garantiert 1s-Updates
    func worstStatus(at date: Date) -> CrossingStatus {
        let upcoming = nextEvents.filter { $0.minutesUntil(from: date) < 6 }

        let hasClosed  = upcoming.contains(where: { $0.status(at: date) == .closed })
        let hasWarning = upcoming.contains(where: { $0.status(at: date) == .warning })
        let hasOpening = upcoming.contains(where: { $0.status(at: date) == .opening })

        if hasClosed && hasWarning { return .closed }
        if hasClosed               { return .closed }
        if hasOpening && !hasWarning { return .opening }
        if hasWarning              { return .warning }
        return .open
    }

    // Fallback ohne explizites Datum (z.B. für Voice-Callout)
    var worstUpcomingStatus: CrossingStatus { worstStatus(at: Date()) }

    // MARK: - Background Voice

    private func scheduleVoiceAnnouncements() {
        cancelVoiceTasks()
        guard let announcer = voiceAnnouncer else { return }

        for event in nextEvents {
            // Sprechen wenn Status auf .warning wechselt (3.5 min vor Crossing)
            let fireTime = event.estimatedCrossingTime.addingTimeInterval(-3.5 * 60)
            let delay    = fireTime.timeIntervalSinceNow
            guard delay > 1 && delay < 5400 else { continue } // nur bis 90 min im Voraus

            let task = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !Task.isCancelled else { return }

                let voiceEnabled = UserDefaults.standard.bool(forKey: "voiceEnabled")
                guard voiceEnabled && self.isDriving && self.isNearCrossing else { return }

                let template = self.selectedCrossing.announcementTemplate
                let next     = self.nextEvents.first { $0.minutesUntil > 0 }

                await MainActor.run {
                    announcer.announce(
                        status: self.worstUpcomingStatus,
                        nextEvent: next,
                        template: template.isEmpty ? nil : template
                    )
                }
            }
            voiceTasks.append(task)
        }
    }

    private func saveSelectedCrossingForWidget() {
        guard let suite = UserDefaults(suiteName: "group.schrankenradar.osh") else { return }
        let c = selectedCrossing
        let community = communityOffsets[c.id]

        suite.set(c.stationEVA,    forKey: "widget_stationEVA")
        suite.set(c.name,          forKey: "widget_crossingName")
        suite.set(c.subtitle,      forKey: "widget_crossingSubtitle")
        suite.set(c.onlyS1,        forKey: "widget_onlyS1")
        // Besten verfügbaren Offset speichern inkl. Tageszeit-Anpassung
        let widgetHour = Calendar.current.component(.hour, from: Date())
        suite.set(c.bestOffset(toMunich: true,
                               communityMunich:   community?.munich,
                               communityFreising: community?.freising,
                               hour:              widgetHour),
                  forKey: "widget_offsetToMunich")
        suite.set(c.bestOffset(toMunich: false,
                               communityMunich:   community?.munich,
                               communityFreising: community?.freising,
                               hour:              widgetHour),
                  forKey: "widget_offsetToFreising")
    }

    private func cancelVoiceTasks() {
        voiceTasks.forEach { $0.cancel() }
        voiceTasks.removeAll()
    }

    // MARK: - Live Activity

    private func updateLiveActivity(events: [CrossingEvent]) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        // Nächsten relevanten Zug finden (innerhalb 5 Minuten)
        let now = Date()
        let relevant = events.first { $0.minutesUntil(from: now) > -1 && $0.minutesUntil(from: now) < 15 }

        guard let event = relevant else {
            // Kein Zug in der Nähe → Activity beenden
            Task {
                await liveActivity?.end(nil, dismissalPolicy: .immediate)
                liveActivity = nil
            }
            return
        }

        let crossing = event.estimatedCrossingTime
        let closing  = crossing.addingTimeInterval(-150)  // 150s vor Zug → rot

        // Öffnungszeit: nach dem letzten Zug in der Kette berechnen
        // Bleibt die Schranke wegen einem Folgezug zu? → dessen Crossing + delay nehmen
        // Kette: alle Züge die innerhalb 120s auf den vorherigen in der Kette folgen
        let sortedFromCrossing = events
            .filter { $0.estimatedCrossingTime >= crossing }
            .sorted { $0.estimatedCrossingTime < $1.estimatedCrossingTime }

        var lastChainedCrossing = crossing
        for ev in sortedFromCrossing {
            let barrierWouldOpen = lastChainedCrossing + trainPassageDurationSeconds + openingDelaySeconds
            if ev.estimatedCrossingTime <= barrierWouldOpen + 30 {
                lastChainedCrossing = ev.estimatedCrossingTime
            } else { break }
        }

        let opening = lastChainedCrossing.addingTimeInterval(trainPassageDurationSeconds + openingDelaySeconds)

        let state = CrossingActivityAttributes.ContentState(
            closingTime:    closing,
            openingTime:    opening,
            statusRaw:      event.status(at: now).rawString,
            trainLine:      event.train.lineName,
            trainDirection: event.train.resolvedDirection.label
        )

        // staleDate = kurz nach Öffnung, damit die Activity nicht zu lange hängen bleibt
        let staleDate = opening.addingTimeInterval(30)

        if let activity = liveActivity {
            // Bestehende Activity updaten
            Task { await activity.update(ActivityContent(state: state, staleDate: staleDate)) }
        } else {
            // Neue Activity starten
            let attributes = CrossingActivityAttributes(crossingName: selectedCrossing.name)
            liveActivity = try? Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: staleDate)
            )
        }
    }
}
