import SwiftUI

struct ContentView: View {
    @State private var viewModel         = CrossingViewModel()
    @State private var drivingDetector   = DrivingDetector()
    @State private var locationMonitor   = LocationMonitor()
    @State private var voiceAnnouncer    = VoiceAnnouncer()
    @State private var lastSpokenStatus: CrossingStatus? = nil
    @State private var showFeedbackSheet  = false
    @State private var showFeedbackHistory = false

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
                    FeedbackSheet(learner: viewModel.feedback) {
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
                Text(viewModel.feedback.debugDescription)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            // Mein Feedback
            if !viewModel.feedback.history.isEmpty {
                Button {
                    showFeedbackHistory = true
                } label: {
                    Label("Mein Feedback (\(viewModel.feedback.history.count))", systemImage: "list.bullet.clipboard")
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color(.tertiarySystemBackground))
                        .foregroundStyle(.secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .sheet(isPresented: $showFeedbackHistory) {
                    FeedbackHistoryView(learner: viewModel.feedback)
                }
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
                Text("\(max(0, seconds))s")
                    .font(.caption)
                    .fontWeight(.medium)
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
    let learner: FeedbackLearner
    let onDone: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var stepInput: String = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 24) {

                Text("Was hat nicht gestimmt?")
                    .font(.headline)

                // --- Schrittgröße ---
                HStack(spacing: 8) {
                    Text("Schrittgröße:")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextField("\(Int(learner.stepSeconds))s", text: $stepInput)
                        .keyboardType(.numberPad)
                        .frame(width: 60)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .onChange(of: stepInput) { _, newValue in
                            if let val = Double(newValue), val > 0 {
                                learner.saveStepSeconds(val)
                            }
                        }
                    Text("Sekunden pro Korrektur")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .onAppear { stepInput = "\(Int(learner.stepSeconds))" }

                // --- Schranke: Schließen ---
                VStack(alignment: .leading, spacing: 10) {
                    Label("Schranke schließen", systemImage: "arrow.down.to.line")
                        .font(.subheadline.bold())
                        .foregroundStyle(.red)

                    HStack(spacing: 12) {
                        feedbackButton(
                            title: "Zu früh rot",
                            subtitle: "App zeigte rot, Schranke war noch offen",
                            icon: "clock.badge.xmark",
                            color: .orange
                        ) {
                            learner.submitTooEarlyRed()
                        }

                        feedbackButton(
                            title: "Zu spät rot",
                            subtitle: "Schranke war schon zu, App noch grün",
                            icon: "clock.badge.checkmark",
                            color: .red
                        ) {
                            learner.submitTooLateRed()
                        }
                    }
                }

                Divider()

                // --- Schranke: Öffnen ---
                VStack(alignment: .leading, spacing: 10) {
                    Label("Schranke öffnen", systemImage: "arrow.up.to.line")
                        .font(.subheadline.bold())
                        .foregroundStyle(.green)

                    HStack(spacing: 12) {
                        feedbackButton(
                            title: "Zu früh grün",
                            subtitle: "App zeigte grün, Schranke war noch zu",
                            icon: "clock.badge.xmark",
                            color: .orange
                        ) {
                            learner.submitTooEarlyGreen()
                        }

                        feedbackButton(
                            title: "Zu spät grün",
                            subtitle: "Schranke war schon offen, App noch rot",
                            icon: "clock.badge.checkmark",
                            color: .green
                        ) {
                            learner.submitTooLateGreen()
                        }
                    }
                }

                Spacer()

                Text(learner.debugDescription)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding()
            .navigationTitle("Korrektur")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Abbrechen") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    @ViewBuilder
    private func feedbackButton(
        title: String,
        subtitle: String,
        icon: String,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
            onDone()
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(color)
                Text(title)
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(color.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

// MARK: - Feedback History

struct FeedbackHistoryView: View {
    let learner: FeedbackLearner
    @Environment(\.dismiss) private var dismiss

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        f.locale = Locale(identifier: "de_DE")
        return f
    }()

    var body: some View {
        NavigationStack {
            Group {
                if learner.history.isEmpty {
                    ContentUnavailableView(
                        "Kein Feedback",
                        systemImage: "list.bullet.clipboard",
                        description: Text("Du hast noch kein Feedback gegeben.")
                    )
                } else {
                    List {
                        ForEach(learner.history) { entry in
                            HStack(spacing: 12) {
                                Image(systemName: entry.type.icon)
                                    .foregroundStyle(color(for: entry.type))
                                    .font(.title3)
                                    .frame(width: 28)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.type.label)
                                        .font(.subheadline)
                                    Text(dateFormatter.string(from: entry.date))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if entry.type != .correct {
                                        Text("\(Int(entry.stepUsed))s angepasst")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }

                                Spacer()

                                if entry.type != .correct {
                                    Button {
                                        learner.undo(entry: entry)
                                    } label: {
                                        Image(systemName: "arrow.uturn.backward.circle")
                                            .foregroundStyle(.blue)
                                            .font(.title3)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Mein Feedback")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Fertig") { dismiss() }
                }
                if !learner.history.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Alles zurücksetzen", role: .destructive) {
                            learner.resetLearning()
                            dismiss()
                        }
                        .foregroundStyle(.red)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func color(for type: FeedbackEntryType) -> Color {
        switch type.color {
        case "green":  .green
        case "red":    .red
        case "orange": .orange
        default:       .secondary
        }
    }
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
