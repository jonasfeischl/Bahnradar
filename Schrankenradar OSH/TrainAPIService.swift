import Foundation

// MARK: - Zugangsdaten DB Timetables

private let dbClientId = "bb2d56302fc6faac8ac204a28a58beda"
private let dbApiKey   = "e77347cdd2f22d6f600a4df38271f4af"
private let dbBase     = "https://apis.deutschebahn.com/db-api-marketplace/apis/timetables/v1"

// MARK: - TrainAPIService

struct TrainAPIService {

    /// Holt Abfahrten für den gewählten Bahnübergang.
    ///
    /// Quellen und Rollenverteilung (siehe Begründung bei `merge`):
    ///   1. DB Timetables API       → Fahrplan-Basis (90-Minuten-Fenster): welche Züge es gibt,
    ///      Linie, Ausfälle. DB-Zeiten sind strukturell nur MINUTENGENAU (kein Sekundenfeld in
    ///      der API), daher als alleinige Quelle für die 10s-genaue Anzeige ungeeignet.
    ///   2. DB Realtime Changes API → offizielle (minutengenaue) Verspätung — Fallback-Zeit,
    ///      solange kein Zug noch keine Live-GPS-Position hat (z.B. weit vor Abfahrt).
    ///   3. Geops-Trajektorie (GPS-Position × Zeit, `GeopsRealtimeService.liveCrossingEstimate`)
    ///      → sekundengenaue PRIMÄRE Zeitquelle sobald verfügbar (CrossingViewModel.buildEvents
    ///      übernimmt sie direkt, siehe dort). Hier in `merge()` wird nur die TripId + Richtung
    ///      übernommen; die eigentliche Zeitberechnung passiert erst in buildEvents, weil dort
    ///      auch Smoothing/Anti-Flacker-Logik greift. Zusätzlich liefert Geops (a) echte
    ///      Durchfahrten ohne DB-Halt (Güterzüge/durchfahrende RE/RB — separater Mechanismus in
    ///      CrossingViewModel).
    func fetchDepartures(crossing: CrossingLocation) async throws -> [TrainEntry] {
        let dbEntries = try await fetchDBEntries(crossing: crossing)
        return mergeWithCurrentGeops(dbEntries: dbEntries, crossing: crossing)
    }

    /// Nur die DB-Fahrplan-Basis laden (Netz-Call). Ergebnis kann gecacht und mit
    /// `mergeWithCurrentGeops` mehrfach (ohne erneuten Netz-Call) mit frischen
    /// Geops-Echtzeitdaten kombiniert werden.
    func fetchDBEntries(crossing: CrossingLocation) async throws -> [TrainEntry] {
        let now   = Date()
        let plus1 = now.addingTimeInterval(3600)
        let plus2 = now.addingTimeInterval(5400)  // +90 Min

        // 1 + 2: DB-Daten parallel laden (aktuelle Stunde + nächste Stunde + übernächste)
        async let batch1  = fetchPlan(for: now,   eva: crossing.stationEVA)
        async let batch2  = fetchPlan(for: plus1, eva: crossing.stationEVA)
        async let batch3  = fetchPlan(for: plus2, eva: crossing.stationEVA)
        async let changes = fetchChanges(eva: crossing.stationEVA)
        // MVG (bevorzugte Verspätungsquelle, siehe MVGService.swift) — wirft nie, da intern
        // gefangen, damit ein MVG-Ausfall den DB-Fetch nicht blockiert.
        async let mvg     = fetchMVGDepartures(globalId: crossing.mvgGlobalId,
                                                includeRegionalTrains: crossing.mvgSupportsRegionalTrains)

        let (stops1, stops2, stops3, changeMap, mvgDepartures) = try await (batch1, batch2, batch3, changes, mvg)

        var seenDB = Set<String>()
        let allStops = (stops1 + stops2 + stops3).filter { seenDB.insert($0.id).inserted }

        // DB-Entries mit Change-Daten anreichern. Die Geops-bestätigten-Linien-Prüfung
        // passiert INNERHALB von TrainEntry.init — und dort NUR für S-Bahn-Einträge (grenzt
        // z.B. S1 gegen andere S-Bahn-Linien ein). Andere Zugarten (RE/IC/…) sind davon nicht
        // betroffen, da sie real über diese Übergänge fahren können, auch wenn geOps für sie
        // noch keine eigene "Bestätigung" gesammelt hat.
        var dbEntries: [TrainEntry] = allStops.compactMap { stop -> TrainEntry? in
            var enriched = stop
            let hasChange = changeMap[stop.id] != nil
            if let change = changeMap[stop.id] { enriched.applyChange(change) }
            let entry = TrainEntry(from: enriched, onlyS1: crossing.onlyS1, confirmedLines: crossing.confirmedLines)
            if let entry, entry.lineName == "S1" {
                DebugLog.shared.add(
                    "[DB] S1 id=\(stop.id) sched=\(entry.scheduledTime.HHmmss) actual=\(entry.actualTime.HHmmss) " +
                    "delay=\(entry.delayMinutes)min dir=\(entry.direction) hasChange=\(hasChange) " +
                    "path=\(stop.dp?.path?.prefix(40) ?? "")"
                )
            }
            return entry
        }

        // MVG-Überlagerung: MVG (dieselbe Datenquelle wie die offizielle MVGO/MVV-App) laut
        // Live-Vergleich (User, 2026-07-19) zuverlässiger als DBs Realtime-Changes-API, die
        // wiederholt Verspätungen fälschlich auf 0 zurückgesetzt oder gar nicht gemeldet hat
        // (siehe CrossingViewModel.stabilizeDelays-Kommentar). Wird bevorzugt übernommen — DBs
        // eigene, oben schon aus changeMap berechnete Verspätung bleibt Fallback, falls MVG für
        // einen Zug keinen Treffer oder keinen Live-Wert liefert.
        if !mvgDepartures.isEmpty {
            dbEntries = dbEntries.map { entry in
                guard let match = bestMVGMatch(for: entry, in: mvgDepartures), match.isRealtime else {
                    return entry
                }
                let updated = entry.with(actualTime: match.realtimeTime)
                // S1 + Regionalzüge (RB/RE) loggen — Rest (Bus etc. kommt hier ohnehin nie an)
                // bewusst außen vor, um das Log nicht mit jeder anderen S-Bahn-Linie zuzumüllen.
                if entry.lineName == "S1" || entry.lineName.hasPrefix("RB") || entry.lineName.hasPrefix("RE") {
                    DebugLog.shared.add(
                        "[MVG] \(entry.lineName) id=\(entry.id) sched=\(entry.scheduledTime.HHmmss) " +
                        "dbDelay=\(entry.delayMinutes)min → mvgDelay=\(match.delayMinutes)min " +
                        "dest=\(match.destination)"
                    )
                }
                return updated
            }
        }

        let beforeWindowFilter = dbEntries.count
        // 90-Min-Filter anwenden
        dbEntries = dbEntries.filter { $0.actualTime <= now.addingTimeInterval(5400) }

        DebugLog.shared.add(
            "DB-Fenster \(crossing.name): Stunden-Blöcke roh=\(stops1.count)/\(stops2.count)/\(stops3.count) " +
            "(Std. \(now.HH)/\(plus1.HH)/\(plus2.HH)), vor 90min-Filter=\(beforeWindowFilter), " +
            "nach 90min-Filter=\(dbEntries.count) (bestätigte S-Bahn-Linien: \(crossing.confirmedLines?.joined(separator: ",") ?? "alle"))"
        )
        return dbEntries
    }

