import ActivityKit
import CoreLocation
import MapKit
import Observation
import UIKit
import UserNotifications

/// Berechnet für eine Start-Ziel-Route, ob sie einen der bekannten Bahnübergänge kreuzt und ob
/// dieser zur voraussichtlichen Ankunftszeit offen oder geschlossen sein wird — Grundlage für
/// den "Fahrt"-Tab. Reicht die gewählte Route per Knopfdruck an Apple Maps/Google Maps weiter
/// (siehe RouteView) statt selbst Turn-by-Turn zu navigieren, und überwacht danach im
/// Hintergrund, ob sich die Zugankunft am relevanten Übergang stark verschiebt.
@MainActor
@Observable
final class RouteViewModel: NSObject {

    // MARK: - Adress-Suche

    var startQuery: String = ""
    var destinationQuery: String = ""
    var startCompletions: [MKLocalSearchCompletion] = []
    var destinationCompletions: [MKLocalSearchCompletion] = []

    /// nil = "Aktueller Standort" (Standardwert). Wird gesetzt, sobald der Nutzer eine
    /// Vorschlagszeile antippt; beim Weitertippen danach wieder auf nil zurückgesetzt (siehe
    /// updateStartQuery), damit "Route berechnen" nicht mit einem veralteten Ziel rechnet.
    private(set) var selectedStart: MKMapItem?
    private(set) var selectedDestination: MKMapItem?

    private var startCompleter: MKLocalSearchCompleter?
    private var destinationCompleter: MKLocalSearchCompleter?
    private var startDebounceTask: Task<Void, Never>?
    private var destinationDebounceTask: Task<Void, Never>?

    // MARK: - Zwischenstopp

    /// Bewusst GENAU EIN optionaler Zwischenstopp statt einer beliebigen Liste — deckt den
    /// Hauptfall ab ("unterwegs noch wen abholen"), ohne die komplette Such-/Kartenauswahl-UI
    /// für eine variable Anzahl Wegpunkte neu bauen zu müssen. Bei Bedarf später erweiterbar.
    var waypointQuery: String = ""
    var waypointCompletions: [MKLocalSearchCompletion] = []
    private(set) var selectedWaypoint: MKMapItem?
    private var waypointCompleter: MKLocalSearchCompleter?
    private var waypointDebounceTask: Task<Void, Never>?

