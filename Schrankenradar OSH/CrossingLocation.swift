import Foundation
import CoreLocation

// MARK: - Bahnübergang Modell

struct CrossingLocation: Identifiable, Codable, Equatable, Hashable {
    let id: String
    let name: String          // "Lechenauer Str."
    let subtitle: String      // "Feldmoching"
    let stationEVA: String    // DB Stations-ID
    let latitude: Double
    let longitude: Double
    var offsetToMunich: Double    // Sekunden: Abfahrt → Schranke (München-Richtung)
    var offsetToFreising: Double  // Sekunden: negativ, Schranke vor Abfahrt
    let onlyS1: Bool              // true = nur S1, false = alle S-Bahnen (z.B. Feldmoching)

    /// Linien die Geops bestätigt hat dass sie diese Schranke überfahren.
    /// nil = noch keine Geops-Daten → alle DB-Linien anzeigen
    /// nach erster Befahrung → nur noch bestätigte Linien
    var confirmedLines: [String]?

    // GPS-gemessene Offsets (nil = noch nicht gemessen, nutzt dann Schätzwert oben)
    // Messung: Zeit zwischen GPS-Durchfahrt an Crossing UND Abfahrt an stationEVA
    // → München:  Crossing NACH Abfahrt  → positiver Wert
    // → Freising: Crossing VOR Abfahrt   → negativer Wert
    // Beispiel Feldmoching: Referenzpunkt immer Feldmoching Station (8004159)
    var measuredOffsetToMunich: Double?
    var measuredOffsetToFreising: Double?
    var gpsOffsetMeasurements: Int = 0    // Gesamtzahl Messungen (Recorder + GPS)

    // Geops-GPS-spezifische Zähler (persistent, pro Richtung)
    var autoMeasurementsMunich: Int = 0
    var autoMeasurementsFreising: Int = 0

    // Kalman-Filter Kovarianz (Schätzungssicherheit); 100 = hohe Unsicherheit
    var kalmanVarianceMunich:   Double = 100.0
    var kalmanVarianceFreising: Double = 100.0

    // Tageszeit-spezifische Offsets ("08" → 195.3s) — lernt Stoßzeit vs. Nebenzeit
    var hourlyOffsetsMunich:   [String: Double] = [:]
    var hourlyOffsetsFreising: [String: Double] = [:]

    /// Besten verfügbaren Offset zurückgeben.
    /// Priorität: Tageszeit-GPS (≥3) > allg. GPS (≥3) > Community > statisch.
    func bestOffset(toMunich: Bool,
                    communityMunich:   Double? = nil,
                    communityFreising: Double? = nil,
                    hour: Int?         = nil) -> Double {
        if toMunich {
            if let h = hour, autoMeasurementsMunich >= 3,
               let hourly = hourlyOffsetsMunich[String(format: "%02d", h)] { return hourly }
            if let m = measuredOffsetToMunich, autoMeasurementsMunich >= 3 { return m }
            if let c = communityMunich { return c }
        } else {
            if let h = hour, autoMeasurementsFreising >= 3,
               let hourly = hourlyOffsetsFreising[String(format: "%02d", h)] { return hourly }
            if let m = measuredOffsetToFreising, autoMeasurementsFreising >= 3 { return m }
            if let c = communityFreising { return c }
        }
        return toMunich ? offsetToMunich : offsetToFreising
    }

    /// Quelle des aktuell genutzten Offsets für Anzeige in der UI.
    enum OffsetSource { case local, community, estimate }
    func offsetSource(toMunich: Bool,
                      communityMunich:   Double? = nil,
                      communityFreising: Double? = nil) -> OffsetSource {
        if toMunich {
            if autoMeasurementsMunich >= 3 && measuredOffsetToMunich != nil { return .local }
            if communityMunich != nil { return .community }
        } else {
            if autoMeasurementsFreising >= 3 && measuredOffsetToFreising != nil { return .local }
            if communityFreising != nil { return .community }
        }
        return .estimate
    }

    /// True wenn GPS-Offset für diese Richtung als zuverlässig gilt (≥ 10 Messungen).
    func isMeasuredOffsetTrusted(toMunich: Bool) -> Bool {
        toMunich ? autoMeasurementsMunich >= 10 : autoMeasurementsFreising >= 10
    }

    // Vom Nutzer konfigurierbar
    var voiceEnabled: Bool
    var radiusMeters: Double
    // Ansage-Template mit Platzhaltern:
    // {status}    → "Schranke schließt bald" / "Schranke geschlossen" etc.
    // {linie}     → "S1"
    // {richtung}  → "München"
    // {zeit}      → "in 2 Minuten" / "in 45 Sekunden"
    var announcementTemplate: String

    static let defaultTemplate = "{status}. {linie} Richtung {richtung} {zeit}."

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    // MARK: - Alle bekannten Bahnübergänge

