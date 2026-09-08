import SwiftUI
import Observation
import WidgetKit

// Hinweis: Schließ-/Öffnungs-Timing wird dynamisch berechnet:
//   - Offset (Abfahrt → Übergang): pro Übergang/Richtung via CrossingLocation.bestOffset
//   - Öffnungsverzögerung: feedback.totalOpeningDelay (lernt aus Feedback, Basis 10s)

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
    /// Verhindert doppelte Ansagen, wenn mehrere geplante Übergangs-Timer (z.B. von
    /// überlappenden Zügen) auf denselben, bereits angesagten Status treffen.
    private var lastAnnouncedStatus: CrossingStatus?
    private var calibrationObserver: Any?
    private var autoOffsetObserver: Any?
    private var geopsChangeObserver: Any?

    // Letzte DB-Zugdaten gecacht — für leichtgewichtigen Rebuild ohne erneuten Netz-Call
    private var lastTrains: [TrainEntry] = []
    private var lastRebuildAt: Date = .distantPast
    private var lastWidgetReloadAt: Date = .distantPast
    // Rohe DB-Entries (vor Geops-Merge) für Re-Merge ohne Netz-Call (Bug-Fix:
    // neue Geops-Züge erschienen früher erst beim nächsten DB-Fetch / Tab-Wechsel).
    private var cachedDBEntries: [TrainEntry] = []
    private var cachedDBCrossingId: String = ""

    // Offline-Modus: True wenn gerade zwischengespeicherte (veraltete) Fahrplandaten angezeigt werden
    var isShowingCachedData: Bool = false

    private struct CachedSchedule: Codable {
        let trains: [TrainEntry]
        let cachedAt: Date
    }
    private func scheduleCacheKey(_ crossingId: String) -> String { "scheduleCache_\(crossingId)" }

    /// Speichert die letzten erfolgreich geladenen Fahrplandaten für den Offline-Modus.
    private func cacheSchedule(_ trains: [TrainEntry], crossingId: String) {
        let cache = CachedSchedule(trains: trains, cachedAt: Date())
        if let data = try? JSONEncoder().encode(cache) {
            UserDefaults.standard.set(data, forKey: scheduleCacheKey(crossingId))
        }
    }

    /// Stellt die letzten bekannten Fahrplandaten aus dem Cache wieder her (offline).
    /// Nur wenn der Cache jünger als 12 Stunden ist. Gibt true zurück bei Erfolg.
    @MainActor
    @discardableResult
    private func restoreFromCache(crossingId: String) -> Bool {
        guard let data = UserDefaults.standard.data(forKey: scheduleCacheKey(crossingId)),
              let cache = try? JSONDecoder().decode(CachedSchedule.self, from: data),
              Date().timeIntervalSince(cache.cachedAt) < 12 * 3600
        else { return false }

        lastTrains = cache.trains
        let events = stabilize(buildEvents(from: cache.trains))
        guard !events.isEmpty else { return false }
        nextEvents = events
        lastUpdated = cache.cachedAt
        isShowingCachedData = true
        saveSelectedCrossingForWidget()
        return true
    }

    // Anti-Flacker: wann eine Zug-Signatur zuletzt in echten Daten gesehen wurde
    private var eventLastConfirmed: [String: Date] = [:]

    // Geglättete Durchfahrtszeit pro Zug (train.id): verhindert einen sichtbaren Sprung in der
    // Anzeige, wenn ein neuer DB-Poll die Verspätung eines Zuges ändert. Ohne Glättung wurde
    // eine neue Zeit sofort komplett übernommen, was wie ein ruckartiger Sprung wirkte.
    private var smoothedCrossingTime: [String: Date] = [:]

    // Zuletzt akzeptierte Verspätung pro Zug (train.id) — siehe stabilizeDelays.
    private var acceptedDelayMinutes: [String: Int] = [:]
    // Eine einmalig gesehene, noch nicht bestätigte Verspätungs-RÜCKNAHME (train.id → neuer,
    // niedrigerer Wert). Erst wenn derselbe niedrigere Wert beim nächsten Poll erneut kommt,
    // wird er akzeptiert.
    private var pendingDelayReduction: [String: (value: Int, count: Int)] = [:]
    // Analog für eine Verspätungs-ERHÖHUNG, aber nur relevant in der kritischen Schlussphase
    // (siehe requiredConsistentPollsForCriticalIncrease unten) — außerhalb davon werden
    // Erhöhungen weiterhin sofort übernommen.
    private var pendingDelayIncrease: [String: (value: Int, count: Int)] = [:]

    /// Ab wie vielen aufeinanderfolgenden Polls mit demselben niedrigeren Wert eine Verspätungs-
    /// Rücknahme übernommen wird. Live-Test 2026-07-19: ein Zug zeigte +19min Verspätung über
    /// 5 konsistente Polls, dann sprang DB kommentarlos auf 0min zurück — UND BLIEB dort über
    /// 4+ Minuten (mehr als 8 weitere Polls) konsistent, obwohl MVV (unabhängige Quelle) für
    /// denselben Zug weiterhin die Verspätung zeigte. Die alte Schwelle von 2 Polls (~15-30s)
    /// akzeptierte die falsche Rücknahme sofort. 7 Polls (bei ~15-20s DB-Poll-Takt ≈ 1,5-2 Min)
    /// fängt kurze Ausreißer zuverlässig ab; ein über mehrere Minuten hinweg tatsächlich falscher
    /// DB-Wert (wie im Live-Test) lässt sich rein aus dem Zeit-/Poll-Muster nicht unterscheiden
    /// von einer echten Rücknahme — das ist eine Grenze dieses Ansatzes, kein Bug.
    /// Auf User-Wunsch (2026-07-19, zweiter Live-Test: App zeigte durch diese Bremse kurzzeitig
    /// 24min statt der bereits korrekten 20min) von 7 auf 5 Polls verkürzt — bei dem in den Logs
    /// beobachteten Poll-Takt (~5-20s, oft dichter als die ursprünglich angenommenen 15-20s)
    /// entspricht das ungefähr 30-60s statt 1,5-2 Min bis zur Übernahme einer Rücknahme. Etwas
    /// weniger Schutz vor kurzen DB-Ausreißern als bei 7, aber spürbar schnelleres Nachziehen.
    private let requiredConsistentPollsForReduction = 5

    /// Nur für Verspätungs-ERHÖHUNGEN in der kritischen Schlussphase (<3 Min, siehe unten) —
    /// deutlich kürzer als requiredConsistentPollsForReduction, weil eine echte Erhöhung sich
    /// beim nächsten Poll (~5-20s) sofort wiederholt bestätigt, ein einzelner DB-Ausreißer
    /// dagegen nicht. Soll nur den einzelnen Fehl-Poll abfangen, keine echte spürbare
    /// Verzögerung einführen.
    private let requiredConsistentPollsForCriticalIncrease = 2

    /// DB's eigene Realtime-Changes-API hat sich als genauso unzuverlässig erwiesen wie zuvor
    /// geOps: Für denselben Zug wurde beobachtet, dass die Verspätung innerhalb weniger Minuten
    /// zwischen einem korrekten Wert (z.B. +3min, mit MVV übereinstimmend) und 0 hin- und
    /// herspringt — DB nimmt eine bereits gemeldete Verspätung offenbar manchmal kommentarlos
    /// wieder zurück, obwohl der Zug real noch verspätet ist. Eine echte Verspätung verschwindet
    /// nicht spontan von einer Sekunde auf die andere. Deshalb: eine RÜCKNAHME (niedrigerer Wert
    /// als zuvor akzeptiert) erst nach mehreren konsistenten Polls in Folge übernehmen (siehe
    /// requiredConsistentPollsForReduction). Eine ERHÖHTE Verspätung wird dagegen immer sofort
    /// übernommen (Sicherheit geht vor — eine zu spät erkannte Verspätung wäre schlimmer als
    /// eine zu früh erkannte).
    private func stabilizeDelays(_ trains: [TrainEntry]) -> [TrainEntry] {
        trains.map { train in
            let key = train.id
            let previous = acceptedDelayMinutes[key]

            guard let previous, train.delayMinutes != previous else {
                // Gleich oder erste Sichtung dieses Zuges: sofort akzeptieren.
                acceptedDelayMinutes[key] = train.delayMinutes
                pendingDelayReduction[key] = nil
                pendingDelayIncrease[key] = nil
                return train
            }

            // Für beide Zweige unten: wo lag die zuletzt akzeptierte (aktuell angezeigte)
            // Durchfahrtszeit relativ zu jetzt? Bezieht sich auf die Abfahrt, nicht die
            // Durchfahrtszeit an der Schranke (kennt hier den Crossing-Offset noch nicht) —
            // dieselbe bewusste Näherung wie schon vorher für die Rücknahme-Sonderregel.
            let currentlyShownTime = train.scheduledTime.addingTimeInterval(Double(previous) * 60)
            let isCriticalPhase = currentlyShownTime.timeIntervalSinceNow < 180

            if train.delayMinutes > previous {
                // Erhöhung: normalerweise sofort übernehmen (Sicherheit geht vor — eine zu
                // spät erkannte Verspätung wäre schlimmer als eine zu früh erkannte). AUSNAHME:
                // in der kritischen Schlussphase (<3 Min) schiebt eine Erhöhung die
                // Durchfahrtszeit nach HINTEN und lässt die Ampel dadurch von
                // geschlossen/warnend auf offen zurückspringen — das Gegenteil von "Sicherheit
                // geht vor". Beobachtet (User-Report): Countdown zeigte 80s, dann 70s
                // (korrekt), dann sprang die Ampel ohne Übergang auf grün — Ursache war ein
                // einzelner, sofort übernommener DB-Verspätungssprung so kurz vor der
                // Durchfahrt (DBs Realtime-Changes-API hat sich schon mehrfach als
                // unzuverlässig erwiesen, siehe requiredConsistentPollsForReduction oben).
                // Deshalb hier — nur in diesem eng begrenzten Fall — dieselbe
                // Mehrfach-Poll-Bestätigung wie bei Rücknahmen, aber kürzer.
                guard isCriticalPhase else {
                    acceptedDelayMinutes[key] = train.delayMinutes
                    pendingDelayIncrease[key] = nil
                    return train
                }
                if pendingDelayIncrease[key]?.value == train.delayMinutes {
                    let count = pendingDelayIncrease[key]!.count + 1
                    if count >= requiredConsistentPollsForCriticalIncrease {
                        acceptedDelayMinutes[key] = train.delayMinutes
                        pendingDelayIncrease[key] = nil
                        return train
                    }
                    pendingDelayIncrease[key] = (train.delayMinutes, count)
                } else {
                    pendingDelayIncrease[key] = (train.delayMinutes, 1)
                }
                let stableActualTime = train.scheduledTime.addingTimeInterval(Double(previous) * 60)
                return train.with(actualTime: stableActualTime)
            }

            // Rücknahme (train.delayMinutes < previous).
            pendingDelayIncrease[key] = nil

            // In der kritischen Schlussphase (<3 Min bis zur AKTUELL angezeigten Durchfahrt)
            // wird eine Rücknahme SOFORT übernommen statt über mehrere Polls gebremst — die
            // Bremse hat hier sonst Zeit/Status eingefroren, obwohl sich die echte Verspätung
            // schon geändert hatte (User-Report 2026-07-20: "bei 2min passiert nichts", Zeile
            // blieb stehen aber Countdown/Ampel nicht). So kurz vor der Durchfahrt ist DB/MVG
            // deutlich zuverlässiger (kaum noch Zeit für einen erneuten Rückfall) UND ein
            // eingefrorener Countdown ist hier am schädlichsten. Außerhalb dieses Fensters
            // bleibt die Bremse unverändert (schützt weiterhin vor dem ursprünglichen
            // +19min→0min-Ausreißer, der deutlich früher als 3 Min vor Abfahrt auftrat).
            if isCriticalPhase {
                acceptedDelayMinutes[key] = train.delayMinutes
                pendingDelayReduction[key] = nil
                return train
            }

            // Rücknahme erkannt: nur übernehmen, wenn derselbe niedrigere Wert schon
            // requiredConsistentPollsForReduction-mal in Folge gemeldet wurde.
            if pendingDelayReduction[key]?.value == train.delayMinutes {
                let count = pendingDelayReduction[key]!.count + 1
                if count >= requiredConsistentPollsForReduction {
                    acceptedDelayMinutes[key] = train.delayMinutes
                    pendingDelayReduction[key] = nil
                    return train
                }
                pendingDelayReduction[key] = (train.delayMinutes, count)
            } else {
                pendingDelayReduction[key] = (train.delayMinutes, 1)
            }

            let stableActualTime = train.scheduledTime.addingTimeInterval(Double(previous) * 60)
            return train.with(actualTime: stableActualTime)
        }
    }

    /// Zug-ids, die bereits mindestens einmal eine bestätigte Live-GPS-Zeit bekommen haben.
    /// Der ERSTE Wechsel auf Live-GPS wird sofort übernommen (echter Genauigkeitsgewinn durch
    /// bessere Daten, kein Rauschen) — danach nur noch eng geglättet, um reines
    /// Interpolations-Jitter zwischen aufeinanderfolgenden WebSocket-Updates zu dämpfen.
    private var liveLockedTrains: Set<String> = []

    /// Wann ein Zug zuletzt einen Live-GPS-Wert hatte — für die Reconnect-Gnadenfrist unten.
    private var lastLiveAt: [String: Date] = [:]
    /// Ein Geops-WS-Reconnect vergibt neue interne Trip-IDs UND leert `subscribedTrips`
    /// (siehe disconnect() in GeopsRealtimeService) — nach dem Reconnect müssen alle im
    /// Bbox sichtbaren Züge nacheinander per Stopsequence neu abgefragt werden, bis der
    /// per EVA passende wieder gefunden ist. Im Live-Test (2026-07-19, Diagnose-Log) dauerte
    /// das ~24s (10:03:38 Match verloren → 10:04:02 neuer Live-Lock), bei vorher
    /// angenommenen ~10-15s. Mit der alten 15s-Gnadenfrist fiel die Anzeige in der Lücke auf
    /// die DB-Schätzung zurück und sprang beim Live-Lock wieder zurück — sichtbares
    /// Hin-und-Herspringen zwischen Fahrplan- und GPS-Zeit. 45s gibt ausreichend Puffer für
    /// diesen beobachteten Reconnect-Ablauf plus Marge für einen zweiten, kurzen Aussetzer.
    private let liveGraceSeconds: TimeInterval = 45

    /// Nähert `raw` an den zuletzt für dieses Zug-Event angezeigten Wert an. Ausnahme: der
    /// erste Live-GPS-Wert für einen Zug (`isLive` wechselt von false/unbekannt auf true)
    /// wird sofort übernommen, siehe `liveLockedTrains` oben.
    /// Solange live: enger Schritt (12s/Aufruf) — nur echtes GPS-Jitter glätten, nicht die
    /// Zeit selbst verzögern (Ziel: 10s-Genauigkeit).
    /// Ohne Live-Daten: KEIN künstlicher Schritt-Cap mehr (früher 45s/Aufruf) — Live-Test
    /// 2026-07-19 zeigte, dass echte Aufrufe hier NICHT alle ~2s passieren (DB-Poll nur alle
    /// ~15-20s, zusätzlich Lücken durch Geops-Reconnects), sondern deutlich seltener. Ein
    /// fixer 45s-Cap pro (seltenem) Aufruf erzeugte dadurch sichtbare 45s-Treppenstufen über
    /// mehrere Poll-Zyklen hinweg statt einer sanften Näherung — genau die vom User gemeldeten
    /// „Sprünge". Der eigentliche Schutz vor Flackern durch einzelne Fehl-Polls kommt bereits
    /// aus `stabilizeDelays()` (Verspätungs-RÜCKNAHME erst nach zwei konsistenten Polls) —
    /// der zusätzliche Cap hier war redundant und schädlich. Innerhalb der Reconnect-
    /// Gnadenfrist wird der letzte Live-Wert weiterhin unverändert gehalten (siehe oben).
    private func smoothedTime(id: String, raw: Date, isLive: Bool) -> Date {
        let now = Date()
        if isLive { lastLiveAt[id] = now }
        let inGracePeriod = !isLive && (lastLiveAt[id].map { now.timeIntervalSince($0) < liveGraceSeconds } ?? false)

        guard let last = smoothedCrossingTime[id] else {
            smoothedCrossingTime[id] = raw
            if isLive { liveLockedTrains.insert(id) }
            return raw
        }

        if isLive, !liveLockedTrains.contains(id) {
            liveLockedTrains.insert(id)
            smoothedCrossingTime[id] = raw
            return raw
        }
        if inGracePeriod { return last }
        if !isLive { liveLockedTrains.remove(id) }

        guard isLive else {
            // Kein Cap: DB-Zeitänderungen sind seltene, poll-getaktete Events, kein Jitter.
            smoothedCrossingTime[id] = raw
            return raw
        }
        let diff = raw.timeIntervalSince(last)
        let maxStep: TimeInterval = 12
        let result = abs(diff) <= maxStep ? raw : last.addingTimeInterval(diff > 0 ? maxStep : -maxStep)
        smoothedCrossingTime[id] = result
        return result
    }

    /// Stabile Signatur eines Events (Linie + Richtung + Abfahrts-Minute). Enthält bewusst
    /// NICHT mehr den Ziel-Hinweis (finalDestinationHint) — Freising- und Flughafen-Äste, die
    /// zur exakt selben Minute fahren, gelten seit der Feldbeobachtung unten als EIN Zug (siehe
    /// TrainAPIService.deduplicate-Kommentar), sollen also auch hier dieselbe Signatur teilen.
    private func eventSignature(_ e: CrossingEvent) -> String {
        let depMinute = Int(e.train.actualTime.timeIntervalSinceReferenceDate / 60)
        return "\(e.train.lineName)|\(e.train.resolvedDirection == .toMunich)|\(depMinute)"
    }

    /// Glättet kurzes Flackern: Ein Zug der gerade noch da war (< 40s, in der kritischen Phase
    /// < 90s) aber jetzt aus den Echtzeitdaten fällt, wird noch gehalten — solange er noch in
    /// der Zukunft liegt. Ein wirklich abgesagter Zug (Gnadenfrist abgelaufen) verschwindet
    /// trotzdem.
    private func stabilize(_ fresh: [CrossingEvent]) -> [CrossingEvent] {
        let now = Date()
        for e in fresh { eventLastConfirmed[eventSignature(e)] = now }

        let freshSignatures = Set(fresh.map { eventSignature($0) })
        var result = fresh
        // WICHTIG: Auch Events kurz VOR der Durchfahrt (<20s) oder gerade eben durchgefahrene
        // (bis -60s) mit einbeziehen — vorher endete das Zeitfenster bei "> 20s in der Zukunft",
        // wodurch ein Zug ausgerechnet im kritischsten Moment (direkt vor der Durchfahrt) OHNE
        // Anti-Flacker-Schutz aus der Liste fallen konnte, sobald ein einzelnes verrauschtes
        // GPS-Update kurzzeitig eine falsche (z.B. bereits vergangene) Durchfahrtszeit lieferte.
        // Das ließ die Ampel fälschlich auf "offen" springen, obwohl der Zug gleich kam.
        for prev in nextEvents where prev.estimatedCrossingTime.timeIntervalSince(now) > -60 {
            let sig = eventSignature(prev)
            guard !freshSignatures.contains(sig) else { continue }
            // Zusätzlich TOLERANT prüfen: existiert schon ein frisches Event derselben
            // Linie+Richtung mit Durchfahrtszeit ±90s? Dann ist `prev` nur eine durch
            // Geops-Update leicht verschobene Dublette → NICHT halten (sonst Doppel-
            // Einträge + falsche Reihenfolge, die die Liste verstopfen).
            let hasCloseFresh = fresh.contains {
                $0.train.lineName == prev.train.lineName &&
                $0.train.resolvedDirection == prev.train.resolvedDirection &&
                abs($0.estimatedCrossingTime.timeIntervalSince(prev.estimatedCrossingTime)) < 90
            }
            guard !hasCloseFresh else { continue }
            // Nie ein `prev` mit einer id halten, die in `fresh` schon vorkommt — sonst
            // erscheint derselbe Zug (gleiche id) zweimal, nur mit unterschiedlicher
            // estimatedCrossingTime (z.B. wenn ein GPS-Update die Zeit um >90s verschiebt).
            guard !fresh.contains(where: { $0.id == prev.id }) else { continue }
            // Gnadenfrist: in der kritischen Phase (<3 Min bis zur Durchfahrt) großzügiger
            // (90s statt 40s) — hier kostet ein fälschliches Verschwinden am meisten (Ampel
            // springt sonst von geschlossen/warnend direkt auf offen, siehe User-Report
            // 2026-09-08: Zug bei 70s "war auf einmal weg", danach sprang die Ampel auf grün).
            // Bei 10s-Polltakt in dieser Phase deckt 90s ~9 Zyklen ab statt nur 4 — genug, um
            // einen mehrzyklischen Merge-/Netz-Aussetzer zu überbrücken, ohne einen wirklich
            // abgesagten Zug unbegrenzt lange zu zeigen. Weiter draußen bleibt es bei 40s
            // (dort ist ein falsches Verschwinden nicht sicherheitsrelevant, dafür soll ein
            // wirklich entfallener Zug dort zügig aus der Liste verschwinden).
            let graceSeconds: TimeInterval = prev.minutesUntil(from: now) < 3 ? 90 : 40
            if let confirmed = eventLastConfirmed[sig], now.timeIntervalSince(confirmed) < graceSeconds {
                result.append(prev)   // echter kurzer Aussetzer → halten
            }
        }
        eventLastConfirmed = eventLastConfirmed.filter { now.timeIntervalSince($0.value) < 120 }
        return result.sorted { $0.estimatedCrossingTime < $1.estimatedCrossingTime }
    }

    /// Entfernt Events, die anhand ihrer Durchfahrtszeit (statt Abfahrtszeit) denselben
    /// physischen Zug doppelt repräsentieren. Siehe Aufrufstelle in buildEvents für Details.
    private func dedupeCloseEvents(_ events: [CrossingEvent]) -> [CrossingEvent] {
        let sorted = events.sorted { $0.estimatedCrossingTime < $1.estimatedCrossingTime }
        var kept: [CrossingEvent] = []
        for event in sorted {
            if let idx = kept.firstIndex(where: {
                $0.train.resolvedDirection == event.train.resolvedDirection &&
                abs($0.estimatedCrossingTime.timeIntervalSince(event.estimatedCrossingTime)) < 120
            }) {
                if event.isLiveData && !kept[idx].isLiveData {
                    kept[idx] = event
                }
            } else {
                kept.append(event)
            }
        }
        return kept
    }

    func setup(voiceAnnouncer: VoiceAnnouncer) {
        self.voiceAnnouncer = voiceAnnouncer
        setupCalibrationListener()
        // Beim Start sofort letzte bekannte Daten zeigen (auch offline), bis der erste Fetch kommt
        restoreFromCache(crossingId: store.selectedId)
    }

    /// Übergang gewechselt: alte Events verwerfen, Cache des neuen Übergangs sofort zeigen,
    /// dann frisch laden. Verhindert kurzes Anzeigen falscher Übergangsdaten.
    @MainActor
    func selectAndRefresh() {
        isShowingCachedData = false
        nextEvents = []
        eventLastConfirmed = [:]   // Hysterese des alten Übergangs zurücksetzen
        lastRebuildAt = .distantPast  // Throttle zurücksetzen — erster Geops-Rebuild darf nicht geblockt werden
        lastWidgetReloadAt = .distantPast  // Widget soll neuen Übergang sofort zeigen
        cachedDBEntries = []           // alten DB-Cache ungültig machen (falscher Übergang)
        cachedDBCrossingId = ""
        lastTrains = []                 // Züge des alten Übergangs verwerfen (sonst Fallback in rebuildEventsFromCache)
        restoreFromCache(crossingId: store.selectedId)
        Task { await fetchData() }
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

        // Neue Geops-Daten (z.B. Nicht-S-Bahn-Zug erkannt) → Events sofort neu bauen
        geopsChangeObserver = NotificationCenter.default.addObserver(
            forName: .geopsDataChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
#if DEBUG
            print("[Rebuild] .geopsDataChanged empfangen")
#endif
            MainActor.assumeIsolated { self?.rebuildEventsFromCache() }
        }
    }

    /// Baut die Events aus den gecachten DB-Daten neu (ohne Netz-Call).
    /// Wird ausgelöst wenn Geops neue Daten liefert — damit Züge sofort erscheinen.
    /// Gedrosselt auf max. alle 4 Sekunden.
    @MainActor
    private func rebuildEventsFromCache() {
        guard Date().timeIntervalSince(lastRebuildAt) > 2 else {
#if DEBUG
            print("[Rebuild] gedrosselt (\(Int(Date().timeIntervalSince(lastRebuildAt)))s < 2s)")
#endif
            return
        }
        // Gecachte DB-Basis mit FRISCHEN Geops-Daten neu mergen → neue Geops-Züge
        // erscheinen sofort (ohne DB-Netz-Call, ohne Tab-Wechsel).
        guard !cachedDBEntries.isEmpty,
              cachedDBCrossingId == selectedCrossing.id else {
            // Kein gültiger DB-Cache (z.B. offline) → wenigstens Zeiten neu berechnen
            guard !lastTrains.isEmpty else { return }
            lastRebuildAt = Date()
            nextEvents = stabilize(buildEvents(from: lastTrains))
            saveSelectedCrossingForWidget()
            reloadWidgetTimelinesThrottled()
            return
        }
        lastRebuildAt = Date()
        let trains = service.mergeWithCurrentGeops(dbEntries: cachedDBEntries,
                                                   crossing: selectedCrossing)
        lastTrains = trains
        nextEvents = stabilize(buildEvents(from: trains))
#if DEBUG
        print("[Rebuild] re-merge: \(cachedDBEntries.count) DB + Geops → \(trains.count) Züge, \(nextEvents.count) Events")
#endif
        saveSelectedCrossingForWidget()
        reloadWidgetTimelinesThrottled()
    }

    // Rollierender Puffer für letzte 10 Rohwerte (im Speicher, nicht persistiert)
    // Wird für adaptive Messrauschen-Schätzung genutzt
    private var recentMeasurements: [String: (munich: [Double], freising: [Double])] = [:]

    /// Speichert einen automatisch gemessenen Geops-Offset mit Kalman-Filter.
    /// Zusätzlich: Tageszeit- UND wochentagsspezifischer Offset (Stoßzeit vs. Nebenzeit,
    /// Werktag vs. Wochenende getrennt gelernt — siehe CrossingLocation.hourlyKey).
    private func applyAutoOffset(crossingId: String, offset: Double,
                                 toMunich: Bool, lineName: String?) {
        guard let idx = store.crossings.firstIndex(where: { $0.id == crossingId }) else { return }
        var crossing = store.crossings[idx]

        let now     = Date()
        let hour    = Calendar.current.component(.hour, from: now)
        let hourKey = CrossingLocation.hourlyKey(hour: hour, isWeekend: CrossingLocation.isWeekend(now))

        // Rollierenden Puffer aktualisieren
        var buf = recentMeasurements[crossingId] ?? ([], [])

        if toMunich {
            // Ausreißer-Schutz: Schwellwert wächst mit Kalman-Varianz (hohe Unsicherheit = toleranter)
            let outlierThreshold = max(60.0, min(180.0, 3.0 * sqrt(crossing.kalmanVarianceMunich)))
            if let existing = crossing.measuredOffsetToMunich, abs(offset - existing) > outlierThreshold {
                print("[AutoOffset] \(crossingId) München: Ausreißer \(Int(offset))s ignoriert (±\(Int(outlierThreshold))s Schwelle)")
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
            let outlierThreshold = max(60.0, min(180.0, 3.0 * sqrt(crossing.kalmanVarianceFreising)))
            if let existing = crossing.measuredOffsetToFreising, abs(offset - existing) > outlierThreshold {
                print("[AutoOffset] \(crossingId) Freising: Ausreißer \(Int(offset))s ignoriert (±\(Int(outlierThreshold))s Schwelle)")
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

    var selectedCrossing: CrossingLocation { store.selected }

    /// Vollständiger Start: Geops verbinden + DB-Fetch + Cloud-Sync.
    /// Nur beim ersten App-Start oder nach Background aufrufen.
    func startAutoRefresh() {
        GeopsRealtimeService.shared.connect()
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
                // Mindestabstand zum letzten Fetch erzwingen — unabhängig davon, wie oft
                // startDBFetch() (über resumeRefresh(), z.B. bei schnell aufeinanderfolgenden
                // SwiftUI onAppear-Aufrufen) neu gestartet wird, ruft das hier NIE öfter als
                // alle 5s die echte Bahn-API auf. Vorher konnte jeder Neustart sofort einen
                // weiteren Netz-Call auslösen, was die API im Sekundentakt angehämmert hat.
                if let last = lastUpdated {
                    let wait = 5 - Date().timeIntervalSince(last)
                    if wait > 0 {
                        try? await Task.sleep(for: .seconds(wait))
                        if Task.isCancelled { break }
                    }
                }
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

    /// voiceTasks werden hier BEWUSST NICHT gecancelt — die zuletzt (vor dem Backgrounding)
    /// geplanten Ansage-Timer sollen mit den zuletzt bekannten Zeiten weiterlaufen können,
    /// sonst verstummt die App komplett sobald man während der Fahrt das Handy sperrt.
    /// Geops NICHT hier trennen (nur DB-Polling stoppen) — der Aufrufer (ContentView)
    /// entscheidet abhängig von der Standortberechtigung, ob Geops im Hintergrund
    /// weiterlaufen darf (siehe scenePhase-Handler).
    func stopAutoRefresh() {
        refreshTask?.cancel()
    }

    @MainActor
    func fetchData() async {
        guard !isLoading else { return }
        let crossing = selectedCrossing   // Ziel-Übergang fest einfrieren (kann sich während des awaits ändern)
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let dbEntries = try await service.fetchDBEntries(crossing: crossing)
            guard crossing.id == selectedCrossing.id else {
                // Nutzer hat währenddessen den Übergang gewechselt — Daten NICHT unter der
                // falschen ID abspeichern. selectAndRefresh() hat bereits einen fetchData()-Aufruf
                // für den neuen Übergang ausgelöst, der wegen isLoading verworfen wurde → erneut anstoßen.
                Task { await fetchData() }
                return
            }
            cachedDBEntries   = dbEntries
            cachedDBCrossingId = crossing.id
            let trains = service.mergeWithCurrentGeops(dbEntries: dbEntries,
                                                       crossing: crossing)
            dbConnected = true
            isShowingCachedData = false
            lastTrains = trains
            lastRebuildAt = Date()
            cacheSchedule(trains, crossingId: crossing.id)
            nextEvents = stabilize(buildEvents(from: trains))
            lastUpdated = Date()
            scheduleVoiceAnnouncements()
            // Daten für Siri-Intents + Widget speichern
            let id = crossing.id
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

            // Erst nachdem ALLE Widget-Daten geschrieben sind → Widget neu laden
            reloadWidgetTimelinesThrottled()
        } catch {
            dbConnected = false
            errorMessage = error.localizedDescription
            // Offline: letzte bekannte Fahrplandaten zeigen, falls noch keine Events da
            if nextEvents.isEmpty {
                restoreFromCache(crossingId: selectedCrossing.id)
            }
        }
    }

    // TEMPORÄRER HARDCODE (User-Anfrage 2026-07-19, nachjustiert 2026-07-20, 2026-07-25):
    // Freising-Richtung an der Dachauer Str. war mit dem aktuell gelernten Offset konsistent
    // ~3min zu früh (bestätigt per Live-GPS-Vergleich im Diagnose-Log), seit MVG-Integration
    // nur noch 20s zu spät → `+175` auf `+155` reduziert. Nach dem GPS-Offset-Freeze für
    // osh_dachauer (Basis jetzt stabil, siehe CrossingLocation.usesFrozenBase) erneuter
    // Live-Test zeigte 40s zu spät → `+155` auf `+115` reduziert, danach 1min zu früh →
    // `+115` auf `+135`. Danach durchgehend "immer 3min zu spät" (deutlich stärkeres Signal
    // als die vorherigen ±20-40s-Wackler) — per Diagnose-Log geprüft: Offset stabil bei +35s,
    // keine Merge-/Berechnungs-Anomalie. Wahrscheinliche Ursache: der Hardcode wurde
    // ursprünglich (vor MVG-Integration) so groß gewählt, um DBs eigene, damals ungenaue
    // Verspätung auszugleichen — seit MVG die Verspätung liefert, korrigiert das schon einen
    // Großteil davon selbst, der alte Hardcode korrigiert seither doppelt. Um die vollen 180s
    // reduziert: `+135` auf `-45`.
    // TODO entfernen, sobald die Freising-Lerndaten sauber neu kalibriert sind
    // (Einstellungen → Dachauer Str. → „Freising zurücksetzen" + neue Messungen).
    private let dachauerFreisingHardcode: Double = -45

    // TEMPORÄRER HARDCODE (User-Anfrage 2026-07-19, nachjustiert 2026-07-20):
    // München-Richtung an der Dachauer Str. soll 1min SPÄTER angezeigt werden, da die Schranke
    // ca. 1min nach der Station liegt (Live-Vergleich, jetzt exakt). War zuvor `-40`, macht
    // +60s Korrektur also `+20`.
    // TODO entfernen, sobald die München-Lerndaten sauber neu kalibriert sind
    // (Einstellungen → Dachauer Str. → „München zurücksetzen" + neue Messungen).
    private let dachauerMunichHardcode: Double = 20

    /// Gelernter Offset (Community/GPS-Basis + Feedback-Korrektur) plus die temporären
    /// Dachauer-Str.-Hardcodes oben — EINZIGE Stelle, die diesen Wert berechnet. Wird sowohl
    /// von `buildEvents()` als auch von `saveSelectedCrossingForWidget()` genutzt: vorher
    /// berechnete Letzteres den Widget-Offset separat nur aus `bestOffset()`, OHNE Feedback-
    /// Korrektur und OHNE die Hardcodes — dadurch zeigte das Widget im Fallback-Fall (eigener
    /// DB-Fetch, wenn der App-geschriebene Payload >12min alt ist) eine andere, unkorrigierte
    /// Zeit als die App selbst, an der Dachauer Str. um bis zu ~155s abweichend.
    private func finalOffset(for crossing: CrossingLocation, toMunich: Bool, at: Date) -> Double {
        let community = communityOffsets[crossing.id]
        let base = crossing.bestOffset(
            toMunich:               toMunich,
            communityMunich:        community?.munich,
            communityMunichCount:   community?.munichCount ?? 0,
            communityFreising:      community?.freising,
            communityFreisingCount: community?.freisingCount ?? 0,
            at:                     at
        )
        var offset = feedback.totalClosingOffset(base: base, toMunich: toMunich)
        if crossing.id == "osh_dachauer" {
            offset += toMunich ? dachauerMunichHardcode : dachauerFreisingHardcode
        }
        return offset
    }

    private func buildEvents(from trains: [TrainEntry]) -> [CrossingEvent] {
        let now = Date()
        var events: [CrossingEvent] = stabilizeDelays(trains)
            .filter { !$0.isCancelled }
            .compactMap { train -> CrossingEvent? in
                let toMunich = train.direction == .toMunich
                let offset = finalOffset(for: selectedCrossing, toMunich: toMunich, at: now)

                // Durchfahrtszeit: DB-Abfahrt (inkl. Verspätung, bevorzugt aus MVG statt DBs
                // eigener Realtime-Changes-API — siehe TrainAPIService-Überlagerung) + gelernter
                // Offset ist die Basis.
                //
                // Live-Geops-GPS wird HIER NICHT MEHR als Zeitquelle verwendet (User-Feedback
                // 2026-07-20, per Live-Vergleich bestätigt: die GPS-Trajektorien-Interpolation
                // war in der Praxis UNGENAUER als DB+MVG, nicht genauer wie ursprünglich
                // angenommen — vermutlich Interpolationsfehler/Fehlzuordnung bei paralleler
                // Gleisführung). `liveEstimate` wird trotzdem berechnet und mitgeloggt (nur für
                // den Debug-Vergleich im [CALC]-Log), fließt aber nicht mehr in rawCrossingTime
                // ein. Das "Live-GPS bestätigt"-Badge (isLive unten) bleibt unabhängig davon
                // bestehen — Geops wird weiterhin für Richtungserkennung, automatische
                // Offset-Kalibrierung und die Erkennung fahrplanloser Züge genutzt.
                let rawCrossingTime = train.actualTime.addingTimeInterval(offset)
                var liveEstimate: GeopsRealtimeService.LiveCrossingEstimate?
                if let tripId = train.geopsMatchedTripId {
                    liveEstimate = GeopsRealtimeService.shared.liveCrossingEstimate(tripId: tripId, crossing: selectedCrossing)
                }
                let crossingTime = smoothedTime(id: train.id, raw: rawCrossingTime, isLive: false)

                // Live-GPS bestätigt: rein informatives Badge, ändert nie die angezeigte Zeit.
                let isLive = train.geopsMatchedTripId.map {
                    GeopsRealtimeService.shared.hasFreshVehicle(tripId: $0)
                } ?? false

                logCalcIfNeeded(train: train, dbTime: train.actualTime, offset: offset,
                                liveEstimate: liveEstimate, finalTime: crossingTime)

                let openingDelay = feedback.totalOpeningDelay
                let keepWindow = openingDelay + 30
                guard crossingTime.timeIntervalSinceNow > -keepWindow else { return nil }

                // Feingranulare Anzeige wenn bekannt (Freising vs. Flughafen München) — an
                // unseren Übergängen (alle südlich von Neufahrn) ist es EIN gekuppelter Zug mit
                // zwei späteren Fahrtzielen (siehe TrainAPIService.deduplicate-Kommentar), aber
                // solange TrainAPIService noch keinen Merge-Partner mit abweichendem Ziel
                // gefunden hat (finalDestinationHint also noch gesetzt ist), zeigt das genauere
                // Ziel mehr Information als der generische "Freising/Flughafen"-Fallback unten.
                let directionLabel: String
                switch (train.direction, train.finalDestinationHint) {
                case (.toMunich, _):            directionLabel = "München"
                case (.toFreising, "freising"):  directionLabel = "Freising"
                case (.toFreising, "flughafen"): directionLabel = "Flughafen München"
                default:                         directionLabel = "Freising/Flughafen"
                }
                let departure = TrainDeparture(
                    id: train.id,
                    lineName: train.lineName,
                    direction: directionLabel,
                    resolvedDirection: train.direction,
                    scheduledTime: train.scheduledTime,
                    actualTime: train.actualTime,
                    delayMinutes: train.delayMinutes,
                    isArrival: false,
                    finalDestinationHint: train.finalDestinationHint
                )
                return CrossingEvent(
                    id: train.id,
                    train: departure,
                    estimatedCrossingTime: crossingTime,
                    openingDelayMinutes: openingDelay / 60,
                    isLiveData: isLive
                )
            }

        // Dedublizieren anhand der berechneten Durchfahrtszeit statt der Abfahrtszeit:
        // Wenn geOps für einen Trip eine verzerrte ("drift") Abfahrtszeit liefert, landet
        // derselbe physische Zug sonst zweimal in der Liste — einmal über den DB-Fahrplan
        // (korrekte Abfahrt, normaler Offset) und einmal über die GPS-Trajektorie (korrekte
        // Durchfahrtszeit, aber verzerrte Abfahrtszeit) — Abfahrtszeiten liegen dann bis zu
        // mehrere Minuten auseinander, obwohl beide auf denselben Zug ~1 Minute vor dem
        // Übergang zeigen. S1 fährt hier nie mit < 10 Minuten Abstand, daher gilt:
        // gleiche Richtung + Durchfahrtszeit < 120s → derselbe Zug, Live-GPS-Eintrag gewinnt.
        events = dedupeCloseEvents(events)

        // Güterzüge / Nicht-S-Bahn (RB, RE, …) via Geops-Echtzeit-GPS — werden wie normale
        // Züge behandelt. Mehrere gleichzeitig anfahrende Nicht-S-Bahn-Züge am selben Übergang
        // werden jetzt alle gezeigt (freightApproaches ist pro tripId geschlüsselt, siehe dort).
        let openingDelay = feedback.totalOpeningDelay
        let freightApproaches = GeopsRealtimeService.shared.freightApproaches.values
            .filter { $0.crossingId == selectedCrossing.id }
        for freight in freightApproaches {
            guard freight.crossingTime.timeIntervalSinceNow > -(openingDelay + 30),
                  // Nicht doppelt: kein S-Bahn-Event innerhalb 90s mit gleicher Richtung
                  !events.contains(where: {
                      $0.train.resolvedDirection == (freight.toMunich ? .toMunich : .toFreising) &&
                      abs($0.estimatedCrossingTime.timeIntervalSince(freight.crossingTime)) < 90
                  })
            else { continue }
            let dir: TrainDirection = freight.toMunich ? .toMunich : .toFreising
            let freightId = "freight_\(freight.tripId)"
            let freightDep = TrainDeparture(
                id:               freightId,
                lineName:         freight.lineName,
                direction:        dir.label,
                resolvedDirection: dir,
                scheduledTime:    freight.crossingTime,
                actualTime:       freight.crossingTime,
                delayMinutes:     0,
                isArrival:        false
            )
            events.append(CrossingEvent(
                id:                    freightId,
                train:                 freightDep,
                estimatedCrossingTime: freight.crossingTime,
                openingDelayMinutes:   openingDelay / 60,
                isLiveData:            true   // Güterzug/RB/RE kommt immer aus Geops-Echtzeit-GPS
            ))
        }

        // Geglättete Zeiten/Verspätungs-Status für Züge löschen, die nicht mehr in der
        // aktuellen Liste sind (sonst wachsen die Dictionaries unbegrenzt über den ganzen Tag).
        let activeIds = Set(trains.map { $0.id })
        smoothedCrossingTime   = smoothedCrossingTime.filter   { activeIds.contains($0.key) }
        acceptedDelayMinutes   = acceptedDelayMinutes.filter   { activeIds.contains($0.key) }
        pendingDelayReduction  = pendingDelayReduction.filter  { activeIds.contains($0.key) }
        pendingDelayIncrease   = pendingDelayIncrease.filter   { activeIds.contains($0.key) }
        liveLockedTrains       = liveLockedTrains.filter       { activeIds.contains($0) }
        lastLiveAt             = lastLiveAt.filter             { activeIds.contains($0.key) }
        lastCalcLog            = lastCalcLog.filter            { activeIds.contains($0.key) }

        return events.sorted { $0.estimatedCrossingTime < $1.estimatedCrossingTime }
    }

    // MARK: - Diagnose-Log für die Zeitberechnung

    /// Throttling für den CALC-Log: verhindert Log-Spam bei jedem Rebuild (alle paar Sekunden) —
    /// nur loggen wenn sich der Inhalt geändert hat oder der letzte Log für diesen Zug > 20s her ist.
    private var lastCalcLog: [String: (at: Date, text: String)] = [:]

    /// Loggt für Züge in den nächsten 20 Minuten alle Zutaten der Zeitberechnung — DB-Basis,
    /// gelernter Offset, Geops-Zuordnung (Trip-Match ja/nein) und Live-GPS-Schätzung (falls
    /// vorhanden, inkl. Distanz/Alter) und das Endergebnis. Das ist die wichtigste Log-Zeile
    /// für die Fehlersuche: daraus lässt sich direkt ablesen, ob eine falsche Anzeige an der
    /// DB, dem gelernten Offset oder der Geops-Zuordnung lag.
    private func logCalcIfNeeded(train: TrainEntry, dbTime: Date, offset: Double,
                                  liveEstimate: GeopsRealtimeService.LiveCrossingEstimate?,
                                  finalTime: Date) {
        guard finalTime.timeIntervalSinceNow < 20 * 60 else { return }

        let dir = train.direction == .toMunich ? "→München" : "→Freising"
        let geopsText = train.geopsMatchedTripId.map { "geops=\($0.suffix(6))" } ?? "geops=kein-Match"
        let liveText = liveEstimate.map {
            "live=\($0.time.HHmmss)(dist=\(Int($0.distanceMeters))m,age=\(Int($0.vehicleAgeSeconds))s)"
        } ?? "live=–"
        let text = "[CALC] \(train.lineName)\(dir): DB=\(dbTime.HHmmss) offset=\(Int(offset))s \(geopsText) " +
                   "\(liveText) final=\(finalTime.HHmmss)\(liveEstimate != nil ? " [LIVE]" : "")"

        let last = lastCalcLog[train.id]
        guard last == nil || last!.text != text || Date().timeIntervalSince(last!.at) > 20 else { return }
        DebugLog.shared.add(text)
        lastCalcLog[train.id] = (Date(), text)
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

        let effectiveOpeningDelay = feedback.totalOpeningDelay
        var last = first.estimatedCrossingTime
        for ev in sorted {
            let barrierWouldOpen = last + trainPassageDurationSeconds + effectiveOpeningDelay
            if ev.estimatedCrossingTime <= barrierWouldOpen + 30 {
                last = ev.estimatedCrossingTime
            } else { break }
        }
        return last.addingTimeInterval(trainPassageDurationSeconds + effectiveOpeningDelay)
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

        let effectiveOpeningDelay = feedback.totalOpeningDelay
        var last  = first.estimatedCrossingTime
        var count = 0
        for ev in sorted {
            let barrierWouldOpen = last + trainPassageDurationSeconds + effectiveOpeningDelay
            if ev.estimatedCrossingTime <= barrierWouldOpen + 30 {
                last = ev.estimatedCrossingTime
                count += 1
            } else { break }
        }
        return count
    }

    // Wird von der View mit dem aktuellen Datum aufgerufen → garantiert 1s-Updates
    func worstStatus(at date: Date) -> CrossingStatus {
        let upcoming = nextEvents.filter { $0.minutesUntil(from: date) < 4 }

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

        // Ein Timer pro Statusübergang (siehe CrossingEvent.status(at:) in Models.swift für
        // die exakten Schwellen — MÜSSEN synchron bleiben): 3,0min vorher -> warning, 2,0min
        // vorher -> closed (Schranke schließt real ca. 120s vor dem Zug), bei gelernter
        // Öffnungsverzögerung -> opening, kurz danach -> wieder open. So kommt bei jedem der
        // vier Zustände (schließt bald/geschlossen/öffnet gleich/offen) eine eigene Ansage
        // statt nur einmalig vor Durchfahrt.
        for event in nextEvents {
            let transitionOffsetsMinutes = [3.0, 2.0, -event.openingDelayMinutes, -event.openingDelayMinutes - 0.17]

            for offsetMinutes in transitionOffsetsMinutes {
                let fireTime = event.estimatedCrossingTime.addingTimeInterval(-offsetMinutes * 60)
                let delay    = fireTime.timeIntervalSinceNow
                // -10s statt >1: scheduleVoiceAnnouncements() läuft bei jedem Datenrefresh
                // (~alle 2s) neu und cancelt dabei alle bisher geplanten Tasks. Landete der
                // exakte Ansage-Zeitpunkt in diesem Neuplanungs-Fenster, wurde mit ">1" gar
                // kein Task mehr erstellt — die Ansage fiel lautlos aus, statt verspätet
                // nachzuholen. Bis zu 10s "zu spät" jetzt noch zulassen (deckt die ~2s-
                // Refresh-Lücke komfortabel ab) und sofort statt gar nicht auslösen; nur
                // wirklich alte Zeitpunkte weiter überspringen.
                guard delay > -10 && delay < 5400 else { continue } // nur bis 90 min im Voraus
                let clampedDelay = max(delay, 0)

                let task = Task { [weak self] in
                    guard !Task.isCancelled else { return }  // sofort prüfen (vor Sleep)
                    try? await Task.sleep(for: .seconds(clampedDelay))
                    guard !Task.isCancelled, let self else { return }

                    let voiceEnabled = UserDefaults.standard.bool(forKey: "voiceEnabled")
                    guard voiceEnabled && self.isDriving && self.isNearCrossing else { return }

                    // Frisch neu bewerten statt den beim Planen erwarteten Status blind zu
                    // übernehmen (Daten können sich seitdem geändert haben) — und nur
                    // ansagen, wenn sich der Status seit der letzten Ansage wirklich
                    // geändert hat (sonst doppelte Ansagen bei überlappenden Zügen).
                    let currentStatus = self.worstUpcomingStatus
                    guard currentStatus != self.lastAnnouncedStatus else { return }
                    self.lastAnnouncedStatus = currentStatus

                    let next = self.nextEvents.first { $0.minutesUntil > 0 }

                    await MainActor.run {
                        announcer.announce(
                            status: currentStatus,
                            nextEvent: next,
                            crossingName: self.selectedCrossing.spokenCrossingName
                        )
                    }
                }
                voiceTasks.append(task)
            }
        }
    }

    /// reloadAllTimelines() läuft über System-Scene-Code und kann den Main Thread für
    /// hunderte ms blockieren (siehe Instruments: Hang bei UIScene/FBSWorkspace-Update).
    /// iOS aktualisiert Homescreen-Widgets ohnehin nicht öfter als alle paar Minuten,
    /// daher reicht ein grobes Throttle statt bei jedem Geops-Tick neu zu laden.
    private func reloadWidgetTimelinesThrottled() {
        guard Date().timeIntervalSince(lastWidgetReloadAt) > 20 else { return }
        lastWidgetReloadAt = Date()
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func saveSelectedCrossingForWidget() {
        guard let suite = UserDefaults(suiteName: "group.schrankenradar.osh") else { return }
        let c = selectedCrossing

        suite.set(c.stationEVA,    forKey: "widget_stationEVA")
        suite.set(c.name,          forKey: "widget_crossingName")
        suite.set(c.subtitle,      forKey: "widget_crossingSubtitle")
        suite.set(c.onlyS1,        forKey: "widget_onlyS1")
        // Über finalOffset() statt bestOffset() direkt — sonst fehlten hier die Feedback-
        // Korrektur UND die Dachauer-Str.-Hardcodes, die buildEvents() für die App-Anzeige
        // anwendet. Das Widget nutzt diesen Wert nur als Fallback (eigener DB-Fetch, wenn der
        // unten geschriebene sharedEvents-Payload >12min alt ist) — ohne diesen Fix hätte der
        // Fallback an der Dachauer Str. bis zu ~155s von der App-Anzeige abgewichen.
        let now = Date()
        suite.set(finalOffset(for: c, toMunich: true,  at: now), forKey: "widget_offsetToMunich")
        suite.set(finalOffset(for: c, toMunich: false, at: now), forKey: "widget_offsetToFreising")

        // Geops-genaue Events für das Widget ablegen (Live-Zeiten + GPS-Offsets + Trajectory).
        // Das Widget nutzt diese primär und macht nur als Fallback einen eigenen DB-Fetch.
        let sharedEvents = nextEvents.prefix(12).map { event in
            SharedTrainEvent(
                line:              event.train.lineName,
                directionIsMunich: event.train.resolvedDirection == .toMunich,
                crossingTime:      event.estimatedCrossingTime,
                delayMinutes:      event.train.delayMinutes
            )
        }
        let payload = SharedWidgetPayload(
            crossingId:       c.id,
            crossingName:     c.name,
            crossingSubtitle: c.subtitle,
            generatedAt:      Date(),
            events:           Array(sharedEvents)
        )
        if let data = try? JSONEncoder().encode(payload) {
            suite.set(data, forKey: SharedWidgetPayload.userDefaultsKey)
        }
    }

    private func cancelVoiceTasks() {
        voiceTasks.forEach { $0.cancel() }
        voiceTasks.removeAll()
    }
}
