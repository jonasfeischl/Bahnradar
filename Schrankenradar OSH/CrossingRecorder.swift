import Foundation
import Observation

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
    /// Exakte Werte die in Firebase gespeichert wurden (für sauberes Löschen)
    var firebaseClosingVote: Double?
    var firebaseOpeningVote: Double?

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

private let keyRecords = "crossingRecords"

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

    var elapsedSeconds: Int {
        if case .closed(let since) = recorderState {
            return Int(Date().timeIntervalSince(since))
        }
        return 0
    }

    init() {
        records = Self.load()
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
    func confirmTrains(confirmed: [CrossingEvent], feedback: FeedbackLearner) {
        guard case .confirmingTrains(let record, _) = recorderState else { return }
        finalize(record: record, confirmedEvents: confirmed, feedback: feedback)
    }

    /// Speichern + automatisch lernen
    private func finalize(record: CrossingRecord, confirmedEvents: [CrossingEvent], feedback: FeedbackLearner) {
        var record = record

        // Lernen nur wenn Zug bestätigt wurde
        if !confirmedEvents.isEmpty, let firstConfirmed = confirmedEvents.first {
            // 1. Schließzeitpunkt korrigieren
            let closingDelta = record.closedAt.timeIntervalSince(firstConfirmed.estimatedCrossingTime)
            record.autoClosingDelta = closingDelta
            if abs(closingDelta) < 120 {
                let vote = feedback.applyAutoClosingCorrection(closingDelta)
                record.firebaseClosingVote = vote  // exakten Vote-Wert merken
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
    }

    func cancel() {
        recorderState = .idle
        _pendingRecord = nil
    }

    func delete(_ record: CrossingRecord, feedback: FeedbackLearner) {
        // Exakten Firebase-Vote entfernen + lokale Korrektur rückgängig
        if let vote = record.firebaseClosingVote {
            feedback.removeVoteFromFirebasePublic(closing: vote, opening: nil)
            feedback.closingOffsetAdjustmentPublic -= vote
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
                feedback.removeVoteFromFirebasePublic(closing: vote, opening: nil)
                feedback.closingOffsetAdjustmentPublic -= vote
            }
            if let vote = record.firebaseOpeningVote {
                feedback.removeVoteFromFirebasePublic(closing: nil, opening: vote)
                feedback.openingDelayAdjustmentPublic -= vote
            }
        }
        records.removeAll()
        save()
    }

    // MARK: Privat

    private var _pendingRecord: CrossingRecord?

    private func save() {
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: keyRecords)
        }
    }

    private static func load() -> [CrossingRecord] {
        guard let data = UserDefaults.standard.data(forKey: keyRecords),
              let decoded = try? JSONDecoder().decode([CrossingRecord].self, from: data)
        else { return [] }
        return decoded
    }
}
