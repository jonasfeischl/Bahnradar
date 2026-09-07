import WidgetKit
import SwiftUI

// MARK: - Timeline Entry

struct CrossingEntry: TimelineEntry {
    let date: Date
    let status: WidgetStatus
    let nextTrains: [WidgetTrain]
    let crossingName: String
    let crossingSubtitle: String
}

enum WidgetStatus: String {
    case open, warning, closed, opening, unknown

    var color: Color {
        switch self {
        case .open:    .green
        case .warning: .yellow
        case .closed:  .red
        case .opening: .yellow
        case .unknown: .gray
        }
    }
    var label: String {
        switch self {
        case .open:    "Offen"
        case .warning: "Schließt bald"
        case .closed:  "Geschlossen"
        case .opening: "Öffnet gleich"
        case .unknown: "Lädt…"
        }
    }
}

struct WidgetTrain {
    let line: String
    let direction: String
    let crossingTime: Date
    var delayMinutes: Int = 0

    func minutesUntil(from date: Date) -> Double {
        crossingTime.timeIntervalSince(date) / 60
    }
}

// MARK: - Timeline Provider

struct CrossingProvider: TimelineProvider {
    private let apiClientId = "bb2d56302fc6faac8ac204a28a58beda"
    private let apiKey      = "e77347cdd2f22d6f600a4df38271f4af"
    private let dbBase      = "https://apis.deutschebahn.com/db-api-marketplace/apis/timetables/v1"
    private let openingDelay: Double = 20   // identisch zur Hauptapp (FeedbackLearner.totalOpeningDelay Basis)

    // Geteilte UserDefaults mit der Haupt-App (App Group)
    private var shared: UserDefaults { UserDefaults(suiteName: "group.schrankenradar.osh") ?? .standard }

    private var stationEVA:       String { shared.string(forKey: "widget_stationEVA")       ?? "8004580" }
    private var crossingName:     String { shared.string(forKey: "widget_crossingName")     ?? "Dachauer Str." }
    private var crossingSubtitle: String { shared.string(forKey: "widget_crossingSubtitle") ?? "Oberschleißheim" }
    private var offsetToMunich:   Double { shared.double(forKey: "widget_offsetToMunich").nonZero ?? 180 }
    private var offsetToFreising: Double { shared.double(forKey: "widget_offsetToFreising").nonZero ?? -180 }
    private var onlyS1:           Bool   { shared.object(forKey: "widget_onlyS1") != nil ? shared.bool(forKey: "widget_onlyS1") : true }

    func placeholder(in context: Context) -> CrossingEntry {
        CrossingEntry(date: .now, status: .open, nextTrains: [
            WidgetTrain(line: "S1", direction: "München",  crossingTime: Date().addingTimeInterval(240)),
            WidgetTrain(line: "S1", direction: "Freising", crossingTime: Date().addingTimeInterval(480)),
        ], crossingName: crossingName, crossingSubtitle: crossingSubtitle)
    }

    func getSnapshot(in context: Context, completion: @escaping (CrossingEntry) -> Void) {
        if context.isPreview { completion(placeholder(in: context)); return }
        Task {
            let trains = (try? await fetchTrains()) ?? []
            completion(CrossingEntry(date: .now, status: worstStatus(trains, at: .now), nextTrains: Array(trains.prefix(3)), crossingName: crossingName, crossingSubtitle: crossingSubtitle))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CrossingEntry>) -> Void) {
        Task {
            do {
                let trains = try await fetchTrains()
                let entries = buildTimeline(trains: trains)
                let nextFetch = Date().addingTimeInterval(5 * 60)
                completion(Timeline(entries: entries, policy: .after(nextFetch)))
            } catch {
                let entry = CrossingEntry(date: .now, status: .unknown, nextTrains: [], crossingName: crossingName, crossingSubtitle: crossingSubtitle)
                let retry = Date().addingTimeInterval(60)
                completion(Timeline(entries: [entry], policy: .after(retry)))
            }
        }
    }

