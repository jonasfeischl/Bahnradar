import Foundation
import CoreLocation

// MARK: - Bahnübergang Modell

struct CrossingLocation: Identifiable, Codable, Equatable, Hashable {
    let id: String
    let name: String          // "Lerchenauer Str."
    let subtitle: String      // "Feldmoching"
    let stationEVA: String    // DB Stations-ID
    /// MVG-Stations-ID (Format "de:09184:2000") für die bevorzugte Verspätungsquelle MVGService —
    /// ermittelt über https://www.mvg.de/api/bgw-pt/v3/locations?query=<Stationsname>. nil = keine
    /// MVG-Abdeckung bekannt, dann bleibt DBs Realtime-Changes-API alleinige Verspätungsquelle.
    var mvgGlobalId: String? = nil
    /// Ob MVG für diese Station Regionalzug-Daten (transportTypes=BAHN) führt — per
    /// Stationsmetadaten verifiziert (2026-07-20): Feldmoching hat `["BAHN","SBAHN","UBAHN",
    /// "BUS"]`, Oberschleißheim nur `["SBAHN","BUS"]`, also strukturell NIE BAHN-Daten. Ohne
    /// dieses Flag fragte TrainAPIService BAHN blind für JEDEN Übergang ab (auch dort, wo es nie
    /// Daten gibt) — reine Verschwendung, und führte live dazu, dass MVG die App wegen der
    /// dadurch verdoppelten Anfragen mit HTTP 509 (Rate-Limit) abgewiesen hat, was kollateral
    /// auch die eigentlich funktionierende SBAHN-Abfrage destabilisiert hat (User-Report
    /// 2026-07-22: "jetzt mvv grau angezeigt"). Jetzt wird BAHN nur noch abgefragt, wo es
    /// tatsächlich Daten geben kann.
    var mvgSupportsRegionalTrains: Bool = false
    /// EVA einer benachbarten Station, an der RE/RB TATSÄCHLICH halten — für Übergänge, deren
    /// eigene stationEVA strukturell nie Regionalzüge führt (reine S-Bahn-Station, Züge fahren
    /// nur durch, ohne Fahrgastwechsel → tauchen in keiner Stations-Abfahrtstafel auf, siehe
    /// TrainAPIService.fetchRegionalDBEntries). Live-Check 2026-09-09: Oberschleißheim (8004580)
    /// hatte an einem kompletten Tag (Std. 05-22) 0 von 202 RE/RB-Einträgen; Unterschleißheim
    /// (8006688, nächster Regionalzug-Halt Richtung Freising/Landshut) dagegen zuverlässig RB33
    /// (~alle 2h). nil = keine separate Referenz nötig (z.B. Feldmoching, dort hält RB33 selbst).
    var regionalStationEVA: String? = nil
    /// Offset Abfahrt/Ankunft an regionalStationEVA → Übergang, analog zu offsetToMunich/
    /// -Freising aber relativ zur entfernteren Regional-Referenzstation. Grobschätzung
    /// (2026-09-09): aus echten RB33-Zeiten an Feldmoching UND Unterschleißheim (identische
    /// Zugnummern, ~5min Segment) plus dem S-Bahn-Fahrplanverhältnis Feldmoching–OSH–
    /// Unterschleißheim als Interpolationsstütze (Oberschleißheims eigener 180s-Offset + ~60s
    /// gemessene S-Bahn-Fahrzeit Oberschleißheim↔Unterschleißheim). NICHT GPS-gemessen — bei
    /// Gelegenheit per echter RB/RE-Durchfahrt im Diagnose-Log verifizieren/nachjustieren.
    var regionalOffsetToMunich: Double = 0
    var regionalOffsetToFreising: Double = 0
    let latitude: Double
    let longitude: Double
    /// Erfassungsradius für die GPS-Auto-Kalibrierung (detectCrossingPassage): wie nah muss
    /// die Zug-Trajektorie an latitude/longitude vorbeikommen, damit eine Durchfahrt gezählt
    /// wird. Standard 200m; höher für Übergänge deren hinterlegte Koordinate ungenauer ist.
    var gpsToleranceMeters: Double = 200
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

    // Tageszeit- UND wochentagsspezifische Offsets (Schlüssel z.B. "WD08"/"WE08", siehe
    // hourlyKey) — lernt Stoßzeit vs. Nebenzeit UND Werktag vs. Wochenende getrennt, da sich
    // S-Bahn-Taktung/Zugfolge am Wochenende oft spürbar unterscheidet und ein gemeinsamer
    // Stunden-Bucket (z.B. Samstag-08 + Montag-08 zusammen) die Kalman-Schätzung unnötig
    // verrauscht hätte.
    var hourlyOffsetsMunich:   [String: Double] = [:]
    var hourlyOffsetsFreising: [String: Double] = [:]

    /// True für Samstag/Sonntag (Calendar-Weekday 1=So, 7=Sa, kalenderunabhängig von der
    /// Locale-Woche-Start-Einstellung — .weekday zählt immer ab Sonntag=1).
    static func isWeekend(_ date: Date) -> Bool {
        let weekday = Calendar.current.component(.weekday, from: date)
        return weekday == 1 || weekday == 7
    }

