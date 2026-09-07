import SwiftUI
import Combine

struct SchrankenModeView: View {
    var viewModel: CrossingViewModel
    var locationMonitor: LocationMonitor
    @State private var recorder = CrossingRecorder()
    @State private var showHistory = false
    @State private var showPattern = false
    @State private var tick = 0
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    @AppStorage("hasSeenSchrankenModeIntro") private var hasSeenSchrankenModeIntro = false
    @State private var showIntro = false

    /// Ab dieser Entfernung gilt man als "an der Schranke" — verhindert, dass Messungen
    /// aus der Ferne eingespeist werden und die geteilten Community-Daten verfälschen.
    /// Nutzt den vom Nutzer pro Übergang konfigurierten Radius (Einstellungen → Radius)
    /// statt eines fest einprogrammierten Werts — sonst kann "in der Nähe" hier etwas
    /// anderes bedeuten als der Radius, den der Nutzer selbst eingestellt hat.
    private var presenceRadius: Double {
        viewModel.selectedCrossing.radiusMeters
    }

    private var distanceToCrossing: Double? {
        locationMonitor.distance(to: viewModel.selectedCrossing)
    }

    private var isAtCrossing: Bool {
        guard let distance = distanceToCrossing else { return false }
        return distance <= presenceRadius
    }