    // Berechnet Einträge für jeden relevanten Zeitpunkt in den nächsten 90 Minuten
    private func buildTimeline(trains: [WidgetTrain]) -> [CrossingEntry] {
        var entries: [CrossingEntry] = []
        var checkDates = Set<Date>()

        // Basisintervall: alle 30 Sekunden
        var t = Date()
        let end = t.addingTimeInterval(90 * 60)
        while t < end {
            checkDates.insert(t)
            t = t.addingTimeInterval(30)
        }

        // Zusätzlich: Statuswechsel-Zeitpunkte für jeden Zug exakt treffen
        for train in trains {
            let crossing = train.crossingTime
            checkDates.insert(crossing.addingTimeInterval(-2.5 * 60))  // warning start
            checkDates.insert(crossing.addingTimeInterval(-1.5 * 60))  // closed start
            checkDates.insert(crossing)                                // crossing
            checkDates.insert(crossing.addingTimeInterval(openingDelay)) // opening
            checkDates.insert(crossing.addingTimeInterval(openingDelay + 15)) // open again
        }

        let now = Date()
        for date in checkDates.sorted() {
            guard date >= now else { continue }
            let status = worstStatus(trains, at: date)
            let visible = trains.filter { $0.minutesUntil(from: date) > -2 && $0.minutesUntil(from: date) < 90 }
            entries.append(CrossingEntry(date: date, status: status, nextTrains: Array(visible.prefix(3)), crossingName: crossingName, crossingSubtitle: crossingSubtitle))
        }

        if entries.isEmpty {
            entries.append(CrossingEntry(date: .now, status: .open, nextTrains: [], crossingName: crossingName, crossingSubtitle: crossingSubtitle))
        }

        return entries
    }

    // MARK: Daten laden

    /// Lädt die von der App berechneten Geops-genauen Events (Live-Zeiten + GPS-Offsets
    /// + Trajectory) aus der App Group. Gibt nil zurück wenn keine oder veraltete Daten
    /// (> 12 min) vorliegen — dann fällt das Widget auf den eigenen DB-Fetch zurück.
    private func loadAppEvents() -> [WidgetTrain]? {
        guard let data = shared.data(forKey: SharedWidgetPayload.userDefaultsKey),
              let payload = try? JSONDecoder().decode(SharedWidgetPayload.self, from: data)
        else { return nil }

        // Nur nutzen wenn frisch und für den aktuell im Widget gezeigten Übergang
        guard Date().timeIntervalSince(payload.generatedAt) < 12 * 60,
              payload.crossingName == crossingName
        else { return nil }

        let now = Date()
        let trains = payload.events
            .filter { $0.crossingTime.addingTimeInterval(openingDelay + 60) > now }
            .map {
                WidgetTrain(
                    line: $0.line,
                    direction: $0.directionIsMunich ? "München" : "Freising",
                    crossingTime: $0.crossingTime,
                    delayMinutes: $0.delayMinutes
                )
            }
            .sorted { $0.crossingTime < $1.crossingTime }

        return trains
    }

