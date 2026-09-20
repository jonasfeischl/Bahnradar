import CoreLocation
import MapKit
import SwiftUI

/// Tab "Fahrt": Start/Ziel eingeben, Route berechnen lassen (berücksichtigt, ob sie über einen
/// der bekannten Bahnübergänge führt und ob dieser zur Ankunft offen/geschlossen ist), dann per
/// Knopfdruck an Apple Maps/Google Maps weiterleiten. Reine Darstellung/Eingabe — die eigentliche
/// Berechnung/Überwachung läuft in RouteViewModel.
struct RouteView: View {
    var routeViewModel: RouteViewModel
    var locationMonitor: LocationMonitor

    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var pickingLocationFor: LocationPickerTarget?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    searchSection
                    calculateButton
                    if let error = routeViewModel.calculationError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    if !routeViewModel.routes.isEmpty {
                        mapSection
                        routeOptionsSection
                        actionButtons
                    }
                    safetyDisclaimer
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Fahrt")
            .navigationBarTitleDisplayMode(.inline)
        }
        .overlay(alignment: .top) {
            if let message = routeViewModel.currentBannerMessage {
                bannerView(message)
            }
        }
        .onAppear { locationMonitor.startForScreenPresence() }
        .onDisappear { locationMonitor.stopForScreenPresence() }
        .sheet(item: $pickingLocationFor) { target in
            LocationPickerSheet(
                title: target.title,
                initialCoordinate: locationMonitor.currentCoordinate
            ) { item in
                switch target {
                case .start:       routeViewModel.setStartFromMap(item)
                case .destination: routeViewModel.setDestinationFromMap(item)
                }
            }
        }
    }

    private enum LocationPickerTarget: Identifiable {
        case start, destination
        var id: Self { self }
        var title: String {
            switch self {
            case .start:       "Start wählen"
            case .destination: "Ziel wählen"
            }
        }
    }

    // MARK: - Suche

    private var searchSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            searchField(
                label: "Start", placeholder: "Aktueller Standort",
                text: routeViewModel.startQuery, completions: routeViewModel.startCompletions,
                onChange: { routeViewModel.updateStartQuery($0) },
                onSelect: { completion in Task { await routeViewModel.selectStart(completion) } },
                onUseCurrentLocation: { routeViewModel.useCurrentLocationAsStart() },
                onPickOnMap: { pickingLocationFor = .start }
            )
            searchField(
                label: "Ziel", placeholder: "Adresse oder Ort eingeben",
                text: routeViewModel.destinationQuery, completions: routeViewModel.destinationCompletions,
                onChange: { routeViewModel.updateDestinationQuery($0) },
                onSelect: { completion in Task { await routeViewModel.selectDestination(completion) } },
                onPickOnMap: { pickingLocationFor = .destination }
            )
        }
        .padding(16)
        .cardStyle()
    }

    @ViewBuilder
    private func searchField(
        label: String, placeholder: String, text: String, completions: [MKLocalSearchCompletion],
        onChange: @escaping (String) -> Void, onSelect: @escaping (MKLocalSearchCompletion) -> Void,
        onUseCurrentLocation: (() -> Void)? = nil, onPickOnMap: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            TextField(placeholder, text: Binding(get: { text }, set: onChange))
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 16) {
                if let onUseCurrentLocation {
                    Button(action: onUseCurrentLocation) {
                        Label("Aktueller Standort", systemImage: "location.fill")
                    }
                }
                Button(action: onPickOnMap) {
                    Label("Auf Karte wählen", systemImage: "map")
                }
            }
            .font(.caption)
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            if !completions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(completions.enumerated()), id: \.offset) { _, completion in
                        Button {
                            onSelect(completion)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(completion.title)
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                                if !completion.subtitle.isEmpty {
                                    Text(completion.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
            }
        }
    }

    private var calculateButton: some View {
        Button {
            Task {
                await routeViewModel.calculateRoute(currentLocation: locationMonitor.currentCoordinate)
                updateCamera()
            }
        } label: {
            Group {
                if routeViewModel.isCalculating {
                    ProgressView().tint(.white)
                } else {
                    Text("Route berechnen")
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bigAction(.brand))
        .disabled(!routeViewModel.canCalculateRoute)
    }

    // MARK: - Karte

    /// Zeigt NUR die unten ausgewählte Karte, nicht alle Alternativen gleichzeitig überlagert
    /// (Nutzerwunsch: "die Vorschau soll immer nur die Route zeigen, die unten ausgewählt ist").
    private var mapSection: some View {
        Map(position: $cameraPosition) {
            if let index = routeViewModel.selectedRouteIndex, routeViewModel.routes.indices.contains(index) {
                MapPolyline(routeViewModel.routes[index].polyline).stroke(Color.brand, lineWidth: 5)
            }
            if let index = routeViewModel.selectedRouteIndex, routeViewModel.matchesByRoute.indices.contains(index) {
                ForEach(routeViewModel.matchesByRoute[index]) { match in
                    Marker(match.crossing.name, systemImage: "road.lanes", coordinate: match.crossing.coordinate)
                        .tint(match.statusAtArrival?.color ?? .gray)
                }
            }
            if let destination = routeViewModel.selectedDestination?.location.coordinate {
                Marker("Ziel", systemImage: "mappin", coordinate: destination)
            }
        }
        .frame(height: 280)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func updateCamera() {
        guard let index = routeViewModel.selectedRouteIndex, routeViewModel.routes.indices.contains(index) else { return }
        cameraPosition = .rect(routeViewModel.routes[index].polyline.boundingMapRect)
    }

    // MARK: - Routen-Optionen

    /// Zeigt IMMER beide Optionen nebeneinander, wenn vorhanden — "Über die Schranke" (schnellste
    /// Route mit bekanntem Übergang) und "Schranke umfahren" (schnellste Route ohne) — statt einer
    /// einzelnen Empfehlung mit versteckter Alternative (Nutzerwunsch: "ein Weg über Schranke und
    /// alternativ Schranke umfahren"). Beide Karten sind gleichwertig antippbar.
    @ViewBuilder
    private var routeOptionsSection: some View {
        VStack(spacing: 12) {
            if let index = routeViewModel.crossingRouteIndex {
                routeOptionCard(title: "Über die Schranke", icon: "arrow.up.right", index: index)
            }
            if let index = routeViewModel.detourRouteIndex {
                routeOptionCard(title: "Schranke umfahren", icon: "arrow.triangle.swap", index: index)
            } else if routeViewModel.crossingRouteIndex != nil {
                Text("Keine Umfahrung ohne bekannten Bahnübergang gefunden.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func routeOptionCard(title: String, icon: String, index: Int) -> some View {
        let isSelected = index == routeViewModel.selectedRouteIndex
        let isRecommended = index == routeViewModel.recommendedRouteIndex
        let hits = routeViewModel.matchesByRoute.indices.contains(index) ? routeViewModel.matchesByRoute[index] : []
        return Button {
            routeViewModel.selectRoute(index)
            updateCamera()
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: icon)
                    Text(title).font(.subheadline.bold())
                    if isRecommended {
                        Text("Empfohlen")
                            .font(.caption2.bold())
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.green.opacity(0.15))
                            .foregroundStyle(.green)
                            .clipShape(Capsule())
                    }
                    Spacer()
                    Text(Self.formattedDuration(routeViewModel.routes[index].expectedTravelTime))
                        .font(.subheadline.bold())
                }
                .foregroundStyle(.primary)
                if hits.isEmpty {
                    Text("Kein bekannter Bahnübergang auf dieser Route.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(hits) { match in
                            crossingDetailRow(match)
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.12) : Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }

    /// Alle Details zu einem auf der Route liegenden Übergang: Status, Ankunftszeit, Zug (falls
    /// bekannt) und konkrete Wartezeit in Minuten statt nur "kurze Wartezeit" (Nutzerwunsch).
    private func crossingDetailRow(_ match: RouteViewModel.MatchedCrossing) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: match.statusAtArrival?.systemImage ?? "questionmark.circle")
                .foregroundStyle(match.statusAtArrival?.color ?? .gray)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(match.crossing.name)
                    .font(.subheadline.bold())
                Text("Ankunft in \(Self.formattedDuration(match.etaSeconds)) — \(match.statusAtArrival?.label ?? "keine Zugdaten")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let event = match.event {
                    Text("\(event.train.lineName) Richtung \(event.train.direction)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if match.waitSeconds > 0 {
                    Text("ca. \(Self.formattedDuration(match.waitSeconds)) Wartezeit")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
        }
    }

    // MARK: - Weiterleitung

    private var actionButtons: some View {
        let isForcedBypassSelected = routeViewModel.selectedRouteIndex
            .flatMap { routeViewModel.routes.indices.contains($0) ? routeViewModel.routes[$0] : nil }?
            .forcedBypassPoint != nil
        // Google zeigen wir bei einer erzwungenen Umfahrung NICHT an: die "umfährt die Schranke"-
        // Prüfung läuft komplett über Apples Routenberechnung (beide Etappen via MKDirections,
        // siehe tryAddKnownBypassIfNeeded) — Google Maps bekommt zwar denselben Zwischenpunkt
        // (waypoints=), wählt mit seiner eigenen, andersartigen Berechnung aber nachweislich
        // wieder einen Weg über dieselbe Schranke zurück (Nutzer-Report + Screenshot: Google fand
        // über die Dachauer Str. den kürzeren Anschluss). Die Garantie gilt nur für Apple Maps,
        // eine falsche "umfährt"-Zusage wäre hier sicherheitsrelevant.
        let showGoogleMaps = routeViewModel.isGoogleMapsInstalled && !isForcedBypassSelected

        return VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    routeViewModel.openInMaps(.apple)
                } label: {
                    Label("Apple Maps", systemImage: "map.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bigAction(.brand))

                if showGoogleMaps {
                    Button {
                        routeViewModel.openInMaps(.google)
                    } label: {
                        Label("Google Maps", systemImage: "location.north.line.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bigAction(.blue))
                }
            }
            if isForcedBypassSelected {
                Text("Diese Umfahrung wurde mit Apples Routenberechnung geprüft. Google Maps kann für denselben Zwischenpunkt eine andere Route wählen, die wieder über die Schranke führt — deshalb hier nur Apple Maps.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            } else if routeViewModel.isGoogleMapsInstalled {
                // Apple Maps nutzt dieselbe Routenberechnung (MapKit) wie diese App und trifft
                // daher zuverlässig dieselbe Route/Zeit. Google Maps hat eine komplett andere
                // Routing-Engine (eigene Straßendaten/Verkehrsmodell) — eine exakte
                // Übereinstimmung lässt sich von hier aus nicht erzwingen (Nutzer-Feedback:
                // "stimmt noch nicht überein mit Google Maps").
                Text("Apple Maps übernimmt die hier berechnete Route exakt. Google Maps nutzt eine eigene Routenberechnung und kann daher eine andere Route oder Zeit anzeigen.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if routeViewModel.isTripActive {
                Button(role: .destructive) {
                    routeViewModel.stopTrip()
                } label: {
                    Label("Überwachung beenden", systemImage: "stop.circle")
                }
                .padding(.top, 4)
            }
        }
    }

    private func bannerView(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message)
                .font(.subheadline.bold())
            Spacer()
            Button {
                routeViewModel.currentBannerMessage = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
        }
        .foregroundStyle(.white)
        .padding()
        .background(Color.orange)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding()
        .transition(.move(edge: .top).combined(with: .opacity))
        .animation(.easeInOut, value: routeViewModel.currentBannerMessage)
    }

    // MARK: - Sicherheitshinweis

    private var safetyDisclaimer: some View {
        VStack(spacing: 6) {
            Label("Keine sicherheitsrelevante Anwendung", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.bold())
                .foregroundStyle(.orange)
            Text("Die Routenempfehlung ist eine unverbindliche Schätzung auf Basis von Fahrplan- und GPS-Daten. Nutze für die eigentliche Fahrt Apple Maps oder Google Maps und schau während der Fahrt nicht auf diese Karte — verlasse dich auf die Sprachansagen und ausschließlich auf die Schranken- und Signalanlage vor Ort.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.orange.opacity(0.25), lineWidth: 1)
        )
    }

    private static func formattedDuration(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        if minutes < 60 { return "\(minutes) Min" }
        return "\(minutes / 60) Std \(minutes % 60) Min"
    }
}

// MARK: - Karten-Auswahl (Start/Ziel per Pin statt Adress-Suche)

/// Vollbild-Kartenauswahl nach dem etablierten "Pin in der Kartenmitte"-Muster (Apple/Google
/// Maps): der Nutzer verschiebt die Karte, ein fester Pin markiert immer die Bildschirmmitte,
/// darunter steht per Reverse-Geocoding die Adresse des aktuell markierten Punkts.
private struct LocationPickerSheet: View {
    let title: String
    var initialCoordinate: CLLocationCoordinate2D?
    let onConfirm: (MKMapItem) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var cameraPosition: MapCameraPosition
    @State private var centerCoordinate: CLLocationCoordinate2D
    @State private var addressText = "Karte bewegen, um einen Ort zu wählen"
    @State private var geocodeTask: Task<Void, Never>?

    init(title: String, initialCoordinate: CLLocationCoordinate2D?, onConfirm: @escaping (MKMapItem) -> Void) {
        self.title = title
        self.initialCoordinate = initialCoordinate
        self.onConfirm = onConfirm
        // Fallback falls noch kein GPS-Fix vorliegt: einer der bekannten Übergänge als
        // sinnvoller Kartenausschnitt für diese Region statt eines leeren Welt-Zooms.
        let coordinate = initialCoordinate ?? CrossingLocation.all[0].coordinate
        _centerCoordinate = State(initialValue: coordinate)
        _cameraPosition = State(initialValue: .region(
            MKCoordinateRegion(center: coordinate, latitudinalMeters: 2000, longitudinalMeters: 2000)
        ))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Map(position: $cameraPosition)
                    .onMapCameraChange(frequency: .onEnd) { context in
                        centerCoordinate = context.region.center
                        scheduleReverseGeocode()
                    }
                Image(systemName: "mappin")
                    .font(.system(size: 36))
                    .foregroundStyle(.red)
                    .shadow(radius: 2)
                    .offset(y: -18)
                    .allowsHitTesting(false)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { confirm() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text(addressText)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(.thinMaterial)
            }
        }
        .onAppear { scheduleReverseGeocode() }
    }

    /// Entprellt (400ms) wie die Adress-Suche in RouteViewModel — sonst würde jede noch so kleine
    /// Kartenbewegung sofort eine Reverse-Geocoding-Anfrage auslösen.
    private func scheduleReverseGeocode() {
        geocodeTask?.cancel()
        geocodeTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await resolveAddress()
        }
    }

    @MainActor
    private func resolveAddress() async {
        let location = CLLocation(latitude: centerCoordinate.latitude, longitude: centerCoordinate.longitude)
        // MKReverseGeocodingRequest statt CLGeocoder.reverseGeocodeLocation — Letzteres ist seit
        // iOS 26 zugunsten von Ersterem deprecated (siehe MapKit-API-Wechsel in diesem Projekt).
        guard let request = MKReverseGeocodingRequest(location: location),
              let items = try? await request.mapItems, let name = items.first?.name else {
            addressText = "Unbekannter Ort"
            return
        }
        addressText = name
    }

    private func confirm() {
        let location = CLLocation(latitude: centerCoordinate.latitude, longitude: centerCoordinate.longitude)
        let item = MKMapItem(location: location, address: nil)
        item.name = addressText
        onConfirm(item)
        dismiss()
    }
}
