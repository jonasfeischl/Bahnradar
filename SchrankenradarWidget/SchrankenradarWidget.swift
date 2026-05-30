import WidgetKit
import SwiftUI

// MARK: - Timeline Entry

struct CrossingEntry: TimelineEntry {
    let date: Date
    let status: WidgetStatus
    let nextTrains: [WidgetTrain]
    let offsetSeconds: Double
}

enum WidgetStatus: String, Codable {
    case open, warning, closed

    var color: Color {
        switch self {
        case .open:    .green
        case .warning: .yellow
        case .closed:  .red
        }
    }
    var label: String {
        switch self {
        case .open:    "Offen"
        case .warning: "Schließt bald"
        case .closed:  "Geschlossen"
        }
    }
}

struct WidgetTrain: Codable {
    let line: String
    let direction: String  // "München" oder "Freising"
    let crossingTime: Date
    var minutesUntil: Double { crossingTime.timeIntervalSinceNow / 60 }
}

// MARK: - Provider

struct CrossingProvider: TimelineProvider {
    private let apiClientId = "647ab7f4b7e66f77ecb43a29c76e3b7b"
    private let apiKey      = "c281c9ce7da96fdb8571d714cdf4dab8"
    private let stationEVA  = "8004158"
    private let dbBase      = "https://apis.deutschebahn.com/db-api-marketplace/apis/timetables/v1"
    private let offsetSeconds: Double = 180

    func placeholder(in context: Context) -> CrossingEntry {
        CrossingEntry(date: .now, status: .open, nextTrains: placeholderTrains(), offsetSeconds: offsetSeconds)
    }

    func getSnapshot(in context: Context, completion: @escaping (CrossingEntry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
            return
        }
        Task {
            let entry = await fetchEntry()
            completion(entry)
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CrossingEntry>) -> Void) {
        Task {
            let entry = await fetchEntry()
            // Nächstes Update in 5 Minuten
            let next = Calendar.current.date(byAdding: .minute, value: 5, to: .now)!
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }

    private func fetchEntry() async -> CrossingEntry {
        guard let trains = try? await fetchTrains() else {
            return CrossingEntry(date: .now, status: .open, nextTrains: [], offsetSeconds: offsetSeconds)
        }
        let status = worstStatus(trains: trains)
        return CrossingEntry(date: .now, status: status, nextTrains: Array(trains.prefix(3)), offsetSeconds: offsetSeconds)
    }

    private func fetchTrains() async throws -> [WidgetTrain] {
        let now  = Date()
        let next = now.addingTimeInterval(3600)
        async let s1 = fetchStops(for: now)
        async let s2 = fetchStops(for: next)
        let stops = (try await s1) + (try await s2)

        return stops.compactMap { stop -> WidgetTrain? in
            guard let dp = stop["dp"] as? [String: String],
                  let pt = dp["pt"],
                  let planned = DateFormatter.dbTime.date(from: pt),
                  let lineRaw = dp["line"] else { return nil }
            let line = lineRaw.hasPrefix("S") ? lineRaw : "S\(lineRaw)"
            let path = dp["path"] ?? ""
            let dir  = isMunich(path) ? "München" : "Freising"
            let offset = isMunich(path) ? offsetSeconds : -offsetSeconds
            let crossingTime = planned.addingTimeInterval(offset)
            guard crossingTime.timeIntervalSinceNow > -30 else { return nil }
            return WidgetTrain(line: line, direction: dir, crossingTime: crossingTime)
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
        let lower = path.lowercased()
        return ["feldmoching","münchen","ostbahnhof","laim","pasing"].contains { lower.contains($0) }
    }

    private func worstStatus(trains: [WidgetTrain]) -> WidgetStatus {
        let upcoming = trains.filter { $0.minutesUntil > -0.5 && $0.minutesUntil < 5 }
        if upcoming.contains(where: { $0.minutesUntil <= 1 })  { return .closed }
        if upcoming.contains(where: { $0.minutesUntil <= 3 })  { return .warning }
        return .open
    }

    private func placeholderTrains() -> [WidgetTrain] {
        [
            WidgetTrain(line: "S1", direction: "München",  crossingTime: Date().addingTimeInterval(240)),
            WidgetTrain(line: "S1", direction: "Freising", crossingTime: Date().addingTimeInterval(480)),
        ]
    }
}

// MARK: - Widget Views

struct SchrankenradarWidgetEntryView: View {
    var entry: CrossingEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .systemSmall:  smallView
        default:            mediumView
        }
    }

    // Kleine Version: nur Ampel + Status
    private var smallView: some View {
        VStack(spacing: 8) {
            MiniTrafficLight(status: entry.status)
            Text(entry.status.label)
                .font(.caption2).bold()
                .foregroundStyle(entry.status.color)
                .multilineTextAlignment(.center)
            if let first = entry.nextTrains.first {
                Text(timeText(first))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .containerBackground(.fill.tertiary, for: .widget)
    }

    // Mittlere Version: Ampel links, Züge rechts
    private var mediumView: some View {
        HStack(spacing: 16) {
            // Linke Seite: Ampel
            VStack(spacing: 6) {
                MiniTrafficLight(status: entry.status)
                Text(entry.status.label)
                    .font(.caption2).bold()
                    .foregroundStyle(entry.status.color)
                    .multilineTextAlignment(.center)
                    .frame(width: 80)
            }

            Divider()

            // Rechte Seite: Züge
            VStack(alignment: .leading, spacing: 6) {
                Text("Nächste Züge")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ForEach(entry.nextTrains.prefix(3), id: \.crossingTime) { train in
                    HStack {
                        Text(train.line)
                            .font(.caption).bold()
                        Text("→ \(train.direction)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(timeText(train))
                            .font(.caption).bold()
                            .foregroundStyle(statusColor(train))
                    }
                }
                if entry.nextTrains.isEmpty {
                    Text("Keine Züge")
                        .font(.caption)
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
        if m < 0    { return "passiert" }
        if m < 1    { return ":\(String(format: "%02d", Int(m * 60)))s" }
        return "in \(Int(m)) min"
    }

    private func statusColor(_ train: WidgetTrain) -> Color {
        let m = train.minutesUntil
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
            circle(color: .red,    active: status == .closed)
            circle(color: .yellow, active: status == .warning)
            circle(color: .green,  active: status == .open)
        }
        .padding(8)
        .background(Color(.systemGray5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func circle(color: Color, active: Bool) -> some View {
        Circle()
            .fill(active ? color : color.opacity(0.15))
            .frame(width: 22, height: 22)
    }
}

// MARK: - Widget Definition

@main
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

// MARK: - Minimal XML Parser für Widget

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
        case "tl": current?["trainNumber"] = a["n"] ?? ""
        default: break
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
