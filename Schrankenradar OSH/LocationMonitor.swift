import CoreLocation
import Observation

private let keyRadius = "voiceRadius"

@Observable
final class LocationMonitor: NSObject, CLLocationManagerDelegate {

    var isNearCrossing = false
    var authorizationStatus: CLAuthorizationStatus = .notDetermined

    /// Globaler Fallback-Radius (wird pro Übergang überschrieben)
    var radius: Double {
        didSet {
            UserDefaults.standard.set(radius, forKey: keyRadius)
            updateNearCrossing()
        }
    }

    /// Wird aufgerufen wenn die App automatisch zu einem näheren Übergang wechseln soll
    var onAutoSwitch: ((CrossingLocation) -> Void)?

    /// Aktuelle GPS-Geschwindigkeit (m/s) für die Fahrt-Erkennung (DrivingDetector).
    var onSpeedUpdate: ((Double) -> Void)?

    private let manager    = CLLocationManager()
    private var lastLocation: CLLocation?

    // Unabhängige Gründe für aktives GPS-Tracking (Fahrt-Erkennung UND/ODER ein offener Tab,
    // der die Position braucht — Schranken-Modus, Anfahrt, Radar) — solange mindestens einer
    // zutrifft, bleibt Tracking aktiv. screenPresenceRequests ist ein ZÄHLER statt eines
    // einzelnen Bools: bei mehreren Tabs, die start/stopForScreenPresence in ihrem
    // onAppear/onDisappear aufrufen, ist die Reihenfolge zwischen "altes Tab verschwindet" und
    // "neues Tab erscheint" beim Tab-Wechsel nicht garantiert — mit einem einzelnen Bool könnte
    // das später ankommende stopForScreenPresence() das kurz zuvor gesetzte "true" wieder
    // überschreiben, obwohl noch ein Tab aktiv ist. Ein Zähler ist unabhängig von der
    // Aufruf-Reihenfolge korrekt, solange jeder Aufrufer start/stop paarweise aufruft.
    private var wantsDrivingTracking = false
    private var screenPresenceRequests = 0
    private var shouldBeTracking: Bool { wantsDrivingTracking || screenPresenceRequests > 0 }

    // Aktuell bekannte Übergänge (werden vom ViewModel gesetzt)
    var crossings: [CrossingLocation] = CrossingLocation.all

    override init() {
        let stored = UserDefaults.standard.double(forKey: keyRadius)
        radius = stored > 0 ? stored : 2000
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        // Hilft CoreLocation, kurze Stopps (Ampel, Stau) nicht als Fahrtende misszuverstehen —
        // Standardverhalten für Navigations-/Fahrt-Apps.
        manager.activityType = .automotiveNavigation
        authorizationStatus = manager.authorizationStatus
    }

    func start() {
        wantsDrivingTracking = true
        applyTrackingIntent()
    }

    func stop() {
        wantsDrivingTracking = false
        applyTrackingIntent()
    }

    /// Hält GPS aktiv solange ein Tab offen ist, der die Position braucht (Schranken-Modus,
    /// Anfahrt, Radar) — unabhängig von der Fahrt-Erkennung, damit sich auch im Stehen die
    /// Entfernung/Fahrzeit prüfen lässt. Mehrfach-sicher: siehe Kommentar bei screenPresenceRequests.
    func startForScreenPresence() {
        screenPresenceRequests += 1
        applyTrackingIntent()
    }

    func stopForScreenPresence() {
        screenPresenceRequests = max(0, screenPresenceRequests - 1)
        applyTrackingIntent()
    }

    private func applyTrackingIntent() {
        guard shouldBeTracking else {
            manager.stopUpdatingLocation()
            isNearCrossing = false
            return
        }
        switch manager.authorizationStatus {
        case .notDetermined:
            DebugLog.shared.add("Standort: Status .notDetermined — fordere Berechtigung an (Popup sollte jetzt erscheinen).")
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            // Ansagen sollen auch bei gesperrtem Bildschirm kommen — dafür reicht "Bei
            // Nutzung" nicht. Das Upgrade wird erst hier (beim tatsächlichen Fahrt-Tracking)
            // angefragt statt schon beim Onboarding, wie von Apple für "Always" empfohlen
            // (Kontext, in dem der Mehrwert erkennbar ist, statt Vorab-Anfrage ohne Grund).
            DebugLog.shared.add("Standort: bereits erlaubt (whenInUse), starte Tracking + fordere Immer-Upgrade an.")
            manager.startUpdatingLocation()
            manager.requestAlwaysAuthorization()
        case .authorizedAlways:
            DebugLog.shared.add("Standort: bereits erlaubt (always), starte Tracking im Hintergrund.")
            manager.allowsBackgroundLocationUpdates = true
            manager.startUpdatingLocation()
        default:
            DebugLog.shared.add("Standort: Status \(manager.authorizationStatus) — kein Tracking (abgelehnt oder eingeschränkt).")
        }
    }

