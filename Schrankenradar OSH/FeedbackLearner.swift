import Foundation
import Observation

private let userDefaultsKey = "crossingOffsetAdjustment"
private let stepSeconds: Double = 15      // Lernschrittgröße pro Feedback
private let minOffset: Double = -300      // Schranke: nie mehr als 5 min früher
private let maxOffset: Double = 300       // Schranke: nie mehr als 5 min später

@Observable
final class FeedbackLearner {
    private(set) var offsetAdjustment: Double
    private(set) var feedbackCount: Int
    var lastFeedbackMessage: String? = nil

    init() {
        offsetAdjustment = UserDefaults.standard.double(forKey: userDefaultsKey)
        feedbackCount    = UserDefaults.standard.integer(forKey: "\(userDefaultsKey)_count")
    }

    /// Gesamtversatz = Basisversatz + gelernter Versatz
    func totalOffset(base: Double) -> Double {
        base + offsetAdjustment
    }

    func submitCorrect() {
        showMessage("Danke! Vorhersage bestätigt.")
    }

    func submitIncorrect(currentStatus: CrossingStatus, note: String = "") {
        let delta: Double
        switch currentStatus {
        case .open:
            delta = +stepSeconds
            showMessage("Verstanden – Schranke schließt früher als gedacht.")
        case .warning, .closed:
            delta = -stepSeconds
            showMessage("Verstanden – Schranke war noch offen.")
        }

        offsetAdjustment = (offsetAdjustment + delta).clamped(to: minOffset...maxOffset)
        feedbackCount += 1
        if !note.isEmpty { saveNote(note, status: currentStatus) }
        persist()
    }

    private(set) var notes: [FeedbackNote] = []

    private func saveNote(_ text: String, status: CrossingStatus) {
        let note = FeedbackNote(text: text, status: status, date: Date())
        notes.append(note)
        // Nur letzte 50 Notizen behalten
        if notes.count > 50 { notes.removeFirst() }
    }

    func resetLearning() {
        offsetAdjustment = 0
        feedbackCount    = 0
        persist()
        showMessage("Lerndaten zurückgesetzt.")
    }

    private func persist() {
        UserDefaults.standard.set(offsetAdjustment, forKey: userDefaultsKey)
        UserDefaults.standard.set(feedbackCount,    forKey: "\(userDefaultsKey)_count")
    }

    private func showMessage(_ text: String) {
        lastFeedbackMessage = text
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            if lastFeedbackMessage == text {
                lastFeedbackMessage = nil
            }
        }
    }
}

struct FeedbackNote: Identifiable {
    let id = UUID()
    let text: String
    let status: CrossingStatus
    let date: Date
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.max(range.lowerBound, Swift.min(range.upperBound, self))
    }
}
