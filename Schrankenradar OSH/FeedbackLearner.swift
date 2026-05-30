import Foundation
import Observation
import FirebaseFirestore

// MARK: - Konstanten

private let keyClosingOffset  = "closingOffsetAdjustment"
private let keyOpeningDelay   = "openingDelayAdjustment"
private let keyFeedbackCount  = "feedbackCount"
private let keyStepSeconds    = "feedbackStepSeconds"
private let keyHistory        = "feedbackHistory"

let defaultStepSeconds: Double = 15
private let minClosing: Double = -120
private let maxClosing: Double =  120
private let minOpening: Double =    0
private let maxOpening: Double =  120

// MARK: - FeedbackEntryType

enum FeedbackEntryType: String, Codable {
    case correct
    case tooEarlyRed
    case tooLateRed
    case tooEarlyGreen
    case tooLateGreen

    var label: String {
        switch self {
        case .correct:       "Vorhersage bestätigt ✓"
        case .tooEarlyRed:   "Zu früh rot"
        case .tooLateRed:    "Zu spät rot"
        case .tooEarlyGreen: "Zu früh grün"
        case .tooLateGreen:  "Zu spät grün"
        }
    }

    var icon: String {
        switch self {
        case .correct:       "checkmark.circle.fill"
        case .tooEarlyRed:   "clock.badge.xmark"
        case .tooLateRed:    "clock.badge.checkmark"
        case .tooEarlyGreen: "clock.badge.xmark"
        case .tooLateGreen:  "clock.badge.checkmark"
        }
    }

    var color: String {   // als String weil Codable
        switch self {
        case .correct:       "green"
        case .tooEarlyRed:   "orange"
        case .tooLateRed:    "red"
        case .tooEarlyGreen: "orange"
        case .tooLateGreen:  "green"
        }
    }

    /// Welches Feld wird verändert
    var affectsClosing: Bool {
        self == .tooEarlyRed || self == .tooLateRed
    }

    /// Vorzeichen des Deltas (+1 = erhöhen, -1 = verringern)
    var sign: Double {
        switch self {
        case .tooEarlyRed:   +1
        case .tooLateRed:    -1
        case .tooEarlyGreen: +1
        case .tooLateGreen:  -1
        case .correct:        0
        }
    }
}

// MARK: - FeedbackEntry

struct FeedbackEntry: Identifiable, Codable {
    let id: UUID
    let date: Date
    let type: FeedbackEntryType
    let stepUsed: Double   // wie viele Sekunden wurden damals angepasst

    init(type: FeedbackEntryType, stepUsed: Double) {
        self.id       = UUID()
        self.date     = Date()
        self.type     = type
        self.stepUsed = stepUsed
    }
}

// MARK: - FeedbackLearner

@Observable
final class FeedbackLearner {

    private(set) var closingOffsetAdjustment: Double
    private(set) var openingDelayAdjustment: Double
    private(set) var feedbackCount: Int
    var stepSeconds: Double

    var lastFeedbackMessage: String? = nil
    private(set) var history: [FeedbackEntry] = []

    init() {
        closingOffsetAdjustment = UserDefaults.standard.double(forKey: keyClosingOffset)
        openingDelayAdjustment  = UserDefaults.standard.double(forKey: keyOpeningDelay)
        feedbackCount           = UserDefaults.standard.integer(forKey: keyFeedbackCount)
        let stored = UserDefaults.standard.double(forKey: keyStepSeconds)
        stepSeconds = stored > 0 ? stored : defaultStepSeconds
        history = Self.loadHistory()
        loadFromFirebase()
    }

    // MARK: Öffentliche API

    func totalClosingOffset(base: Double) -> Double {
        base + closingOffsetAdjustment
    }

    var totalOpeningDelay: Double {
        30 + openingDelayAdjustment
    }

    // MARK: Feedback

    func submitCorrect() {
        addHistory(.correct)
        showMessage("Danke! Vorhersage war korrekt. 👍")
    }

    func submitTooEarlyRed() {
        let delta = stepSeconds
        closingOffsetAdjustment = (closingOffsetAdjustment + delta).clamped(to: minClosing...maxClosing)
        feedbackCount += 1
        addHistory(.tooEarlyRed)
        persistLocal()
        addVoteToFirebase(closing: delta, opening: nil)
        showMessage("Verstanden – Schranke schließt \(Int(closingOffsetAdjustment))s später als Basis.")
    }

    func submitTooLateRed() {
        let delta = -stepSeconds
        closingOffsetAdjustment = (closingOffsetAdjustment + delta).clamped(to: minClosing...maxClosing)
        feedbackCount += 1
        addHistory(.tooLateRed)
        persistLocal()
        addVoteToFirebase(closing: delta, opening: nil)
        showMessage("Verstanden – Schranke schließt \(Int(closingOffsetAdjustment))s früher als Basis.")
    }

    func submitTooEarlyGreen() {
        let delta = stepSeconds
        openingDelayAdjustment = (openingDelayAdjustment + delta).clamped(to: minOpening...maxOpening)
        feedbackCount += 1
        addHistory(.tooEarlyGreen)
        persistLocal()
        addVoteToFirebase(closing: nil, opening: delta)
        showMessage("Verstanden – Schranke bleibt \(Int(totalOpeningDelay))s nach Zug geschlossen.")
    }

    func submitTooLateGreen() {
        let delta = -stepSeconds
        openingDelayAdjustment = (openingDelayAdjustment + delta).clamped(to: minOpening...maxOpening)
        feedbackCount += 1
        addHistory(.tooLateGreen)
        persistLocal()
        addVoteToFirebase(closing: nil, opening: delta)
        showMessage("Verstanden – Schranke öffnet \(Int(totalOpeningDelay))s nach Zug.")
    }

