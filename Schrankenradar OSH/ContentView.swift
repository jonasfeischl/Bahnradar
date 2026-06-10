import SwiftUI
import Combine

struct ContentView: View {
    var viewModel: CrossingViewModel
    var locationMonitor: LocationMonitor
    var voiceAnnouncer: VoiceAnnouncer
    @State private var drivingDetector = DrivingDetector()
    @State private var rotationAngle: Double = 0
    @State private var showFeedbackSheet  = false
    @State private var showFeedbackHistory = false
    @AppStorage("voiceEnabled") private var voiceEnabled: Bool = true
    @Environment(\.scenePhase) private var scenePhase
    @State private var now: Date = Date()
    @State private var showSidebar: Bool = false
    @State private var lastHapticStatus: CrossingStatus? = nil
    @State private var isInitialized = false

    private var voiceActive: Bool {
        voiceEnabled && viewModel.isDriving && viewModel.isNearCrossing
    }

    var body: some View {
        SidebarContainerView(isOpen: $showSidebar, store: viewModel.store) {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    statusHeader
                    safetyWarningBanner
                    TrafficLightView(status: viewModel.worstStatus(at: now))
                    statusLabel
                    openingCountdown
                    accuracyBadge
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
            .navigationTitle(viewModel.selectedCrossing.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        withAnimation(.easeOut(duration: 0.25)) { showSidebar = true }
                    } label: {
                        Image(systemName: "line.3.horizontal")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        withAnimation(.linear(duration: 0.6)) { rotationAngle += 360 }
                        Task { await viewModel.fetchData() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .rotationEffect(.degrees(rotationAngle))
                    }
                    .disabled(viewModel.isLoading)
                }
            }
        }
        } // SidebarContainerView
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { date in
            now = date
            triggerHapticIfNeeded()
        }
        .onAppear {
            if !isInitialized {
                // Einmaliges Setup beim allerersten Start
                isInitialized = true
                viewModel.setup(voiceAnnouncer: voiceAnnouncer)
                viewModel.startAutoRefresh()
                drivingDetector.start()
                locationMonitor.crossings = viewModel.store.crossings
                locationMonitor.onAutoSwitch = { crossing in
                    guard viewModel.store.selectedId != crossing.id else { return }
                    viewModel.store.select(crossing)
                    Task { await viewModel.fetchData() }
                }
            } else {
                // Rückkehr vom Settings-Tab: nur DB-Fetch fortsetzen
                viewModel.resumeRefresh()
            }
        }
        .onDisappear {
            // Tab-Wechsel: nur DB-Fetch pausieren, Geops NICHT trennen
            viewModel.pauseRefresh()
        }
        .onChange(of: scenePhase) { oldPhase, phase in
            if phase == .active && oldPhase == .background {
                // App aus Hintergrund: Geops reconnecten + alles neu starten
                viewModel.startAutoRefresh()
                drivingDetector.start()
            } else if phase == .background {
                // App geht in Hintergrund: alles stoppen
                viewModel.stopAutoRefresh()
                drivingDetector.stop()
                locationMonitor.stop()
            }
        }
        .onChange(of: drivingDetector.isDriving) { _, driving in
            if driving { locationMonitor.start() } else { locationMonitor.stop() }
            viewModel.isDriving = driving
        }
        .onChange(of: locationMonitor.isNearCrossing) { _, near in
            viewModel.isNearCrossing = near
        }
        .onChange(of: viewModel.store.selectedId) { _, _ in
            Task { await viewModel.fetchData() }
        }
    }

    // MARK: - Subviews

    private var statusHeader: some View {
        VStack(spacing: 4) {
            Text(viewModel.selectedCrossing.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let updated = viewModel.lastUpdated {
                Text("Aktualisiert \(updated.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusLabel: some View {
        let status = viewModel.worstStatus(at: now)
        return HStack(spacing: 8) {
            Image(systemName: status.systemImage)
                .foregroundStyle(status.color)
            Text(status.label)
                .font(.title3)
                .fontWeight(.semibold)
        }
        .animation(.easeInOut, value: status)
    }

    // MARK: - Haptisches Feedback

    private func triggerHapticIfNeeded() {
        let current = viewModel.worstStatus(at: now)
        guard current != lastHapticStatus else { return }
        defer { lastHapticStatus = current }

        // Nur haptisch wenn der Nutzer fährt und in der Nähe ist
        guard viewModel.isDriving && viewModel.isNearCrossing else { return }

        switch current {
        case .closed:
            // Doppel-Schlag: Alarm-Muster
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            }
        case .warning:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .opening:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .open:
            if lastHapticStatus == .closed || lastHapticStatus == .opening {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        }
    }

    // MARK: - Sicherheits-Banner

    /// Zeigt ein Banner wenn die DB-Daten > 2 Minuten alt sind.
    @ViewBuilder
    private var safetyWarningBanner: some View {
        if viewModel.dataIsStale {
            HStack(spacing: 8) {
                Image(systemName: "clock.badge.exclamationmark")
                Text("Daten veraltet – Aktualität nicht garantiert")
                    .font(.caption.bold())
                Spacer()
                Button {
                    Task { await viewModel.fetchData() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption.bold())
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.orange)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(.easeInOut, value: viewModel.dataIsStale)
        }
    }

    // MARK: - Öffnungs-Countdown + Zugfolge

    @ViewBuilder
    private var openingCountdown: some View {
        let status     = viewModel.worstStatus(at: now)
        let chainCount = viewModel.chainedTrainCount(at: now)
        let openTime   = viewModel.estimatedOpeningTime(at: now)

        if status == .closed || status == .opening {
            VStack(spacing: 6) {
                // Zugfolge-Badge
                if chainCount > 1 {
                    HStack(spacing: 6) {
                        Image(systemName: "tram.fill.tunnel")
                            .foregroundStyle(.orange)
                        Text("\(chainCount) Züge in Folge")
                            .font(.caption.bold())
                            .foregroundStyle(.orange)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Color.orange.opacity(0.12))
                    .clipShape(Capsule())
                }

                // Öffnungszeit
                if let openTime {
                    let secsUntil = Int(openTime.timeIntervalSince(now))
                    if secsUntil > 0 {
                        HStack(spacing: 5) {
                            Image(systemName: "lock.open.fill")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                            Text("Öffnet ~")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            + Text("\(openTime, style: .time)")
                                .font(.caption.bold())
                                .foregroundStyle(.primary)
                            Text("(in \(secsUntil)s)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .contentTransition(.numericText())
                        }
                    } else {
                        Label("Öffnet gleich", systemImage: "lock.open.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
            }
        }
    }

    // MARK: - Genauigkeits-Indikator

    private enum AccuracyLevel {
        case estimate, learning, calibrated, precise

        var label: String {
            switch self {
            case .estimate:   return "Schätzung"
            case .learning:   return "Gelernt"
            case .calibrated: return "Kalibriert"
            case .precise:    return "Präzise"
            }
        }
        var icon: String {
            switch self {
            case .estimate:   return "questionmark.circle"
            case .learning:   return "arrow.triangle.2.circlepath"
            case .calibrated: return "checkmark.circle"
            case .precise:    return "checkmark.circle.fill"
            }
        }
        var color: Color {
            switch self {
            case .estimate:   return .secondary
            case .learning:   return .orange
            case .calibrated: return .blue
            case .precise:    return .green
            }
        }
        var detail: String {
            switch self {
            case .estimate:   return "Noch keine eigenen Messungen. Nutze den Schranken-Modus um die Genauigkeit zu verbessern."
            case .learning:   return "Feedback vorhanden, aber noch zu wenig Aufzeichnungen für eine genaue Kalibrierung (mind. 3 pro Richtung)."
            case .calibrated: return "Eine Fahrtrichtung ist aus eigenen Aufzeichnungen kalibriert."
            case .precise:    return "Beide Fahrtrichtungen sind aus echten Messungen kalibriert. Höchste Genauigkeit."
            }
        }
    }

    private var accuracyLevel: AccuracyLevel {
        let crossing  = viewModel.selectedCrossing
        let feedback  = viewModel.feedback
        let community = viewModel.communityOffsets[crossing.id]

        let localMunich    = crossing.autoMeasurementsMunich >= 3
        let localFreising  = crossing.autoMeasurementsFreising >= 3
        let commMunich     = community?.munich != nil
        let commFreising   = community?.freising != nil

        // Präzise: beide Richtungen aus eigenen Messungen kalibriert
        if localMunich && localFreising                         { return .precise }
        // Kalibriert: eine Richtung lokal ODER beide aus Community
        if localMunich || localFreising                         { return .calibrated }
        if commMunich && commFreising                           { return .calibrated }
        // Lernend: Community-Daten für eine Richtung ODER manuelles Feedback
        if commMunich || commFreising                           { return .learning }
        if feedback.feedbackCount > 0
            || feedback.closingOffsetToMunich != 0
            || feedback.closingOffsetToFreising != 0            { return .learning }
        return .estimate
    }

    @State private var showAccuracyDetail = false

    private var accuracyBadge: some View {
        let level = accuracyLevel
        return Button {
            showAccuracyDetail = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: level.icon)
                    .foregroundStyle(level.color)
                Text(level.label)
                    .font(.caption)
                    .foregroundStyle(level.color)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(level.color.opacity(0.1))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showAccuracyDetail) {
            accuracyDetailSheet
        }
    }

    private var accuracyDetailSheet: some View {
        let level    = accuracyLevel
        let crossing = viewModel.selectedCrossing
        let feedback = viewModel.feedback
        return NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: level.icon)
                            .font(.largeTitle)
                            .foregroundStyle(level.color)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(level.label)
                                .font(.headline)
                            Text(level.detail)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Messungen") {
                    accuracyRow(
                        label: "→ München",
                        value: crossing.measuredOffsetToMunich.map { "\(Int($0))s gemessen" } ?? "Schätzwert",
                        calibrated: crossing.measuredOffsetToMunich != nil
                    )
                    accuracyRow(
                        label: "→ Freising",
                        value: crossing.measuredOffsetToFreising.map { "\(Int($0))s gemessen" } ?? "Schätzwert",
                        calibrated: crossing.measuredOffsetToFreising != nil
                    )
                }

                Section("Korrekturen (Cloud)") {
                    accuracyRow(label: "Allgemein",    value: offsetText(feedback.closingOffsetAdjustment), calibrated: feedback.closingOffsetAdjustment != 0)
                    accuracyRow(label: "→ München",    value: offsetText(feedback.closingOffsetToMunich),   calibrated: feedback.closingOffsetToMunich != 0)
                    accuracyRow(label: "→ Freising",   value: offsetText(feedback.closingOffsetToFreising), calibrated: feedback.closingOffsetToFreising != 0)
                    accuracyRow(label: "Öffnungsverzögerung", value: offsetText(feedback.openingDelayAdjustment), calibrated: feedback.openingDelayAdjustment != 0)
                }

                Section {
                    Text("Nutze den **Schranken-Modus** um eigene Messungen aufzuzeichnen. Ab 3 Messungen pro Richtung kalibriert sich die App automatisch.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Genauigkeit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fertig") { showAccuracyDetail = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func accuracyRow(label: String, value: String, calibrated: Bool) -> some View {
        HStack {
            Text(label).foregroundStyle(.primary)
            Spacer()
            Text(value)
                .foregroundStyle(calibrated ? .blue : .secondary)
                .font(.subheadline)
        }
    }

    private func offsetText(_ value: Double) -> String {
        guard value != 0 else { return "Kein Wert" }
        return value > 0 ? "+\(Int(value))s" : "\(Int(value))s"
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
                     : "Nicht in der Nähe der \(viewModel.selectedCrossing.name) Schranke")
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
                    TrainEventRow(event: event, now: now)
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
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
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
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
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
        VStack(spacing: 8) {
            Text("Güterzüge und Sonderfahrten können nicht erfasst werden. Alle Angaben sind Schätzungen.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            // API-Status-Leiste
            HStack(spacing: 16) {
                apiDot(color: viewModel.dbConnected ? .green : .red,
                       label: "DB Fahrplan")
                apiDot(color: GeopsRealtimeService.shared.connectionState.color,
                       label: "Geops Live")
                apiDot(color: viewModel.feedback.isCloudConnected ? .green : .red,
                       label: "Cloud")
            }
        }
    }

    private func apiDot(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
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

}


// MARK: - Train Event Row

struct TrainEventRow: View {
    let event: CrossingEvent
    let now: Date

    var body: some View {
        HStack {
            Circle()
                .fill(event.status(at: now).color)
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
                HStack(spacing: 4) {
                    Text("Abfahrt \(event.train.actualTime, style: .time)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if event.train.delayMinutes > 0 {
                        Text("+\(event.train.delayMinutes) min")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
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
        let minutes = event.minutesUntil(from: now)
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

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Header
                VStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.orange)
                    Text("Was hat nicht gestimmt?")
                        .font(.title3.bold())
                    Text("Dein Feedback hilft der App genauer zu werden.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 24)
                .padding(.bottom, 28)

                // Buttons
                VStack(spacing: 12) {
                    feedbackRow(
                        title: "App wurde zu früh rot",
                        subtitle: "Schranke war noch offen",
                        icon: "chevron.left.2",
                        color: .orange
                    ) { learner.submitTooEarlyRed() }

                    feedbackRow(
                        title: "App wurde zu spät rot",
                        subtitle: "Schranke war schon geschlossen",
                        icon: "chevron.right.2",
                        color: .red
                    ) { learner.submitTooLateRed() }

                    Divider().padding(.vertical, 4)

                    feedbackRow(
                        title: "App wurde zu früh grün",
                        subtitle: "Schranke war noch geschlossen",
                        icon: "chevron.left.2",
                        color: .orange
                    ) { learner.submitTooEarlyGreen() }

                    feedbackRow(
                        title: "App wurde zu spät grün",
                        subtitle: "Schranke war schon offen",
                        icon: "chevron.right.2",
                        color: .green
                    ) { learner.submitTooLateGreen() }
                }
                .padding(.horizontal)

                Spacer()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Abbrechen") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private func feedbackRow(
        title: String,
        subtitle: String,
        icon: String,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            action()
            onDone()
            dismiss()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title3.bold())
                    .foregroundStyle(color)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.bold())
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
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