    /// Zweite, unabhängige DB-Fahrplan-Abfrage für Übergänge, deren eigene stationEVA
    /// strukturell nie RE/RB führt (siehe CrossingLocation.regionalStationEVA-Kommentar) — fragt
    /// stattdessen die nächste Station ab, an der diese Züge TATSÄCHLICH halten, und behält nur
    /// die Nicht-S-Bahn-Einträge (S-Bahn kommt bereits über fetchDBEntries/stationEVA, sonst
    /// gäbe es Dubletten mit ggf. abweichender Zeitbasis). Der Aufrufer (CrossingViewModel)
    /// wendet crossing.regionalOffsetToMunich/-Freising an statt der normalen Offsets.
    func fetchRegionalDBEntries(crossing: CrossingLocation) async throws -> [TrainEntry] {
        guard let regionalEVA = crossing.regionalStationEVA else { return [] }
        let now   = Date()
        let plus1 = now.addingTimeInterval(3600)
        let plus2 = now.addingTimeInterval(5400)

        async let batch1  = fetchPlan(for: now,   eva: regionalEVA)
        async let batch2  = fetchPlan(for: plus1, eva: regionalEVA)
        async let batch3  = fetchPlan(for: plus2, eva: regionalEVA)
        async let changes = fetchChanges(eva: regionalEVA)

        let (stops1, stops2, stops3, changeMap) = try await (batch1, batch2, batch3, changes)

        var seenDB = Set<String>()
        let allStops = (stops1 + stops2 + stops3).filter { seenDB.insert($0.id).inserted }

        var entries: [TrainEntry] = allStops.compactMap { stop -> TrainEntry? in
            var enriched = stop
            if let change = changeMap[stop.id] { enriched.applyChange(change) }
            guard let entry = TrainEntry(from: enriched, onlyS1: false, confirmedLines: nil),
                  !entry.lineName.hasPrefix("S") else { return nil }
            return entry
        }
        entries = entries.filter { $0.actualTime <= now.addingTimeInterval(5400) }

        DebugLog.shared.add("[Regional] \(crossing.name): \(entries.count) RE/RB-Einträge von EVA \(regionalEVA)")
        return entries
    }

    /// Nur für den Admin-Vergleichs-Tab (API-Vergleich): identischer DB-Fetch/Parse wie
    /// `fetchDBEntries` oben, aber bewusst OHNE die MVG-Überlagerung — sonst wäre "DB" im
    /// Vergleich nicht mehr DBs eigene Meinung, sondern hätte MVGs Verspätung schon eingemischt,
    /// was den Vergleich sinnlos machen würde. Eigenständige Funktion statt Umbau von
    /// `fetchDBEntries`, damit die dort produktiv genutzte, fein abgestimmte Funktion und ihre
    /// Nebenläufigkeit (MVG parallel zu den DB-Batches) unangetastet bleiben.
    func fetchDBEntriesRaw(crossing: CrossingLocation) async throws -> [TrainEntry] {
        let now   = Date()
        let plus1 = now.addingTimeInterval(3600)
        let plus2 = now.addingTimeInterval(5400)  // +90 Min

        async let batch1  = fetchPlan(for: now,   eva: crossing.stationEVA)
        async let batch2  = fetchPlan(for: plus1, eva: crossing.stationEVA)
        async let batch3  = fetchPlan(for: plus2, eva: crossing.stationEVA)
        async let changes = fetchChanges(eva: crossing.stationEVA)

        let (stops1, stops2, stops3, changeMap) = try await (batch1, batch2, batch3, changes)

        var seenDB = Set<String>()
        let allStops = (stops1 + stops2 + stops3).filter { seenDB.insert($0.id).inserted }

        var dbEntries: [TrainEntry] = allStops.compactMap { stop -> TrainEntry? in
            var enriched = stop
            if let change = changeMap[stop.id] { enriched.applyChange(change) }
            return TrainEntry(from: enriched, onlyS1: crossing.onlyS1, confirmedLines: crossing.confirmedLines)
        }
        dbEntries = dbEntries.filter { $0.actualTime <= now.addingTimeInterval(5400) }

        DebugLog.shared.add("[DB-Vergleich] \(crossing.name): \(dbEntries.count) Rohe DB-Einträge (ohne MVG)")
        return dbEntries
    }

    /// Nur für den Admin-Vergleichs-Tab: lädt MVG-Abfahrten direkt, ohne DB-Zuordnung/Overlay.
    /// Ruft dieselbe private `fetchMVGDepartures(globalId:includeRegionalTrains:)` wie die
    /// MVG-Überlagerung oben auf — übernimmt dadurch automatisch dieselbe SBAHN/BAHN-Aufteilung
    /// + das `mvgSupportsRegionalTrains`-Gating. WICHTIG das so zu belassen: ohne dieses Gating
    /// drohte am 2026-07-22 bereits einmal ein MVG-Rate-Limit (HTTP 509), siehe Kommentar bei
    /// `fetchMVGDepartures` unten.
    func fetchMVGEntriesRaw(crossing: CrossingLocation) async -> [MVGService.Departure] {
        await fetchMVGDepartures(globalId: crossing.mvgGlobalId, includeRegionalTrains: crossing.mvgSupportsRegionalTrains)
    }

