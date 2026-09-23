import SwiftUI

/// Liste vergangener Fahrten (Ziel, betroffener Übergang, Ausgang) — gleicher Listenstil wie
/// CrossingHistoryView (SchrankenModeView.swift). Einträge entstehen in
/// RouteViewModel.startTrip()/stopTrip(), hier nur Anzeige + Löschen.
struct TripHistoryView: View {
    let routeViewModel: RouteViewModel
    @Environment(\.dismiss) private var dismiss

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        f.locale = Locale(identifier: "de_DE")
        return f
    }()

    var body: some View {
        NavigationStack {
            Group {
                if routeViewModel.tripHistory.isEmpty {
                    ContentUnavailableView(
                        "Keine Fahrten",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Noch keine Fahrt über \"Fahrt\" gestartet.")
                    )
                } else {
                    List {
                        ForEach(routeViewModel.tripHistory) { trip in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(trip.destinationName)
                                        .font(.subheadline.bold())
                                    Spacer()
                                    Text(dateFormatter.string(from: trip.date))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if let crossingName = trip.crossingName {
                                    HStack(spacing: 6) {
                                        Image(systemName: "road.lanes")
                                            .foregroundStyle(.secondary)
                                        Text(crossingName)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        if trip.wasBlockedAtStart == true {
                                            Text("war zu")
                                                .font(.caption.bold())
                                                .foregroundStyle(.red)
                                        }
                                    }
                                    if let delay = trip.finalDelayMinutes, delay != 0 {
                                        Text(delay > 0 ? "Zug kam \(delay) Min später als erwartet" : "Zug kam \(-delay) Min früher als erwartet")
                                            .font(.caption2)
                                            .foregroundStyle(.orange)
                                    }
                                } else {
                                    Text("Kein bekannter Bahnübergang auf der Route")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .onDelete { routeViewModel.deleteTripHistory(at: $0) }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Fahrten-Verlauf")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    TripHistoryView(routeViewModel: RouteViewModel())
}