    private func fetchTrains() async throws -> [WidgetTrain] {
        // 1. Bevorzugt: Geops-genaue Events aus der App
        if let appEvents = loadAppEvents() {
            return appEvents
        }

        // 2. Fallback: eigener DB-Fetch (ohne Geops)
        let now  = Date()
        let next = now.addingTimeInterval(3600)

        // Plan + Echtzeit-Änderungen parallel laden
        async let s1      = fetchStops(for: now)
        async let s2      = fetchStops(for: next)
        async let changes = fetchChanges()
        let (stops1, stops2, changeMap) = try await (s1, s2, changes)

        var seen = Set<String>()
        let allStops = (stops1 + stops2).filter {
            seen.insert(($0["id"] as? String) ?? UUID().uuidString).inserted
        }

        return allStops
            .compactMap { stop -> WidgetTrain? in
                guard let dp  = stop["dp"] as? [String: String],
                      let pt  = dp["pt"],
                      let planned = DateFormatter.dbTime.date(from: pt) else { return nil }

                let stopId   = stop["id"] as? String ?? ""
                let change   = changeMap[stopId]

                // Abgebrochen?
                if change?.cancelled == true { return nil }

                // Tatsächliche Abfahrtszeit (Verspätung aus rchg-API)
                let actual: Date
                if let ct = change?.changedTime,
                   let changed = DateFormatter.dbTime.date(from: ct) {
                    actual = changed
                } else {
                    actual = planned
                }

                let rawLine  = dp["line"] ?? ""
                let trainNum = stop["trainNumber"] as? String ?? ""
                let lineR    = rawLine.isEmpty ? trainNum : rawLine

                guard !lineR.hasPrefix("RB"), !lineR.hasPrefix("RE"),
                      !lineR.hasPrefix("IC"), !lineR.hasPrefix("EC") else { return nil }

                if onlyS1 {
                    let blocked: Set<String> = ["2","3","4","5","6","7","8","20",
                                               "S2","S3","S4","S5","S6","S7","S8","S20"]
                    guard !blocked.contains(lineR) else { return nil }
                }

                let line: String
                if lineR == "1" { line = "S1" }
                else if let nr = Int(lineR), nr > 9 { line = "S1" }
                else { line = lineR.hasPrefix("S") ? lineR : "S\(lineR)" }

                let depPath = dp["path"] ?? ""
                let arrPath = (stop["ar"] as? [String: String])?["path"] ?? ""
                let toMunich = isMunich(departurePath: depPath, arrivalPath: arrPath)
                let offset   = toMunich ? offsetToMunich : offsetToFreising
                let crossing = actual.addingTimeInterval(offset)

                guard crossing.addingTimeInterval(openingDelay + 60) > now else { return nil }

                let delayMin = max(0, Int(actual.timeIntervalSince(planned) / 60))
                return WidgetTrain(line: line,
                                   direction: toMunich ? "München" : "Freising",
                                   crossingTime: crossing,
                                   delayMinutes: delayMin)
            }
            .sorted { $0.crossingTime < $1.crossingTime }
    }

    private func fetchStops(for date: Date) async throws -> [[String: Any]] {
        let url = URL(string: "\(dbBase)/plan/\(stationEVA)/\(date.yyMMdd)/\(date.HH)")!
        var req = URLRequest(url: url)
        req.setValue(apiClientId, forHTTPHeaderField: "DB-Client-Id")
        req.setValue(apiKey,      forHTTPHeaderField: "DB-Api-Key")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
        return WidgetXMLParser.parse(data: data)
    }