    /// Schlüssel für hourlyOffsetsMunich/-Freising: Stunde + Werktag/Wochenende kombiniert.
    static func hourlyKey(hour: Int, isWeekend: Bool) -> String {
        "\(isWeekend ? "WE" : "WD")\(String(format: "%02d", hour))"
    }

    /// Mindestanzahl an Rohmessungen, ab der ein Community-Wert vertraut wird — dieselbe
    /// Schwelle wie bei eigenen Messungen. Ohne das könnte ein einzelner Ausreißer (z.B. ein
    /// GPS-Messfehler eines anderen Nutzers) die Vorhersage für alle sofort verfälschen.
    static let minCommunitySamples = 3

    /// An der Dachauer Str. laufen zwei fest verdrahtete, von Hand kalibrierte Korrekturen
    /// (siehe CrossingViewModel.buildEvents, "TEMPORÄRER HARDCODE"-Kommentare) — die sind gegen
    /// einen bestimmten Community-/Standard-Basiswert justiert. Die GPS-Auto-Kalibrierung läuft
    /// aber unabhängig davon im Hintergrund WEITER (jede erkannte Durchfahrt aktualisiert
    /// measuredOffsetToMunich/-Freising) und hätte, sobald sie ≥3 Messungen erreicht, plötzlich
    /// Priorität über den Community-/Standardwert bekommen — die Basis unter dem Hardcode hätte
    /// sich dann unbemerkt verschieben können, obwohl der Hardcode unverändert blieb. User-Report
    /// 2026-07-20: "manchmal passt münchen offset nicht" + "manchmal kommt gps noch immer" (nach
    /// der bereits erfolgten Abschaltung von GPS als direkter Zeitquelle) passt genau zu diesem
    /// Mechanismus. Fix: für osh_dachauer wird die GPS-Auto-Kalibrierung hier bewusst ignoriert
    /// (Basis bleibt stabil bei Community/Standard), bis die Hardcodes irgendwann durch sauber
    /// neu kalibrierte Lerndaten ersetzt werden. Feldmoching hat KEINE Hardcodes und braucht die
    /// GPS-Auto-Kalibrierung weiterhin als einzige Kalibrierungsquelle — dort unverändert.
    private var usesFrozenBase: Bool { id == "osh_dachauer" }

    /// Besten verfügbaren Offset zurückgeben.
    /// Priorität: Tageszeit+Wochentag-GPS (≥3) > allg. GPS (≥3) > Community (≥3) > statisch.
    /// Ausnahme: osh_dachauer überspringt beide GPS-Stufen, siehe usesFrozenBase.
    func bestOffset(toMunich: Bool,
                    communityMunich:      Double? = nil,
                    communityMunichCount: Int     = 0,
                    communityFreising:      Double? = nil,
                    communityFreisingCount: Int     = 0,
                    at: Date?          = nil) -> Double {
        let hourlyKey: String? = at.map {
            Self.hourlyKey(hour: Calendar.current.component(.hour, from: $0), isWeekend: Self.isWeekend($0))
        }
        if toMunich {
            if !usesFrozenBase {
                // Tageszeit+Wochentag-Offset erst ab 3 Messungen (braucht genug Stichproben
                // insgesamt — die einzelnen Stunden/Wochentag-Buckets selbst haben keine eigene
                // Mindestanzahl, siehe Kommentar bei applyAutoOffset).
                if let key = hourlyKey, autoMeasurementsMunich >= 3,
                   let hourly = hourlyOffsetsMunich[key] { return hourly }
                if let m = measuredOffsetToMunich, autoMeasurementsMunich >= 3 { return m }
            }
            if let c = communityMunich, communityMunichCount >= Self.minCommunitySamples { return c }
        } else {
            if !usesFrozenBase {
                if let key = hourlyKey, autoMeasurementsFreising >= 3,
                   let hourly = hourlyOffsetsFreising[key] { return hourly }
                if let m = measuredOffsetToFreising, autoMeasurementsFreising >= 3 { return m }
            }
            if let c = communityFreising, communityFreisingCount >= Self.minCommunitySamples { return c }
        }
        return toMunich ? offsetToMunich : offsetToFreising
    }

