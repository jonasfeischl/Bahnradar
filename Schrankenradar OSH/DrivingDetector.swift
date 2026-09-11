import CoreMotion
import Observation
import Foundation

@Observable
final class DrivingDetector {
    var isDriving = false

    /// Nur für den Admin-Test-Schalter in den Einstellungen: erzwingt isDriving=true
    /// unabhängig von den echten Sensoren, um Sprachansagen ohne echte Fahrt zu testen.
    /// Ohne diesen Weg über recompute() würde eine direkt gesetzte isDriving spätestens beim
    /// nächsten tick() (jede Sekunde) wieder auf false zurückfallen, sobald weder CoreMotion
    /// noch GPS "fährt" melden.
    var debugForceDriving = false {
        didSet { recompute() }
    }

    private let motionManager = CMMotionActivityManager()
    private var coreMotionAutomotive = false
    private var gpsDrivingUntil: Date?

    // ~15 km/h — deutlich über Geh-/Radfahrtempo, aber früh genug erkannt
    private static let speedOnThreshold: Double = 4.2
    // Hält "fährt" für kurze Stopps (Ampel, Bahnübergang selbst) statt sofort zu kippen
    private static let gpsGracePeriod: TimeInterval = 45

    func start() {
        guard CMMotionActivityManager.isActivityAvailable() else {
            DebugLog.shared.add("Bewegung&Fitness: Core Motion NICHT verfügbar (z.B. Simulator) — kein Berechtigungs-Popup möglich, keine automatische Fahrterkennung.")
            return
        }
        // Bei .denied/.restricted keinen Sinn mehr, startActivityUpdates erneut aufzurufen
        // (z.B. bei jeder Rückkehr aus dem Hintergrund) — spart unnötige Neustarts.
        let status = CMMotionActivityManager.authorizationStatus()
        guard status == .notDetermined || status == .authorized else { return }
        motionManager.startActivityUpdates(to: .main) { [weak self] activity in
            guard let activity else { return }
            MainActor.assumeIsolated {
                self?.coreMotionAutomotive = activity.automotive
                self?.recompute()
            }
        }
    }

    /// Wartet bis der Nutzer das Bewegung&Fitness-Popup tatsächlich beantwortet hat (oder es
    /// erst gar nicht angezeigt werden kann), bevor die nächste Berechtigungs-Abfrage folgt.
    /// Ein festes Zeitfenster reicht nicht, wenn sich der Nutzer beim Antworten Zeit lässt —
    /// dann würde die nächste Abfrage mitten in die noch offene erste hineinplatzen.
    static func waitForAuthorizationAnswer() async {
        guard CMMotionActivityManager.isActivityAvailable() else { return }
        while CMMotionActivityManager.authorizationStatus() == .notDetermined {
            try? await Task.sleep(for: .milliseconds(300))
        }
        DebugLog.shared.add("Bewegung&Fitness: Popup beantwortet (Status: \(CMMotionActivityManager.authorizationStatus().rawValue)).")
    }

    func stop() {
        motionManager.stopActivityUpdates()
        coreMotionAutomotive = false
        gpsDrivingUntil = nil
        isDriving = false
    }

    /// GPS-Geschwindigkeit einspeisen (von LocationMonitor). Deutlich schneller als Core
    /// Motions Aktivitätserkennung, die anfangs oft mehrere Minuten unsicher bleibt.
    func updateSpeed(metersPerSecond speed: Double) {
        guard speed >= 0 else { return }   // negativ = ungültige Messung
        if speed > Self.speedOnThreshold {
            gpsDrivingUntil = Date().addingTimeInterval(Self.gpsGracePeriod)
        }
        recompute()
    }

    /// Regelmäßig aufrufen (z.B. im 1s-UI-Timer), damit die GPS-Gnadenfrist auch ohne
    /// neue Standort-Updates rechtzeitig abläuft.
    func tick() {
        recompute()
    }

    private func recompute() {
        let gpsActive = gpsDrivingUntil.map { $0 > Date() } ?? false
        isDriving = debugForceDriving || coreMotionAutomotive || gpsActive
    }
}