    /// Nur für den Admin-Vergleichs-Tab (Kombiniert-Seite): baut aus den vom Nutzer ausgewählten
    /// Quellen eine ABGEGLICHENE, deduplizierte Liste — genau dieselbe Zuordnungslogik wie die
    /// Produktions-Pipeline (MVG-Überlagerung + Geops-`merge`/`deduplicate`), nur parametrisiert
    /// nach Quellen-Auswahl statt immer alle drei zu verwenden. DB dient dabei zwingend als Anker
    /// (wie überall sonst in dieser Datei — `bestGeopsMatch`/`bestMVGMatch` matchen beide auf
    /// einen `TrainEntry`); ohne DB gibt es dafür keine bestehende Zuordnungslogik, dieser Fall
    /// wird vom Aufrufer separat behandelt (APIComparisonViewModel fällt dann auf eine einfache,
    /// unabgeglichene Konkatenation zurück statt diese Funktion aufzurufen).
    func combineForComparison(dbEntries: [TrainEntry],
                               geopsStops: [GeopsStopDeparture]?,
                               geopsVehicles: [String: GeopsVehicle],
                               mvgDepartures: [MVGService.Departure]?) -> [TrainEntry] {
        var entries = dbEntries

        if let mvgDepartures, !mvgDepartures.isEmpty {
            entries = entries.map { entry in
                guard let match = bestMVGMatch(for: entry, in: mvgDepartures), match.isRealtime else {
                    return entry
                }
                return entry.with(actualTime: match.realtimeTime)
            }
        }

        if let geopsStops {
            entries = merge(dbEntries: entries, geopsStops: geopsStops, geopsVehicles: geopsVehicles)
        } else {
            entries = deduplicate(entries)
        }

        return entries.sorted { $0.actualTime < $1.actualTime }
    }

    /// Gecachte DB-Entries mit dem AKTUELLEN Geops-Stand mergen (KEIN Netz-Call).
    /// Dadurch erscheinen neue Geops-Züge sofort, ohne erneuten DB-Fetch.
    @MainActor
    func mergeWithCurrentGeops(dbEntries: [TrainEntry],
                               crossing: CrossingLocation) -> [TrainEntry] {
        let geopsStops    = GeopsRealtimeService.shared.departures(forEva: crossing.stationEVA)
        let geopsVehicles = GeopsRealtimeService.shared.vehicles

        let entries = merge(
            dbEntries: dbEntries,
            geopsStops: geopsStops,
            geopsVehicles: geopsVehicles
        )
        return entries.sorted { $0.actualTime < $1.actualTime }
    }

    // MARK: - Merge-Logik

    /// DB liefert hier die Basis-Zeit (inkl. offizieller Verspätung aus der Realtime-Changes-
    /// API) — als Fallback, solange kein Zug keine Live-GPS-Position hat. Diese Funktion hängt
    /// bewusst NUR die TripId + Richtung an, OHNE Geops' eigenes stopsequence-`departureDelay`-
    /// Feld zu übernehmen: dieses Feld war für einzelne Trips wiederholt unzuverlässig — mal
    /// "Trip-Drift" (Zug fälschlich mit falscher Fahrplan-Instanz verknüpft, dadurch absurde
    /// ±Werte), mal dauerhaft bei 0s hängend obwohl der Zug laut MVV/DB tatsächlich Verspätung
    /// hat (vermutlich weil bei gekuppelten Zugteilen nur eine der beiden Trip-IDs echte
    /// Live-GPS-Anbindung hat).
    ///
    /// WICHTIG: das ist NICHT dasselbe wie die GPS-Trajektorie (Live-Position × Zeit,
    /// `liveCrossingEstimate` in GeopsRealtimeService) — die ist von diesem Trip-Drift-Problem
    /// nicht betroffen (sie interpoliert die tatsächliche Fahrzeugposition, kein separat
    /// gemeldetes Verspätungsfeld) und wird in CrossingViewModel.buildEvents als primäre,
    /// sekundengenaue Zeitquelle verwendet, sobald sie verfügbar ist. Hier wird nur die TripId
    /// durchgereicht, damit buildEvents sie nachschlagen kann.
    ///   • Fahrtrichtung: Live-GPS-Bewegungsrichtung ist zuverlässiger als der DB-Pfadtext.
    ///   • "Live-GPS bestätigt"-Badge: rein informativ, ändert nie die angezeigte Zeit.
    ///   • Echte Durchfahrten ohne DB-Halt (Güterzüge, durchfahrende RE/RB) — das läuft über
    ///     einen komplett separaten Mechanismus (detectNonSBahnApproach/freightApproaches in
    ///     GeopsRealtimeService + CrossingViewModel), nicht über diese Merge-Funktion.
    // `fileprivate` statt `private` (nicht `internal`!) — bleibt datei-scoped, reine
    // Compile-Zeit-Sichtbarkeit ohne Verhaltensänderung, ermöglicht aber Wiederverwendung durch
    // `combineForComparison` (Admin-Vergleichs-Tab, siehe unten) statt die fein abgestimmte
    // Matching-Logik dort zu duplizieren.
    fileprivate func merge(dbEntries: [TrainEntry],
                       geopsStops: [GeopsStopDeparture],
                       geopsVehicles: [String: GeopsVehicle]) -> [TrainEntry] {

        let result: [TrainEntry] = dbEntries.map { dbEntry in
            var entry = dbEntry
            guard let geopsStop = bestGeopsMatch(for: dbEntry, in: geopsStops, vehicles: geopsVehicles) else { return entry }

            // Nur TripId merken (für das Live-GPS-Badge) — NICHT die Zeit übernehmen.
            entry = entry.withGeopsId(geopsStop.tripId)
            if let geopsDirection = geopsVehicles[geopsStop.tripId]?.computedDirection()
                                  ?? geopsStop.inferredDirection,
               geopsDirection != entry.direction {
                if entry.lineName == "S1" {
                    DebugLog.shared.add(
                        "[MERGE] S1 id=\(dbEntry.id) sched=\(dbEntry.scheduledTime.HHmmss) Richtung " +
                        "\(entry.direction)→\(geopsDirection) via Geops-Trip \(geopsStop.tripId) " +
                        "(hint=\(dbEntry.finalDestinationHint ?? "nil"))",
                        level: .warn
                    )
                }
                entry = entry.withDirection(geopsDirection)
            }
            return entry
        }

        return deduplicate(result)
    }

