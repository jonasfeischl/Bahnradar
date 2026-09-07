import Foundation
import Observation

// MARK: - Notification

extension Notification.Name {
    /// Wird gepostet wenn genug Messungen für eine Kalibrierung vorhanden sind (manuell via Schranken-Modus).
    /// userInfo: ["crossingId": String, "munichOffset": Double?, "freisingOffset": Double?, "count": Int]
    static let crossingCalibrationUpdated = Notification.Name("crossingCalibrationUpdated")

    /// Wird gepostet wenn Geops automatisch einen Offset gemessen hat (GPS-Durchfahrt).
    /// userInfo: ["crossingId": String, "offset": Double, "toMunich": Bool]
    static let trainAutoOffsetMeasured = Notification.Name("trainAutoOffsetMeasured")

    /// Wird gepostet wenn neue relevante Geops-Daten vorliegen (z.B. Nicht-S-Bahn-Zug erkannt).
    /// Veranlasst das ViewModel die Events sofort neu zu berechnen (kein Warten auf nächsten Reload).
    static let geopsDataChanged = Notification.Name("geopsDataChanged")
}

// MARK: - Zugtyp

enum RecordedTrainType: String, Codable, CaseIterable {
    case sBahn     = "S-Bahn"
    case sonderzug = "Sonderzug"
    case both      = "S-Bahn + Sonderzug"

    var icon: String {
        switch self {
        case .sBahn:     "tram.fill"
        case .sonderzug: "exclamationmark.triangle.fill"
        case .both:      "tram.fill.tunnel"
        }
    }
}

// MARK: - Aufzeichnung

struct CrossingRecord: Identifiable, Codable {
    let id: UUID
    let closedAt: Date
    var openedAt: Date?
    var trainType: RecordedTrainType?
    /// Vorhergesagte Schließzeit laut App (für Lernkorrektur)
    var predictedClosingAt: Date?
    /// Vorhergesagte Öffnungszeit laut App (für Lernkorrektur)
    var predictedOpeningAt: Date?
    /// Automatisch berechnete Korrektur in Sekunden
    var autoClosingDelta: Double?
    var autoOpeningDelta: Double?
    /// Exakte Werte die in JSONBin gespeichert wurden (für sauberes Löschen)
    var firebaseClosingVote: Double?
    var firebaseOpeningVote: Double?
    /// Richtung des bestätigten Zugs (für richtungs-spezifische Kalibrierung)
    var confirmedToMunich: Bool?
    /// Tatsächlich gemessener Offset: closedAt − train.actualTime
    var measuredClosingOffset: Double?

    init(closedAt: Date) {
        self.id       = UUID()
        self.closedAt = closedAt
    }

    var duration: TimeInterval? {
        guard let openedAt else { return nil }
        return openedAt.timeIntervalSince(closedAt)
    }

    var durationText: String {
        guard let d = duration else { return "läuft…" }
        let minutes = Int(d) / 60
        let seconds = Int(d) % 60
        return minutes > 0 ? "\(minutes) min \(seconds) s" : "\(seconds) s"
    }
}

// MARK: - Recorder

@Observable
final class CrossingRecorder {

    enum RecorderState {
        case idle
        case closed(since: Date)
        case selectingType(record: CrossingRecord)
        case confirmingTrains(record: CrossingRecord, predicted: [CrossingEvent])
    }

    private(set) var recorderState: RecorderState = .idle
    private(set) var records: [CrossingRecord] = []
    private var crossingId: String = ""
    private var keyRecords: String { "crossingRecords_\(crossingId)" }

    var elapsedSeconds: Int {
        if case .closed(let since) = recorderState {
            return Int(Date().timeIntervalSince(since))
        }
        return 0
    }

    init() { }

    func switchCrossing(_ id: String) {
        guard crossingId != id else { return }
        // Bei Übergang-Wechsel laufende Aufzeichnung abbrechen
        if case .idle = recorderState { } else { cancel() }
        crossingId = id
        records = Self.load(key: keyRecords)
    }

