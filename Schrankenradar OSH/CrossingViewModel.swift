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
                let offset = feedback.totalOffset(base: base)

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
                return CrossingEvent(id: train.id, train: departure, estimatedCrossingTime: crossingTime)
            }
            .sorted { $0.estimatedCrossingTime < $1.estimatedCrossingTime }
    }

    var worstUpcomingStatus: CrossingStatus {
        let upcoming = nextEvents.filter { $0.minutesUntil > -0.5 && $0.minutesUntil < 5 }
        if upcoming.contains(where: { $0.status == .closed }) { return .closed }
        if upcoming.contains(where: { $0.status == .warning }) { return .warning }
        return .open
    }
}