    /// Entfernt doppelte Züge: DB listet gekuppelte Zugteile (Doppeltraktion) manchmal als
    /// zwei separate Fahrplan-Einträge mit unterschiedlicher Zugnummer, aber identischer
    /// (oder fast identischer) Abfahrtszeit — für die Schranken-Anzeige ist das ein Zug.
    /// Zwei Einträge gelten als Duplikat wenn gleiche Richtung + Abfahrtszeit < 150s
    /// auseinander (gleiche Linie) bzw. < 30s (nur gleiche Zugart, z.B. beide "RB").
    /// Führender Buchstaben-Teil eines Linien-Namens, z.B. "RB" aus "RB57170", "S" aus "S1".
    private func linePrefix(_ lineName: String) -> String {
        String(lineName.prefix(while: { $0.isLetter }))
    }

    fileprivate func deduplicate(_ entries: [TrainEntry]) -> [TrainEntry] {
        let sorted = entries.sorted { $0.actualTime < $1.actualTime }
        var kept: [TrainEntry] = []

        for entry in sorted {
            if let idx = kept.firstIndex(where: {
                guard $0.direction == entry.direction else { return false }
                if $0.lineName == entry.lineName {
                    return abs($0.actualTime.timeIntervalSince(entry.actualTime)) < 150
                }
                // Gekuppelte Zugteile: gleiche Zugart (RB/RE/…), exakt identische Zeit —
                // enger toleriert als der Namens-Match oben, da hier NUR der Zufall einer
                // wirklich identischen Abfahrtszeit als Signal dient.
                return linePrefix($0.lineName) == linePrefix(entry.lineName) &&
                       abs($0.actualTime.timeIntervalSince(entry.actualTime)) < 30
            }) {
                // Duplikat gefunden: den mit Geops-Bestätigung behalten (etwas vertrauenswürdiger,
                // da zusätzlich per Live-GPS verifiziert), sonst den bestehenden.
                let existing = kept[idx]
                let keepsNew = entry.geopsMatchedTripId != nil && existing.geopsMatchedTripId == nil
                if entry.lineName == "S1" {
                    let dropped = keepsNew ? existing : entry
                    let survivor = keepsNew ? entry : existing
                    DebugLog.shared.add(
                        "[DEDUP] S1 verworfen: id=\(dropped.id) sched=\(dropped.scheduledTime.HHmmss) " +
                        "dir=\(dropped.direction) ← behalten: id=\(survivor.id) sched=\(survivor.scheduledTime.HHmmss) " +
                        "dir=\(survivor.direction)"
                    )
                }
                var winner = keepsNew ? entry : existing
                // Unterschiedliche bekannte Fahrtziele (Freising vs. Flughafen München) hier
                // bewusst NICHT mehr als "zwei verschiedene Züge" behandeln — Live-Feldbeobachtung
                // (User, 2026-07-23, mehrfach bestätigt: "das ist bei allen") zeigt, dass an
                // unseren Übergängen (alle südlich von Neufahrn, wo sich S1 erst in die Äste
                // Freising/Flughafen aufteilt) tatsächlich EIN gekuppelter Zug durchfährt, nicht
                // zwei — MVVs Abfahrtstafel zeigt zwar zwei Zeilen (eine pro späterem Fahrtziel,
                // Standard-Praxis für gekuppelte Züge mit unterschiedlichem Ziel), das ist aber
                // eine Fahrgastinformation, kein Beleg für zwei physische Durchfahrten am
                // Übergang. Wenn beide gemergten Einträge ein bekanntes, ABWEICHENDES Ziel
                // hatten, wird der Hint deshalb bewusst auf nil zurückgesetzt (zeigt dann
                // "Freising/Flughafen" statt irreführend nur eines der beiden Ziele).
                if let a = existing.finalDestinationHint, let b = entry.finalDestinationHint, a != b {
                    winner = winner.withDestinationHint(nil)
                }
                kept[idx] = winner
            } else {
                kept.append(entry)
            }
        }
        return kept
    }

    /// Grobes Ziel aus einem Geops-`destination`-String — dieselbe Klassifikation wie
    /// `TrainEntry.finalDestinationHint`, nur aus der Geops- statt der DB-Quelle. Nötig, damit
    /// bestGeopsMatch() zwei gleichzeitig fahrende S1-Züge (Freising-Ast vs. Flughafen-Ast, die
    /// zufällig zur selben Minute fahren) nicht an denselben Geops-Trip bindet — ohne diese
    /// Prüfung matchte `.first(where:)` beide DB-Einträge auf denselben ersten Treffer, wodurch
    /// einer der beiden Züge die (falsche) Live-GPS-Position des anderen übernahm.
    private func geopsDestinationHint(_ destination: String) -> String? {
        let d = destination.lowercased().folding(options: [.diacriticInsensitive], locale: .current)
        if d.contains("flughafen") || d.contains("hallbergmoos") { return "flughafen" }
        if d.contains("freising") { return "freising" }
        return nil
    }

    // MARK: - MVG-Überlagerung (siehe MVGService.swift)

    /// Lädt MVG-Abfahrten für die Verspätungs-Überlagerung. Fängt Fehler intern (Netz-Aussetzer
    /// o.ä.) — ein MVG-Ausfall soll die App nicht beeinträchtigen, DBs eigene Verspätung bleibt
    /// dann einfach unverändert als Fallback.
    /// Zweite, separate Abfrage für BAHN/Regionalzüge NUR wenn `includeRegionalTrains` gesetzt
    /// ist (siehe CrossingLocation.mvgSupportsRegionalTrains) — ursprünglich wurde BAHN blind für
    /// JEDEN Übergang mitgefragt, auch dort wo MVG laut eigenen Stationsmetadaten strukturell nie
    /// Daten liefert (Oberschleißheim). Live beobachtet (2026-07-22): das hat die Anfragen dort
    /// verdoppelt und MVG hat daraufhin mit HTTP 509 (Rate-Limit) reagiert — kollateral auch für
    /// die eigentlich funktionierende SBAHN-Abfrage, wodurch der MVV-Status-Punkt grau/rot wurde.
    /// Getrennte statt kombinierter Abfrage weiterhin nötig, da MVGs API bei kombinierter Query
    /// (Komma oder wiederholter Parameter, beides per curl getestet) nachweislich nur den ersten
    /// Typ zurückliefert.
    private func fetchMVGDepartures(globalId: String?, includeRegionalTrains: Bool) async -> [MVGService.Departure] {
        guard let globalId else { return [] }
        guard includeRegionalTrains else {
            return await fetchMVGDepartures(globalId: globalId, transportTypes: "SBAHN")
        }
        async let sbahn = fetchMVGDepartures(globalId: globalId, transportTypes: "SBAHN")
        async let bahn  = fetchMVGDepartures(globalId: globalId, transportTypes: "BAHN")
        return await sbahn + bahn
    }