    // MARK: Aktionen

    /// Schranke geht ZU — nächsten vorhergesagten Zug merken
    func markClosed(nextEvents: [CrossingEvent]) {
        let now = Date()
        var record = CrossingRecord(closedAt: now)

        // Nächsten Zug in den nächsten 5 Minuten finden
        if let nearest = nextEvents
            .filter({ $0.minutesUntil > -1 && $0.minutesUntil < 5 })
            .min(by: { abs($0.minutesUntil) < abs($1.minutesUntil) }) {
            record.predictedClosingAt = nearest.estimatedCrossingTime
        }

        recorderState = .closed(since: now)
        // Record zwischenspeichern für späteren Zugriff
        _pendingRecord = record
    }

    /// Schranke geht AUF — Öffnungszeit merken
    func markOpen(feedback: FeedbackLearner) {
        guard let record = _pendingRecord else {
            recorderState = .idle
            return
        }

        var updated = record
        // Vorhergesagte Öffnungszeit = vorhergesagte Schließzeit + totalOpeningDelay
        if let predicted = record.predictedClosingAt {
            updated.predictedOpeningAt = predicted.addingTimeInterval(feedback.totalOpeningDelay)
        }

        recorderState = .selectingType(record: updated)
    }

    /// Schranke AUF → direkt zur Zugbestätigung (Schritt 3 entfernt)
    func markOpenAndConfirm(feedback: FeedbackLearner, allEvents: [CrossingEvent]) {
        guard let record = _pendingRecord else {
            recorderState = .idle
            return
        }

        var updated = record
        updated.openedAt = Date()
        if let predicted = record.predictedClosingAt {
            updated.predictedOpeningAt = predicted.addingTimeInterval(feedback.totalOpeningDelay)
        }

        // Züge die während der Sperrzeit vorhergesagt waren
        let predicted = allEvents.filter {
            $0.estimatedCrossingTime >= updated.closedAt.addingTimeInterval(-60) &&
            $0.estimatedCrossingTime <= (updated.openedAt ?? Date()).addingTimeInterval(60)
        }

        _pendingRecord = updated
        recorderState = .confirmingTrains(record: updated, predicted: predicted)
    }

    /// Zugbestätigung abschließen
    func confirmTrains(confirmed: [CrossingEvent], sonderzug: Bool = false, feedback: FeedbackLearner) {
        guard case .confirmingTrains(let record, _) = recorderState else { return }
        var r = record
        if sonderzug { r.trainType = .sonderzug }
        finalize(record: r, confirmedEvents: confirmed, feedback: feedback)
    }

    /// Speichern + automatisch lernen
    private func finalize(record: CrossingRecord, confirmedEvents: [CrossingEvent], feedback: FeedbackLearner) {
        var record = record

        // Lernen nur wenn Zug bestätigt wurde
        if !confirmedEvents.isEmpty, let firstConfirmed = confirmedEvents.first {
            // 1. Schließzeitpunkt richtungs-spezifisch korrigieren
            let toMunich = firstConfirmed.train.resolvedDirection == .toMunich
            let closingDelta = record.closedAt.timeIntervalSince(firstConfirmed.estimatedCrossingTime)
            record.autoClosingDelta  = closingDelta
            record.confirmedToMunich = toMunich
            // Rohen Offset speichern (closedAt − actualTime) für spätere Kalibrierung
            record.measuredClosingOffset = record.closedAt.timeIntervalSince(firstConfirmed.train.actualTime)
            if abs(closingDelta) < 120 {
                let vote = feedback.applyAutoClosingCorrection(closingDelta, toMunich: toMunich)
                record.firebaseClosingVote = vote
            }

            // 2. Öffnungsverzögerung korrigieren
            if let actualOpen = record.openedAt {
                let predictedOpen = firstConfirmed.estimatedCrossingTime.addingTimeInterval(feedback.totalOpeningDelay)
                let openingDelta  = actualOpen.timeIntervalSince(predictedOpen)
                record.autoOpeningDelta = openingDelta
                if abs(openingDelta) < 120 {
                    let vote = feedback.applyAutoOpeningCorrection(openingDelta)
                    record.firebaseOpeningVote = vote
                }
            }
        }

        records.insert(record, at: 0)
        if records.count > 200 { records.removeLast() }
        save()
        recorderState = .idle
        _pendingRecord = nil

        // Kalibrierung neu berechnen und ViewModel benachrichtigen
        postCalibrationIfReady()
    }

