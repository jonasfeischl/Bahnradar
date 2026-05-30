import SwiftUI

struct ContentView: View {
    @State private var viewModel         = CrossingViewModel()
    @State private var drivingDetector   = DrivingDetector()
    @State private var locationMonitor   = LocationMonitor()
    @State private var voiceAnnouncer    = VoiceAnnouncer()
    @State private var lastSpokenStatus: CrossingStatus? = nil
    @State private var showFeedbackSheet = false
    @State private var feedbackNote = ""

    private var voiceActive: Bool {
        drivingDetector.isDriving && locationMonitor.isNearCrossing
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            NavigationStack {
                ScrollView {
                    VStack(spacing: 24) {
                        statusHeader
                        trafficLight
                        statusLabel
                        voiceBadge
                        if viewModel.isLoading && viewModel.nextEvents.isEmpty {
                            ProgressView("Lade Zugdaten...")
                        }
                        if let error = viewModel.errorMessage {
                            errorBanner(error)
                        }
                        upcomingTrainsList
                        feedbackButtons
                        disclaimer
                    }
                    .padding()
                }
                .navigationTitle("Schrankenradar OSH")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { refreshButton }
            }
        }
        .task {
            viewModel.startAutoRefresh()
            drivingDetector.start()
        }
        .onDisappear {
            viewModel.stopAutoRefresh()
            drivingDetector.stop()
            locationMonitor.stop()
        }
        // Standort nur aktivieren wenn gefahren wird
        .onChange(of: drivingDetector.isDriving) { _, driving in
            if driving { locationMonitor.start() } else { locationMonitor.stop() }
        }
        // Bei jedem Ampelwechsel Voice-Callout (nur wenn aktiv)
        .onChange(of: viewModel.worstUpcomingStatus) { _, newStatus in
            guard voiceActive, newStatus != lastSpokenStatus else { return }
            lastSpokenStatus = newStatus
            let next = viewModel.nextEvents.first { $0.minutesUntil > 0 }
            voiceAnnouncer.announce(status: newStatus, nextEvent: next)
        }
    }

    // MARK: - Subviews

    private var statusHeader: some View {
        VStack(spacing: 4) {
            Text("Bahnübergang Dachauer Str.")
                .font(.headline)
            if let updated = viewModel.lastUpdated {
                Text("Aktualisiert \(updated.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var trafficLight: some View {
        TrafficLightView(status: viewModel.worstUpcomingStatus)
    }

    private var statusLabel: some View {
        let status = viewModel.worstUpcomingStatus
        return HStack(spacing: 8) {
            Image(systemName: status.systemImage)
                .foregroundStyle(status.color)
            Text(status.label)
                .font(.title3)
                .fontWeight(.semibold)
        }
        .animation(.easeInOut, value: status)
    }

    // Zeigt ob Voice-Callouts gerade aktiv sind
    @ViewBuilder
    private var voiceBadge: some View {
        if drivingDetector.isDriving {
            HStack(spacing: 6) {
                Image(systemName: voiceActive ? "speaker.wave.2.fill" : "location.slash")
                    .foregroundStyle(voiceActive ? .green : .orange)
                Text(voiceActive
                     ? "Sprachansagen aktiv"
                     : "Außerhalb von Oberschleißheim")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(.secondarySystemBackground))
            .clipShape(Capsule())
        }
    }

    private var upcomingTrainsList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Nächste Züge")
                .font(.headline)
                .padding(.bottom, 2)
            if viewModel.nextEvents.isEmpty && !viewModel.isLoading {
                Text("Keine Züge in den nächsten 90 Minuten.")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            } else {
                ForEach(viewModel.nextEvents.prefix(8)) { event in
                    TrainEventRow(event: event)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var feedbackButtons: some View {
        VStack(spacing: 10) {
            Text("Stimmt die Anzeige?")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                Button {
                    viewModel.feedback.submitCorrect()
                } label: {
                    Label("Stimmt", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.green.opacity(0.15))
                        .foregroundStyle(.green)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                Button {
                    feedbackNote = ""
                    showFeedbackSheet = true
                } label: {
                    Label("Stimmt nicht", systemImage: "xmark.circle.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.red.opacity(0.15))
                        .foregroundStyle(.red)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .sheet(isPresented: $showFeedbackSheet) {
                    FeedbackSheet(
                        note: $feedbackNote,
                        currentStatus: viewModel.worstUpcomingStatus
                    ) { note in
                        viewModel.feedback.submitIncorrect(
                            currentStatus: viewModel.worstUpcomingStatus,
                            note: note
                        )
                        Task { await viewModel.fetchData() }
                    }
                }
            }

            if let message = viewModel.feedback.lastFeedbackMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
                    .animation(.easeInOut, value: message)
            }

            if viewModel.feedback.feedbackCount > 0 {
                Text("Gelernt aus \(viewModel.feedback.feedbackCount) Rückmeldungen · Versatz \(Int(viewModel.feedback.offsetAdjustment > 0 ? viewModel.feedback.offsetAdjustment : -viewModel.feedback.offsetAdjustment))s \(viewModel.feedback.offsetAdjustment >= 0 ? "früher" : "später")")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var disclaimer: some View {
        Text("Hinweis: Güterzüge und Sonderfahrten können nicht erfasst werden. Alle Angaben sind Schätzungen.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack {
            Image(systemName: "wifi.slash")
            Text(message)
                .font(.subheadline)
        }
        .foregroundStyle(.white)
        .padding()
        .background(Color.red)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ToolbarContentBuilder
    private var refreshButton: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                Task { await viewModel.fetchData() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(viewModel.isLoading)
        }
    }
}

// MARK: - Train Event Row

struct TrainEventRow: View {
    let event: CrossingEvent

    var body: some View {
        HStack {
            Circle()
                .fill(event.status.color)
                .frame(width: 12, height: 12)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(event.train.lineName)
                        .font(.subheadline)
                        .fontWeight(.bold)
                    Text(event.train.resolvedDirection.label)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if event.train.delayMinutes > 0 {
                    Text("+\(event.train.delayMinutes) min Verspätung")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(event.estimatedCrossingTime, style: .time)
                    .font(.subheadline)
                    .fontWeight(.medium)
                timeUntilLabel
            }
        }
        .padding(.vertical, 4)
    }

    private var timeUntilLabel: some View {
        let minutes = event.minutesUntil
        let seconds = Int(minutes * 60)

        if minutes < -0.5 {
            return AnyView(
                Text("passiert")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            )
        } else if minutes < 1 {
            return AnyView(
                Text(":\(String(format: "%02d", max(0, seconds)))")
                    .font(.system(.title, design: .monospaced).bold())
                    .foregroundStyle(.red)
                    .contentTransition(.numericText())
            )
        } else {
            let color: Color = minutes < 3 ? .orange : .secondary
            return AnyView(
                Text("in \(Int(minutes)) min")
                    .font(.caption)
                    .foregroundStyle(color)
            )
        }
    }
}

// MARK: - Feedback Sheet

struct FeedbackSheet: View {
    @Binding var note: String
    let currentStatus: CrossingStatus
    let onSubmit: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Was war falsch?")
                        .font(.headline)
                    Text("Aktuelle Anzeige: \(currentStatus.emoji) \(currentStatus.label)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Beschreibung (optional)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("z.B. „Schranke war 2 min zu früh rot" oder „Zug kam nicht"",
                              text: $note, axis: .vertical)
                        .lineLimit(3...6)
                        .padding(12)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                // Schnellauswahl-Chips
                VStack(alignment: .leading, spacing: 8) {
                    Text("Schnellauswahl")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    FlowLayout(spacing: 8) {
                        ForEach(quickOptions, id: \.self) { option in
                            Button(option) {
                                note = option
                            }
                            .font(.caption)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(note == option ? Color.red.opacity(0.2) : Color(.secondarySystemBackground))
                            .foregroundStyle(note == option ? .red : .primary)
                            .clipShape(Capsule())
                        }
                    }
                }

                Spacer()

                Button {
                    onSubmit(note)
                    dismiss()
                } label: {
                    Text("Rückmeldung senden")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.red)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding()
            .navigationTitle("Stimmt nicht")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Abbrechen") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private let quickOptions = [
        "Schranke zu früh rot",
        "Schranke zu früh grün",
        "Zug kam nicht",
        "Zug kam später",
        "Zug kam früher",
        "Güterzug nicht erkannt",
    ]
}

// Einfaches FlowLayout für die Chips
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        let height = rows.map { $0.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0 }
                         .reduce(0) { $0 + $1 + spacing } - spacing
        return CGSize(width: proposal.width ?? 0, height: max(0, height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            let rowHeight = row.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
            for subview in row {
                let size = subview.sizeThatFits(.unspecified)
                subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += rowHeight + spacing
        }
    }

    private func computeRows(proposal: ProposedViewSize, subviews: Subviews) -> [[LayoutSubview]] {
        let maxWidth = proposal.width ?? 0
        var rows: [[LayoutSubview]] = [[]]
        var rowWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth, !rows[rows.count - 1].isEmpty {
                rows.append([])
                rowWidth = 0
            }
            rows[rows.count - 1].append(subview)
            rowWidth += size.width + spacing
        }
        return rows
    }
}

#Preview {
    ContentView()
}
