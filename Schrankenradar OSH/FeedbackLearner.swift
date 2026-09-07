import Foundation
import Observation

// MARK: - Key-Hilfsfunktion (pro Übergang)

private func key(_ base: String, crossing: String) -> String {
    "\(base)_\(crossing)"
}

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

    let crossingId: String  // z.B. "osh_dachauer"

    // Manuelles Feedback — gilt für beide Richtungen
    private(set) var closingOffsetAdjustment: Double
    private(set) var openingDelayAdjustment: Double
    private(set) var feedbackCount: Int
    var stepSeconds: Double

    // Richtungs-spezifische Korrekturen aus dem Schranken-Modus
    private(set) var closingOffsetToMunich: Double
    private(set) var closingOffsetToFreising: Double

    var lastFeedbackMessage: String? = nil
    private(set) var isCloudConnected: Bool = false
    /// Anzahl Community-Votes (geräteübergreifend) für diesen Übergang — auch wenn sie
    /// sich netto aufheben. Nötig damit das Genauigkeits-Badge auf einem ZWEITEN Gerät
    /// „Gelernt“ zeigt (lokales feedbackCount kennt fremde Geräte nicht).
    private(set) var communityVoteCount: Int = 0
    private let jsonBin = JSONBinService()
    private(set) var history: [FeedbackEntry] = []

    // UserDefaults Keys — pro Übergang eindeutig
    private var keyClosingOffset:   String { key("closingOffsetAdjustment",  crossing: crossingId) }
    private var keyOpeningDelay:    String { key("openingDelayAdjustment",   crossing: crossingId) }
    private var keyFeedbackCount:   String { key("feedbackCount",            crossing: crossingId) }
    private var keyStepSeconds:     String { key("feedbackStepSeconds",      crossing: crossingId) }
    private var keyHistory:         String { key("feedbackHistory",          crossing: crossingId) }
    private var keyClosingMunich:   String { key("closingOffsetMunich",      crossing: crossingId) }
    private var keyClosingFreising: String { key("closingOffsetFreising",    crossing: crossingId) }

    init(crossingId: String = "osh_dachauer") {
        self.crossingId         = crossingId
        let kClose   = key("closingOffsetAdjustment", crossing: crossingId)
        let kOpen    = key("openingDelayAdjustment",  crossing: crossingId)
        let kCount   = key("feedbackCount",           crossing: crossingId)
        let kStep    = key("feedbackStepSeconds",     crossing: crossingId)
        let kMunich  = key("closingOffsetMunich",     crossing: crossingId)
        let kFreis   = key("closingOffsetFreising",   crossing: crossingId)
        closingOffsetAdjustment = UserDefaults.standard.double(forKey: kClose)
        openingDelayAdjustment  = UserDefaults.standard.double(forKey: kOpen)
        feedbackCount           = UserDefaults.standard.integer(forKey: kCount)
        closingOffsetToMunich   = UserDefaults.standard.double(forKey: kMunich)
        closingOffsetToFreising = UserDefaults.standard.double(forKey: kFreis)
        let stored = UserDefaults.standard.double(forKey: kStep)
        stepSeconds = stored > 0 ? stored : defaultStepSeconds
        history = Self.loadHistory(crossingId: crossingId)
        Task { await loadFromJSONBin() }
    }

    // MARK: Öffentliche API

    /// Gesamtoffset = Basis + manuelles Feedback + richtungs-spezifische Auto-Korrektur
    func totalClosingOffset(base: Double, toMunich: Bool) -> Double {
        let directionOffset = toMunich ? closingOffsetToMunich : closingOffsetToFreising
        return base + closingOffsetAdjustment + directionOffset
    }

    var totalOpeningDelay: Double {
        // Basis 20s: S-Bahn-Schranken bleiben ~20-30s nach Zugdurchfahrt geschlossen
        // bevor sie zu öffnen beginnen. War vorher 10s, was zu frühem Grün führte.
        20 + openingDelayAdjustment
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
        addVoteToCloud(closing: delta, opening: nil)
        showMessage("Verstanden – Schranke schließt \(Int(closingOffsetAdjustment))s später als Basis.")
    }

    func submitTooLateRed() {
        let delta = -stepSeconds
        closingOffsetAdjustment = (closingOffsetAdjustment + delta).clamped(to: minClosing...maxClosing)
        feedbackCount += 1
        addHistory(.tooLateRed)
        persistLocal()
        addVoteToCloud(closing: delta, opening: nil)
        showMessage("Verstanden – Schranke schließt \(Int(closingOffsetAdjustment))s früher als Basis.")
    }

    func submitTooEarlyGreen() {
        let delta = stepSeconds
        openingDelayAdjustment = (openingDelayAdjustment + delta).clamped(to: minOpening...maxOpening)
        feedbackCount += 1
        addHistory(.tooEarlyGreen)
        persistLocal()
        addVoteToCloud(closing: nil, opening: delta)
        showMessage("Verstanden – Schranke bleibt \(Int(totalOpeningDelay))s nach Zug geschlossen.")
    }

    func submitTooLateGreen() {
        let delta = -stepSeconds
        openingDelayAdjustment = (openingDelayAdjustment + delta).clamped(to: minOpening...maxOpening)
        feedbackCount += 1
        addHistory(.tooLateGreen)
        persistLocal()
        addVoteToCloud(closing: nil, opening: delta)
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
        showMessage("Rückgängig gemacht – auch aus Cloud entfernt.")
    }

    /// Alles zurücksetzen inkl. Cloud (für kompletten Reset)
    func resetLearning() {
        closingOffsetAdjustment = 0
        openingDelayAdjustment  = 0
        closingOffsetToMunich   = 0
        closingOffsetToFreising = 0
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
        closingOffsetToMunich   = 0
        closingOffsetToFreising = 0
        feedbackCount           = 0
        history.removeAll()
        persistLocal()
        saveHistory()
        showMessage("Deine Lerndaten wurden gelöscht.")
    }

    // MARK: Automatisches Lernen aus Schranken-Modus

    /// Korrigiert den Schließzeitpunkt richtungs-spezifisch — gibt den Vote-Wert zurück
    @discardableResult
    func applyAutoClosingCorrection(_ delta: Double, toMunich: Bool) -> Double {
        let correction = delta * 0.3
        if toMunich {
            closingOffsetToMunich = (closingOffsetToMunich + correction).clamped(to: minClosing...maxClosing)
        } else {
            closingOffsetToFreising = (closingOffsetToFreising + correction).clamped(to: minClosing...maxClosing)
        }
        feedbackCount += 1
        persistLocal()
        // Richtungs-spezifisch in Cloud speichern
        Task {
            await jsonBin.submitVote(
                crossingId: crossingId,
                closingDelta: nil, openingDelta: nil,
                closingMunich:   toMunich ? correction : nil,
                closingFreising: toMunich ? nil : correction
            )
        }
        return correction
    }

    /// Korrigiert die Öffnungsverzögerung automatisch — gibt den Firebase-Vote-Wert zurück
    @discardableResult
    func applyAutoOpeningCorrection(_ delta: Double) -> Double {
        let correction = delta * 0.3
        openingDelayAdjustment = (openingDelayAdjustment + correction).clamped(to: minOpening...maxOpening)
        feedbackCount += 1
        persistLocal()
        addVoteToCloud(closing: nil, opening: correction)
        return correction
    }

    /// Setzt NUR die richtungs-spezifische Auto-Korrektur (aus Schranken-Modus) einer
    /// Richtung zurück — lässt die andere Richtung UND den direktions-unabhängigen manuellen
    /// Feedback-Anteil (closingOffsetAdjustment) unangetastet. Nötig für den Fall, dass eine
    /// Richtung bereits korrekt gelernt ist und nur die andere zurückgesetzt werden soll.
    func resetDirectionalLearning(toMunich: Bool) {
        if toMunich {
            closingOffsetToMunich = 0
        } else {
            closingOffsetToFreising = 0
        }
        persistLocal()
    }

    /// Richtungs-spezifische Auto-Korrektur rückgängig machen (beim Löschen eines Records)
    func revertAutoClosingCorrection(_ vote: Double, toMunich: Bool) {
        if toMunich {
            closingOffsetToMunich = (closingOffsetToMunich - vote).clamped(to: minClosing...maxClosing)
        } else {
            closingOffsetToFreising = (closingOffsetToFreising - vote).clamped(to: minClosing...maxClosing)
        }
        feedbackCount = max(0, feedbackCount - 1)
        persistLocal()
        Task {
            await jsonBin.submitVote(
                crossingId: crossingId,
                closingDelta: nil, openingDelta: nil,
                closingMunich:   toMunich ? -vote : nil,
                closingFreising: toMunich ? nil : -vote
            )
        }
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
        UserDefaults.standard.set(closingOffsetToMunich,   forKey: keyClosingMunich)
        UserDefaults.standard.set(closingOffsetToFreising, forKey: keyClosingFreising)
    }

    // MARK: JSONBin — User-Median Aggregation

    private func addVoteToCloud(closing: Double?, opening: Double?) {
        Task { await jsonBin.submitVote(crossingId: crossingId, closingDelta: closing, openingDelta: opening) }
    }

    func removeVoteFromFirebasePublic(closing: Double?, opening: Double?) {
        // Bei Undo: den ursprünglichen Vote WIRKLICH aus der Cloud entfernen
        // (nicht mehr einen Gegen-Vote anhängen — das polluierte die Daten).
        Task {
            await jsonBin.removeLastVote(
                crossingId: crossingId,
                closingDelta: closing,
                openingDelta: opening
            )
        }
    }

    private func loadFromJSONBin() async {
        let result = await jsonBin.loadAggregated(crossingId: crossingId)
        await MainActor.run {
            self.isCloudConnected = true
            self.communityVoteCount = result.voteCount
            if result.closing  != 0 { self.closingOffsetAdjustment = result.closing.clamped(to: minClosing...maxClosing) }
            if result.opening  != 0 { self.openingDelayAdjustment  = result.opening.clamped(to: minOpening...maxOpening) }
            if result.munich   != 0 { self.closingOffsetToMunich   = result.munich.clamped(to: minClosing...maxClosing) }
            if result.freising != 0 { self.closingOffsetToFreising = result.freising.clamped(to: minClosing...maxClosing) }
            self.persistLocal()
        }
    }

    private func resetFirebase() {
        Task { await jsonBin.resetUserVotes() }
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

    private static func loadHistory(crossingId: String) -> [FeedbackEntry] {
        let k = key("feedbackHistory", crossing: crossingId)
        guard let data = UserDefaults.standard.data(forKey: k),
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
