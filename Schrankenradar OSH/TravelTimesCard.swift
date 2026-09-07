import SwiftUI
import MapKit

/// Karte mit geschätzten Fahrzeiten (Auto/Rad/Fuß) vom aktuellen Standort zu einem
/// Bahnübergang — wird sowohl im Anfahrt-Tab als auch oben im Radar-Tab verwendet, damit
/// beide immer dieselbe Berechnung/Anzeige zeigen statt zweier abweichender Implementierungen.
struct TravelTimesCard: View {
    var crossing: CrossingLocation
    var locationMonitor: LocationMonitor
    /// Meldet die aktuelle Auto-Fahrzeit nach oben — genutzt von ContentView, um in der
    /// Zugliste pro Zug einen Haken/Ausrufezeichen zu zeigen ("schaffst du's noch rechtzeitig").
    var onCarETAUpdate: ((TimeInterval?) -> Void)? = nil

    private struct ETAs {
        var car: TimeInterval?
        var cycling: TimeInterval?
        var walking: TimeInterval?
    }

    @State private var etas = ETAs()
    @State private var isLoading = false
    @State private var loadError: String?
    /// Für welchen Übergang zuletzt tatsächlich geladen wurde — nur zur Entprellung unten
    /// genutzt (siehe .task), kein UI-relevanter Zustand.
    @State private var lastFetchedCrossingID: String?

    var body: some View {
        Group {
            if let coordinate = locationMonitor.currentCoordinate {
                VStack(spacing: 12) {
                    etaRow(icon: "car.fill", label: "Auto", seconds: etas.car)
                    Divider()
                    etaRow(icon: "bicycle", label: "Fahrrad", seconds: etas.cycling)
                    Divider()
                    etaRow(icon: "figure.walk", label: "Zu Fuß", seconds: etas.walking)
                    if let loadError {
                        Text(loadError)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .cardStyle()
                // Task-id auf ein ~100m-Raster gerundet statt Roh-Koordinaten: jedes noch so
                // kleine GPS-Zittern hat sonst eine neue id erzeugt und damit sofort 3 neue
                // MKDirections-Anfragen (Auto/Rad/Fuß) ausgelöst — bei häufigen GPS-Updates
                // während der Fahrt hat das Apples Limit von 50 Anfragen/60s gerissen
                // ("Throttled ETA request", GEOErrorDomain -3), wodurch die Fahrzeiten (und
                // damit der Haken/Ausrufezeichen bei den Zügen) zeitweise ausfielen.
                .task(id: "\(gridRounded(coordinate.latitude)),\(gridRounded(coordinate.longitude)),\(crossing.id)") {
                    // Beim ersten Erscheinen bzw. bei Wechsel des Übergangs sofort laden;
                    // bei bloßer Positionsänderung am selben Übergang 15s entprellen — SwiftUI
                    // bricht diesen Task bei jeder neuen id ab und startet ihn neu, sodass in
                    // einem 15s-Fenster nur die jeweils letzte Positionsänderung tatsächlich
                    // eine Anfrage auslöst.
                    if lastFetchedCrossingID == crossing.id {
                        try? await Task.sleep(for: .seconds(15))
                        guard !Task.isCancelled else { return }
                    }
                    lastFetchedCrossingID = crossing.id
                    await loadETAs(from: coordinate)
                }
            } else {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Standort wird ermittelt…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(16)
                .cardStyle()
            }
        }
    }

    private func etaRow(icon: String, label: String, seconds: TimeInterval?) -> some View {
        HStack {
            Label(label, systemImage: icon)
                .font(.subheadline)
            Spacer()
            if isLoading, seconds == nil {
                ProgressView()
            } else if let seconds {
                Text(Self.formatted(seconds))
                    .font(.subheadline.bold().monospacedDigit())
            } else {
                Text("—")
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Rundet auf ein ~0.001°-Raster (≈70-110m je nach Breitengrad) — für die .task-id, damit
    /// GPS-Rauschen keine neue Anfrage auslöst, echte Fortbewegung aber weiterhin erfasst wird.
    private func gridRounded(_ value: Double) -> Double {
        (value / 0.001).rounded() * 0.001
    }

    private static func formatted(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        if minutes < 60 { return "\(minutes) Min" }
        return "\(minutes / 60) Std \(minutes % 60) Min"
    }

    // MARK: - Fahrzeiten laden

    @MainActor
    private func loadETAs(from coordinate: CLLocationCoordinate2D) async {
        isLoading = true
        loadError = nil
        etas = ETAs()

        async let car     = eta(from: coordinate, transportType: .automobile)
        async let cycling = eta(from: coordinate, transportType: .cycling)
        async let walking = eta(from: coordinate, transportType: .walking)

        let (carResult, cyclingResult, walkingResult) = await (car, cycling, walking)
        etas = ETAs(car: carResult, cycling: cyclingResult, walking: walkingResult)
        isLoading = false
        onCarETAUpdate?(carResult)

        if carResult == nil, cyclingResult == nil, walkingResult == nil {
            loadError = "Fahrzeiten konnten nicht berechnet werden."
        }
    }

    private func eta(from coordinate: CLLocationCoordinate2D,
                      transportType: MKDirectionsTransportType) async -> TimeInterval? {
        let request = MKDirections.Request()
        request.source      = MKMapItem(location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude), address: nil)
        request.destination = MKMapItem(location: CLLocation(latitude: crossing.latitude, longitude: crossing.longitude), address: nil)
        request.transportType = transportType
        do {
            let response = try await MKDirections(request: request).calculateETA()
            return response.expectedTravelTime
        } catch {
            return nil
        }
    }
}
