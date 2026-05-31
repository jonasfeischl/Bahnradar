import WidgetKit
import SwiftUI

// MARK: - Timeline Entry

struct CrossingEntry: TimelineEntry {
    let date: Date
    let status: WidgetStatus
    let nextTrains: [WidgetTrain]
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

    func minutesUntil(from date: Date) -> Double {
        crossingTime.timeIntervalSince(date) / 60
    }
}

// MARK: - Timeline Provider

struct CrossingProvider: TimelineProvider {
    private let apiClientId  = "bb2d56302fc6faac8ac204a28a58beda"
    private let apiKey       = "e77347cdd2f22d6f600a4df38271f4af"
    private let stationEVA   = "8004158"
    private let dbBase       = "https://apis.deutschebahn.com/db-api-marketplace/apis/timetables/v1"
    private let offsetSeconds: Double = 180
    private let openingDelay: Double  = 120  // Sekunden bis Schranke nach Zug öffnet

    func placeholder(in context: Context) -> CrossingEntry {
        CrossingEntry(date: .now, status: .open, nextTrains: [
            WidgetTrain(line: "S1", direction: "München",  crossingTime: Date().addingTimeInterval(240)),
            WidgetTrain(line: "S1", direction: "Freising", crossingTime: Date().addingTimeInterval(480)),
        ])
    }