    /// Quelle des aktuell genutzten Offsets für Anzeige in der UI.
    enum OffsetSource { case local, community, estimate }
    func offsetSource(toMunich: Bool,
                      communityMunich:      Double? = nil,
                      communityMunichCount: Int     = 0,
                      communityFreising:      Double? = nil,
                      communityFreisingCount: Int     = 0) -> OffsetSource {
        if toMunich {
            if !usesFrozenBase && autoMeasurementsMunich >= 3 && measuredOffsetToMunich != nil { return .local }
            if communityMunich != nil && communityMunichCount >= Self.minCommunitySamples { return .community }
        } else {
            if !usesFrozenBase && autoMeasurementsFreising >= 3 && measuredOffsetToFreising != nil { return .local }
            if communityFreising != nil && communityFreisingCount >= Self.minCommunitySamples { return .community }
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
    // {uebergang} → "Oberschleißheimer Schranke" (gesprochener Name, siehe spokenCrossingName)
    // {status}    → "Schranke schließt bald" / "Schranke geschlossen" etc.
    // {linie}     → "S1"
    // {richtung}  → "München"
    // {zeit}      → "in 2 Minuten" / "in 45 Sekunden"
    var announcementTemplate: String

    static let defaultTemplate = "{uebergang}. {status}. {linie} Richtung {richtung} {zeit}."

    /// Gesprochener Name für Sprachansagen — dieselbe Benennung wie in den Siri-Kurzbefehlen
    /// (SiriIntents.swift), damit die Ansage konsistent klingt ("Oberschleißheimer Schranke"
    /// statt des kurzen UI-Namens "Dachauer Str.").
    var spokenCrossingName: String {
        switch id {
        case "osh_dachauer":                return "Oberschleißheimer Schranke"
        case "feldmoching_lerchenauer1":      return "erste Feldmochinger Schranke"
        case "feldmoching_lerchenauer2":      return "zweite Feldmochinger Schranke"
        case "feldmoching_feldmochinger":    return "Fasanerier Schranke"
        default:                             return "\(subtitle) Schranke"
        }
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    
    
    
    // MARK: - Alle bekannten Bahnübergänge

    static let all: [CrossingLocation] = [

        CrossingLocation(
            id: "osh_dachauer",
            name: "Dachauer Str.",
            subtitle: "Oberschleißheim",
            // War fälschlich "8004158" (falsche Station) — per DB-API-Stationssuche verifiziert:
            // die echte EVA für Oberschleißheim ist 8004580. Der Zahlendreher hatte zur Folge,
            // dass die App die ganze Zeit Fahrplandaten einer anderen Station abgefragt hat
            // (deshalb tauchte dort z.B. nie eine S1 auf, obwohl geOps sie live bestätigte).
            stationEVA: "8004580",
            mvgGlobalId: "de:09184:2000",
            regionalStationEVA: "8006688",
            regionalOffsetToMunich: 240,
            regionalOffsetToFreising: -240,
            // Vor-Ort per GPS nachgemessen (48°15'02.8"N 11°33'13.5"E) — alte Koordinate hatte
            // beim Längengrad ca. 337m Fehler, dadurch kam nie eine Trajektorie <200m heran.
            latitude: 48.250778,
            longitude: 11.553750,
            offsetToMunich: 180,
            offsetToFreising: -180,
            onlyS1: true,
            voiceEnabled: true,
            radiusMeters: 500,
            announcementTemplate: CrossingLocation.defaultTemplate
        ),

        CrossingLocation(
            id: "feldmoching_lerchenauer1",
            name: "Lerchenauer Str. (1)",
            subtitle: "Feldmoching",
            // War fälschlich "8004159" — per DB-API-Stationssuche verifiziert: die echte EVA
            // für München-Feldmoching ist 8004147.
            stationEVA: "8004147",
            mvgGlobalId: "de:09162:320",
            mvgSupportsRegionalTrains: true,
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
            id: "feldmoching_lerchenauer2",
            name: "Lerchenauer Str. (2)",
            subtitle: "Feldmoching",
            // War fälschlich "8004159" — per DB-API-Stationssuche verifiziert: die echte EVA
            // für München-Feldmoching ist 8004147.
            stationEVA: "8004147",
            mvgGlobalId: "de:09162:320",
            mvgSupportsRegionalTrains: true,
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
            // War fälschlich "8004159" — per DB-API-Stationssuche verifiziert: die echte EVA
            // für München-Feldmoching ist 8004147.
            stationEVA: "8004147",
            mvgGlobalId: "de:09162:320",
            mvgSupportsRegionalTrains: true,
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

        // Einmaliger Reset: alle stationEVA-Codes wurden korrigiert (waren fälschlich mit
        // einer komplett anderen Station verknüpft). Jede zuvor GELERNTE Offset-Kalibrierung
        // (Kalman-Filter, Tageszeit-Werte) basiert also auf Abfahrtszeiten der FALSCHEN
        // Station und ist jetzt verzerrt/wertlos — sie würde sonst weiter bevorzugt vor dem
        // (korrekten) Standardwert genutzt und die Vorhersage systematisch verschieben.
        if !UserDefaults.standard.bool(forKey: "calibrationResetAfterEVAFix_v1") {
            for idx in crossings.indices {
                crossings[idx].measuredOffsetToMunich   = nil
                crossings[idx].measuredOffsetToFreising = nil
                crossings[idx].autoMeasurementsMunich   = 0
                crossings[idx].autoMeasurementsFreising = 0
                crossings[idx].kalmanVarianceMunich     = 100.0
                crossings[idx].kalmanVarianceFreising   = 100.0
                crossings[idx].hourlyOffsetsMunich      = [:]
                crossings[idx].hourlyOffsetsFreising    = [:]
            }
            UserDefaults.standard.set(true, forKey: "calibrationResetAfterEVAFix_v1")
            saveSettings()
        }
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