    func updateWaypointQuery(_ text: String) {
        waypointQuery = text
        selectedWaypoint = nil
        resetRoutes()
        waypointDebounceTask?.cancel()
        guard !text.isEmpty else { waypointCompletions = []; return }
        waypointDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            self.waypointCompleter?.queryFragment = text
        }
    }

    func selectWaypoint(_ completion: MKLocalSearchCompletion) async {
        waypointQuery = completion.title
        waypointCompletions = []
        resetRoutes()
        selectedWaypoint = await resolve(completion)
    }

    func setWaypointFromMap(_ item: MKMapItem) {
        resetRoutes()
        waypointQuery = item.name ?? "Ausgewählter Ort"
        waypointCompletions = []
        selectedWaypoint = item
    }

    /// Entfernt den Zwischenstopp wieder — z.B. über das "×" neben dem Suchfeld in RouteView.
    func clearWaypoint() {
        resetRoutes()
        waypointQuery = ""
        waypointCompletions = []
        selectedWaypoint = nil
    }

    // MARK: - Reisemodus

    /// Bewusst NICHT persistiert (kein @AppStorage) — fahrtspezifisch statt eine dauerhafte
    /// Einstellung, genau wie selectedStart/selectedDestination auch nicht persistiert werden.
    enum TravelMode: String, CaseIterable, Hashable {
        case auto, fahrrad, fuss

        var mkTransportType: MKDirectionsTransportType {
            switch self {
            case .auto:    .automobile
            case .fahrrad: .cycling
            case .fuss:    .walking
            }
        }

        var appleLaunchMode: String {
            switch self {
            case .auto:    MKLaunchOptionsDirectionsModeDriving
            case .fahrrad: MKLaunchOptionsDirectionsModeCycling
            case .fuss:    MKLaunchOptionsDirectionsModeWalking
            }
        }

        var googleModeParam: String {
            switch self {
            case .auto:    "driving"
            case .fahrrad: "bicycling"
            case .fuss:    "walking"
            }
        }

        var icon: String {
            switch self {
            case .auto:    "car.fill"
            case .fahrrad: "bicycle"
            case .fuss:    "figure.walk"
            }
        }

        var label: String {
            switch self {
            case .auto:    "Auto"
            case .fahrrad: "Fahrrad"
            case .fuss:    "Zu Fuß"
            }
        }
    }

    private(set) var travelMode: TravelMode = .auto

    /// Eine stehengebliebene Auto-Route wäre im Fußgänger-/Rad-Modus schlicht falsch — deshalb
    /// dieselbe resetRoutes()-Invalidierung wie bei jeder Start-/Ziel-Änderung.
    func setTravelMode(_ mode: TravelMode) {
        guard mode != travelMode else { return }
        travelMode = mode
        resetRoutes()
    }

    // MARK: - Favoriten

    /// Gespeichertes Ziel (z.B. "Zuhause"/"Arbeit") zum schnellen Wählen statt Neu-Eintippen.
    /// `MKMapItem` selbst ist nicht Codable — Koordinate + Name reichen zum Rekonstruieren
    /// (gleiches Muster wie an den bestehenden `MKMapItem(location:address:)`-Stellen unten).
    struct FavoriteDestination: Codable, Identifiable, Equatable {
        let id: UUID
        var name: String
        let latitude: Double
        let longitude: Double

        var mapItem: MKMapItem {
            let item = MKMapItem(location: CLLocation(latitude: latitude, longitude: longitude), address: nil)
            item.name = name
            return item
        }
    }
    private(set) var favorites: [FavoriteDestination] = []
    private static let favoritesKey = "routeFavorites"

    func addFavorite(name: String, mapItem: MKMapItem) {
        let coordinate = mapItem.location.coordinate
        favorites.append(FavoriteDestination(id: UUID(), name: name, latitude: coordinate.latitude, longitude: coordinate.longitude))
        persistFavorites()
    }

    func removeFavorite(_ favorite: FavoriteDestination) {
        favorites.removeAll { $0.id == favorite.id }
        persistFavorites()
    }

    private func persistFavorites() {
        guard let data = try? JSONEncoder().encode(favorites) else { return }
        UserDefaults.standard.set(data, forKey: Self.favoritesKey)
    }

    private static func loadFavorites() -> [FavoriteDestination] {
        guard let data = UserDefaults.standard.data(forKey: favoritesKey),
              let decoded = try? JSONDecoder().decode([FavoriteDestination].self, from: data)
        else { return [] }
        return decoded
    }

    // MARK: - Fahrten-Verlauf

    /// Abgeschlossene Fahrt mit Ziel, (falls getroffen) Übergang und Ausgang — für die
    /// Verlaufsansicht (TripHistoryView). Gleiches Persistenz-Muster wie CrossingRecorder
    /// (JSON-Encode in UserDefaults).
    struct TripRecord: Codable, Identifiable {
        let id: UUID
        let date: Date
        let destinationName: String
        let crossingName: String?
        let wasBlockedAtStart: Bool?
        let finalDelayMinutes: Int?
    }
    private(set) var tripHistory: [TripRecord] = []
    private static let tripHistoryKey = "tripHistory"

    // Während einer laufenden Fahrt gesammelt (siehe startTrip()/checkForSignificantChange()),
    // in stopTrip() zu einem TripRecord zusammengeführt — analog zum bestehenden
    // monitoredCrossing/monitoredEventId/baselineCrossingTime-Trio für dieselbe Fahrt.
    private var currentTripDestinationName: String?
    private var currentTripCrossingName: String?
    private var currentTripWasBlockedAtStart: Bool?
    private var currentTripLastDelayMinutes: Int?

    private func persistTripHistory() {
        guard let data = try? JSONEncoder().encode(tripHistory) else { return }
        UserDefaults.standard.set(data, forKey: Self.tripHistoryKey)
    }

    private static func loadTripHistory() -> [TripRecord] {
        guard let data = UserDefaults.standard.data(forKey: tripHistoryKey),
              let decoded = try? JSONDecoder().decode([TripRecord].self, from: data)
        else { return [] }
        return decoded
    }

    func deleteTripHistory(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) where tripHistory.indices.contains(index) {
            tripHistory.remove(at: index)
        }
        persistTripHistory()
    }

    // MARK: - Routenberechnung

    var isCalculating = false
    var calculationError: String?

    /// Einheitliche Route-Darstellung, egal ob direkt von MapKit (`requestsAlternateRoutes`) oder
    /// über eine bekannte Ausweichstraße ERZWUNGEN (siehe knownBypassQuery/
    /// tryAddKnownBypassIfNeeded) — MapKit selbst hat keine "meide diesen Punkt"-API (nur
    /// Maut-/Autobahn-Präferenz laut MKDirectionsRequest.h), findet also über
    /// requestsAlternateRoutes oft KEINE Route, die gezielt einen bestimmten Übergang umfährt.
    struct RouteCandidate: Identifiable {
        let id = UUID()
        let polyline: MKPolyline
        let expectedTravelTime: TimeInterval
        let distance: CLLocationDistance
        /// Nicht nil nur bei einer über eine bekannte Ausweichstraße erzwungenen Route — für die
        /// Maps-Weiterleitung als Zwischenstopp (ersetzt dort die sonst genutzte grobe
        /// "Mittelpunkt der Polyline"-Näherung).
        let forcedBypassPoint: CLLocationCoordinate2D?

        init(route: MKRoute) {
            polyline = route.polyline
            expectedTravelTime = route.expectedTravelTime
            distance = route.distance
            forcedBypassPoint = nil
        }

        /// forcedBypassPoint bleibt optional: derselbe Mehr-Etappen-Zusammenbau dient sowohl der
        /// erzwungenen Ausweichstraßen-Route (siehe tryAddKnownBypassIfNeeded, dort nicht-nil)
        /// als auch einem vom Nutzer gewählten Zwischenstopp (dort nil — kein "umfährt die
        /// Schranke"-Anspruch, nur ein zusätzlicher Wegpunkt).
        init(legs: [MKRoute], forcedBypassPoint: CLLocationCoordinate2D? = nil) {
            let combined = legs.flatMap { RouteViewModel.coordinates(of: $0.polyline) }
            polyline = MKPolyline(coordinates: combined, count: combined.count)
            expectedTravelTime = legs.reduce(0) { $0 + $1.expectedTravelTime }
            distance = legs.reduce(0) { $0 + $1.distance }
            self.forcedBypassPoint = forcedBypassPoint
        }
    }
    var routes: [RouteCandidate] = []
    /// Vom Nutzer manuell gewählte Route (Standard: die Empfehlung, siehe recommendedRouteIndex)
    /// — durch Antippen einer der beiden Karten in RouteView übersteuerbar. Wird für
    /// openInMaps()/startTrip() verwendet.
    var selectedRouteIndex: Int?

    struct MatchedCrossing: Identifiable {
        var id: String { crossing.id }
        let crossing: CrossingLocation
        let distanceAlongRoute: CLLocationDistance
        let etaSeconds: TimeInterval
        let event: CrossingEvent?
        let statusAtArrival: CrossingStatus?
        /// Geschätzte Wartezeit in Sekunden (0 wenn offen/unbekannt) — für die Detailanzeige.
        let waitSeconds: TimeInterval
        /// true nur bei einem bekannten, nicht-offenen Status — `nil` (keine Zugdaten) gilt
        /// bewusst NICHT als blockiert. Einzige Wahrheitsquelle statt dreifach dupliziertem
        /// `statusAtArrival != nil && statusAtArrival != .open` (Code-Review-Fund).
        var isBlocked: Bool { statusAtArrival != nil && statusAtArrival != .open }
    }
    /// Pro Route (per Index, parallel zu `routes`) die getroffenen Übergänge, sortiert in der
    /// Reihenfolge, in der man ihnen beim Fahren tatsächlich begegnet (distanceAlongRoute).
    private(set) var matchesByRoute: [[MatchedCrossing]] = []

    /// Beste (schnellste inkl. Wartezeit) Route, die über mindestens einen bekannten Übergang
    /// führt — nil wenn keine der Alternativen einen kreuzt. Zusammen mit detourRouteIndex bilden
    /// diese beiden IMMER gleichwertig sichtbaren Optionen "über die Schranke" / "Schranke
    /// umfahren" (Nutzerwunsch), statt einer versteckten Alternative hinter einem Override-Button.
    var crossingRouteIndex: Int? { bestRouteIndex { !matchesByRoute[$0].isEmpty } }

    /// Beste (schnellste) Route, die KEINEN bekannten Übergang kreuzt — die "Umfahrung". nil wenn
    /// jede Alternative über mindestens einen führt (dann gibt es keine echte Umfahrung).
    var detourRouteIndex: Int? { bestRouteIndex { matchesByRoute[$0].isEmpty } }

    /// Von den beiden Optionen oben die insgesamt schnellere (inkl. Wartezeit) — nur ein
    /// Hinweis-Badge in RouteView, beide Karten bleiben gleichwertig antippbar.
    var recommendedRouteIndex: Int? {
        [crossingRouteIndex, detourRouteIndex].compactMap { $0 }.min(by: { totalTime(for: $0) < totalTime(for: $1) })
    }

    private func bestRouteIndex(where predicate: (Int) -> Bool) -> Int? {
        routes.indices
            .filter { matchesByRoute.indices.contains($0) && predicate($0) }
            .min(by: { totalTime(for: $0) < totalTime(for: $1) })
    }

    private func totalTime(for index: Int) -> TimeInterval {
        guard routes.indices.contains(index) else { return .infinity }
        let wait = matchesByRoute.indices.contains(index) ? matchesByRoute[index].reduce(0) { $0 + $1.waitSeconds } : 0
        return routes[index].expectedTravelTime + wait
    }

    // MARK: - Live-Monitoring

    var isTripActive = false
    var currentBannerMessage: String?
    private var monitorTask: Task<Void, Never>?
    private var currentActivity: Activity<TripActivityAttributes>?
    private var tripStartedAt: Date?
    private var currentTripEtaSeconds: TimeInterval?
    private var monitoredCrossing: CrossingLocation?
    private var monitoredEventId: String?
    private var baselineCrossingTime: Date?

    // MARK: - Abhängigkeiten

    private weak var crossingViewModel: CrossingViewModel?
    private weak var voiceAnnouncer: VoiceAnnouncer?

    /// Toleranz für "Route führt über diesen Übergang" — eigene, kleinere Konstante statt
    /// CrossingLocation.gpsToleranceMeters (die ist für die GPS-Auto-Kalibrierung der
    /// Trajektorien-Erkennung gedacht, ein anderer Zweck mit anderen Anforderungen).
    private static let routeMatchToleranceMeters: CLLocationDistance = 80

    /// Vom Nutzer genannte, lokal bekannte Ausweichstraßen pro Übergang (siehe
    /// tryAddKnownBypassIfNeeded) — nötig, weil MapKit selbst nicht weiß, dass diese Straße eine
    /// Schranke umfährt, und requestsAlternateRoutes sie deshalb oft nicht von sich aus anbietet.
    private static let knownBypassQuery: [String: String] = [
        "osh_dachauer": "Feierabendstraße, Oberschleißheim"
    ]
    /// Ab welcher Abweichung der vorhergesagten Durchfahrtszeit während einer laufenden Fahrt
    /// eine Sprachansage/Banner ausgelöst wird (Nutzervorgabe: "großartig ändert").
    private static let significantChangeThreshold: TimeInterval = 120
    private static let monitorIntervalSeconds: UInt64 = 30

    /// Mittelpunkt der 4 bekannten Übergänge — Bias für die Adress-Autovervollständigung
    /// (Vorschläge aus der Region werden bevorzugt, andere Orte bleiben weiterhin suchbar).
    private static var regionCenter: CLLocationCoordinate2D {
        let crossings = CrossingLocation.all
        let lat = crossings.map(\.latitude).reduce(0, +) / Double(crossings.count)
        let lon = crossings.map(\.longitude).reduce(0, +) / Double(crossings.count)
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// Ob Google Maps installiert ist (Deep-Link-Schema abfragbar) — der "Google Maps"-Button in
    /// RouteView wird nur gezeigt, wenn ja, statt sonst unauffällig auf den Web-Link auszuweichen
    /// (Nutzerwunsch: Button soll nur existieren, wenn die App tatsächlich installiert ist). Als
    /// computed statt einmalig in init() geprüft — kostet praktisch nichts und schließt aus, dass
    /// der Check zu einem ungünstigen Zeitpunkt (App-Start) ein stilles falsches Ergebnis liefert
    /// (Nutzer-Report: Button fehlte trotz installierter App).
    var isGoogleMapsInstalled: Bool {
        guard let url = URL(string: "comgooglemaps://") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    override init() {
        super.init()
        favorites = Self.loadFavorites()
        tripHistory = Self.loadTripHistory()
        let region = MKCoordinateRegion(
            center: Self.regionCenter, latitudinalMeters: 30_000, longitudinalMeters: 30_000
        )

        let start = MKLocalSearchCompleter()
        start.delegate = self
        start.region = region
        start.resultTypes = [.address, .pointOfInterest]
        startCompleter = start

        let destination = MKLocalSearchCompleter()
        destination.delegate = self
        destination.region = region
        destination.resultTypes = [.address, .pointOfInterest]
        destinationCompleter = destination

        let waypoint = MKLocalSearchCompleter()
        waypoint.delegate = self
        waypoint.region = region
        waypoint.resultTypes = [.address, .pointOfInterest]
        waypointCompleter = waypoint
    }

    /// Verdrahtung von außen (Schrankenradar_OSHApp), analog CrossingViewModel.setup(voiceAnnouncer:).
    func attach(crossingViewModel: CrossingViewModel, voiceAnnouncer: VoiceAnnouncer) {
        self.crossingViewModel = crossingViewModel
        self.voiceAnnouncer = voiceAnnouncer
    }

    var canCalculateRoute: Bool {
        selectedDestination != nil && !isCalculating
    }

    // MARK: - Sucheingabe

    func updateStartQuery(_ text: String) {
        startQuery = text
        selectedStart = nil
        // Jede Start-/Ziel-Änderung macht eine bereits berechnete Route ungültig — sonst könnte
        // z.B. openInMaps() mit einem NEUEN Ziel weiterleiten, während die Empfehlungs-Karte noch
        // die ALTE (jetzt nicht mehr passende) Route/Zeit anzeigt (genau das wurde live
        // beobachtet: App zeigte "9 Min", Google Maps bekam ein ganz anderes, weiter entferntes
        // Ziel).
        resetRoutes()
        startDebounceTask?.cancel()
        guard !text.isEmpty else { startCompletions = []; return }
        startDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            self.startCompleter?.queryFragment = text
        }
    }

    func updateDestinationQuery(_ text: String) {
        destinationQuery = text
        selectedDestination = nil
        resetRoutes()
        destinationDebounceTask?.cancel()
        guard !text.isEmpty else { destinationCompletions = []; return }
        destinationDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            self.destinationCompleter?.queryFragment = text
        }
    }

    func selectStart(_ completion: MKLocalSearchCompletion) async {
        startQuery = completion.title
        startCompletions = []
        resetRoutes()
        selectedStart = await resolve(completion)
    }

    func selectDestination(_ completion: MKLocalSearchCompletion) async {
        destinationQuery = completion.title
        destinationCompletions = []
        resetRoutes()
        selectedDestination = await resolve(completion)
    }

    private func resolve(_ completion: MKLocalSearchCompletion) async -> MKMapItem? {
        let search = MKLocalSearch(request: MKLocalSearch.Request(completion: completion))
        return try? await search.start().mapItems.first
    }

    /// Setzt den Start explizit zurück auf den Standardwert (aktueller Standort) — als
    /// eigenständige, immer sichtbare Option statt nur implizit über ein leeres Textfeld.
    func useCurrentLocationAsStart() {
        resetRoutes()
        startQuery = ""
        startCompletions = []
        selectedStart = nil
    }

    /// Übernimmt einen auf der Karte gewählten Punkt (siehe RouteView.LocationPickerSheet) als
    /// Start bzw. Ziel.
    func setStartFromMap(_ item: MKMapItem) {
        resetRoutes()
        startQuery = item.name ?? "Ausgewählter Ort"
        startCompletions = []
        selectedStart = item
    }

    func setDestinationFromMap(_ item: MKMapItem) {
        resetRoutes()
        destinationQuery = item.name ?? "Ausgewählter Ort"
        destinationCompletions = []
        selectedDestination = item
    }

    // MARK: - Routenberechnung

    /// Erhöht sich bei jedem `calculateRoute`-Start UND bei jedem `resetRoutes()` — schützt
    /// gegen die Race Condition, bei der eine noch laufende (langsame) Berechnung ERST NACH
    /// einer bereits neueren Eingabe/Berechnung zurückkommt und deren Ergebnis überschreibt
    /// (live beobachtet: App zeigte eine Route/Zeit, Weiterleitung nutzte ein anderes Ziel).
    /// Jeder Schreibzugriff auf routes/matchesByRoute prüft vorher, ob seine Generation noch
    /// aktuell ist — sonst wird das (jetzt veraltete) Ergebnis kommentarlos verworfen.
    private var calculationGeneration = 0

    /// currentLocation kommt vom Aufrufer (RouteView → LocationMonitor.currentCoordinate) —
    /// RouteViewModel hält bewusst keine eigene LocationMonitor-Referenz, um nicht eine dritte
    /// Abhängigkeit neben crossingViewModel/voiceAnnouncer einzuführen.
    func calculateRoute(currentLocation: CLLocationCoordinate2D?) async {
        guard let destination = selectedDestination else {
            calculationError = "Bitte ein Ziel auswählen."
            return
        }
        let sourceItem: MKMapItem
        if let selectedStart {
            sourceItem = selectedStart
        } else if let currentLocation {
            sourceItem = MKMapItem(location: CLLocation(latitude: currentLocation.latitude, longitude: currentLocation.longitude), address: nil)
        } else {
            calculationError = "Aktueller Standort noch nicht bekannt — bitte kurz warten oder einen Startpunkt eingeben."
            return
        }

        calculationGeneration += 1
        let generation = calculationGeneration
        isCalculating = true
        calculationError = nil
        defer { isCalculating = false }

        if let waypoint = selectedWaypoint {
            // Mit Zwischenstopp: zwei Etappen einzeln berechnen und zu EINER Route kombinieren
            // (RouteCandidate.init(legs:), forcedBypassPoint hier bewusst nil — kein "umfährt
            // die Schranke"-Anspruch, nur ein zusätzlicher Wegpunkt). Keine Alternativrouten in
            // diesem Fall, das würde die Zwei-Etappen-Logik unnötig verkomplizieren.
            guard let leg1 = try? await directions(from: sourceItem, to: waypoint, mode: travelMode.mkTransportType),
                  let leg2 = try? await directions(from: waypoint, to: destination, mode: travelMode.mkTransportType) else {
                guard generation == calculationGeneration else { return }
                resetRoutes()
                calculationError = "Route über den Zwischenstopp konnte nicht berechnet werden."
                return
            }
            guard generation == calculationGeneration else { return }
            routes = [RouteCandidate(legs: [leg1, leg2])]
            await evaluateRoutes(source: sourceItem, destination: destination, generation: generation)
            return
        }

        let request = MKDirections.Request()
        request.source = sourceItem
        request.destination = destination
        request.transportType = travelMode.mkTransportType
        request.requestsAlternateRoutes = true

        do {
            let response = try await MKDirections(request: request).calculate()
            guard generation == calculationGeneration else { return }
            guard !response.routes.isEmpty else {
                resetRoutes()
                calculationError = "Keine Route gefunden."
                return
            }
            routes = response.routes.map { RouteCandidate(route: $0) }
            await evaluateRoutes(source: sourceItem, destination: destination, generation: generation)
        } catch {
            guard generation == calculationGeneration else { return }
            resetRoutes()
            calculationError = "Route konnte nicht berechnet werden."
        }
    }

    private func resetRoutes() {
        calculationGeneration += 1
        routes = []
        matchesByRoute = []
        selectedRouteIndex = nil
    }

    private func evaluateRoutes(source: MKMapItem, destination: MKMapItem, generation: Int) async {
        guard let crossingViewModel else { return }
        // Die kalibrierte, gelernte Kopie nutzen (Kalman-/Community-/Feedback-Basis), nicht die
        // statischen Defaults aus CrossingLocation.all — sonst weicht die Fahrt-Tab-Vorhersage
        // von der des Radar-Tabs für denselben Übergang zur selben Zeit ab (Code-Review-Fund).
        let crossings = crossingViewModel.store.crossings
        var matches: [[MatchedCrossing]] = []

        for candidate in routes {
            guard generation == calculationGeneration else { return }
            guard let result = await evaluate(candidate: candidate, crossings: crossings, crossingViewModel: crossingViewModel, generation: generation) else { return }
            matches.append(result)
        }

        guard generation == calculationGeneration else { return }
        matchesByRoute = matches

        // ERST hier (nicht schon vor der Bypass-Prüfung) selectedRouteIndex setzen — sonst bliebe
        // bei erfolgreich hinzugefügter Umfahrung die VORHER berechnete Empfehlung ausgewählt,
        // obwohl recommendedRouteIndex sich durch die neue Route gerade geändert haben kann
        // (Nutzer-Report: "die empfohlene Route soll immer am Anfang ausgewählt sein").
        await tryAddKnownBypassIfNeeded(source: source, destination: destination, crossings: crossings, crossingViewModel: crossingViewModel, generation: generation)
        guard generation == calculationGeneration else { return }
        selectedRouteIndex = recommendedRouteIndex
    }

    /// Übergangs-Treffer + Vorhersage für eine einzelne Route berechnen — von evaluateRoutes()
    /// (für alle MapKit-Alternativen) und tryAddKnownBypassIfNeeded() (für die erzwungene
    /// Ausweich-Route) gemeinsam genutzt, statt denselben Ablauf zweimal zu schreiben.
    /// Rückgabe nil bedeutet "veraltet, generation hat sich geändert" — vom Aufrufer wie ein
    /// sofortiger Abbruch zu behandeln, nicht wie ein leeres Ergebnis.
    private func evaluate(
        candidate: RouteCandidate, crossings: [CrossingLocation], crossingViewModel: CrossingViewModel, generation: Int
    ) async -> [MatchedCrossing]? {
        guard candidate.distance > 0 else { return [] }
        var routeMatches: [MatchedCrossing] = []

        for hit in matchedCrossings(for: candidate.polyline, crossings: crossings) {
            let etaSeconds = hit.distanceAlongRoute / candidate.distance * candidate.expectedTravelTime
            let arrival = Date().addingTimeInterval(etaSeconds)
            let events = await crossingViewModel.fetchEvents(for: hit.crossing)
            guard generation == calculationGeneration else { return nil }
            let relevant = events.min(by: {
                abs($0.estimatedCrossingTime.timeIntervalSince(arrival)) < abs($1.estimatedCrossingTime.timeIntervalSince(arrival))
            })
            var status: CrossingStatus?
            var waitSeconds: TimeInterval = 0
            if let relevant {
                status = relevant.status(at: arrival)
                if status != .open {
                    waitSeconds = relevant.openingDelayMinutes * 60
                }
            }
            routeMatches.append(MatchedCrossing(
                crossing: hit.crossing, distanceAlongRoute: hit.distanceAlongRoute,
                etaSeconds: etaSeconds, event: relevant, statusAtArrival: status, waitSeconds: waitSeconds
            ))
        }
        return routeMatches
    }

    /// MapKit hat keine "meide diesen Punkt"-API (nur Maut-/Autobahn-Präferenz, siehe
    /// MKDirectionsRequest.h) — requestsAlternateRoutes findet deshalb oft KEINE Route, die
    /// gezielt eine bestimmte Schranke umfährt, weil MapKit von ihr nichts weiß (Nutzer-Report:
    /// "Apple findet die Umfahrungen nicht"). Für Übergänge mit einer bekannten Ausweichstraße
    /// (knownBypassQuery, vom Nutzer genannt) wird deshalb — nur falls keine der MapKit-eigenen
    /// Alternativen den Übergang bereits umfährt — zusätzlich EXPLIZIT in zwei Etappen über
    /// diesen Punkt geroutet (Start→Ausweichpunkt, Ausweichpunkt→Ziel).
    private func tryAddKnownBypassIfNeeded(
        source: MKMapItem, destination: MKMapItem, crossings: [CrossingLocation],
        crossingViewModel: CrossingViewModel, generation: Int
    ) async {
        // "Andere Straße wegen Schranke" ist ein Auto-spezifisches Konzept — für Fußgänger/
        // Radfahrer ergibt eine erzwungene Straßen-Umfahrung keinen Sinn (siehe TravelMode).
        guard travelMode == .auto else { return }
        guard detourRouteIndex == nil, let index = crossingRouteIndex, matchesByRoute.indices.contains(index) else { return }
        guard let hit = matchesByRoute[index].first(where: { Self.knownBypassQuery[$0.crossing.id] != nil }),
              let query = Self.knownBypassQuery[hit.crossing.id] else { return }

        guard let bypassPoint = await resolveBypassCoordinate(query: query, near: hit.crossing.coordinate) else { return }
        guard generation == calculationGeneration else { return }
        let bypassItem = MKMapItem(location: CLLocation(latitude: bypassPoint.latitude, longitude: bypassPoint.longitude), address: nil)

        guard let leg1 = try? await directions(from: source, to: bypassItem),
              let leg2 = try? await directions(from: bypassItem, to: destination) else { return }
        guard generation == calculationGeneration else { return }

        let candidate = RouteCandidate(legs: [leg1, leg2], forcedBypassPoint: bypassPoint)
        guard let candidateMatches = await evaluate(candidate: candidate, crossings: crossings, crossingViewModel: crossingViewModel, generation: generation)
        else { return }
        guard generation == calculationGeneration else { return }
        // Nur übernehmen, wenn die erzwungene Route den Übergang auch WIRKLICH umfährt — sonst
        // brächte sie gegenüber der direkten Route keinen Mehrwert (z.B. falls die genannte
        // Straße selbst über einen anderen bekannten Übergang führt).
        guard candidateMatches.isEmpty else { return }

        routes.append(candidate)
        matchesByRoute.append(candidateMatches)
    }

    private func resolveBypassCoordinate(query: String, near coordinate: CLLocationCoordinate2D) async -> CLLocationCoordinate2D? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = MKCoordinateRegion(center: coordinate, latitudinalMeters: 8_000, longitudinalMeters: 8_000)
        guard let response = try? await MKLocalSearch(request: request).start(), let item = response.mapItems.first else { return nil }
        return item.location.coordinate
    }

    private func directions(from source: MKMapItem, to destination: MKMapItem, mode: MKDirectionsTransportType = .automobile) async throws -> MKRoute? {
        let request = MKDirections.Request()
        request.source = source
        request.destination = destination
        request.transportType = mode
        let response = try await MKDirections(request: request).calculate()
        return response.routes.first
    }

    private static func coordinates(of polyline: MKPolyline) -> [CLLocationCoordinate2D] {
        let count = polyline.pointCount
        var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: count)
        polyline.getCoordinates(&coords, range: NSRange(location: 0, length: count))
        return coords
    }

    private struct RouteCrossingHit {
        let crossing: CrossingLocation
        let distanceAlongRoute: CLLocationDistance
    }

    /// Extrahiert die Polyline-Koordinaten (getCoordinates(_:range:), Apples effiziente Bulk-API
    /// dafür) und prüft für jeden bekannten Übergang die minimale Distanz zu jedem LINIENSEGMENT
    /// der Route (nicht nur zu den diskreten Stützpunkten selbst — auf einem langen, geraden
    /// Straßenabschnitt kann MapKit die Polyline sehr grob abtasten, sodass ein Übergang exakt in
    /// der Mitte zwischen zwei weit auseinanderliegenden Punkten liegt und bei reiner Punkt-zu-
    /// Punkt-Prüfung fälschlich als "nicht getroffen" gilt, obwohl die Straße buchstäblich über
    /// ihn hinwegführt — live beobachtet an der Dachauer Str.). `crossings` kommt vom Aufrufer
    /// (die kalibrierte `store.crossings`-Kopie, nicht die statischen `CrossingLocation.all`-
    /// Defaults — sonst würden Koordinate/Radius eines vom Nutzer korrigierten Übergangs hier
    /// ignoriert). Ergebnis sortiert nach distanceAlongRoute — das ist die Reihenfolge, in der man
    /// den Übergängen beim tatsächlichen Fahren begegnet (wichtig für startTrip(), das den ERSTEN
    /// getroffenen Übergang überwacht).
    private func matchedCrossings(for polyline: MKPolyline, crossings: [CrossingLocation]) -> [RouteCrossingHit] {
        let coords = Self.coordinates(of: polyline)
        guard coords.count > 1 else { return [] }

        var cumulativeDistance: CLLocationDistance = 0
        var bestDistance: [String: CLLocationDistance] = [:]
        var bestAlongRoute: [String: CLLocationDistance] = [:]

        for index in 0..<(coords.count - 1) {
            let segmentStart = coords[index]
            let segmentEnd = coords[index + 1]
            let segmentLength = CLLocation(latitude: segmentStart.latitude, longitude: segmentStart.longitude)
                .distance(from: CLLocation(latitude: segmentEnd.latitude, longitude: segmentEnd.longitude))

            for crossing in crossings {
                let target = CLLocationCoordinate2D(latitude: crossing.latitude, longitude: crossing.longitude)
                let (distance, fraction) = Self.closestPoint(from: target, onSegmentFrom: segmentStart, to: segmentEnd)
                if distance < (bestDistance[crossing.id] ?? .greatestFiniteMagnitude) {
                    bestDistance[crossing.id] = distance
                    bestAlongRoute[crossing.id] = cumulativeDistance + fraction * segmentLength
                }
            }

            cumulativeDistance += segmentLength
        }

        return crossings
            .compactMap { crossing -> RouteCrossingHit? in
                guard let distance = bestDistance[crossing.id], distance <= Self.routeMatchToleranceMeters,
                      let along = bestAlongRoute[crossing.id] else { return nil }
                return RouteCrossingHit(crossing: crossing, distanceAlongRoute: along)
            }
            .sorted { $0.distanceAlongRoute < $1.distanceAlongRoute }
    }

    /// Nächster Punkt auf der Strecke [from, to] zu `point`, als (Distanz in Metern, Anteil
    /// 0...1 entlang des Segments). Flache (equirechteckige) Näherung um den Startpunkt herum —
    /// Polyline-Segmente sind für eine Autoroute i.d.R. nur einige hundert Meter lang, auf dieser
    /// Skala ist der Fehler durch die Erdkrümmung irrelevant gegenüber der 80m-Toleranz.
    private static func closestPoint(
        from point: CLLocationCoordinate2D, onSegmentFrom from: CLLocationCoordinate2D, to: CLLocationCoordinate2D
    ) -> (distance: CLLocationDistance, fraction: Double) {
        let metersPerDegreeLat = 111_320.0
        let metersPerDegreeLon = 111_320.0 * cos(from.latitude * .pi / 180)

        let dx = (to.longitude - from.longitude) * metersPerDegreeLon
        let dy = (to.latitude - from.latitude) * metersPerDegreeLat
        let px = (point.longitude - from.longitude) * metersPerDegreeLon
        let py = (point.latitude - from.latitude) * metersPerDegreeLat

        let lengthSquared = dx * dx + dy * dy
        let fraction = lengthSquared > 0 ? max(0, min(1, (px * dx + py * dy) / lengthSquared)) : 0

        let closest = CLLocationCoordinate2D(
            latitude: from.latitude + fraction * (to.latitude - from.latitude),
            longitude: from.longitude + fraction * (to.longitude - from.longitude)
        )
        let distance = CLLocation(latitude: point.latitude, longitude: point.longitude)
            .distance(from: CLLocation(latitude: closest.latitude, longitude: closest.longitude))
        return (distance, fraction)
    }

    /// Wechselt zwischen den beiden gleichwertigen Optionen (crossingRouteIndex/detourRouteIndex)
    /// — angetippt über die jeweilige Karte in RouteView.
    func selectRoute(_ index: Int) {
        guard routes.indices.contains(index) else { return }
        selectedRouteIndex = index
    }

    /// Nutzt ausschließlich schon geladene Daten (kein zusätzlicher Netzwerk-Call) — prüft für
    /// den ERSTEN getroffenen (blockierten) Übergang mehrere hypothetische Abfahrts-
    /// Verzögerungen und meldet die früheste, bei der die Schranke laut Vorhersage bei Ankunft
    /// wieder offen wäre. Reine Schätzung auf Basis der aktuellen Vorhersage, keine Garantie.
    func departureRecommendation(for index: Int) -> String? {
        guard routes.indices.contains(index), matchesByRoute.indices.contains(index),
              let hit = matchesByRoute[index].first, hit.isBlocked, let event = hit.event
        else { return nil }
        for delayMinutes in stride(from: 5, through: 30, by: 5) {
            let hypotheticalArrival = Date().addingTimeInterval(Double(delayMinutes) * 60 + hit.etaSeconds)
            if event.status(at: hypotheticalArrival) == .open {
                return "Fahr in \(delayMinutes) Minuten los, dann ist \(hit.crossing.name) bei Ankunft voraussichtlich offen."
            }
        }
        return nil
    }

    // MARK: - Weiterleitung an Apple Maps / Google Maps

    enum MapsApp { case apple, google }

    func openInMaps(_ app: MapsApp) {
        guard let index = selectedRouteIndex, routes.indices.contains(index),
              let destination = selectedDestination else { return }
        let route = routes[index]
        let viaPoint = viaPointIfDetour(for: route, index: index)
        // selectedStart ist nil, wenn der Nutzer den Standardwert (aktueller Standort) belassen
        // hat — dann geben wir keine Quelle mit, beide Apps interpretieren das selbst als
        // "ab aktuellem Standort". Wurde ein eigener Startpunkt gewählt, muss die Weiterleitung
        // genau den nutzen, sonst weicht die externe Navigation vom berechneten Ergebnis ab.
        switch app {
        case .apple:  openInAppleMaps(source: selectedStart, destination: destination, viaPoint: viaPoint)
        case .google: openInGoogleMaps(source: selectedStart, destination: destination, viaPoint: viaPoint)
        }
        startTrip()
    }

    /// Bei einer über eine bekannte Ausweichstraße erzwungenen Route ist der exakte Punkt schon
    /// bekannt (forcedBypassPoint). Sonst — nur wenn die gewählte Route NICHT Apples eigene
    /// erste/bevorzugte ist, gilt sie als bewusste Umfahrung — einen Zwischenpunkt aus ihrer
    /// Polyline mitgeben, damit die externe App grob denselben Umweg nimmt statt selbst wieder
    /// die direkte (ggf. durch eine geschlossene Schranke blockierte) Route zu berechnen.
    private func viaPointIfDetour(for candidate: RouteCandidate, index: Int) -> CLLocationCoordinate2D? {
        if let forced = candidate.forcedBypassPoint { return forced }
        guard index != 0, routes.count > 1 else { return nil }
        let coords = Self.coordinates(of: candidate.polyline)
        guard !coords.isEmpty else { return nil }
        return coords[coords.count / 2]
    }

    /// MKMapItem(placemark:)/.placemark sind seit iOS 26 deprecated zugunsten von
    /// location/address — init(location:address:) ist bereits an anderer Stelle im Projekt im
    /// Einsatz (TravelTimesCard.swift).
    private func openInAppleMaps(source: MKMapItem?, destination: MKMapItem, viaPoint: CLLocationCoordinate2D?) {
        let options = [MKLaunchOptionsDirectionsModeKey: travelMode.appleLaunchMode]

        guard source != nil || viaPoint != nil else {
            // Weder eigener Start noch Umfahrung — das einfache openInMaps() bedeutet für Apple
            // Maps bereits implizit "ab aktuellem Standort", keine Mehrfach-Stopp-API nötig.
            destination.openInMaps(launchOptions: options)
            return
        }

        // Anders als das einfache openInMaps() kennt openMaps(with:) KEIN implizites "ab
        // aktuellem Standort" — ohne eigenen Startpunkt muss die Quelle deshalb explizit als
        // MKMapItem.forCurrentLocation() mitgegeben werden. Vorher fehlte dieser erste Stopp im
        // Standardfall komplett, sobald zusätzlich ein Umfahrungspunkt dabei war — Apple Maps
        // navigierte dann nur "vom Umfahrungspunkt zum Ziel", die Heimstrecke fehlte ganz
        // (Nutzer-Report: "die Route geht von diesem Punkt zum Ziel, nicht von zuhause zu diesem
        // Punkt zum Ziel").
        var items: [MKMapItem] = [source ?? MKMapItem.forCurrentLocation()]
        if let viaPoint {
            let viaItem = MKMapItem(location: CLLocation(latitude: viaPoint.latitude, longitude: viaPoint.longitude), address: nil)
            viaItem.name = "Umfahrung"
            items.append(viaItem)
        }
        items.append(destination)
        MKMapItem.openMaps(with: items, launchOptions: options)
    }

    /// Kein Web-Fallback mehr nötig: der Button, der diese Methode auslöst, ist in RouteView nur
    /// sichtbar, wenn isGoogleMapsInstalled bereits true ist (Nutzerwunsch) — ein Fallback für
    /// "nicht installiert" wäre an dieser Stelle unerreichbarer Code.
    private func openInGoogleMaps(source: MKMapItem?, destination: MKMapItem, viaPoint: CLLocationCoordinate2D?) {
        let destCoordinate = destination.location.coordinate
        var appQuery = "daddr=\(destCoordinate.latitude),\(destCoordinate.longitude)&directionsmode=\(travelMode.googleModeParam)"
        // Ohne saddr interpretiert Google Maps "ab aktuellem Standort" — genau das
        // Standardverhalten, wenn der Nutzer keinen eigenen Startpunkt gewählt hat.
        if let source {
            let sourceCoordinate = source.location.coordinate
            appQuery += "&saddr=\(sourceCoordinate.latitude),\(sourceCoordinate.longitude)"
        }
        if let viaPoint {
            appQuery += "&waypoints=\(viaPoint.latitude),\(viaPoint.longitude)"
        }
        guard let appURL = URL(string: "comgooglemaps://?\(appQuery)") else { return }
        UIApplication.shared.open(appURL)
    }

    // MARK: - Live-Monitoring

    /// Wird von openInMaps(_:) ausgelöst — der Weiterleiten-Tap ist der natürliche Moment, an
    /// dem die Fahrt beginnt, kein separater Bestätigungsschritt nötig. No-op, wenn die gewählte
    /// Route keinen bekannten Übergang kreuzt ODER kein konkreter Zug dafür bekannt ist (dann gäbe
    /// es nichts, gegen das checkForSignificantChange() vergleichen könnte — isTripActive bliebe
    /// sonst fälschlich "aktiv", obwohl nie eine Änderung erkannt werden kann).
    func startTrip() {
        guard let index = selectedRouteIndex, matchesByRoute.indices.contains(index),
              let firstHit = matchesByRoute[index].first,
              let event = firstHit.event else { return }

        // openInMaps(_:) ruft startTrip() bei JEDEM Weiterleiten-Tap auf — tippt der Nutzer z.B.
        // erst Apple Maps und danach (gleiche oder neu berechnete Route) Google Maps, würde ohne
        // dieses Aufräumen die vorherige Live Activity referenzlos und dauerhaft auf dem
        // Sperrbildschirm hängen bleiben, statt sauber beendet zu werden.
        if isTripActive {
            endCurrentActivity()
        }

        monitoredCrossing = firstHit.crossing
        monitoredEventId = event.id
        baselineCrossingTime = event.estimatedCrossingTime
        isTripActive = true
        currentBannerMessage = nil

        currentTripDestinationName = selectedDestination?.name
        currentTripCrossingName = firstHit.crossing.name
        currentTripWasBlockedAtStart = firstHit.isBlocked
        currentTripLastDelayMinutes = nil

        tripStartedAt = Date()
        currentTripEtaSeconds = firstHit.etaSeconds
        startLiveActivity(crossingName: firstHit.crossing.name, status: firstHit.statusAtArrival)

        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.monitorIntervalSeconds))
                guard !Task.isCancelled else { return }
                await self?.checkForSignificantChange()
            }
        }
        // Normalerweise längst beim Onboarding entschieden (siehe PermissionRequester.requestAll)
        // — dieser Aufruf ist nur noch das Sicherheitsnetz für "Später" übersprungene Sequenzen
        // oder Alt-Installationen ohne die dritte Berechtigungszeile.
        Task { await PermissionRequester.requestNotifications() }
    }

    func stopTrip() {
        isTripActive = false
        monitorTask?.cancel()
        monitorTask = nil
        monitoredCrossing = nil
        monitoredEventId = nil
        baselineCrossingTime = nil
        currentBannerMessage = nil
        tripStartedAt = nil
        currentTripEtaSeconds = nil
        endCurrentActivity()

        if let destinationName = currentTripDestinationName {
            let record = TripRecord(
                id: UUID(), date: Date(), destinationName: destinationName,
                crossingName: currentTripCrossingName, wasBlockedAtStart: currentTripWasBlockedAtStart,
                finalDelayMinutes: currentTripLastDelayMinutes
            )
            tripHistory.insert(record, at: 0)
            persistTripHistory()
        }
        currentTripDestinationName = nil
        currentTripCrossingName = nil
        currentTripWasBlockedAtStart = nil
        currentTripLastDelayMinutes = nil
    }

    /// Best-effort — schlägt das Anlegen fehl (Live Activities in iOS-Einstellungen deaktiviert,
    /// Berechtigung fehlt o.ä.), läuft die bestehende Sprache/Banner/Push-Kette unverändert
    /// weiter. `try?` statt Fehlerbehandlung, da es hier keine sinnvolle Nutzeraktion gäbe.
    private func startLiveActivity(crossingName: String, status: CrossingStatus?) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attributes = TripActivityAttributes(
            crossingName: crossingName, destinationName: selectedDestination?.name ?? "Ziel"
        )
        let content = ActivityContent(state: liveActivityContent(status: status), staleDate: nil)
        currentActivity = try? Activity.request(attributes: attributes, content: content, pushType: nil)
    }

    private func endCurrentActivity() {
        let activityToEnd = currentActivity
        currentActivity = nil
        Task { await activityToEnd?.end(nil, dismissalPolicy: .immediate) }
    }

    /// `etaText` zählt linear ab der ursprünglich berechneten Fahrzeit runter (keine echte
    /// GPS-Live-Verfolgung — die App navigiert ja bewusst nicht selbst, siehe RouteView-Kontext)
    /// statt stehenzubleiben; für eine grobe Orientierung auf dem Sperrbildschirm reicht das.
    private func liveActivityContent(status: CrossingStatus?) -> TripActivityAttributes.ContentState {
        var etaText = ""
        if let tripStartedAt, let etaSeconds = currentTripEtaSeconds {
            let remainingMinutes = Int((etaSeconds - Date().timeIntervalSince(tripStartedAt)) / 60)
            etaText = remainingMinutes > 0 ? "Ankunft in ca. \(remainingMinutes) Min" : "Gleich da"
        }
        return TripActivityAttributes.ContentState(
            statusLabel: status?.label ?? "Unbekannt",
            etaText: etaText,
            isBlocked: status != nil && status != .open
        )
    }

    private func checkForSignificantChange() async {
        guard let crossingViewModel else { return }
        // isDriving wird App-weit aus CoreMotion/GPS gepflegt (Schrankenradar_OSHApp.swift) und
        // hier wiederverwendet statt einer eigenen Abhängigkeit. Ohne diese Prüfung lief die
        // Überwachung nach jedem Tap auf "Apple Maps"/"Google Maps" unbegrenzt im Hintergrund
        // weiter (auch nur zum Ausprobieren, ohne tatsächlich loszufahren) und konnte
        // announceTrainTimeChanged() auslösen, obwohl der Nutzer gar nicht im Auto war
        // (Nutzer-Report). Sobald das Fahren endet (oder nie begann), Überwachung sauber beenden
        // statt jeden Tick stillschweigend zu überspringen.
        guard crossingViewModel.isDriving else {
            stopTrip()
            return
        }
        guard let crossing = monitoredCrossing, let eventId = monitoredEventId,
              let baseline = baselineCrossingTime else { return }
        let events = await crossingViewModel.fetchEvents(for: crossing)
        guard let match = events.first(where: { $0.id == eventId }) else { return }

        // Live Activity bei JEDEM Tick aktualisieren (nicht nur bei "signifikanter" Änderung
        // weiter unten) — sie soll den jeweils aktuellen Stand zeigen, nicht wie Sprache/Banner
        // nur bei großen Sprüngen anschlagen.
        if let activity = currentActivity {
            let content = ActivityContent(state: liveActivityContent(status: match.status(at: Date())), staleDate: nil)
            await activity.update(content)
        }

        let diff = match.estimatedCrossingTime.timeIntervalSince(baseline)
        guard abs(diff) >= Self.significantChangeThreshold else { return }

        let minutes = Int((abs(diff) / 60).rounded())
        currentBannerMessage = diff > 0
            ? "Der Zug an \(crossing.name) kommt \(minutes) Min später als erwartet."
            : "Der Zug an \(crossing.name) kommt \(minutes) Min früher als erwartet."
        voiceAnnouncer?.announceTrainTimeChanged()
        currentTripLastDelayMinutes = Int((diff / 60).rounded())
        await postSignificantChangeNotification()
        // Baseline aktualisieren, sonst würde jeder folgende 30s-Tick dieselbe (jetzt bereits
        // gemeldete) Abweichung erneut als "signifikant" werten und den Alarm wiederholen.
        baselineCrossingTime = match.estimatedCrossingTime
    }

    /// Ergänzt Sprachansage/Banner, ersetzt sie nicht — erreicht zusätzlich auch, wenn man
    /// gerade in Apple/Google Maps ist statt in der App (Nutzerwunsch). Nutzt denselben bereits
    /// berechneten currentBannerMessage-Text, keine eigene Formatierung nötig. `trigger: nil`
    /// liefert sofort statt zeitversetzt aus.
    private func postSignificantChangeNotification() async {
        let content = UNMutableNotificationContent()
        content.title = "Zugankunft geändert"
        content.body = currentBannerMessage ?? ""
        content.sound = .default
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }
}

// MARK: - MKLocalSearchCompleterDelegate

extension RouteViewModel: MKLocalSearchCompleterDelegate {
    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        if completer === startCompleter {
            startCompletions = completer.results
        } else if completer === destinationCompleter {
            destinationCompletions = completer.results
        } else if completer === waypointCompleter {
            waypointCompletions = completer.results
        }
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        // Still fehlschlagen — die Vorschlagsliste bleibt einfach leer/unverändert.
    }
}