    private func fetchChanges() async throws -> [String: WidgetChangeInfo] {
        let url = URL(string: "\(dbBase)/rchg/\(stationEVA)")!
        var req = URLRequest(url: url)
        req.setValue(apiClientId, forHTTPHeaderField: "DB-Client-Id")
        req.setValue(apiKey,      forHTTPHeaderField: "DB-Api-Key")
        req.setValue("application/xml", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse, http.statusCode == 200
        else { return [:] }
        return WidgetChangesParser.parse(data: data)
    }

    private func isMunich(departurePath: String, arrivalPath: String = "") -> Bool {
        let freisungKW = ["freising", "flughafen", "neufahrn", "pulling", "eching",
                          "lohhof", "unterschlei", "hallbergmoos"]
        let munichKW   = ["feldmoching", "münchen", "ostbahnhof", "laim", "pasing",
                          "moosach", "petershausen", "dachau", "karlsfeld"]

        let dep = departurePath.lowercased().components(separatedBy: "|")
        if dep.contains(where: { s in freisungKW.contains { s.contains($0) } }) { return false }
        if dep.contains(where: { s in munichKW.contains   { s.contains($0) } }) { return true }

        if !arrivalPath.isEmpty {
            let arr = arrivalPath.lowercased().components(separatedBy: "|")
            if arr.contains(where: { s in munichKW.contains   { s.contains($0) } }) { return false }
            if arr.contains(where: { s in freisungKW.contains { s.contains($0) } }) { return true }
        }

        return true  // Fallback München
    }

    /// Identische Logik wie CrossingViewModel.worstStatus + CrossingEvent.status(at:)
    private func worstStatus(_ trains: [WidgetTrain], at date: Date) -> WidgetStatus {
        let openingDelayMin = openingDelay / 60  // 10s → 0.167 min

        let upcoming = trains.filter { $0.minutesUntil(from: date) < 6 }

        func status(_ train: WidgetTrain) -> WidgetStatus {
            let m = train.minutesUntil(from: date)
            if m > 2.5                          { return .open }
            if m > 1.5                          { return .warning }
            if m > -openingDelayMin             { return .closed }
            if m > -openingDelayMin - 0.17      { return .opening }
            return .open
        }

        let hasClosed  = upcoming.contains { status($0) == .closed }
        let hasWarning = upcoming.contains { status($0) == .warning }
        let hasOpening = upcoming.contains { status($0) == .opening }

        if hasClosed               { return .closed }
        if hasOpening && !hasWarning { return .opening }
        if hasWarning              { return .warning }
        return .open
    }
}

// MARK: - Widget View

struct SchrankenradarWidgetEntryView: View {
    var entry: CrossingEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .systemSmall:              smallView
        case .systemLarge:              largeView
        case .accessoryCircular:        accessoryCircularView
        case .accessoryRectangular:     accessoryRectangularView
        default:                        mediumView
        }
    }

    // MARK: Small

    private var smallView: some View {
        VStack(spacing: 0) {
            VStack(spacing: 5) {
                MiniTrafficLight(status: entry.status)
                Text(entry.status.label)
                    .font(.caption.bold())
                    .foregroundStyle(entry.status.color)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            Group {
                if let next = entry.nextTrains.first {
                    let isMunich = next.direction == "München"
                    HStack(spacing: 4) {
                        Circle()
                            .fill(isMunich ? Color.blue : Color.orange)
                            .frame(width: 6, height: 6)
                        Text(next.line)
                            .font(.caption2.bold())
                        Spacer(minLength: 2)
                        Text(relativeLabel(next, from: entry.date))
                            .font(.caption2)
                            .foregroundStyle(countdownColor(next.crossingTime))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                } else {
                    Text("Kein Zug")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 7)
                }
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    // MARK: Medium

    private var mediumView: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Circle()
                    .fill(entry.status.color)
                    .frame(width: 9, height: 9)
                Text(entry.crossingName)
                    .font(.caption.bold())
                    .lineLimit(1)
                Spacer()
                Text(entry.status.label)
                    .font(.caption.bold())
                    .foregroundStyle(entry.status.color)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)

            Divider()

            if entry.nextTrains.isEmpty {
                Spacer()
                Text("Keine Züge in 90 min")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(entry.nextTrains.prefix(3).enumerated()), id: \.offset) { idx, train in
                        mediumTrainRow(train)
                        if idx < min(entry.nextTrains.count, 3) - 1 {
                            Divider().padding(.horizontal, 14)
                        }
                    }
                }
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private func mediumTrainRow(_ train: WidgetTrain) -> some View {
        let isMunich = train.direction == "München"
        return HStack(spacing: 8) {
            Circle()
                .fill(isMunich ? Color.blue : Color.orange)
                .frame(width: 7, height: 7)

            Text(train.line)
                .font(.caption.bold())

            Text("→ \(train.direction)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if train.delayMinutes > 0 {
                Text("+\(train.delayMinutes)m")
                    .font(.caption2.bold())
                    .foregroundStyle(.orange)
            }

            Spacer(minLength: 4)

            Text(relativeLabel(train, from: entry.date))
                .font(.caption2)
                .foregroundStyle(countdownColor(train.crossingTime))

            Text(train.crossingTime, style: .time)
                .font(.caption.bold())
                .monospacedDigit()
                .frame(width: 38, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    /// Gibt "in X min" ohne Sekunden zurück — basiert auf entry.date
    private func relativeLabel(_ train: WidgetTrain, from date: Date) -> String {
        let seconds = train.crossingTime.timeIntervalSince(date)
        guard seconds > 0 else { return "passiert" }
        let minutes = Int(seconds / 60)
        if minutes == 0 { return "< 1 min" }
        if minutes == 1 { return "in 1 min" }
        return "in \(minutes) min"
    }

    // MARK: Large

    private var largeView: some View {
        VStack(spacing: 0) {

            // MARK: Status-Block
            HStack(alignment: .center, spacing: 14) {
                MiniTrafficLight(status: entry.status)

                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.crossingName)
                        .font(.subheadline.bold())
                        .lineLimit(1)
                    Text(entry.status.label)
                        .font(.title3.bold())
                        .foregroundStyle(entry.status.color)
                }
                Spacer()
            }
            .padding(14)

            Divider()

            // MARK: Zug-Liste
            if entry.nextTrains.isEmpty {
                Spacer()
                VStack(spacing: 6) {
                    Image(systemName: "tram")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("Keine Züge in 90 min")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(entry.nextTrains.prefix(5).enumerated()), id: \.offset) { idx, train in
                        largeTrainRow(train)
                        if idx < min(entry.nextTrains.count, 5) - 1 {
                            Divider().padding(.horizontal, 14)
                        }
                    }
                }
            }

            Divider()

            // MARK: Footer
            HStack {
                Text(entry.crossingSubtitle)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("Stand \(entry.date, style: .time)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private func largeTrainRow(_ train: WidgetTrain) -> some View {
        HStack(spacing: 12) {
            // Richtungs-Indikator
            let isMunich = train.direction == "München"
            RoundedRectangle(cornerRadius: 3)
                .fill(isMunich ? Color.blue : Color.orange)
                .frame(width: 4)
                .padding(.vertical, 10)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(train.line).font(.subheadline.bold())
                    if train.delayMinutes > 0 {
                        Text("+\(train.delayMinutes)m")
                            .font(.caption2.bold())
                            .foregroundStyle(.orange)
                    }
                }
                Text("→ \(train.direction)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(train.crossingTime, style: .time)
                    .font(.subheadline.bold())
                    .monospacedDigit()
                Text(relativeLabel(train, from: entry.date))
                    .font(.caption2)
                    .foregroundStyle(countdownColor(train.crossingTime))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: Lock Screen — Circular

    private var accessoryCircularView: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 2) {
                Circle()
                    .fill(entry.status.color)
                    .frame(width: 16, height: 16)
                Text(entry.status.label)
                    .font(.system(size: 9, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.7)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    // MARK: Lock Screen — Rectangular

    private var accessoryRectangularView: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(entry.status.color)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.status.label)
                    .font(.caption.bold())
                    .foregroundStyle(entry.status.color)
                if let next = entry.nextTrains.first {
                    HStack(spacing: 4) {
                        Text(next.line)
                            .font(.caption2.bold())
                        Text("→ \(next.direction)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(next.crossingTime, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                } else {
                    Text("Kein Zug in 90 min")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private func countdownColor(_ date: Date) -> Color {
        let m = date.timeIntervalSinceNow / 60
        if m < 1 { return .red }
        if m < 3 { return .orange }
        return .secondary
    }
}

// MARK: - Mini Ampel

struct MiniTrafficLight: View {
    let status: WidgetStatus

    var body: some View {
        VStack(spacing: 4) {
            dot(.red,    active: status == .closed)
            dot(.yellow, active: status == .warning || status == .opening)
            dot(.green,  active: status == .open)
        }
        .padding(8)
        .background(Color(.systemGray5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func dot(_ color: Color, active: Bool) -> some View {
        Circle()
            .fill(active ? color : color.opacity(0.15))
            .frame(width: 22, height: 22)
    }
}

// MARK: - Widget Registrierung

struct SchrankenradarWidget: Widget {
    let kind = "SchrankenradarWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CrossingProvider()) { entry in
            SchrankenradarWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Schrankenradar OSH")
        .description("Zeigt ob der Bahnübergang Dachauer Str. offen ist.")
        .supportedFamilies([
            .systemSmall, .systemMedium, .systemLarge,
            .accessoryCircular, .accessoryRectangular
        ])
    }
}

// MARK: - Changes Model

struct WidgetChangeInfo {
    let changedTime: String?
    let cancelled: Bool
}

// MARK: - Changes XML Parser

final class WidgetChangesParser: NSObject, XMLParserDelegate {
    private var changes: [String: WidgetChangeInfo] = [:]
    private var currentId: String?

    static func parse(data: Data) -> [String: WidgetChangeInfo] {
        let h = WidgetChangesParser()
        let p = XMLParser(data: data)
        p.delegate = h; p.parse()
        return h.changes
    }

    func parser(_ parser: XMLParser, didStartElement el: String,
                namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
        switch el {
        case "s":  currentId = a["id"]
        case "dp" where currentId != nil:
            changes[currentId!] = WidgetChangeInfo(changedTime: a["ct"],
                                                    cancelled: a["cs"] == "c")
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement el: String,
                namespaceURI: String?, qualifiedName: String?) {
        if el == "s" { currentId = nil }
    }
}

// MARK: - Plan XML Parser

final class WidgetXMLParser: NSObject, XMLParserDelegate {
    private var stops: [[String: Any]] = []
    private var current: [String: Any]?

    static func parse(data: Data) -> [[String: Any]] {
        let h = WidgetXMLParser()
        let p = XMLParser(data: data)
        p.delegate = h; p.parse()
        return h.stops
    }

    func parser(_ parser: XMLParser, didStartElement el: String,
                namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
        switch el {
        case "s":  current = ["id": a["id"] ?? ""]
        case "dp": current?["dp"] = ["pt": a["pt"] ?? "", "line": a["l"] ?? "", "path": a["ppth"] ?? ""]
        case "ar": current?["ar"] = ["path": a["ppth"] ?? ""]
        case "tl": current?["category"] = a["c"] ?? ""   // z.B. "RB", "RE", "S"
                   current?["trainNumber"] = a["n"] ?? ""
        default:   break
        }
    }

    func parser(_ parser: XMLParser, didEndElement el: String,
                namespaceURI: String?, qualifiedName: String?) {
        if el == "s", let s = current { stops.append(s); current = nil }
    }
}

// MARK: - Hilfserweiterungen

private extension Double {
    /// Gibt nil zurück wenn der Wert 0 ist (UserDefaults default)
    var nonZero: Double? { self == 0 ? nil : self }
}

// MARK: - Date Helpers

private extension Date {
    var yyMMdd: String { DateFormatter.yyMMdd.string(from: self) }
    var HH: String     { DateFormatter.HH.string(from: self) }
}

extension DateFormatter {
    static let yyMMdd: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyMMdd"
        f.locale = Locale(identifier: "de_DE"); return f
    }()
    static let HH: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH"; return f
    }()
    static let dbTime: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyMMddHHmm"
        f.locale = Locale(identifier: "de_DE"); return f
    }()
}

// MARK: - Preview

#Preview(as: .systemSmall) {
    SchrankenradarWidget()
} timeline: {
    CrossingEntry(date: .now, status: .warning, nextTrains: [
        WidgetTrain(line: "S1", direction: "München", crossingTime: Date().addingTimeInterval(120)),
    ], crossingName: "Dachauer Str.", crossingSubtitle: "Oberschleißheim")
}

#Preview(as: .systemMedium) {
    SchrankenradarWidget()
} timeline: {
    CrossingEntry(date: .now, status: .warning, nextTrains: [
        WidgetTrain(line: "S1", direction: "München",  crossingTime: Date().addingTimeInterval(120)),
        WidgetTrain(line: "S1", direction: "Freising", crossingTime: Date().addingTimeInterval(360)),
    ], crossingName: "Dachauer Str.", crossingSubtitle: "Oberschleißheim")
}

#Preview(as: .systemLarge) {
    SchrankenradarWidget()
} timeline: {
    CrossingEntry(date: .now, status: .closed, nextTrains: [
        WidgetTrain(line: "S1", direction: "München",  crossingTime: Date().addingTimeInterval(60)),
        WidgetTrain(line: "S1", direction: "Freising", crossingTime: Date().addingTimeInterval(300)),
        WidgetTrain(line: "S1", direction: "München",  crossingTime: Date().addingTimeInterval(600)),
        WidgetTrain(line: "S1", direction: "Freising", crossingTime: Date().addingTimeInterval(900)),
    ], crossingName: "Dachauer Str.", crossingSubtitle: "Oberschleißheim")
}

#Preview(as: .accessoryRectangular) {
    SchrankenradarWidget()
} timeline: {
    CrossingEntry(date: .now, status: .warning, nextTrains: [
        WidgetTrain(line: "S1", direction: "München", crossingTime: Date().addingTimeInterval(180)),
    ], crossingName: "Dachauer Str.", crossingSubtitle: "Oberschleißheim")
}
