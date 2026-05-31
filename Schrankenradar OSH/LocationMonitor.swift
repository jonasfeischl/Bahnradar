import CoreLocation
import Observation

private let crossingLocation = CLLocation(latitude: 48.2500, longitude: 11.5597)
private let keyRadius = "voiceRadius"

@Observable
final class LocationMonitor: NSObject, CLLocationManagerDelegate {
    var isNearCrossing = false
    var authorizationStatus: CLAuthorizationStatus = .notDetermined

    /// Radius in Metern (einstellbar, Standard 2000m)
    var radius: Double {
        didSet {
            UserDefaults.standard.set(radius, forKey: keyRadius)
            updateNearCrossing()
        }
    }

    private let manager = CLLocationManager()
    private var lastLocation: CLLocation?

    override init() {
        let stored = UserDefaults.standard.double(forKey: keyRadius)
        radius = stored > 0 ? stored : 2000
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        authorizationStatus = manager.authorizationStatus
    }

    func start() {
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
        manager.stopUpdatingLocation()
        isNearCrossing = false
    }

    private func updateNearCrossing() {
        guard let location = lastLocation else { return }
        isNearCrossing = location.distance(from: crossingLocation) <= radius
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        if manager.authorizationStatus == .authorizedWhenInUse ||
           manager.authorizationStatus == .authorizedAlways {
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        lastLocation = location
        isNearCrossing = location.distance(from: crossingLocation) <= radius
    }
}
