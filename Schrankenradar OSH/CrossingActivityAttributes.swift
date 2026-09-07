import Foundation

// Muss in BEIDEN Targets eingebunden sein:
// → Schrankenradar OSH (Haupt-App)
// → SchrankenradarWidget (Widget Extension)

// MARK: - Geteilte Widget-Daten (App → Widget via App Group)
// Das Widget kann selbst kein Geops (WebSocket) nutzen. Die App berechnet die Events
// mit voller Geops-Genauigkeit (Live-Zeiten + GPS-Offsets + Trajectory) und legt sie hier
// ab. Das Widget liest sie und nutzt nur seinen eigenen DB-Fetch als Fallback.

struct SharedTrainEvent: Codable {
    let line: String
    let directionIsMunich: Bool
    let crossingTime: Date
    let delayMinutes: Int
}

struct SharedWidgetPayload: Codable {
    let crossingId: String
    let crossingName: String
    let crossingSubtitle: String
    let generatedAt: Date
    let events: [SharedTrainEvent]

    static let userDefaultsKey = "widget_sharedEvents_v1"
}
