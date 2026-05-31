import Foundation
import Observation

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
    private(set) var isCloudConnected: Bool = false
    private let jsonBin = JSONBinService()
    private var closingVotesCache: [Double] = []
    private var openingVotesCache: [Double] = []
    private(set) var history: [FeedbackEntry] = []

    init() {
        closingOffsetAdjustment = UserDefaults.standard.double(forKey: keyClosingOffset)
        openingDelayAdjustment  = UserDefaults.standard.double(forKey: keyOpeningDelay)
        feedbackCount           = UserDefaults.standard.integer(forKey: keyFeedbackCount)
        let stored = UserDefaults.standard.double(forKey: keyStepSeconds)
        stepSeconds = stored > 0 ? stored : defaultStepSeconds
        history = Self.loadHistory()
        Task { await loadFromJSONBin() }
    }

    // MARK: Öffentliche API

    func totalClosingOffset(base: Double) -> Double {
        base + closingOffsetAdjustment
    }

    var totalOpeningDelay: Double {
        10 + openingDelayAdjustment   // Basis: 10 Sekunden Nachhaltzeit
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
            removeVoteFromFirebasePublic(closing: delta, opening: nil)
        } else if entry.type != .correct {
            openingDelayAdjustment = (openingDelayAdjustment - delta).clamped(to: minOpening...maxOpening)
            removeVoteFromFirebasePublic(closing: nil, opening: delta)
        }

        if entry.type != .correct { feedbackCount = max(0, feedbackCount - 1) }
        history.removeAll { $0.id == entry.id }
        persistLocal()
        saveHistory()
        showMessage("Rückgängig gemacht – auch aus Firebase entfernt.")
    }

    /// Alles zurücksetzen inkl. Cloud (für kompletten Reset)
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

    /// Nur lokale Daten löschen — Cloud bleibt erhalten
    func resetLocalLearning() {
        closingOffsetAdjustment = 0
        openingDelayAdjustment  = 0
        feedbackCount           = 0
        history.removeAll()
        persistLocal()
        saveHistory()
        showMessage("Deine Lerndaten wurden gelöscht.")
    }

    // MARK: Automatisches Lernen aus Schranken-Modus

    /// Korrigiert den Schließzeitpunkt automatisch — gibt den Firebase-Vote-Wert zurück
    @discardableResult
    func applyAutoClosingCorrection(_ delta: Double) -> Double {
        let correction = delta * 0.3
        closingOffsetAdjustment = (closingOffsetAdjustment + correction).clamped(to: minClosing...maxClosing)
        feedbackCount += 1
        persistLocal()
        addVoteToFirebase(closing: correction, opening: nil)
        return correction
    }

    /// Korrigiert die Öffnungsverzögerung automatisch — gibt den Firebase-Vote-Wert zurück
    @discardableResult
    func applyAutoOpeningCorrection(_ delta: Double) -> Double {
        let correction = delta * 0.3
        openingDelayAdjustment = (openingDelayAdjustment + correction).clamped(to: minOpening...maxOpening)
        feedbackCount += 1
        persistLocal()
        addVoteToFirebase(closing: nil, opening: correction)
        return correction
    }

    var closingOffsetAdjustmentPublic: Double {
        get { closingOffsetAdjustment }
        set { closingOffsetAdjustment = newValue.clamped(to: minClosing...maxClosing); persistLocal() }
    }

    var openingDelayAdjustmentPublic: Double {
        get { openingDelayAdjustment }
        set { openingDelayAdjustment = newValue.clamped(to: minOpening...maxOpening); persistLocal() }
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

    // MARK: JSONBin — Option 2 (Median) + Option 3 (Undo-Sync)

    private func addVoteToFirebase(closing: Double?, opening: Double?) {
        if let c = closing { closingVotesCache.append(c) }
        if let o = opening { openingVotesCache.append(o) }
        Task { await jsonBin.saveVotes(closingVotes: closingVotesCache, openingVotes: openingVotesCache) }
    }

    func removeVoteFromFirebasePublic(closing: Double?, opening: Double?) {
        if let c = closing { closingVotesCache.removeAll { $0 == c } }
        if let o = opening { openingVotesCache.removeAll { $0 == o } }
        Task { await jsonBin.saveVotes(closingVotes: closingVotesCache, openingVotes: openingVotesCache) }
    }

    private func loadFromJSONBin() async {
        let (closingVotes, openingVotes) = await jsonBin.loadVotes()
        await MainActor.run {
            self.closingVotesCache = closingVotes
            self.openingVotesCache = openingVotes
            self.isCloudConnected  = true
            if !closingVotes.isEmpty {
                self.closingOffsetAdjustment = Self.median(of: closingVotes).clamped(to: minClosing...maxClosing)
            }
            if !openingVotes.isEmpty {
                self.openingDelayAdjustment = Self.median(of: openingVotes).clamped(to: minOpening...maxOpening)
            }
            let total = closingVotes.count + openingVotes.count
            if total > self.feedbackCount { self.feedbackCount = total }
            self.persistLocal()
        }
    }

    private func resetFirebase() {
        closingVotesCache = []
        openingVotesCache = []
        Task { await jsonBin.saveVotes(closingVotes: [], openingVotes: []) }
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