    var body: some View {
        NavigationStack {
            Group {
                if isAtCrossing {
                    ScrollView {
                        VStack(spacing: 24) {

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

                            // Historie & Muster
                            if !recorder.records.isEmpty {
                                VStack(spacing: 10) {
                                    Button {
                                        showHistory = true
                                    } label: {
                                        Label("Aufzeichnungen (\(recorder.records.count))", systemImage: "list.bullet.clipboard")
                                            .font(.subheadline)
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 14)
                                            .foregroundStyle(.secondary)
                                    }
                                    .cardStyle()

                                    Button {
                                        showPattern = true
                                    } label: {
                                        Label("Tages-Muster", systemImage: "chart.bar.xaxis")
                                            .font(.subheadline)
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 14)
                                            .foregroundStyle(.secondary)
                                    }
                                    .cardStyle()
                                }
                            }

                            purposeExplanation
                        }
                        .padding()
                        .padding(.top, 40)
                    }
                } else {
                    notAvailableView
                }
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Schranken-Modus")
            .navigationBarTitleDisplayMode(.inline)
            .onReceive(timer) { _ in tick += 1 }  // View jede Sekunde neu zeichnen
            .onAppear {
                recorder.switchCrossing(viewModel.store.selectedId)
                locationMonitor.startForScreenPresence()
                if !hasSeenSchrankenModeIntro {
                    showIntro = true
                }
            }
            .onDisappear {
                locationMonitor.stopForScreenPresence()
            }
            .onChange(of: viewModel.store.selectedId) { _, newId in recorder.switchCrossing(newId) }
            // Bewusst hier auf dem stabilen NavigationStack statt an den Buttons weiter oben,
            // die nur sichtbar sind wenn `!recorder.records.isEmpty` — sonst reißt "Alle
            // löschen" (CrossingHistoryView-Toolbar, leert recorder.records) die if-Bedingung
            // um, während das Sheet noch offen ist, und SwiftUI wirft das Sheet mitten in der
            // Interaktion ab statt den jetzt-leeren Zustand darin anzuzeigen.
            .sheet(isPresented: $showHistory) {
                CrossingHistoryView(recorder: recorder, feedback: viewModel.feedback)
            }
            .sheet(isPresented: $showPattern) {
                DailyPatternView(records: recorder.records)
            }
            .fullScreenCover(isPresented: $showIntro) {
                FeatureIntroScreen(
                    icon: "record.circle",
                    title: "Schranken-Modus",
                    message: "Hier zeichnest du live auf, wann eine Schranke schließt und wieder öffnet. Drücke „Schranke ZU“ sobald du sie live schließen siehst, und „Schranke AUF“ sobald sie wieder öffnet. Aus diesen echten Messungen lernt die App und wird für alle genauer.\n\nDamit die Daten stimmen, funktioniert der Schranken-Modus nur, wenn du dich wirklich in der Nähe der Schranke befindest."
                ) {
                    hasSeenSchrankenModeIntro = true
                    showIntro = false
                }
            }
        }
    }

    // MARK: - Nicht verfügbar (außerhalb des Radius)

    /// Wie weit man dem 100m-Radius schon nähergekommen ist, für die Fortschrittsanzeige
    /// unten (0 = sehr weit weg oder unbekannt, 1 = am Rand des Radius). Auf das
    /// 5-fache des Radius gedeckelt, damit die Anzeige bei z.B. 5km nicht komplett leer wirkt.
    private var approachProgress: Double {
        guard let distance = distanceToCrossing else { return 0 }
        let cappedRange = presenceRadius * 5
        return 1 - min(1, max(0, (distance - presenceRadius) / (cappedRange - presenceRadius)))
    }

    private var notAvailableView: some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer(minLength: 24)

                ZStack {
                    Circle()
                        .fill(Color.brand.opacity(0.15))
                        .frame(width: 108, height: 108)
                    Image(systemName: "location.slash.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(Color.brand)
                        .symbolRenderingMode(.hierarchical)
                }

                VStack(spacing: 8) {
                    Text("Nicht verfügbar")
                        .font(.title2.bold())
                    Text("Du bist noch nicht an \(viewModel.selectedCrossing.name)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 14) {
                    if let distance = distanceToCrossing {
                        VStack(spacing: 8) {
                            HStack {
                                Text("Entfernung")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("ca. \(Int(distance)) m")
                                    .font(.subheadline.bold().monospacedDigit())
                            }
                            ProgressView(value: approachProgress)
                                .tint(Color.brand)
                            HStack {
                                Text("0 m")
                                Spacer()
                                Text("\(Int(presenceRadius)) m Radius")
                            }
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        }
                    } else {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Standort wird ermittelt…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 4)
                    }
                }
                .padding(16)
                .cardStyle()

                VStack(alignment: .leading, spacing: 10) {
                    Label("Warum nur vor Ort?", systemImage: "checkmark.shield.fill")
                        .font(.subheadline.bold())
                        .foregroundStyle(Color.brand)
                    Text("Der Schranken-Modus funktioniert nur direkt an der Schranke (im Umkreis von \(Int(presenceRadius))m). So bleiben die Messungen echt — niemand kann aus der Ferne falsche Aufzeichnungen einspeisen und die geteilten Daten für alle verfälschen.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .cardStyle()

                Spacer(minLength: 24)
            }
            .padding()
        }
    }

    // MARK: - Zweck-Erklärung

    private var purposeExplanation: some View {
        VStack(spacing: 6) {
            Label("Wofür ist der Schranken-Modus?", systemImage: "info.circle.fill")
                .font(.caption.bold())
                .foregroundStyle(.blue)
            Text("Drücke „Schranke ZU“ und „Schranke AUF“ wenn du live an der Schranke stehst und sie tatsächlich schließen bzw. öffnen siehst. Aus diesen echten Messungen lernt die App und wird für alle genauer.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.blue.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.blue.opacity(0.2), lineWidth: 1)
        )
    }

    // MARK: - Idle

    private var idleView: some View {
        VStack(spacing: 20) {
            VStack(spacing: 14) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(.green)
                    .symbolRenderingMode(.hierarchical)

                Text("Schranke ist offen")
                    .font(.title2.bold())

                Text("Drücke den Knopf sobald\ndie Schranke schließt.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
            .cardStyle()

            // Letztes Messergebnis anzeigen
            if let m = lastMeasurement {
                HStack(spacing: 10) {
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
                .padding(14)
                .background(Color.blue.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            Button {
                recorder.markClosed(nextEvents: viewModel.nextEvents)
            } label: {
                Label("Schranke ZU", systemImage: "xmark.octagon.fill")
            }
            .buttonStyle(.bigAction(.red))
        }
    }

    // MARK: - Geschlossen (Timer läuft)

    private var closedView: some View {
        VStack(spacing: 20) {
            VStack(spacing: 14) {
                Image(systemName: "xmark.octagon.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(.red)
                    .symbolRenderingMode(.hierarchical)

                Text("Schranke ist ZU")
                    .font(.title2.bold())

                // Timer
                Text(timerText)
                    .font(.system(size: 52, weight: .bold, design: .monospaced))
                    .foregroundStyle(.red)
                    .contentTransition(.numericText())
                    .animation(.linear(duration: 0.3), value: tick)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
            .cardStyle()

            Button {
                recorder.markOpenAndConfirm(feedback: viewModel.feedback, allEvents: viewModel.nextEvents)
            } label: {
                Label("Schranke AUF", systemImage: "checkmark.circle.fill")
            }
            .buttonStyle(.bigAction(.green))

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
            VStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(.blue)
                    .symbolRenderingMode(.hierarchical)

                Text(predicted.count == 1 ? "War der Zug da?" : "Welche Züge waren da?")
                    .font(.title2.bold())

                Text("Bestätige welche Züge tatsächlich gefahren sind.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .cardStyle()

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
                Label("Bestätigen", systemImage: "checkmark")
            }
            .buttonStyle(.bigAction(canConfirm ? .blue : .gray))
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
    SchrankenModeView(viewModel: CrossingViewModel(), locationMonitor: LocationMonitor())
}
