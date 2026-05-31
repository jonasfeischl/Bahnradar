import WidgetKit
import SwiftUI

// MARK: - Timeline Entry
// Was das Widget zu einem bestimmten Zeitpunkt anzeigt

struct CrossingEntry: TimelineEntry {
    let date: Date
    let status: WidgetStatus
    let nextTrains: [WidgetTrain]
}

enum WidgetStatus: String {
    case open, warning, closed, unknown

    var color: Color {
        switch self {
        case .open:    .green
        case .warning: .yellow
        case .closed:  .red
        case .unknown: .gray
        }
    }
    var label: String {
        switch self {
        case .open:    "Offen"
        case .warning: "Schließt bald"
        case .closed:  "Geschlossen"
        case .unknown: "Lädt…"
        }
    }
}

struct WidgetTrain {
    let line: String
    let direction: String
    let crossingTime: Date

    var minutesUntil: Double {
        crossingTime.timeIntervalSinceNow / 60
    }
}

// MARK: - Timeline Provider
// Liefert Apple das nächste Widget-Update — maximal alle 5 Minuten (Apple-Limit)

struct CrossingProvider: TimelineProvider {
    private let apiClientId = "7f8ece2b4a0824111555b04ab77a3290"
    private let apiKey      = "b18663ed16ca9f92290b60aa774f3baa"
    private let stationEVA  = "8004158"
    private let dbBase      = "https://apis.deutschebahn.com/db-api-marketplace/apis/timetables/v1"
    private let offsetSeconds: Double = 180

    // Platzhalterdaten während das Widget lädt
    func placeholder(in context: Context) -> CrossingEntry {
        CrossingEntry(date: .now, status: .open, nextTrains: [
            WidgetTrain(line: "S1", direction: "München",  crossingTime: Date().addingTimeInterval(240)),
            WidgetTrain(line: "S1", direction: "Freising", crossingTime: Date().addingTimeInterval(480)),
        ])
    }

    // Schnelle Vorschau (z.B. beim Hinzufügen zum Homescreen)
    func getSnapshot(in context: Context, completion: @escaping (CrossingEntry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
            return
        }
        Task {
            completion(await fetchEntry())
        }
    }

    // Wird regelmäßig aufgerufen — liefert den nächsten Refresh-Zeitpunkt
    func getTimeline(in context: Context, completion: @escaping (Timeline<CrossingEntry>) -> Void) {
        Task {
            let entry = await fetchEntry()
            // Bei Fehler schneller neu versuchen (1 min), sonst alle 2 min
            let minutes = entry.status == .unknown ? 1 : 2
            let nextUpdate = Calendar.current.date(byAdding: .minute, value: minutes, to: .now)!
            completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
        }
    }

    // MARK: Daten laden

    private func fetchEntry() async -> CrossingEntry {
        do {
            let trains = try await fetchTrains()
            return CrossingEntry(date: .now, status: worstStatus(trains), nextTrains: Array(trains.prefix(3)))
        } catch {
            // Bei Fehler: in 1 Minute nochmal versuchen, nicht einfach grün zeigen
            return CrossingEntry(date: .now, status: .unknown, nextTrains: [])
        }
    }

    private func fetchTrains() async throws -> [WidgetTrain] {
        let now  = Date()
        let next = now.addingTimeInterval(3600)
        async let s1 = fetchStops(for: now)
        async let s2 = fetchStops(for: next)
        let stops = (try await s1) + (try await s2)

        return stops.compactMap { stop -> WidgetTrain? in
            guard let dp    = stop["dp"] as? [String: String],
                  let pt    = dp["pt"],
                  let date  = DateFormatter.dbTime.date(from: pt),
                  let lineR = dp["line"] else { return nil }

            let line   = lineR.hasPrefix("S") ? lineR : "S\(lineR)"
            let path   = dp["path"] ?? ""
            let south  = isMunich(path)
            let offset = south ? offsetSeconds : -offsetSeconds
            let crossing = date.addingTimeInterval(offset)
            guard crossing.timeIntervalSinceNow > -30 else { return nil }
            return WidgetTrain(line: line, direction: south ? "München" : "Freising", crossingTime: crossing)
        }
        .sorted { $0.crossingTime < $1.crossingTime }
    }

    private func fetchStops(for date: Date) async throws -> [[String: Any]] {
        let url = URL(string: "\(dbBase)/plan/\(stationEVA)/\(date.yyMMdd)/\(date.HH)")!
        var req = URLRequest(url: url)
        req.setValue(apiClientId, forHTTPHeaderField: "DB-Client-Id")
        req.setValue(apiKey,      forHTTPHeaderField: "DB-Api-Key")
        let (data, _) = try await URLSession.shared.data(for: req)
        return WidgetXMLParser.parse(data: data)
    }

    private func isMunich(_ path: String) -> Bool {
        let stops = path.lowercased().components(separatedBy: "|")
        let oshIndex = stops.firstIndex(where: { $0.contains("oberschlei") }) ?? -1
        let futureStops = oshIndex >= 0 ? Array(stops[(oshIndex + 1)...]) : stops
        let freisungKW = ["freising", "flughafen", "neufahrn", "pulling", "eching", "lohhof", "unterschlei"]
        if futureStops.contains(where: { s in freisungKW.contains { s.contains($0) } }) { return false }
        return true
    }

    private func worstStatus(_ trains: [WidgetTrain]) -> WidgetStatus {
        let upcoming = trains.filter { $0.minutesUntil > -0.5 && $0.minutesUntil < 5 }
        if upcoming.contains(where: { $0.minutesUntil <= 1 }) { return .closed }
        if upcoming.contains(where: { $0.minutesUntil <= 3 }) { return .warning }
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

    // Klein: Ampel + Status + nächster Zug
    private var smallView: some View {
        VStack(spacing: 8) {
            MiniTrafficLight(status: entry.status)
            Text(entry.status.label)
                .font(.caption).bold()
                .foregroundStyle(entry.status.color)
            if let first = entry.nextTrains.first {
                Text(timeText(first))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .containerBackground(.fill.tertiary, for: .widget)
    }

    // Mittel: Ampel links | Züge rechts
    private var mediumView: some View {
        HStack(spacing: 16) {

            // --- Linke Seite: Ampel ---
            VStack(spacing: 6) {
                MiniTrafficLight(status: entry.status)
                Text(entry.status.label)
                    .font(.caption).bold()
                    .foregroundStyle(entry.status.color)
                    .multilineTextAlignment(.center)
                    .frame(width: 75)
            }

            Divider()

            // --- Rechte Seite: Züge ---
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
                        Text(timeText(train))
                            .font(.caption).bold()
                            .foregroundStyle(minuteColor(train.minutesUntil))
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

    private func timeText(_ train: WidgetTrain) -> String {
        let m = train.minutesUntil
        if m < 0   { return "passiert" }
        if m < 1   { return "< 1 min" }
        return "in \(Int(m)) min"
    }

    private func minuteColor(_ m: Double) -> Color {
        if m < 1 { return .red }
        if m < 3 { return .orange }
        return .secondary
    }
}

// Kleine Ampel: drei Kreise übereinander
struct MiniTrafficLight: View {
    let status: WidgetStatus

    var body: some View {
        VStack(spacing: 4) {
            dot(.red,    active: status == .closed)
            dot(.yellow, active: status == .warning)
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

// MARK: - Minimaler XML Parser (eigenständig für Widget-Target)

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
        case "tl": if current?["dp"] == nil { current?["trainNumber"] = a["n"] ?? "" }
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