    /// Fragt das Upgrade auf "Immer" explizit an — aufgerufen direkt in der Berechtigungs-
    /// Sequenz (PermissionRequester), damit der Dialog zusammen mit den anderen Berechtigungs-
    /// Popups am Anfang kommt statt erst beim ersten Fahrt-Start. No-op ohne vorherige
    /// "Bei Nutzung"-Freigabe (iOS würde sonst gar keinen Dialog zeigen).
    func requestAlwaysUpgradeIfNeeded() {
        guard manager.authorizationStatus == .authorizedWhenInUse else { return }
        DebugLog.shared.add("Standort: fordere Immer-Upgrade an (Berechtigungs-Sequenz).")
        manager.requestAlwaysAuthorization()
    }

    /// Entfernung zur übergebenen Schranke in Metern, oder nil solange noch keine GPS-Position vorliegt.
    func distance(to crossing: CrossingLocation) -> Double? {
        guard let location = lastLocation else { return nil }
        return location.distance(from: CLLocation(latitude: crossing.latitude, longitude: crossing.longitude))
    }

    /// Letzte bekannte Position, z.B. als Startpunkt für Routen-/Fahrzeit-Berechnungen (Anfahrt-Tab).
    var currentCoordinate: CLLocationCoordinate2D? { lastLocation?.coordinate }

    /// Wartet bis der Nutzer das Standort-Popup beantwortet hat (oder es keins gab, weil
    /// bereits entschieden), bevor die nächste Berechtigungs-Abfrage in der Startsequenz folgt.
    func waitForAuthorizationAnswer() async {
        while authorizationStatus == .notDetermined {
            try? await Task.sleep(for: .milliseconds(300))
        }
    }

    private func updateNearCrossing() {
        guard let location = lastLocation else { return }

        // Nächster Übergang innerhalb seines Radius finden
        let nearest = crossings
            .filter { $0.voiceEnabled }
            .min(by: { a, b in
                let da = location.distance(from: CLLocation(latitude: a.latitude, longitude: a.longitude))
                let db = location.distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
                return da < db
            })

        if let nearest = nearest {
            let distance = location.distance(from: CLLocation(latitude: nearest.latitude, longitude: nearest.longitude))
            isNearCrossing = distance <= nearest.radiusMeters

            // Bei JEDEM Innerhalb-des-Radius-Update aufrufen, nicht nur beim Ersteintritt
            // (vorher: "if !wasNear && isNearCrossing") — sonst blieb die Auswahl auf dem alten
            // Übergang stehen, wenn (a) sich bei überlappenden Radien der nächste Übergang
            // wechselt OHNE dass isNearCrossing zwischenzeitlich false wird (z.B. die beiden
            // nah beieinanderliegenden Feldmochinger Schranken), oder (b) der Nutzer manuell auf
            // einen anderen Übergang umgeschaltet hat, obwohl er weiter physisch beim alten ist —
            // isNearCrossing bezieht sich dann fälschlich auf den manuell gewählten statt den
            // tatsächlich nahen Übergang, wodurch z.B. eine Status-Ansage für einen Übergang
            // kam, in dessen Radius man gar nicht war. onAutoSwitch() selbst ist bereits
            // idempotent (Schrankenradar_OSHApp.swift: no-op wenn schon ausgewählt).
            if isNearCrossing {
                onAutoSwitch?(nearest)
            }
        } else {
            isNearCrossing = false
        }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        DebugLog.shared.add("Standort: Berechtigungs-Status geändert zu \(manager.authorizationStatus) (Nutzer hat Popup beantwortet).")
        if manager.authorizationStatus == .authorizedAlways {
            manager.allowsBackgroundLocationUpdates = true
        }
        if shouldBeTracking &&
           (manager.authorizationStatus == .authorizedWhenInUse ||
            manager.authorizationStatus == .authorizedAlways) {
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        lastLocation = location
        updateNearCrossing()
        onSpeedUpdate?(location.speed)
    }
}