    private func fetchMVGDepartures(globalId: String, transportTypes: String) async -> [MVGService.Departure] {
        do {
            return try await MVGService.shared.fetchDepartures(globalId: globalId, transportTypes: transportTypes)
        } catch {
            DebugLog.shared.add("[MVG] Fehler beim Laden (\(transportTypes)): \(error)", level: .warn)
            return []
        }
    }

    /// Dieselbe Ziel-Klassifikation wie geopsDestinationHint, nur aus der MVG-`destination`.
    private func mvgDestinationHint(_ destination: String) -> String? {
        let d = destination.lowercased().folding(options: [.diacriticInsensitive], locale: .current)
        if d.contains("flughafen") || d.contains("hallbergmoos") { return "flughafen" }
        if d.contains("freising") { return "freising" }
        return nil
    }

    /// Sucht die beste MVG-Abfahrt für einen DB-TrainEntry — gleiche Linie, enge Zeitnähe,
    /// widerspricht nicht dem bekannten Fahrtziel (falls vorhanden). Analog zu bestGeopsMatch.
    fileprivate func bestMVGMatch(for entry: TrainEntry,
                               in departures: [MVGService.Departure]) -> MVGService.Departure? {
        let tol: TimeInterval = 90
        func hintConflicts(_ dep: MVGService.Departure) -> Bool {
            guard let entryHint = entry.finalDestinationHint,
                  let depHint = mvgDestinationHint(dep.destination) else { return false }
            return entryHint != depHint
        }
        // MVG schreibt Regionalzug-Labels MIT Leerzeichen ("RB 33"), unser DB-lineName baut sie
        // OHNE ("RB33") — ohne Normalisierung hätte ein strikter ==-Vergleich hier IMMER
        // verfehlt, RB/RE hätten also nie einen MVG-Treffer bekommen können. S-Bahn-Labels
        // ("S1") haben ohnehin kein Leerzeichen, die Normalisierung ist für sie ein No-op.
        func normalized(_ s: String) -> String { s.replacingOccurrences(of: " ", with: "") }
        return departures.first(where: {
            normalized($0.label) == entry.lineName && !hintConflicts($0) &&
            abs($0.scheduledTime.timeIntervalSince(entry.scheduledTime)) < tol
        })
    }

    /// Sucht den besten Geops-stopDeparture für einen DB-TrainEntry.
    /// Priorität: gleiche Linie + enge Zeitübereinstimmung > nur Zeit, jeweils zuerst nur unter
    /// richtungskonformen Kandidaten, erst danach auch richtungswidersprüchliche (siehe unten).
    private func bestGeopsMatch(for entry: TrainEntry,
                                 in stops: [GeopsStopDeparture],
                                 vehicles: [String: GeopsVehicle]) -> GeopsStopDeparture? {
        let tightTol: TimeInterval = 60    // 1 Minute (gleiche Linie)
        let wideTol:  TimeInterval = 120   // 2 Minuten (Fallback)

        // Bekanntes, abweichendes Ziel schließt den Kandidaten aus (siehe geopsDestinationHint).
        // Bei unbekanntem Ziel auf einer der beiden Seiten bleibt das Verhalten unverändert.
        func hintConflicts(_ stop: GeopsStopDeparture) -> Bool {
            guard let entryHint = entry.finalDestinationHint,
                  let stopHint = geopsDestinationHint(stop.destination) else { return false }
            return entryHint != stopHint
        }

        // Die Richtung, die `merge()` diesem Zug am Ende zuweisen würde, wenn dieser Kandidat
        // gewählt wird. Ohne diese Prüfung konnte ein S1-Zug ohne finalDestinationHint (z.B. weil
        // der DB-Pfadtext nur bis Neufahrn reicht, siehe detectDirection — "neufahrn"/"eching"/
        // "lohhof" lösen zwar schon Richtung .toFreising aus, OHNE aber den Hint "freising" zu
        // setzen) rein per Zeitzufall an eine München-Abfahrt gebunden werden. `merge()` hat dann
        // die Richtung stillschweigend auf toMunich gedreht, wodurch `deduplicate()` ihn später
        // als Duplikat der echten München-Abfahrt verworfen hat — der Zug verschwand komplett aus
        // der Liste (beobachtet: ein 17:05-Freising-Zug fehlte ersatzlos, Live-Log 2026-07-19).
        func directionMismatch(_ stop: GeopsStopDeparture) -> Bool {
            guard let geopsDirection = vehicles[stop.tripId]?.computedDirection() ?? stop.inferredDirection else { return false }
            return geopsDirection != entry.direction
        }

        // 1+2: zuerst NUR richtungskonforme (oder richtungslose) Kandidaten versuchen.
        if let exact = stops.first(where: {
            $0.lineName == entry.lineName && !hintConflicts($0) && !directionMismatch($0) &&
            abs($0.plannedDeparture.timeIntervalSince(entry.scheduledTime)) < tightTol
        }) { return exact }
        if let wide = stops.first(where: {
            $0.lineName == entry.lineName && !hintConflicts($0) && !directionMismatch($0) &&
            abs($0.plannedDeparture.timeIntervalSince(entry.scheduledTime)) < wideTol
        }) { return wide }

        // 3+4: Fallback AUCH mit widersprüchlicher Richtung — damit Geops weiterhin eine
        // tatsächlich falsche DB-Richtungserkennung korrigieren kann (Kommentar oben bei merge():
        // "Live-GPS-Bewegungsrichtung ist zuverlässiger als der DB-Pfadtext"), aber nur wenn es
        // KEINEN richtungskonformen Kandidaten gibt.
        // WICHTIG: Es gab hier früher einen dritten Fallback-Schritt, der rein nach Zeitnähe
        // gematcht hat (ohne Linien-Check) — als "Fallback wenn Linie unbekannt" gedacht.
        // Seit lineName aber für JEDEN DB-Eintrag zuverlässig bestimmt wird (S1/S2/…/RE…/RB…),
        // gab es diesen Fall nicht mehr, und der Fallback hat stattdessen munter S1-Ankünfte
        // von geOps an zeitlich zufällig nahe RE/RB-Einträge "verschenkt" — die S1-Zeit landete
        // dann in einem RE/RB-Eintrag, und die S1 verschwand komplett aus der Liste (statt als
        // synthetischer Eintrag zu erscheinen). Deshalb entfernt: ohne Linien-Übereinstimmung
        // gibt es kein Match mehr.
        if let exact = stops.first(where: {
            $0.lineName == entry.lineName && !hintConflicts($0) &&
            abs($0.plannedDeparture.timeIntervalSince(entry.scheduledTime)) < tightTol
        }) { return exact }

        return stops.first(where: {
            $0.lineName == entry.lineName && !hintConflicts($0) &&
            abs($0.plannedDeparture.timeIntervalSince(entry.scheduledTime)) < wideTol
        })
    }

