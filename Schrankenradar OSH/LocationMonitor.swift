import CoreLocation
import Observation

// Mittelpunkt Oberschleißheim (Bahnübergang Dachauer Str.)
private let crossingLocation = CLLocation(latitude: 48.2500, longitude: 11.5597)
private let activeRadius: CLLocationDistance = 2000 // 2 km

@Observable
final class LocationMonitor: NSObject, CLLocationManagerDelegate {
    var isNearCrossing = false
    var authorizationStatus: CLAuthorizationStatus = .notDetermined

    private let manager = CLLocationManager()

    override init() {
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

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        if manager.authorizationStatus == .authorizedWhenInUse ||
           manager.authorizationStatus == .authorizedAlways {
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let distance = location.distance(from: crossingLocation)
        isNearCrossing = distance <= activeRadius
    }
}
