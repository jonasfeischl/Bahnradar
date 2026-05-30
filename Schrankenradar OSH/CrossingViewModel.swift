import SwiftUI
import Observation

// Abstand zwischen Station Oberschleißheim und Bahnübergang Dachauer Str. (in Sekunden)
// Südlich gelegener Übergang:
//   → München: Zug fährt ab, kreuzt danach  → + offset
//   → Freising: Zug kommt an, kreuzte davor → - offset
private let crossingOffsetSeconds: Double = 180

@Observable
final class CrossingViewModel {
    var nextEvents: [CrossingEvent] = []
    var isLoading = false
    var errorMessage: String? = nil
    var lastUpdated: Date? = nil

    let feedback = FeedbackLearner()
    private let service = TrainAPIService()
    private var refreshTask: Task<Void, Never>?

    func startAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            while !Task.isCancelled {
                await fetchData()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func stopAutoRefresh() {
        refreshTask?.cancel()
    }

    func fetchData() async {
        isLoading = true
        errorMessage = nil
        do {
            let trains = try await service.fetchDepartures()
            nextEvents = buildEvents(from: trains)
            lastUpdated = Date()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
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
                guard crossingTime.timeIntervalSinceNow > -30 else { return nil }

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
                    openingDelayMinutes: feedback.totalOpeningDelay / 60
                )
            }
            .sorted { $0.estimatedCrossingTime < $1.estimatedCrossingTime }
    }

    var worstUpcomingStatus: CrossingStatus {
        // Alle Events im relevanten Fenster (-2 min bis +5 min)
        let upcoming = nextEvents.filter { $0.minutesUntil > -2 && $0.minutesUntil < 5 }

        let hasClosed  = upcoming.contains(where: { $0.status == .closed })
        let hasWarning = upcoming.contains(where: { $0.status == .warning })
        let hasOpening = upcoming.contains(where: { $0.status == .opening })

        // Wenn gerade geschlossen UND bald wieder ein Zug kommt → bleibt geschlossen
        if hasClosed && hasWarning { return .closed }
        if hasClosed { return .closed }

        // Kein Zug mehr kommt bald → Schranke öffnet
        if hasOpening && !hasWarning { return .opening }

        if hasWarning { return .warning }
        return .open
    }
}
