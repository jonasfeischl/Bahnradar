import ActivityKit
import Foundation

// Muss in BEIDEN Targets eingebunden sein:
// → Schrankenradar OSH (Haupt-App)
// → SchrankenradarWidget (Widget Extension)

struct CrossingActivityAttributes: ActivityAttributes {

    // Statisch — ändert sich nicht während der Activity läuft
    let crossingName: String

    // Dynamisch — wird jede Minute aktualisiert
    struct ContentState: Codable, Hashable {
        /// Zeitpunkt wenn Schranke ROT wird (crossingTime - 60s)
        var closingTime: Date
        /// Zeitpunkt wenn Schranke wieder öffnet (crossingTime + 10s)
        var openingTime: Date
        /// Aktueller Status als String
        var statusRaw: String   // "open", "warning", "closed", "opening"
        var trainLine: String
        var trainDirection: String

        var statusLabel: String {
            switch statusRaw {
            case "warning": return "Schließt bald"
            case "closed":  return "Geschlossen"
            case "opening": return "Öffnet gleich"
            default:        return "Offen"
            }
        }
    }
}
