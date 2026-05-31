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

    let feedback = FeedbackLearner()
    private let service = TrainAPIService()
    private var refreshTask: Task<Void, Never>?
    private var liveActivity: Activity<CrossingActivityAttributes>?

    func startAutoRefresh() {
        refreshTask?.cancel()
        isLoading = false  // vorherigen abgebrochenen Fetch zurücksetzen
        refreshTask = Task {
            while !Task.isCancelled {
                await fetchData()
                try? await Task.sleep(for: .seconds(30))
                if Task.isCancelled { break }
            }
        }
    }

    func stopAutoRefresh() {
        refreshTask?.cancel()
    }

    @MainActor
    func fetchData() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let trains = try await service.fetchDepartures()
            nextEvents = buildEvents(from: trains)
            lastUpdated = Date()
            WidgetCenter.shared.reloadAllTimelines()
            updateLiveActivity(events: nextEvents)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func buildEvents(from trains: [TrainEntry]) -> [CrossingEvent] {
        trains
            .filter { !$0.isCancelled }
            .compactMap { train -> CrossingEvent? in
                let base: Double = train.direction == .toMunich
                    ? crossingOffsetSeconds
                    : -crossingOffsetSeconds
                let offset = feedback.totalClosingOffset(base: base)

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

    // MARK: - Live Activity

    private func updateLiveActivity(events: [CrossingEvent]) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        // Nächsten relevanten Zug finden (innerhalb 5 Minuten)
        let now = Date()
        let relevant = events.first { $0.minutesUntil(from: now) > -1 && $0.minutesUntil(from: now) < 5 }

        guard let event = relevant else {
            // Kein Zug in der Nähe → Activity beenden
            Task {
                await liveActivity?.end(dismissalPolicy: .immediate)
                liveActivity = nil
            }
            return
        }

        let crossing  = event.estimatedCrossingTime
        let closing   = crossing.addingTimeInterval(-60)   // 1 min vor Zug → rot
        let opening   = crossing.addingTimeInterval(openingDelaySeconds)

        let state = CrossingActivityAttributes.ContentState(
            closingTime:    closing,
            openingTime:    opening,
            statusRaw:      event.status(at: now).rawString,
            trainLine:      event.train.lineName,
            trainDirection: event.train.resolvedDirection.label
        )

        if let activity = liveActivity {
            // Bestehende Activity updaten
            Task { await activity.update(.init(state: state)) }
        } else {
            // Neue Activity starten
            let attributes = CrossingActivityAttributes(crossingName: "Bahnübergang Dachauer Str.")
            liveActivity = try? Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: crossing.addingTimeInterval(120))
            )
        }
    }
}