    func getSnapshot(in context: Context, completion: @escaping (CrossingEntry) -> Void) {
        if context.isPreview { completion(placeholder(in: context)); return }
        Task {
            let trains = (try? await fetchTrains()) ?? []
            completion(CrossingEntry(date: .now, status: worstStatus(trains, at: .now), nextTrains: Array(trains.prefix(3))))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CrossingEntry>) -> Void) {
        Task {
            do {
                let trains = try await fetchTrains()
                // Viele Einträge vorausberechnen → Widget updated sich ohne neue API-Calls
                let entries = buildTimeline(trains: trains)
                // Nach 5 Minuten neue Daten laden
                let nextFetch = Date().addingTimeInterval(5 * 60)
                completion(Timeline(entries: entries, policy: .after(nextFetch)))
            } catch {
                let entry = CrossingEntry(date: .now, status: .unknown, nextTrains: [])
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
            checkDates.insert(crossing.addingTimeInterval(-3 * 60))  // warning start
            checkDates.insert(crossing.addingTimeInterval(-60))       // closed start
            checkDates.insert(crossing)                               // crossing
            checkDates.insert(crossing.addingTimeInterval(openingDelay)) // opening
            checkDates.insert(crossing.addingTimeInterval(openingDelay + 15)) // open again
        }

        let now = Date()
        for date in checkDates.sorted() {
            guard date >= now else { continue }
            let status = worstStatus(trains, at: date)
            let visible = trains.filter { $0.minutesUntil(from: date) > -2 && $0.minutesUntil(from: date) < 90 }
            entries.append(CrossingEntry(date: date, status: status, nextTrains: Array(visible.prefix(3))))
        }

        if entries.isEmpty {
            entries.append(CrossingEntry(date: .now, status: .open, nextTrains: []))
        }

        return entries
    }

    // MARK: Daten laden

    private func fetchTrains() async throws -> [WidgetTrain] {
        let now  = Date()
        let next = now.addingTimeInterval(3600)
        async let s1 = fetchStops(for: now)
        async let s2 = fetchStops(for: next)
        let stops = (try await s1) + (try await s2)

        var seen = Set<String>()
        return stops
            .filter { seen.insert(($0["id"] as? String) ?? UUID().uuidString).inserted }
            .compactMap { stop -> WidgetTrain? in
                guard let dp   = stop["dp"] as? [String: String],
                      let pt   = dp["pt"],
                      let date = DateFormatter.dbTime.date(from: pt) else { return nil }

                let lineR    = dp["line"] ?? ""
                let category = stop["category"] as? String ?? ""

                // RB, RE, IC fahren nicht durch Oberschleißheim → rausfiltern
                // Prüfen über Linienname UND Kategorie (tl-Element)
                let isBlocked = ["RB", "RE", "IC", "EC", "ICE"].contains(where: {
                    lineR.hasPrefix($0) || category.hasPrefix($0)
                })
                guard !isBlocked else { return nil }

                // Leere Linie ohne S-Bahn-Kategorie → überspringen
                guard !lineR.isEmpty || category == "S" else { return nil }

                let line     = lineR == "1" ? "S1" : (lineR.hasPrefix("S") ? lineR : "S\(lineR)")
                let depPath  = dp["path"] ?? ""
                let arrPath  = (stop["ar"] as? [String: String])?["path"] ?? ""
                let toMunich = isMunich(departurePath: depPath, arrivalPath: arrPath)
                let offset   = toMunich ? offsetSeconds : -offsetSeconds
                let crossing = date.addingTimeInterval(offset)
                let keepUntil = crossing.addingTimeInterval(openingDelay + 60)
                guard keepUntil > now else { return nil }

                return WidgetTrain(line: line, direction: toMunich ? "München" : "Freising", crossingTime: crossing)
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

    private func worstStatus(_ trains: [WidgetTrain], at date: Date) -> WidgetStatus {
        let upcoming = trains.filter {
            let m = $0.minutesUntil(from: date)
            return m < 5
        }

        let hasClosed  = upcoming.contains(where: {
            let m = $0.minutesUntil(from: date)
            return m <= 1 && m > -(openingDelay / 60)
        })
        let hasWarning = upcoming.contains(where: {
            let m = $0.minutesUntil(from: date)
            return m > 1 && m <= 3
        })
        let hasOpening = upcoming.contains(where: {
            let m = $0.minutesUntil(from: date)
            return m > -(openingDelay / 60) && m <= -(openingDelay / 60) + 0.25
        })

        if hasClosed && hasWarning { return .closed }
        if hasClosed               { return .closed }
        if hasOpening              { return .opening }
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
        case .systemSmall: smallView
        default:           mediumView
        }
    }

    private var smallView: some View {
        VStack(spacing: 8) {
            MiniTrafficLight(status: entry.status)
            Text(entry.status.label)
                .font(.caption).bold()
                .foregroundStyle(entry.status.color)
            if let first = entry.nextTrains.first {
                Text(timeText(first, from: entry.date))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private var mediumView: some View {
        HStack(spacing: 16) {
            VStack(spacing: 6) {
                MiniTrafficLight(status: entry.status)
                Text(entry.status.label)
                    .font(.caption).bold()
                    .foregroundStyle(entry.status.color)
                    .multilineTextAlignment(.center)
                    .frame(width: 75)
            }

            Divider()

            VStack(alignment: .leading, spacing: 7) {
                Text("Nächste Züge")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                ForEach(Array(entry.nextTrains.enumerated()), id: \.offset) { _, train in
                    HStack {
                        Text(train.line)
                            .font(.caption).bold()
                        Text("→ \(train.direction)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(timeText(train, from: entry.date))
                            .font(.caption).bold()
                            .foregroundStyle(minuteColor(train.minutesUntil(from: entry.date)))
                    }
                }

                if entry.nextTrains.isEmpty {
                    Text("Keine Züge in 90 min")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private func timeText(_ train: WidgetTrain, from date: Date) -> String {
        let m = train.minutesUntil(from: date)
        if m < -1  { return "passiert" }
        if m < 0   { return "öffnet gleich" }
        if m < 1   { return "< 1 min" }
        return "in \(Int(m)) min"
    }

    private func minuteColor(_ m: Double) -> Color {
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
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - XML Parser

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

#Preview(as: .systemMedium) {
    SchrankenradarWidget()
} timeline: {
    CrossingEntry(date: .now, status: .warning, nextTrains: [
        WidgetTrain(line: "S1", direction: "München",  crossingTime: Date().addingTimeInterval(120)),
        WidgetTrain(line: "S1", direction: "Freising", crossingTime: Date().addingTimeInterval(360)),
    ])
}