    // MARK: Rückgängig (Option 3 — auch Firebase)

    func undo(entry: FeedbackEntry) {
        let delta = entry.type.sign * entry.stepUsed
        if entry.type.affectsClosing {
            closingOffsetAdjustment = (closingOffsetAdjustment - delta).clamped(to: minClosing...maxClosing)
            removeVoteFromFirebase(closing: delta, opening: nil)
        } else if entry.type != .correct {
            openingDelayAdjustment = (openingDelayAdjustment - delta).clamped(to: minOpening...maxOpening)
            removeVoteFromFirebase(closing: nil, opening: delta)
        }

        if entry.type != .correct { feedbackCount = max(0, feedbackCount - 1) }
        history.removeAll { $0.id == entry.id }
        persistLocal()
        saveHistory()
        showMessage("Rückgängig gemacht – auch aus Firebase entfernt.")
    }

    func resetLearning() {
        closingOffsetAdjustment = 0
        openingDelayAdjustment  = 0
        feedbackCount           = 0
        history.removeAll()
        persistLocal()
        saveHistory()
        resetFirebase()
        showMessage("Lerndaten zurückgesetzt.")
    }

    func saveStepSeconds(_ value: Double) {
        let clamped = value.clamped(to: 5...120)
        stepSeconds = clamped
        UserDefaults.standard.set(clamped, forKey: keyStepSeconds)
    }

    // MARK: Debug

    var debugDescription: String {
        "Schließen: \(Int(closingOffsetAdjustment))s | Öffnen: +\(Int(totalOpeningDelay))s nach Zug | Feedbacks: \(feedbackCount)"
    }

    // MARK: Privat

    private func addHistory(_ type: FeedbackEntryType) {
        let entry = FeedbackEntry(type: type, stepUsed: stepSeconds)
        history.insert(entry, at: 0)   // neuestes zuerst
        if history.count > 100 { history.removeLast() }
        saveHistory()
    }

    private func persistLocal() {
        UserDefaults.standard.set(closingOffsetAdjustment, forKey: keyClosingOffset)
        UserDefaults.standard.set(openingDelayAdjustment,  forKey: keyOpeningDelay)
        UserDefaults.standard.set(feedbackCount,           forKey: keyFeedbackCount)
    }

    // MARK: Firebase — Option 2 (Median) + Option 3 (Undo-Sync)

    /// Stimme hinzufügen — Firebase speichert alle Einzelstimmen als Array
    private func addVoteToFirebase(closing: Double?, opening: Double?) {
        let db = Firestore.firestore()
        var update: [String: Any] = ["lastUpdated": FieldValue.serverTimestamp()]
        if let c = closing { update["closingVotes"] = FieldValue.arrayUnion([c]) }
        if let o = opening { update["openingVotes"] = FieldValue.arrayUnion([o]) }
        db.collection("learning").document("shared").setData(update, merge: true)
    }

    /// Stimme entfernen (Undo) — Option 3
    private func removeVoteFromFirebase(closing: Double?, opening: Double?) {
        let db = Firestore.firestore()
        var update: [String: Any] = [:]
        if let c = closing { update["closingVotes"] = FieldValue.arrayRemove([c]) }
        if let o = opening { update["openingVotes"] = FieldValue.arrayRemove([o]) }
        guard !update.isEmpty else { return }
        db.collection("learning").document("shared").updateData(update)
    }

    /// Beim App-Start: Stimmen laden und Median berechnen — Option 2
    private func loadFromFirebase() {
        let db = Firestore.firestore()
        db.collection("learning").document("shared").getDocument { [weak self] snapshot, error in
            guard let self,
                  let data = snapshot?.data(),
                  error == nil else { return }

            DispatchQueue.main.async {
                let closingVotes = data["closingVotes"] as? [Double] ?? []
                let openingVotes = data["openingVotes"] as? [Double] ?? []

                // Median berechnen — ein Ausreißer kann nichts kaputt machen
                if !closingVotes.isEmpty {
                    let medianClosing = Self.median(of: closingVotes)
                    self.closingOffsetAdjustment = medianClosing.clamped(to: minClosing...maxClosing)
                }
                if !openingVotes.isEmpty {
                    let medianOpening = Self.median(of: openingVotes)
                    self.openingDelayAdjustment = medianOpening.clamped(to: minOpening...maxOpening)
                }

                let totalVotes = closingVotes.count + openingVotes.count
                if totalVotes > self.feedbackCount {
                    self.feedbackCount = totalVotes
                }

                self.persistLocal()
            }
        }
    }

    /// Alle Votes löschen beim Reset
    private func resetFirebase() {
        let db = Firestore.firestore()
        db.collection("learning").document("shared").setData([
            "closingVotes": [Double](),
            "openingVotes": [Double](),
            "lastUpdated":  FieldValue.serverTimestamp()
        ], merge: true)
    }

    /// Median-Berechnung
    private static func median(of values: [Double]) -> Double {
        let sorted = values.sorted()
        let count  = sorted.count
        if count % 2 == 1 {
            return sorted[count / 2]
        } else {
            return (sorted[count / 2 - 1] + sorted[count / 2]) / 2
        }
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: keyHistory)
        }
    }

    private static func loadHistory() -> [FeedbackEntry] {
        guard let data = UserDefaults.standard.data(forKey: keyHistory),
              let decoded = try? JSONDecoder().decode([FeedbackEntry].self, from: data)
        else { return [] }
        return decoded
    }

    private func showMessage(_ text: String) {
        lastFeedbackMessage = text
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if lastFeedbackMessage == text { lastFeedbackMessage = nil }
        }
    }
}

// MARK: - Hilfserweiterung

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.max(range.lowerBound, Swift.min(range.upperBound, self))
    }
}
