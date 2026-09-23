import Foundation
import Observation

/// Globaler (nicht pro Übergang) Lebenszeit-Zähler für abgegebene Meldungen — getrennt von
/// `FeedbackLearner.feedbackCount` (pro Übergang, dient der Kalibrierung, kann bei Undo wieder
/// sinken). Dieser Zähler ehrt die Lebenszeit-Mitwirkung und sinkt nie, auch nicht bei einem
/// Undo — man hat die Meldung ja trotzdem abgegeben. Gleiches Singleton-Muster wie
/// `DebugLog`/`MetricKitMonitor`.
@Observable
final class RankTracker {
    static let shared = RankTracker()

    private(set) var lifetimeMeldungen: Int
    private(set) var currentRank: Rank
    /// Nicht-nil solange ein erreichter Rang noch nicht gefeiert wurde — bleibt über einen
    /// Force-Quit hinweg erhalten (siehe celebratedKey), damit kein Aufstieg verloren geht.
    private(set) var pendingRankUp: Rank?

    /// Meldungen seit Beginn der laufenden Kalenderwoche — für die Statistik-Kachel im
    /// Wächter-Tab. Setzt sich beim Wochenwechsel selbst zurück (siehe recordMeldung()).
    private(set) var weeklyMeldungen: Int
    private var weekStart: Date

    /// Anzahl aufeinanderfolgender Kalendertage mit mindestens einer Meldung.
    private(set) var streakDays: Int
    private var lastMeldungDay: Date?

    /// Erfahrungspunkte — reine Ableitung aus lifetimeMeldungen/weeklyMeldungen (Faktor 20,
    /// wie im Rang-Mockup vorgegeben), keine eigene Persistenz nötig und kein Drift-Risiko
    /// zwischen zwei Zählern für dieselbe zugrunde liegende Zahl.
    var xp: Int { lifetimeMeldungen * 20 }
    var weeklyXP: Int { weeklyMeldungen * 20 }

    private static let countKey = "rankTracker_lifetimeMeldungen"
    private static let celebratedKey = "rankTracker_lastCelebratedRank"
    private static let weeklyCountKey = "rankTracker_weeklyMeldungen"
    private static let weekStartKey = "rankTracker_weekStart"
    private static let streakDaysKey = "rankTracker_streakDays"
    private static let lastMeldungDayKey = "rankTracker_lastMeldungDay"

    private init() {
        let count = UserDefaults.standard.integer(forKey: Self.countKey)
        let lastCelebrated = UserDefaults.standard.integer(forKey: Self.celebratedKey)
        // Lokale Variable statt self.currentRank zu lesen — @Observable's synthetisierte
        // Property-Zugriffe brauchen ein voll initialisiertes self, das ist vor Zuweisung
        // ALLER gespeicherten Properties (auch der weiter unten folgenden) noch nicht der Fall.
        let rank = Rank.forCount(count)

        lifetimeMeldungen = count
        currentRank = rank
        pendingRankUp = rank.rawValue > lastCelebrated ? rank : nil

        let storedWeekStart = UserDefaults.standard.object(forKey: Self.weekStartKey) as? Date
        let currentWeekStart = Self.startOfWeek(for: Date())
        if let storedWeekStart, storedWeekStart == currentWeekStart {
            weeklyMeldungen = UserDefaults.standard.integer(forKey: Self.weeklyCountKey)
            weekStart = storedWeekStart
        } else {
            // Erster Start oder App war seit dem letzten Wochenwechsel nicht offen — zählt
            // erst bei der nächsten Meldung wieder von 0, kein rückwirkendes Zurücksetzen nötig.
            weeklyMeldungen = 0
            weekStart = currentWeekStart
        }

        streakDays = UserDefaults.standard.integer(forKey: Self.streakDaysKey)
        lastMeldungDay = UserDefaults.standard.object(forKey: Self.lastMeldungDayKey) as? Date
    }

    func recordMeldung() {
        lifetimeMeldungen += 1
        UserDefaults.standard.set(lifetimeMeldungen, forKey: Self.countKey)
        let newRank = Rank.forCount(lifetimeMeldungen)
        if newRank != currentRank {
            currentRank = newRank
            pendingRankUp = newRank
        }

        let currentWeekStart = Self.startOfWeek(for: Date())
        if currentWeekStart != weekStart {
            weeklyMeldungen = 0
            weekStart = currentWeekStart
            UserDefaults.standard.set(weekStart, forKey: Self.weekStartKey)
        }
        weeklyMeldungen += 1
        UserDefaults.standard.set(weeklyMeldungen, forKey: Self.weeklyCountKey)

        updateStreak()
    }

    /// Tagesgenauer Vergleich über `Calendar`-Komponenten statt roher Zeit-Differenz (DST-sicher
    /// — eine reine Sekunden-Differenz/86400 kann an Zeitumstellungstagen einen Tag daneben liegen).
    private func updateStreak() {
        let today = Calendar.current.startOfDay(for: Date())
        if let lastMeldungDay {
            let daysBetween = Calendar.current.dateComponents([.day], from: lastMeldungDay, to: today).day ?? 0
            switch daysBetween {
            case 0: break                    // heute schon gezählt, Streak unverändert
            case 1: streakDays += 1          // nahtlos weiterer Tag
            default: streakDays = 1          // Lücke (oder Uhrzeit-Anomalie) — neu bei 1 beginnen
            }
        } else {
            streakDays = 1
        }
        self.lastMeldungDay = today
        UserDefaults.standard.set(streakDays, forKey: Self.streakDaysKey)
        UserDefaults.standard.set(today, forKey: Self.lastMeldungDayKey)
    }

    func consumeRankUpEvent() {
        guard let pendingRankUp else { return }
        UserDefaults.standard.set(pendingRankUp.rawValue, forKey: Self.celebratedKey)
        self.pendingRankUp = nil
    }

    private static func startOfWeek(for date: Date) -> Date {
        Calendar.current.dateInterval(of: .weekOfYear, for: date)?.start ?? date
    }
}