    static let all: [CrossingLocation] = [

        CrossingLocation(
            id: "osh_dachauer",
            name: "Dachauer Str.",
            subtitle: "Oberschleißheim",
            stationEVA: "8004158",
            latitude: 48.2508,
            longitude: 11.5583,
            offsetToMunich: 180,
            offsetToFreising: -180,
            onlyS1: true,
            voiceEnabled: true,
            radiusMeters: 500,
            announcementTemplate: CrossingLocation.defaultTemplate
        ),

        CrossingLocation(
            id: "feldmoching_lechenauer1",
            name: "Lechenauer Str. (1)",
            subtitle: "Feldmoching",
            stationEVA: "8004159",
            latitude: 48.205056,
            longitude: 11.537028,
            // Crossing liegt NÖRDLICH von Feldmoching Station (zwischen Feldmoching + OSH)
            // → München: Crossing VOR Ankunft Feldmoching → negativ
            // → Freising: Crossing NACH Abfahrt Feldmoching → positiv
            offsetToMunich: -120,
            offsetToFreising: 120,
            onlyS1: false,
            voiceEnabled: true,
            radiusMeters: 500,
            announcementTemplate: CrossingLocation.defaultTemplate
        ),

        CrossingLocation(
            id: "feldmoching_lechenauer2",
            name: "Lechenauer Str. (2)",
            subtitle: "Feldmoching",
            stationEVA: "8004159",
            latitude: 48.202379,
            longitude: 11.540786,
            offsetToMunich: -90,
            offsetToFreising: 90,
            onlyS1: false,
            voiceEnabled: true,
            radiusMeters: 500,
            announcementTemplate: CrossingLocation.defaultTemplate
        ),

        CrossingLocation(
            id: "feldmoching_feldmochinger",
            name: "Feldmochinger Str.",
            subtitle: "Fasanerie",
            stationEVA: "8004159",
            latitude: 48.196908,
            longitude: 11.524508,
            offsetToMunich: 30,
            offsetToFreising: -30,
            onlyS1: false,
            voiceEnabled: true,
            radiusMeters: 500,
            announcementTemplate: CrossingLocation.defaultTemplate
        )
    ]
}

// MARK: - Store (persistiert Einstellungen)

@Observable
final class CrossingsStore {

    var crossings: [CrossingLocation]
    var selectedId: String

    var selected: CrossingLocation {
        crossings.first { $0.id == selectedId } ?? crossings[0]
    }

    init() {
        // Gespeicherte Einstellungen laden oder Defaults verwenden
        if let data = UserDefaults.standard.data(forKey: "crossings_settings"),
           let saved = try? JSONDecoder().decode([String: CrossingUserSettings].self, from: data) {
            crossings = CrossingLocation.all.map { c in
                var copy = c
                if let s = saved[c.id] {
                    copy.voiceEnabled             = s.voiceEnabled
                    copy.radiusMeters             = s.radiusMeters
                    copy.announcementTemplate     = s.announcementTemplate
                    copy.measuredOffsetToMunich   = s.measuredOffsetToMunich   ?? c.measuredOffsetToMunich
                    copy.measuredOffsetToFreising = s.measuredOffsetToFreising ?? c.measuredOffsetToFreising
                    copy.confirmedLines           = s.confirmedLines           ?? c.confirmedLines
                    copy.autoMeasurementsMunich   = s.autoMeasurementsMunich   ?? c.autoMeasurementsMunich
                    copy.autoMeasurementsFreising = s.autoMeasurementsFreising ?? c.autoMeasurementsFreising
                    copy.kalmanVarianceMunich     = s.kalmanVarianceMunich     ?? c.kalmanVarianceMunich
                    copy.kalmanVarianceFreising   = s.kalmanVarianceFreising   ?? c.kalmanVarianceFreising
                    copy.hourlyOffsetsMunich      = s.hourlyOffsetsMunich      ?? c.hourlyOffsetsMunich
                    copy.hourlyOffsetsFreising    = s.hourlyOffsetsFreising    ?? c.hourlyOffsetsFreising
                }
                return copy
            }
        } else {
            crossings = CrossingLocation.all
        }
        selectedId = UserDefaults.standard.string(forKey: "selected_crossing") ?? CrossingLocation.all[0].id
    }

    func select(_ crossing: CrossingLocation) {
        selectedId = crossing.id
        UserDefaults.standard.set(selectedId, forKey: "selected_crossing")
    }

    func update(_ crossing: CrossingLocation) {
        if let idx = crossings.firstIndex(where: { $0.id == crossing.id }) {
            crossings[idx] = crossing
            saveSettings()
        }
    }

    private func saveSettings() {
        let settings = Dictionary(uniqueKeysWithValues: crossings.map {
            ($0.id, CrossingUserSettings(
                voiceEnabled: $0.voiceEnabled,
                radiusMeters: $0.radiusMeters,
                announcementTemplate: $0.announcementTemplate,
                measuredOffsetToMunich: $0.measuredOffsetToMunich,
                measuredOffsetToFreising: $0.measuredOffsetToFreising,
                confirmedLines: $0.confirmedLines,
                autoMeasurementsMunich:   $0.autoMeasurementsMunich,
                autoMeasurementsFreising: $0.autoMeasurementsFreising,
                kalmanVarianceMunich:     $0.kalmanVarianceMunich,
                kalmanVarianceFreising:   $0.kalmanVarianceFreising,
                hourlyOffsetsMunich:      $0.hourlyOffsetsMunich.isEmpty ? nil : $0.hourlyOffsetsMunich,
                hourlyOffsetsFreising:    $0.hourlyOffsetsFreising.isEmpty ? nil : $0.hourlyOffsetsFreising
            ))
        })
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: "crossings_settings")
        }
    }
}

struct CrossingUserSettings: Codable {
    var voiceEnabled: Bool
    var radiusMeters: Double
    var announcementTemplate: String
    var measuredOffsetToMunich: Double?
    var measuredOffsetToFreising: Double?
    var confirmedLines: [String]?
    var autoMeasurementsMunich: Int?
    var autoMeasurementsFreising: Int?
    var kalmanVarianceMunich: Double?
    var kalmanVarianceFreising: Double?
    var hourlyOffsetsMunich: [String: Double]?
    var hourlyOffsetsFreising: [String: Double]?
}
