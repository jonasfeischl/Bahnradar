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

    private let manager    = CLLocationManager()
    private var lastLocation: CLLocation?
    private var shouldBeTracking = false

    // Aktuell bekannte Übergänge (werden vom ViewModel gesetzt)
    var crossings: [CrossingLocation] = CrossingLocation.all

    override init() {
        let stored = UserDefaults.standard.double(forKey: keyRadius)
        radius = stored > 0 ? stored : 2000
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        authorizationStatus = manager.authorizationStatus
    }

    func start() {
        shouldBeTracking = true
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.startUpdatingLocation()
        default:
            break
        }
    }

    func stop() {
        shouldBeTracking = false
        manager.stopUpdatingLocation()
        isNearCrossing = false
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
            let wasNear = isNearCrossing
            isNearCrossing = distance <= nearest.radiusMeters

            // Automatisch wechseln wenn gerade in den Radius eingetreten
            if !wasNear && isNearCrossing {
                onAutoSwitch?(nearest)
            }
        } else {
            isNearCrossing = false
        }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
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
    }
}
