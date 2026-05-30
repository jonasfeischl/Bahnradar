import SwiftUI
import Combine

struct SchrankenModeView: View {
    @State private var recorder = CrossingRecorder()
    @State private var showHistory = false
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
                    selectTypeView
                }

                Spacer()

                // Historie
                if !recorder.records.isEmpty {
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
                            .padding(.horizontal)
                    }
                    .sheet(isPresented: $showHistory) {
                        CrossingHistoryView(records: recorder.records)
                    }
                }
            }
            .navigationTitle("Schranken-Modus")
            .navigationBarTitleDisplayMode(.inline)
            .onReceive(timer) { _ in tick += 1 }  // View jede Sekunde neu zeichnen
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

            Button {
                recorder.markClosed()
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
                recorder.markOpen()
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

    // MARK: - Zugtyp auswählen

    private var selectTypeView: some View {
        VStack(spacing: 20) {
            Image(systemName: "questionmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.orange)

            Text("Was ist gefahren?")
                .font(.title2.bold())

            Text("Wähle den Zugtyp aus der\ndie Schranke ausgelöst hat.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            VStack(spacing: 12) {
                ForEach(RecordedTrainType.allCases, id: \.self) { type in
                    Button {
                        recorder.confirmType(type)
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: type.icon)
                                .font(.title3)
                            Text(type.rawValue)
                                .font(.title3.bold())
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 18)
                        .padding(.horizontal, 20)
                        .background(Color(.secondarySystemBackground))
                        .foregroundStyle(.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                }
            }
            .padding(.horizontal)

            Button("Abbrechen", role: .cancel) {
                recorder.cancel()
            }
            .foregroundStyle(.secondary)
            .padding(.top, 4)
        }
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
    let records: [CrossingRecord]
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
            List(records) { record in
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
                }
                .padding(.vertical, 4)
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Aufzeichnungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    SchrankenModeView()
}