    // MARK: - DB API

    private func fetchPlan(for date: Date, eva: String) async throws -> [TimetableStop] {
        let url = URL(string: "\(dbBase)/plan/\(eva)/\(date.yyMMdd)/\(date.HH)")!
        let data = try await dbRequest(url)
        return TimetableXMLParser.parse(data: data)
    }

    private func fetchChanges(eva: String) async throws -> [String: ChangeInfo] {
        let url = URL(string: "\(dbBase)/rchg/\(eva)")!
        let data = try await dbRequest(url)
        return ChangesXMLParser.parse(data: data)
    }

    // MARK: - HTTP

    private func dbRequest(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        // WICHTIG: ohne explizite cachePolicy nutzt URLSession.shared den systemweiten
        // URLCache — wenn DB's API-Gateway Cache-Control/Expires-Header sendet, liefert
        // URLSession bei wiederholten Abfragen derselben URL (z.B. /rchg/{eva} alle 10-20s)
        // sonst stillschweigend eine VERALTETE gecachte Antwort statt neu zu laden. Das sah
        // aus wie "DB-API meldet Verspätung nicht" — war aber ein Client-seitiger Stale-Cache,
        // nicht die DB-API selbst. Erzwingt bei jedem Aufruf eine echte Netzwerk-Anfrage.
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue(dbClientId, forHTTPHeaderField: "DB-Client-Id")
        request.setValue(dbApiKey,   forHTTPHeaderField: "DB-Api-Key")
        request.setValue("application/xml", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                DebugLog.shared.add("[DB] HTTP \(code) für \(url.path)", level: .error)
                throw APIError.httpError(code)
            }
            return data
        } catch let error as APIError {
            throw error
        } catch {
            DebugLog.shared.add("[DB] Netzwerkfehler für \(url.path): \(error.localizedDescription)", level: .error)
            throw error
        }
    }
}

// MARK: - XML: Plan Parser

final class TimetableXMLParser: NSObject, XMLParserDelegate {
    private var stops: [TimetableStop] = []
    private var current: TimetableStop?

    static func parse(data: Data) -> [TimetableStop] {
        let h = TimetableXMLParser()
        let p = XMLParser(data: data)
        p.delegate = h
        p.parse()
        return h.stops
    }

    func parser(_ parser: XMLParser, didStartElement el: String,
                namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
        switch el {
        case "s":  current = TimetableStop(id: a["id"] ?? UUID().uuidString)
        case "dp": current?.dp = DeparturePoint(pt: a["pt"], line: a["l"], path: a["ppth"])
        case "ar": current?.ar = DeparturePoint(pt: a["pt"], line: a["l"], path: a["ppth"])
        case "tl": current?.category = a["c"]; current?.trainNumber = a["n"]
        default:   break
        }
    }

    func parser(_ parser: XMLParser, didEndElement el: String,
                namespaceURI: String?, qualifiedName: String?) {
        if el == "s", let s = current { stops.append(s); current = nil }
    }
}

// MARK: - XML: Changes Parser

final class ChangesXMLParser: NSObject, XMLParserDelegate {
    private var changes: [String: ChangeInfo] = [:]
    private var currentId: String?

    static func parse(data: Data) -> [String: ChangeInfo] {
        let h = ChangesXMLParser()
        let p = XMLParser(data: data)
        p.delegate = h
        p.parse()
        return h.changes
    }

    func parser(_ parser: XMLParser, didStartElement el: String,
                namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
        switch el {
        case "s":
            currentId = a["id"]
        case "dp" where currentId != nil:
            changes[currentId!] = ChangeInfo(
                changedTime: a["ct"],
                changedPlatform: a["cp"],
                cancelled: a["cs"] == "c"
            )
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement el: String,
                namespaceURI: String?, qualifiedName: String?) {
        if el == "s" { currentId = nil }
    }
}

// MARK: - Models

struct TimetableStop {
    var id: String
    var dp: DeparturePoint?
    var ar: DeparturePoint?
    var category: String?
    var trainNumber: String?
    var actualDepartureTime: Date?
    var isCancelled: Bool = false
    var changedPlatform: String?

    mutating func applyChange(_ change: ChangeInfo) {
        isCancelled = change.cancelled
        changedPlatform = change.changedPlatform
        if let ct = change.changedTime {
            actualDepartureTime = DateFormatter.dbTime.date(from: ct)
        }
    }
}

struct DeparturePoint {
    let pt: String?
    let line: String?
    let path: String?
}

struct ChangeInfo {
    let changedTime: String?
    let changedPlatform: String?
    let cancelled: Bool
}

// MARK: - TrainEntry

struct TrainEntry: Identifiable, Codable {
    let id: String
    let lineName: String
    let direction: TrainDirection
    let scheduledTime: Date
    let actualTime: Date
    let delayMinutes: Int
    let isCancelled: Bool
    let platform: String?
    let stopsAtStation: Bool
    /// Geops tripId wenn dieser Eintrag mit einem Geops-Stop gematcht wurde
    let geopsMatchedTripId: String?
    /// Grobes Fahrtziel ("freising"/"flughafen"), wenn aus dem DB-Pfadtext erkennbar — nil wenn
    /// unbekannt. Dient NUR der Dedup-Unterscheidung (siehe deduplicate()): S1 teilt sich hinter
    /// Neufahrn in zwei Äste (Freising / Flughafen über Hallbergmoos), die beide über dieselben
    /// Übergänge südlich davon fahren — zwei verschiedene Züge können zufällig zur exakt selben
    /// Minute fahren und dürfen dann NICHT als ein (gekuppelter) Zug zusammengefasst werden.
    let finalDestinationHint: String?

    func with(actualTime newTime: Date) -> TrainEntry {
        TrainEntry(
            id: id, lineName: lineName, direction: direction,
            scheduledTime: scheduledTime, actualTime: newTime,
            delayMinutes: max(0, Int(newTime.timeIntervalSince(scheduledTime) / 60)),
            isCancelled: isCancelled, platform: platform, stopsAtStation: stopsAtStation,
            geopsMatchedTripId: geopsMatchedTripId, finalDestinationHint: finalDestinationHint
        )
    }

