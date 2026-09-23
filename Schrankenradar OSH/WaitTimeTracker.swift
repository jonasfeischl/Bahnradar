import Foundation
import Observation

/// Passiv erfasste Wartezeit vor Schranken — jede Sekunde, in der der Nutzer nachweislich in
/// Reichweite eines Übergangs UND die Schranke unten ist, zählt (siehe
/// CrossingViewModel.evaluateWaitTimeTracking(), Teil desselben 1s-Monitors wie die
/// Sprachansagen). Bewusst NICHT aus CrossingRecorder abgeleitet — der erfasst nur manuell im
/// Schranken-Modus bestätigte Ereignisse, nicht jede bloße Anwesenheit, und würde die tatsächlich
/// erlebte Wartezeit für die meisten Nutzer stark unterschätzen. Gleiches Singleton-Muster wie
/// RankTracker.
@Observable
final class WaitTimeTracker {
    static let shared = WaitTimeTracker()

    /// Key "yyyy-MM" → aufsummierte Sekunden in diesem Monat.
    private(set) var monthlySeconds: [String: TimeInterval]
    private var lastTick: Date?
    /// Seit dem letzten UserDefaults-Schreiben angesammelte Sekunden — vermeidet einen Disk-
    /// Schreibzugriff JEDE Sekunde während einer laufenden Wartezeit (kann mehrere Minuten
    /// dauern); wird alle 10s sowie beim Ende einer Wartephase geflusht.
    private var unsavedSeconds: TimeInterval = 0

    private static let storageKey = "waitTimeTracker_monthlySeconds"

    private init() {
        monthlySeconds = UserDefaults.standard.dictionary(forKey: Self.storageKey) as? [String: TimeInterval] ?? [:]
    }

    /// Von CrossingViewModels 1-Sekunden-Monitor aufgerufen (evaluateWaitTimeTracking()).
    /// Nutzt die tatsächlich seit dem letzten Tick verstrichene Zeit statt fix 1s aufzuaddieren
    /// (auf max. 5s gekappt) — sonst würde ein verzögerter/verpasster Tick (App-Suspend,
    /// Hintergrund-Drosselung) einen künstlichen Sprung in der Wartezeit erzeugen.
    func tick(isWaiting: Bool) {
        let now = Date()
        defer { lastTick = now }
        guard isWaiting, let last = lastTick else {
            if unsavedSeconds > 0 { save() }
            return
        }
        let elapsed = min(now.timeIntervalSince(last), 5)
        guard elapsed > 0 else { return }
        monthlySeconds[Self.monthKey(for: now), default: 0] += elapsed
        unsavedSeconds += elapsed
        if unsavedSeconds >= 10 { save() }
    }

    var currentMonthSeconds: TimeInterval { monthlySeconds[Self.monthKey(for: Date()), default: 0] }
    var currentMonthDisplayName: String { Self.displayName(for: Self.monthKey(for: Date())) }

    /// Neuester Monat zuerst.
    var history: [(monthKey: String, seconds: TimeInterval)] {
        monthlySeconds.sorted { $0.key > $1.key }.map { ($0.key, $0.value) }
    }

    private func save() {
        UserDefaults.standard.set(monthlySeconds, forKey: Self.storageKey)
        unsavedSeconds = 0
    }

    private static func monthKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        formatter.locale = Locale(identifier: "en_US_POSIX")  // fixes Format unabhängig vom Nutzer-Kalender
        return formatter.string(from: date)
    }

    /// "yyyy-MM" → "September 2026" für die Anzeige.
    static func displayName(for monthKey: String) -> String {
        let inFormatter = DateFormatter()
        inFormatter.dateFormat = "yyyy-MM"
        inFormatter.locale = Locale(identifier: "en_US_POSIX")
        guard let date = inFormatter.date(from: monthKey) else { return monthKey }
        let outFormatter = DateFormatter()
        outFormatter.dateFormat = "LLLL yyyy"
        outFormatter.locale = Locale(identifier: "de_DE")
        return outFormatter.string(from: date)
    }

    /// "3 Std 12 Min" bzw. "45 Min" wenn unter einer Stunde.
    static func formatted(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return hours > 0 ? "\(hours) Std \(remainingMinutes) Min" : "\(remainingMinutes) Min"
    }
}
