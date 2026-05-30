import CoreMotion
import Observation

@Observable
final class DrivingDetector {
    var isDriving = false

    private let motionManager = CMMotionActivityManager()

    func start() {
        guard CMMotionActivityManager.isActivityAvailable() else { return }
        motionManager.startActivityUpdates(to: .main) { [weak self] activity in
            guard let activity else { return }
            MainActor.assumeIsolated {
                self?.isDriving = activity.automotive
            }
        }
    }

    func stop() {
        motionManager.stopActivityUpdates()
    }
}