    func withGeopsId(_ tripId: String) -> TrainEntry {
        TrainEntry(
            id: id, lineName: lineName, direction: direction,
            scheduledTime: scheduledTime, actualTime: actualTime,
            delayMinutes: delayMinutes,
            isCancelled: isCancelled, platform: platform, stopsAtStation: stopsAtStation,
            geopsMatchedTripId: tripId, finalDestinationHint: finalDestinationHint
        )
    }

    /// Überschreibt die Richtung — genutzt wenn Geops (Live-GPS/Zieldestination) eine
    /// zuverlässigere Richtung liefert als die anfängliche DB-Pfad-Textschätzung.
    func withDirection(_ newDirection: TrainDirection) -> TrainEntry {
        TrainEntry(
            id: id, lineName: lineName, direction: newDirection,
            scheduledTime: scheduledTime, actualTime: actualTime,
            delayMinutes: delayMinutes,
            isCancelled: isCancelled, platform: platform, stopsAtStation: stopsAtStation,
            geopsMatchedTripId: geopsMatchedTripId, finalDestinationHint: finalDestinationHint
        )
    }

    /// Überschreibt den Ziel-Hinweis — genutzt in deduplicate(), wenn zwei zusammengeführte
    /// Einträge unterschiedliche bekannte Ziele hatten (Freising vs. Flughafen München): keines
    /// der beiden Ziele ist dann noch korrekt für den gemergten, gekuppelten Zug, daher nil.
    func withDestinationHint(_ newHint: String?) -> TrainEntry {
        TrainEntry(
            id: id, lineName: lineName, direction: direction,
            scheduledTime: scheduledTime, actualTime: actualTime,
            delayMinutes: delayMinutes,
            isCancelled: isCancelled, platform: platform, stopsAtStation: stopsAtStation,
            geopsMatchedTripId: geopsMatchedTripId, finalDestinationHint: newHint
        )
    }

    // Designated init (privat, alle Felder)
    private init(id: String, lineName: String, direction: TrainDirection,
                 scheduledTime: Date, actualTime: Date, delayMinutes: Int,
                 isCancelled: Bool, platform: String?, stopsAtStation: Bool,
                 geopsMatchedTripId: String? = nil, finalDestinationHint: String? = nil) {
        self.id = id; self.lineName = lineName; self.direction = direction
        self.scheduledTime = scheduledTime; self.actualTime = actualTime
        self.delayMinutes = delayMinutes; self.isCancelled = isCancelled
        self.platform = platform; self.stopsAtStation = stopsAtStation
        self.geopsMatchedTripId = geopsMatchedTripId
        self.finalDestinationHint = finalDestinationHint
    }

    /// Erstellt einen TrainEntry aus einem TimetableStop (DB-Quelle).
    /// Verspätung kommt aus der DB Realtime Changes API.
    /// Geops-Verfeinerung passiert nachgelagert in fetchDepartures().
    init?(from stop: TimetableStop, onlyS1: Bool = true, confirmedLines: [String]? = nil) {
        guard let dp = stop.dp,
              let pt = dp.pt,
              let planned = DateFormatter.dbTime.date(from: pt) else { return nil }

        let category = stop.category ?? ""
        let lineRaw  = dp.line ?? ""

        // Bekannte Münchner S-Bahn-Liniennummern (unabhängig von der Kategorie prüfen — siehe
        // unten, warum die Kategorie allein nicht reicht).
        let sBahnLine: String?
        switch lineRaw {
        case "1", "S1":   sBahnLine = "S1"
        case "2", "S2":   sBahnLine = "S2"
        case "3", "S3":   sBahnLine = "S3"
        case "4", "S4":   sBahnLine = "S4"
        case "5", "S5":   sBahnLine = "S5"
        case "6", "S6":   sBahnLine = "S6"
        case "7", "S7":   sBahnLine = "S7"
        case "8", "S8":   sBahnLine = "S8"
        case "20", "S20": sBahnLine = "S20"
        default:          sBahnLine = nil
        }

        // Bahn-Kategorie ("S"/"RE"/"RB"/"IC"/"ICE"/"ARV"/...) kommt aus der DB-API (<tl c="…">).
        // WICHTIG: "ARV" ist KEINE zuverlässige S-Bahn-Kennung — die DB-API nutzt sie laut
        // Beobachtung sowohl für echte S-Bahnen als auch für RE/RB (z.B. category="ARV"
        // lineRaw="RE72"). Ein reiner Kategorie-Check hätte solche RE/RB-Züge fälschlich in
        // den S-Bahn-Zweig geschickt, wo sie mangels bekannter S-Linien-Nummer komplett
        // verworfen wurden. Deshalb zählt primär die Liniennummer (lineRaw); die Kategorie
        // dient nur noch dazu, Fernverkehr (ICE/IC/EC/WB) zu erkennen und auszuschließen.
        let lineName: String
        if (category.isEmpty || category == "S" || category == "ARV"), let sLine = sBahnLine {
            // Nur bekannte Münchner S-Bahn-Linien akzeptieren, alles andere ablehnen statt zu
            // raten. Vorher wurde JEDE numerische Zugnummer > 9 (z.B. eine vierstellige
            // ICE-Nummer) fälschlich als "S1" angezeigt — inklusive deren echter, oft riesiger
            // Verspätung (daher die absurden "+242 min"-Anzeigen).
            lineName = sLine
            // Bei onlyS1: andere S-Bahn-Linien für diesen Übergang ausblenden
            if onlyS1, lineName != "S1" { return nil }
            // Geops-bestätigte S-Bahn-Linien: sobald geOps mindestens eine S-Bahn-Linie für
            // diesen Übergang per Live-GPS bestätigt hat, nur noch bestätigte S-Bahn-Linien
            // zeigen. Gilt bewusst NUR für S-Bahnen (nicht für RE/IC/… im else-Zweig unten) —
            // Regionalzüge fahren laut Vor-Ort-Beobachtung real über diese Übergänge, auch
            // wenn geOps für sie noch keine eigene Bestätigung gesammelt hat.
            if let confirmed = confirmedLines, !confirmed.isEmpty, !confirmed.contains(lineName) {
                return nil
            }
        } else if category == "ICE" || category == "IC" || category == "EC" || category == "WB" {
            // Fernverkehr (ICE/IC/EC sowie WESTbahn "WB", der private österreichische
            // Betreiber Wien–Salzburg–München) fährt laut Vor-Ort-Beobachtung NICHT über
            // diesen Übergang — die kommen über eine andere Strecke (Salzburg/Rosenheim
            // statt Regensburg/Landshut) nach München. Nur weil die DB-API sie für die
            // Station listet, heißt das nicht, dass sie hier die Schranke auslösen.
            // Deshalb verwerfen statt (wie RE/RB) anzuzeigen.
            return nil
        } else if category.isEmpty || category == "S" {
            // Kategorie sagt S-Bahn, aber die Liniennummer passt zu keiner bekannten Linie —
            // nicht sicher genug zum Anzeigen, lieber ablehnen statt zu raten.
            return nil
        } else {
            // Andere Zugart (RE, RB, … oder "ARV" mit einer Liniennummer wie "RE72" in lineRaw,
            // die keiner S-Bahn-Linie entspricht) — fährt laut Vor-Ort-Beobachtung real über diese
            // Übergänge, wird deshalb NICHT verworfen, sondern mit echtem Namen gezeigt. lineRaw
            // (dp/ar l=) ist bei RE/RB bereits die öffentliche Linienbezeichnung (z.B. "RB33",
            // "RE3") — Live-Test 2026-09-09 an Feldmoching zeigte, dass die vorherige Reihenfolge
            // (trainNumber zuerst) stattdessen die interne DB-Zugnummer verwendete, weil tl n=
            // bei RE/RB fast immer gesetzt ist ("RB59231" statt "RB33" — unbrauchbar für Nutzer).
            if !lineRaw.isEmpty {
                lineName = lineRaw
            } else {
                let number = stop.trainNumber ?? ""
                lineName = number.isEmpty ? category : "\(category)\(number)"
            }
        }

        let actual  = stop.actualDepartureTime ?? planned
        let dbDelay = max(0, Int(actual.timeIntervalSince(planned) / 60))

        self.id                  = stop.id
        self.lineName            = lineName
        self.scheduledTime       = planned
        self.actualTime          = actual
        self.delayMinutes        = dbDelay
        self.isCancelled         = stop.isCancelled
        self.platform            = stop.changedPlatform
        self.stopsAtStation      = lineName == "S1"
        self.geopsMatchedTripId  = nil
        let detected = Self.detectDirection(
            departurePath: dp.path ?? "",
            arrivalPath:   stop.ar?.path ?? ""
        )
        self.direction = detected.direction
        self.finalDestinationHint = detected.destinationHint
    }

