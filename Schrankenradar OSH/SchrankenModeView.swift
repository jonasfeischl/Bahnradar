import SwiftUI
import Combine

struct SchrankenModeView: View {
    var viewModel: CrossingViewModel
    @State private var recorder = CrossingRecorder()
    @State private var showHistory = false
    @State private var showPattern = false
    @State private var tick = 0
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {

                Spacer()

                switch recorder.recorderState {
                case .idle:
                    idleView

                case .closed:
                    closedView

                case .selectingType:
                    EmptyView()  // wird nicht mehr verwendet

                case .confirmingTrains(_, let predicted):
                    confirmTrainsView(predicted: predicted)
                }

                Spacer()

                // Historie & Muster
                if !recorder.records.isEmpty {
                    VStack(spacing: 10) {
                        Button {
                            showHistory = true
                        } label: {
                            Label("Aufzeichnungen (\(recorder.records.count))", systemImage: "list.bullet.clipboard")
                                .font(.subheadline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color(.secondarySystemBackground))
                                .foregroundStyle(.secondary)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .sheet(isPresented: $showHistory) {
                            CrossingHistoryView(recorder: recorder, feedback: viewModel.feedback)
                        }

                        Button {
                            showPattern = true
                        } label: {
                            Label("Tages-Muster", systemImage: "chart.bar.xaxis")
                                .font(.subheadline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color(.secondarySystemBackground))
                                .foregroundStyle(.secondary)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .sheet(isPresented: $showPattern) {
                            DailyPatternView(records: recorder.records)
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .navigationTitle("Schranken-Modus")
            .navigationBarTitleDisplayMode(.inline)
            .onReceive(timer) { _ in tick += 1 }  // View jede Sekunde neu zeichnen
            .onAppear { recorder.switchCrossing(viewModel.store.selectedId) }
            .onChange(of: viewModel.store.selectedId) { _, newId in recorder.switchCrossing(newId) }
        }
    }

    // MARK: - Idle

    private var idleView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)

            Text("Schranke ist offen")
                .font(.title2.bold())

            Text("Drücke den Knopf sobald\ndie Schranke schließt.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            // Letztes Messergebnis anzeigen
            if let m = lastMeasurement {
                HStack(spacing: 8) {
                    Image(systemName: "ruler")
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        let dir = m.direction == .toMunich ? "→ München" : "→ Freising"
                        Text("Offset gemessen: **\(Int(m.offsetSec))s** (\(dir))")
                            .font(.subheadline)
                        Text("\(m.total) Messung\(m.total == 1 ? "" : "en") gespeichert")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        lastMeasurement = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .background(Color.blue.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            Button {
                recorder.markClosed(nextEvents: viewModel.nextEvents)
            } label: {
                Text("Schranke ZU 🔴")
                    .font(.title2.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .background(Color.red)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .padding(.horizontal)
            }
            .padding(.top, 8)
        }
    }

    // MARK: - Geschlossen (Timer läuft)

    private var closedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "xmark.octagon.fill")
                .font(.system(size: 64))
                .foregroundStyle(.red)

            Text("Schranke ist ZU")
                .font(.title2.bold())

            // Timer
            Text(timerText)
                .font(.system(size: 52, weight: .bold, design: .monospaced))
                .foregroundStyle(.red)
                .contentTransition(.numericText())
                .animation(.linear(duration: 0.3), value: tick)

            Button {
                recorder.markOpenAndConfirm(feedback: viewModel.feedback, allEvents: viewModel.nextEvents)
            } label: {
                Text("Schranke AUF 🟢")
                    .font(.title2.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .background(Color.green)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .padding(.horizontal)
            }
            .padding(.top, 8)

            Button("Abbrechen", role: .cancel) {
                recorder.cancel()
            }
            .foregroundStyle(.secondary)
        }
    }


    // MARK: - Zugbestätigung

    @State private var confirmedEvents: Set<String> = []
    @State private var lastMeasurement: MeasurementResult? = nil

    struct MeasurementResult {
        let offsetSec: Double
        let direction: TrainDirection
        let total: Int
    }

    @ViewBuilder
    private func confirmTrainsView(predicted: [CrossingEvent]) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.blue)

            Text(predicted.count == 1 ? "War der Zug da?" : "Welche Züge waren da?")
                .font(.title2.bold())

            Text("Bestätige welche Züge tatsächlich gefahren sind.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            VStack(spacing: 10) {
                ForEach(predicted) { event in
                    let confirmed = confirmedEvents.contains(event.id)
                    Button {
                        if confirmed {
                            confirmedEvents.remove(event.id)
                        } else {
                            confirmedEvents.insert(event.id)
                        }
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: confirmed ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(confirmed ? .green : .secondary)
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(event.train.lineName)
                                        .font(.subheadline.bold())
                                    directionBadge(event.train.resolvedDirection)
                                }
                                Text("Erwartet um \(timeString(event.estimatedCrossingTime))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(14)
                        .background(confirmed ? Color.green.opacity(0.1) : Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .foregroundStyle(.primary)
                }

                Divider()

                // Sonderzug / Güterzug Option
                Button {
                    confirmedEvents.insert("sonderzug")
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: confirmedEvents.contains("sonderzug") ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(confirmedEvents.contains("sonderzug") ? .orange : .secondary)
                            .font(.title3)
                        Text("Sonderzug / Güterzug war auch da")
                            .font(.subheadline)
                        Spacer()
                    }
                    .padding(14)
                    .background(confirmedEvents.contains("sonderzug") ? Color.orange.opacity(0.1) : Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .foregroundStyle(.primary)

                // Keiner war da
                Button {
                    confirmedEvents.removeAll()
                    recorder.confirmTrains(confirmed: [], feedback: viewModel.feedback)
                } label: {
                    Text("Keiner dieser Züge war da")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(14)
                        .background(Color(.secondarySystemBackground))
                        .foregroundStyle(.secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(.horizontal)

            // Bestätigen Button
            let hasRealSelection = !confirmedEvents.subtracting(["sonderzug"]).isEmpty
            let hasSonderzug     = confirmedEvents.contains("sonderzug")
            let canConfirm       = hasRealSelection || hasSonderzug

            Button {
                let confirmed = predicted.filter { confirmedEvents.contains($0.id) }
                confirmedEvents.removeAll()
                recorder.confirmTrains(confirmed: confirmed,
                                       sonderzug: hasSonderzug,
                                       feedback: viewModel.feedback)
                applyCalibrationIfReady()
                captureMeasurement()
            } label: {
                Text("Bestätigen ✓")
                    .font(.title3.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(canConfirm ? Color.blue : Color.gray)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal)
            }
            .disabled(!canConfirm)

            Button("Überspringen", role: .cancel) {
                confirmedEvents.removeAll()
                recorder.confirmTrains(confirmed: [], feedback: viewModel.feedback)
            }
            .foregroundStyle(.secondary)
        }
    }

    private func applyCalibrationIfReady() {
        var crossing = viewModel.selectedCrossing
        var updated  = false
        // Ab der ersten Messung sofort kalibrieren
        if let offset = recorder.calibratedClosingOffset(toMunich: true,  minSamples: 1) {
            crossing.measuredOffsetToMunich = offset
            updated = true
        }
        if let offset = recorder.calibratedClosingOffset(toMunich: false, minSamples: 1) {
            crossing.measuredOffsetToFreising = offset
            updated = true
        }
        let total = recorder.records.filter { $0.measuredClosingOffset != nil }.count
        crossing.gpsOffsetMeasurements = total
        if updated { viewModel.store.update(crossing) }
    }

    private func captureMeasurement() {
        guard let record = recorder.records.first,
              let offset = record.measuredClosingOffset,
              let toMunich = record.confirmedToMunich,
              abs(offset) < 300 else { return }
        let total = recorder.records.filter { $0.measuredClosingOffset != nil }.count
        lastMeasurement = MeasurementResult(
            offsetSec: offset,
            direction: toMunich ? .toMunich : .toFreising,
            total: total
        )
    }

    @ViewBuilder
    private func directionBadge(_ direction: TrainDirection) -> some View {
        let isMunich = direction == .toMunich
        Text(isMunich ? "→ München" : "→ Freising")
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(isMunich ? Color.blue.opacity(0.15) : Color.orange.opacity(0.15))
            .foregroundStyle(isMunich ? Color.blue : Color.orange)
            .clipShape(Capsule())
    }

    private static let _timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private func timeString(_ date: Date) -> String {
        Self._timeFmt.string(from: date)
    }

    // MARK: - Timer Text

    private var timerText: String {
        let s = recorder.elapsedSeconds
        let m = s / 60
        let sec = s % 60
        return String(format: "%02d:%02d", m, sec)
    }
}

// MARK: - Historie

struct CrossingHistoryView: View {
    let recorder: CrossingRecorder
    let feedback: FeedbackLearner
    @Environment(\.dismiss) private var dismiss

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .medium
        f.locale = Locale(identifier: "de_DE")
        return f
    }()

    var body: some View {
        NavigationStack {
            Group {
                if recorder.records.isEmpty {
                    ContentUnavailableView(
                        "Keine Aufzeichnungen",
                        systemImage: "list.bullet.clipboard",
                        description: Text("Noch keine Schranken aufgezeichnet.")
                    )
                } else {
                    List {
                        ForEach(recorder.records) { record in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Image(systemName: record.trainType?.icon ?? "questionmark.circle")
                                        .foregroundStyle(record.trainType == nil ? Color.secondary : Color.blue)
                                    Text(record.trainType?.rawValue ?? "Unbekannt")
                                        .font(.subheadline.bold())
                                    Spacer()
                                    Text(record.durationText)
                                        .font(.subheadline.bold())
                                        .foregroundStyle(.red)
                                }

                                Text("Zu: \(dateFormatter.string(from: record.closedAt))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                if let openedAt = record.openedAt {
                                    Text("Auf: \(dateFormatter.string(from: openedAt))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                if let delta = record.autoClosingDelta {
                                    Text("Lernkorrektur: \(delta > 0 ? "+" : "")\(Int(delta))s")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .onDelete { indexSet in
                            indexSet.forEach { recorder.delete(recorder.records[$0], feedback: feedback) }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Aufzeichnungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Fertig") { dismiss() }
                }
                if !recorder.records.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Alle löschen", role: .destructive) {
                            recorder.deleteAll(feedback: feedback)
                        }
                        .foregroundStyle(.red)
                    }
                }
            }
        }
    }
}

#Preview {
    SchrankenModeView(viewModel: CrossingViewModel())
}