    func cancel() {
        recorderState = .idle
        _pendingRecord = nil
    }

    func delete(_ record: CrossingRecord, feedback: FeedbackLearner) {
        if let vote = record.firebaseClosingVote {
            if let toMunich = record.confirmedToMunich {
                // Auto-Korrektur aus Schranken-Modus → richtungs-spezifisch rückgängig
                feedback.revertAutoClosingCorrection(vote, toMunich: toMunich)
            } else {
                // Manuelles Feedback → shared offset rückgängig
                feedback.removeVoteFromFirebasePublic(closing: vote, opening: nil)
                feedback.closingOffsetAdjustmentPublic -= vote
            }
        }
        if let vote = record.firebaseOpeningVote {
            feedback.removeVoteFromFirebasePublic(closing: nil, opening: vote)
            feedback.openingDelayAdjustmentPublic -= vote
        }
        records.removeAll { $0.id == record.id }
        save()
    }

    func deleteAll(feedback: FeedbackLearner) {
        for record in records {
            if let vote = record.firebaseClosingVote {
                if let toMunich = record.confirmedToMunich {
                    feedback.revertAutoClosingCorrection(vote, toMunich: toMunich)
                } else {
                    feedback.removeVoteFromFirebasePublic(closing: vote, opening: nil)
                    feedback.closingOffsetAdjustmentPublic -= vote
                }
            }
            if let vote = record.firebaseOpeningVote {
                feedback.removeVoteFromFirebasePublic(closing: nil, opening: vote)
                feedback.openingDelayAdjustmentPublic -= vote
            }
        }
        records.removeAll()
        save()
    }

    // MARK: Kalibrierung

    /// Gibt den Median der gemessenen Offsets zurück wenn genug Aufzeichnungen vorhanden.
    /// Mindestens 3 bestätigte Messungen pro Richtung nötig.
    func calibratedClosingOffset(toMunich: Bool, minSamples: Int = 3) -> Double? {
        let samples = records
            .filter { $0.confirmedToMunich == toMunich }
            .compactMap { $0.measuredClosingOffset }
            .filter { abs($0) < 300 } // Ausreißer ignorieren (> 5 min)
        guard samples.count >= minSamples else { return nil }
        let sorted = samples.sorted()
        let mid    = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[mid - 1] + sorted[mid]) / 2
            : sorted[mid]
    }

    // MARK: Kalibrierungs-Notification

    private func postCalibrationIfReady() {
        // Ab der ersten Messung sofort kalibrieren (minSamples: 1)
        let munichOffset   = calibratedClosingOffset(toMunich: true,  minSamples: 1)
        let freisingOffset = calibratedClosingOffset(toMunich: false, minSamples: 1)
        guard munichOffset != nil || freisingOffset != nil else { return }

        let count = records.filter { $0.measuredClosingOffset != nil }.count
        var info: [String: Any] = ["crossingId": crossingId, "count": count]
        if let m = munichOffset   { info["munichOffset"]   = m }
        if let f = freisingOffset { info["freisingOffset"] = f }

        NotificationCenter.default.post(
            name: .crossingCalibrationUpdated,
            object: nil,
            userInfo: info
        )
    }

    // MARK: Privat

    private var _pendingRecord: CrossingRecord?

    private func save() {
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: keyRecords)
        }
    }

    private static func load(key: String) -> [CrossingRecord] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([CrossingRecord].self, from: data)
        else { return [] }
        return decoded
    }
}