    /// Diakritik-unabhängiger, kleingeschriebener Vergleichstext — macht das Keyword-Matching
    /// robust gegen unterschiedliche Unicode-Normalform (vorkomponiertes vs. zusammengesetztes
    /// ü/ö/ä), mit der DB- und Geops-Stationsnamen je nach API-Antwort kodiert sein können.
    private static func foldedForMatching(_ s: String) -> String {
        s.lowercased().folding(options: [.diacriticInsensitive], locale: .current)
    }

    private static func detectDirection(departurePath: String,
                                        arrivalPath: String) -> (direction: TrainDirection, destinationHint: String?) {
        let freisungKeywords = ["freising", "flughafen", "neufahrn", "pulling", "eching",
                                "lohhof", "unterschlei", "oberschlei", "hallbergmoos"]
        let munichKeywords   = ["feldmoching", "munchen", "ostbahnhof", "laim", "pasing",
                                "moosach", "petershausen", "dachau", "karlsfeld"]

        // S1 teilt sich hinter Neufahrn in zwei Äste (Freising / Flughafen München über
        // Hallbergmoos) — beide fahren über dieselben Übergänge südlich davon. Ohne diese
        // Erkennung hat deduplicate() zwei verschiedene, zufällig zur selben Minute fahrende
        // Züge (einer Richtung Freising, einer Richtung Flughafen) fälschlich als denselben
        // (gekuppelten) Zug behandelt und einen davon verworfen.
        func destinationHint(_ folded: String) -> String? {
            if folded.contains("flughafen") || folded.contains("hallbergmoos") { return "flughafen" }
            if folded.contains("freising") { return "freising" }
            return nil
        }

        let depFolded = foldedForMatching(departurePath)
        let depStops  = depFolded.components(separatedBy: "|")
        if depStops.contains(where: { s in freisungKeywords.contains { s.contains($0) } }) {
            return (.toFreising, destinationHint(depFolded))
        }
        if depStops.contains(where: { s in munichKeywords.contains   { s.contains($0) } }) {
            return (.toMunich, nil)
        }

        if !arrivalPath.isEmpty {
            // arrivalPath listet die VORHERIGEN Stationen (woher der Zug kommt) — daraus lässt
            // sich das ZIEL nicht ableiten, deshalb hier immer destinationHint=nil (konservativ,
            // wie vor dieser Änderung).
            let arrStops = foldedForMatching(arrivalPath).components(separatedBy: "|")
            if arrStops.contains(where: { s in munichKeywords.contains   { s.contains($0) } }) { return (.toFreising, nil) }
            if arrStops.contains(where: { s in freisungKeywords.contains { s.contains($0) } }) { return (.toMunich, nil) }
        }

        return (.toMunich, nil)
    }
}

// MARK: - Errors

enum APIError: LocalizedError {
    case httpError(Int)
    var errorDescription: String? {
        switch self {
        case .httpError(401): "Ungültige DB API-Keys."
        case .httpError(403): "Kein Zugriff – DB Timetables API abonniert?"
        case .httpError(let c): "DB API-Fehler (HTTP \(c))."
        }
    }
}

// MARK: - Date Helpers

private extension Date {
    var yyMMdd: String { DateFormatter.yyMMdd.string(from: self) }
    var HH: String     { DateFormatter.HH.string(from: self) }
}

extension Date {
    /// Kurzform "HH:mm:ss" fürs Debug-Log — lesbar statt der vollen `Date`-Beschreibung.
    var HHmmss: String { DateFormatter.HHmmss.string(from: self) }

    var roundedToMinute: Date {
        let secs = (timeIntervalSinceReferenceDate / 60).rounded() * 60
        return Date(timeIntervalSinceReferenceDate: secs)
    }

    static func fromISO8601(_ string: String) -> Date? {
        if let d = _iso8601WithFractional.date(from: string) { return d }
        return _iso8601Standard.date(from: string)
    }

    private static let _iso8601WithFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let _iso8601Standard = ISO8601DateFormatter()
}

extension DateFormatter {
    static let yyMMdd: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyMMdd"
        f.locale = Locale(identifier: "de_DE"); return f
    }()
    static let HH: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH"; return f
    }()
    static let HHmmss: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()
    static let dbTime: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyMMddHHmm"
        f.locale = Locale(identifier: "de_DE"); return f
    }()
}
