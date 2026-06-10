import SwiftUI
import Charts

struct DailyPatternView: View {
    let records: [CrossingRecord]
    @Environment(\.dismiss) private var dismiss

    // MARK: - Datenmodell

    private struct HourData: Identifiable {
        let id   = UUID()
        let hour: Int
        let count: Int
        let avgDurationSeconds: Double

        var hourLabel: String {
            String(format: "%02d:00", hour)
        }
        var avgDurationText: String {
            let m = Int(avgDurationSeconds) / 60
            let s = Int(avgDurationSeconds) % 60
            return m > 0 ? "⌀ \(m) min \(s) s" : "⌀ \(s) s"
        }
        // Farbe nach durchschnittlicher Sperrdauer
        var color: Color {
            if avgDurationSeconds < 60  { return .green }
            if avgDurationSeconds < 120 { return .yellow }
            return .red
        }
    }

    private var hourlyData: [HourData] {
        var groups: [Int: [TimeInterval]] = [:]
        for record in records {
            guard let duration = record.duration, duration > 0 else { continue }
            let hour = Calendar.current.component(.hour, from: record.closedAt)
            groups[hour, default: []].append(duration)
        }
        return groups.map { hour, durations in
            HourData(
                hour: hour,
                count: durations.count,
                avgDurationSeconds: durations.reduce(0, +) / Double(durations.count)
            )
        }
        .sorted { $0.hour < $1.hour }
    }

    private var totalRecordings: Int { records.filter { $0.openedAt != nil }.count }

    private var busiestHour: HourData? { hourlyData.max(by: { $0.count < $1.count }) }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Group {
                if hourlyData.isEmpty {
                    ContentUnavailableView(
                        "Noch keine Daten",
                        systemImage: "chart.bar.xaxis",
                        description: Text("Zeichne Schranken-Schließungen im Schranken-Modus auf um Tages-Muster zu sehen.")
                    )
                } else {
                    ScrollView {
                        VStack(spacing: 20) {
                            summaryCards
                            chartSection
                            listSection
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Tages-Muster")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }

    // MARK: - Summary Cards

    private var summaryCards: some View {
        HStack(spacing: 12) {
            summaryCard(
                value: "\(totalRecordings)",
                label: "Aufzeichnungen",
                icon: "list.bullet.clipboard",
                color: .blue
            )
            if let busiest = busiestHour {
                summaryCard(
                    value: busiest.hourLabel,
                    label: "Häufigste Zeit",
                    icon: "clock.fill",
                    color: .orange
                )
            }
            if let avgAll = averageAllDuration {
                summaryCard(
                    value: durationShort(avgAll),
                    label: "Ø Sperrdauer",
                    icon: "timer",
                    color: .red
                )
            }
        }
    }

    private func summaryCard(value: String, label: String, icon: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
            Text(value)
                .font(.title2.bold())
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Chart

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Schließungen pro Stunde")
                .font(.headline)

            Chart(hourlyData) { entry in
                BarMark(
                    x: .value("Uhrzeit", entry.hourLabel),
                    y: .value("Anzahl",  entry.count)
                )
                .foregroundStyle(entry.color)
                .cornerRadius(4)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: 1)) { value in
                    if let label = value.as(String.self) {
                        // Nur jede 3. Stunde beschriften damit es nicht zu voll wird
                        let hour = Int(label.prefix(2)) ?? 0
                        if hour % 3 == 0 {
                            AxisValueLabel { Text(label) }
                        }
                    }
                    AxisGridLine()
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading)
            }
            .frame(height: 180)

            // Legende
            HStack(spacing: 16) {
                legendDot(.green,  "< 1 min")
                legendDot(.yellow, "1–2 min")
                legendDot(.red,    "> 2 min")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
        }
    }

    // MARK: - Liste

    private var listSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Details")
                .font(.headline)

            let data = hourlyData
            VStack(spacing: 8) {
                ForEach(Array(data.enumerated()), id: \.element.id) { index, entry in
                    HStack(spacing: 12) {
                        Circle()
                            .fill(entry.color)
                            .frame(width: 10, height: 10)

                        Text(entry.hourLabel)
                            .font(.subheadline.bold())
                            .frame(width: 54, alignment: .leading)

                        Text("\(entry.count)×")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Spacer()

                        Text(entry.avgDurationText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 4)
                    if index < data.count - 1 {
                        Divider()
                    }
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Hilfsfunktionen

    private var averageAllDuration: Double? {
        let durations = records.compactMap { $0.duration }.filter { $0 > 0 }
        guard !durations.isEmpty else { return nil }
        return durations.reduce(0, +) / Double(durations.count)
    }

    private func durationShort(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return m > 0 ? "\(m)m \(s)s" : "\(s)s"
    }
}
