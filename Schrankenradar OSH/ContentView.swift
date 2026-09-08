import SwiftUI
import Combine
import CoreLocation

struct ContentView: View {
    var viewModel: CrossingViewModel
    var locationMonitor: LocationMonitor
    var voiceAnnouncer: VoiceAnnouncer
    var drivingDetector: DrivingDetector
    @State private var showFeedbackSheet  = false
    @State private var showFeedbackHistory = false
    @AppStorage("voiceEnabled") private var voiceEnabled: Bool = true
    @Environment(\.scenePhase) private var scenePhase
    @State private var now: Date = Date()
    @State private var showSidebar: Bool = false
    @State private var lastHapticStatus: CrossingStatus? = nil
    @State private var isInitialized = false
    @State private var wasInBackground = false
    @State private var backgroundGraceTask: Task<Void, Never>?
    /// Verhindert, dass Ampel/Status-Pille/Hintergrund beim App-Start sichtbar in ihren
    /// Zustand "einfliegen" — erst nach dem ersten Laden werden echte Statuswechsel animiert.
    @State private var statusAnimationsEnabled = false

    @AppStorage("hasSeenRadarIntro") private var hasSeenRadarIntro = false
    @State private var showRadarIntro = false
    /// Wird von Schrankenradar_OSHApp erst nach der kompletten Onboarding+Berechtigungs-
    /// Sequenz auf true gesetzt. ContentView wartet darauf, bevor es (a) selbst aktiv GPS für
    /// die Fahrzeiten-Karte anfordert und (b) den Radar-Intro-Screen zeigt — sonst würde
    /// ContentView.onAppear (Radar ist Standard-Tab, erscheint quasi sofort beim Kaltstart)
    /// der bewusst sequenzierten Berechtigungs-Abfrage zuvorkommen (Standort-Popup kam dadurch
    /// beobachtet vereinzelt statt geordnet nach Bewegung&Fitness) bzw. mit dem Onboarding-
    /// fullScreenCover kollidieren.
    @AppStorage("appStartupSequenceComplete") private var appStartupSequenceComplete = false
    @State private var isTrackingScreenPresence = false

    private var voiceActive: Bool {
        voiceEnabled && viewModel.isDriving && viewModel.isNearCrossing
    }

    /// Zuletzt berechnete Auto-Fahrzeit zur Schranke (von TravelTimesCard gemeldet) — steuert
    /// den Haken/Ausrufezeichen in der Zugliste ("schaffst du's noch vor Schließung").
    @State private var carETASeconds: TimeInterval?

    var body: some View {
        SidebarContainerView(isOpen: $showSidebar, store: viewModel.store) {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    statusHeader
                    safetyWarningBanner
                    VStack(spacing: 22) {
                        statusCard
                        TravelTimesCard(
                            crossing: viewModel.selectedCrossing,
                            locationMonitor: locationMonitor,
                            onCarETAUpdate: { carETASeconds = $0 }
                        )
                        badgeRow
                    }
                    if viewModel.isLoading && viewModel.nextEvents.isEmpty {
                        VStack(spacing: 6) {
                            ProgressView("Lade Zugdaten...")
                            Text("Kann beim ersten Start kurz dauern — bitte warten, bis die ersten Züge angezeigt werden.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 24)
                        }
                    }
                    if let error = viewModel.errorMessage {
                        errorBanner(error)
                    }
                    upcomingTrainsList
                    feedbackButtons
                    disclaimer
                    safetyDisclaimer
                }
                .padding()
            }
            .background(statusBackgroundTint.ignoresSafeArea())
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
            }
            .fullScreenCover(isPresented: $showRadarIntro) {
                FeatureIntroScreen(
                    icon: "antenna.radiowaves.left.and.right",
                    title: "Radar",
                    message: "Hier siehst du auf einen Blick, ob die Schranke am gewählten Bahnübergang bald schließt. Ampel, Fahrzeiten und die nächsten Züge zeigen dir alles Wichtige — wechsle den Übergang über das Menü oben links."
                ) {
                    hasSeenRadarIntro = true
                    showRadarIntro = false
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
                // viewModel.setup()/startAutoRefresh() sowie die Fahrterkennungs-Verdrahtung
                // (crossings/onAutoSwitch/onSpeedUpdate) werden zentral von der App-Ebene
                // ausgelöst (siehe Schrankenradar_OSHApp.swift) — genau wie drivingDetector.start(),
                // aus demselben Grund: der Radar-Tab ist beim allerersten Erscheinen manchmal
                // noch nicht "richtig" da bzw. später evtl. gar nicht aktiv, wodurch das sonst
                // nicht (mehr) korrekt lief.
                // Ampel/Status-Pille zeigen den Anfangszustand sofort ohne Überblendung.
                // Erst danach werden echte, während der Nutzung auftretende Statuswechsel animiert.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    statusAnimationsEnabled = true
                }
            } else {
                // Rückkehr vom Settings-Tab: nur DB-Fetch fortsetzen
                viewModel.resumeRefresh()
            }
            applyStartupGatedBehavior()
        }
        .onDisappear {
            // Tab-Wechsel: nur DB-Fetch pausieren, Geops NICHT trennen
            viewModel.pauseRefresh()
            if isTrackingScreenPresence {
                isTrackingScreenPresence = false
                locationMonitor.stopForScreenPresence()
            }
        }
        .onChange(of: appStartupSequenceComplete) { _, _ in
            applyStartupGatedBehavior()
        }
        .onChange(of: scenePhase) { _, phase in
            // WICHTIG: iOS durchläuft background → inactive → active. Eine Prüfung auf
            // oldPhase == .background verfehlt den Reconnect (Vorgänger von .active ist
            // .inactive). Darum mit wasInBackground-Flag arbeiten.
            switch phase {
            case .active:
                // Ein noch nicht ausgeführter Stopp (siehe .background unten) wird verworfen —
                // kehrt die App vor Ablauf der Gnadenfrist zurück, ist gar nichts passiert.
                backgroundGraceTask?.cancel()
                backgroundGraceTask = nil
                guard wasInBackground else { return }   // nur echter Hintergrund→Vordergrund
                wasInBackground = false
                // App aus Hintergrund: Geops reconnecten + alles neu starten
                viewModel.startAutoRefresh()
                drivingDetector.start()
                // LocationMonitor explizit neu starten falls isDriving schon true war —
                // onChange(isDriving) feuert sonst nicht (Wert unverändert).
                if viewModel.isDriving { locationMonitor.start() }

            case .background:
                // Kurze Unterbrechungen (z.B. das System-Dialog für die Standort-Berechtigung)
                // lassen die App kurz durch .background/.inactive laufen, obwohl der Nutzer sie
                // gar nicht verlassen hat. Ein sofortiges Trennen (DB-Polling, ggf. Geops) würde
                // dabei den gesamten Live-Zustand leeren (Fahrzeuge, Stopsequence-Zeiten) — beim
                // sofortigen Reconnect landen die Züge dann in einer neuen, leicht anderen
                // Zuordnung, was als Sprung in der Schrankenzeit sichtbar wurde. Darum erst nach
                // einer kurzen Gnadenfrist wirklich stoppen.
                backgroundGraceTask?.cancel()
                backgroundGraceTask = Task {
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled else { return }
                    wasInBackground = true
                    // Wert VOR dem Stoppen der Sensoren lesen
                    let wasDriving = viewModel.isDriving

                    // DB-Polling stoppt hier immer — dafür gibt's kein eigenes Hintergrund-
                    // Netzwerk-Setup. Geops wird unten NUR bei fehlender "Immer"-Berechtigung
                    // mitgetrennt (siehe dort); bereits geplante Ansage-Timer laufen so oder so
                    // mit den zuletzt bekannten Zeiten weiter (stopAutoRefresh cancelt sie nicht).
                    viewModel.stopAutoRefresh()

                    // Mit "Immer"-Standortberechtigung läuft die Sprachausgabe selbst im
                    // Hintergrund weiter (siehe LocationMonitor: allowsBackgroundLocationUpdates
                    // + UIBackgroundModes "location"/"audio") — dafür GPS/Fahrterkennung NICHT
                    // stoppen, sonst bricht genau das ab, was das erst ermöglicht. Aus demselben
                    // Grund bleibt Geops hier verbunden (der App-Prozess wird durch die aktiven
                    // Hintergrundmodi ohnehin am Leben gehalten) — Versuch, damit Ansagen im
                    // Hintergrund weiter aktuelle statt nur zuletzt bekannte Zeiten nutzen.
                    // Muss noch bei einer echten Fahrt mit gesperrtem Handy verifiziert werden,
                    // ob iOS die Verbindung wirklich durchgehend offen lässt. Ohne "Immer"-
                    // Freigabe (nur "Bei Nutzung" erlaubt) pausiert GPS im Hintergrund ohnehin
                    // durch iOS selbst — dann Geops und Sensoren bewusst mittrennen, kein
                    // Mitteilungs-Rückfall mehr bis die App wieder geöffnet wird.
                    if locationMonitor.authorizationStatus == .authorizedAlways {
                        // Hörbare Bestätigung bei jeder erkannten Fahrt, unabhängig von der
                        // Schranken-Nähe — die Bestätigung soll gerade VOR Ankunft an der
                        // Schranke zeigen, dass die App im Hintergrund mitläuft (nicht erst,
                        // wenn man ohnehin schon da ist). Nur beim simplen Wegwischen daheim
                        // (nicht am Fahren) bleibt sie bewusst aus.
                        if voiceEnabled && wasDriving {
                            voiceAnnouncer.announceBackgroundActive()
                        }
                    } else {
                        drivingDetector.stop()
                        locationMonitor.stop()
                        GeopsRealtimeService.shared.disconnect()
                    }
                }

            case .inactive:
                break   // kurze Unterbrechung (Banner etc.) → nichts tun

            @unknown default:
                break
            }
        }
        .onChange(of: viewModel.store.selectedId) { _, _ in
            viewModel.selectAndRefresh()
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
            Text(status.label)
                .fontWeight(.bold)
        }
        .font(.title3)
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(status.color, in: Capsule())
        .shadow(color: status.color.opacity(0.4), radius: 8, y: 3)
        .animation(statusAnimationsEnabled ? .easeInOut : nil, value: status)
    }

    private var statusCard: some View {
        VStack(spacing: 14) {
            TrafficLightView(status: viewModel.worstStatus(at: now), animated: statusAnimationsEnabled)
            statusLabel
            openingCountdown
        }
        .frame(maxWidth: .infinity)
    }

    /// Dezenter Farbverlauf im Hintergrund passend zum Status — macht den Zustand
    /// auch beim Reinschauen aus der Ferne sofort erkennbar (z.B. beim Losfahren).
    private var statusBackgroundTint: some View {
        let status = viewModel.worstStatus(at: now)
        return LinearGradient(
            colors: [status.color.opacity(0.12), Color(.systemGroupedBackground)],
            startPoint: .top,
            endPoint: .bottom
        )
        .animation(statusAnimationsEnabled ? .easeInOut(duration: 0.6) : nil, value: status)
    }

    private var badgeRow: some View {
        FlowLayout(spacing: 8) {
            accuracyBadge
            liveDataBadge
            voiceBadge
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Startup-Gate (GPS für Fahrzeiten-Karte + Radar-Intro)

    /// Startet GPS-Tracking für die Fahrzeiten-Karte und zeigt ggf. den Radar-Intro-Screen —
    /// aber NUR, wenn die App-Berechtigungs-Sequenz bereits durchgelaufen ist (siehe
    /// appStartupSequenceComplete-Kommentar oben). Wird sowohl bei jedem Erscheinen des Tabs
    /// als auch (für den Erststart-Fall) aufgerufen, sobald die Sequenz fertig wird.
    private func applyStartupGatedBehavior() {
        guard appStartupSequenceComplete else { return }
        if !isTrackingScreenPresence {
            isTrackingScreenPresence = true
            locationMonitor.startForScreenPresence()
        }
        if !hasSeenRadarIntro {
            showRadarIntro = true
        }
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

    /// Zeigt ein Banner wenn die App offline ist (Cache) oder die Daten > 2 Minuten alt sind.
    @ViewBuilder
    private var safetyWarningBanner: some View {
        if viewModel.isShowingCachedData {
            HStack(spacing: 8) {
                Image(systemName: "wifi.slash")
                VStack(alignment: .leading, spacing: 1) {
                    Text("Offline – letzte bekannte Daten")
                        .font(.caption.bold())
                    if let updated = viewModel.lastUpdated {
                        Text("Stand \(updated.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2)
                    }
                }
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
            .background(Color.gray)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(.easeInOut, value: viewModel.isShowingCachedData)
        } else if viewModel.dataIsStale {
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
                            Text("\(openTime, style: .time)")
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

        // Über offsetSource() statt direkt autoMeasurements-Felder lesen — sonst würde dieses
        // Badge für osh_dachauer weiterhin "Präzise/Kalibriert" (aus GPS-Messungen) behaupten,
        // obwohl bestOffset() diese Messungen seit dem GPS-Offset-Freeze (siehe
        // CrossingLocation.usesFrozenBase, 2026-07-20) für osh_dachauer gar nicht mehr nutzt —
        // die Anzeige basiert dort nur noch auf Community-/Standardwert + Hardcode.
        let localMunich    = crossing.offsetSource(
            toMunich: true,
            communityMunich: community?.munich, communityMunichCount: community?.munichCount ?? 0
        ) == .local
        let localFreising  = crossing.offsetSource(
            toMunich: false,
            communityFreising: community?.freising, communityFreisingCount: community?.freisingCount ?? 0
        ) == .local
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
            || feedback.communityVoteCount > 0
            || feedback.closingOffsetToMunich != 0
            || feedback.closingOffsetToFreising != 0            { return .learning }
        return .estimate
    }

    @State private var showAccuracyDetail = false

    /// Ob die NÄCHSTE relevante Vorhersage ein Zug ohne DB-Fahrplaneintrag ist (Güterzug/RE/RB,
    /// nur per Geops-Live-GPS erkannt, siehe buildEvents `isLiveData: true` für Nicht-S-Bahn-
    /// Züge) oder ein regulärer Fahrplan-Zug. nil = kein anstehender Zug → Badge ausblenden.
    /// Seit der Umstellung auf DB+MVG als alleinige Zeitquelle (2026-07-20 — GPS-Trajektorien
    /// waren in der Praxis ungenauer als DB/MVG) ist "Fahrplan" der verlässliche Normalfall,
    /// nicht mehr die unsichere Ausweichlösung.
    /// WICHTIG: `event.isLiveData` allein reicht hier NICHT — bei einem regulären S-Bahn-Zug
    /// wird es einfach nur bei frischer GPS-Bestätigung true (buildEvents: `hasFreshVehicle`),
    /// unabhängig davon, ob überhaupt ein DB-Fahrplaneintrag existiert. Zeigte dadurch fälschlich
    /// "Live-GPS" für ganz normale, DB/MVG-basierte S-Bahn-Züge (User-Report 2026-07-20:
    /// "manchmal kommt gps noch immer" — die Zeit selbst kommt weiterhin ausschließlich aus
    /// DB/MVG, nur das Badge suggerierte fälschlich etwas anderes). Echte GPS-only-Züge ohne
    /// Fahrplaneintrag bekommen in buildEvents die id `"freight_<tripId>"` — nur DAS ist das
    /// verlässliche Signal für "kein Fahrplaneintrag, nur Live-GPS".
    private var nextEventIsLive: Bool? {
        let upcoming = viewModel.nextEvents
            .filter { $0.minutesUntil(from: now) > -1 }
            .sorted { $0.estimatedCrossingTime < $1.estimatedCrossingTime }
        guard let next = upcoming.first else { return nil }
        return next.id.hasPrefix("freight_")
    }

    @ViewBuilder
    private var liveDataBadge: some View {
        if let isLive = nextEventIsLive {
            let color: Color = isLive ? .secondary : .green
            HStack(spacing: 5) {
                Image(systemName: isLive ? "dot.radiowaves.left.and.right" : "calendar")
                    .foregroundStyle(color)
                Text(isLive ? "Live-GPS" : "Fahrplan")
                    .font(.caption)
                    .foregroundStyle(color)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(color.opacity(0.1))
            .clipShape(Capsule())
            .accessibilityLabel(isLive
                ? "Zug ohne Fahrplaneintrag, nur per Live-GPS erkannt"
                : "Vorhersage beruht auf Fahrplan- und Echtzeitdaten")
        }
    }

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

    /// nextEvents hält einen gerade durchgefahrenen Zug noch kurz (keepWindow = openingDelay+30s
    /// in CrossingViewModel.buildEvents) — nötig, damit Ampel/Status nicht direkt nach der
    /// Durchfahrt zurückspringen. Für DIESE Liste ist das aber verwirrend: so ein Zug hat die
    /// früheste estimatedCrossingTime von allen und stand dadurch als "erster Zug" ganz oben,
    /// obwohl er schon durchgefahren ist (Uhrzeit liegt sichtbar in der Vergangenheit). Deshalb
    /// hier zusätzlich gefiltert — Ampel/Status bleiben unberührt, die lesen weiter nextEvents.
    private var displayedTrainEvents: [CrossingEvent] {
        viewModel.nextEvents.filter { $0.minutesUntil(from: now) > -0.5 }
    }

    private var upcomingTrainsList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Nächste Züge")
                .font(.headline)
                .padding(.bottom, 2)
            if displayedTrainEvents.isEmpty && !viewModel.isLoading {
                Text("Keine Züge in den nächsten 90 Minuten.")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            } else {
                // 90-Min-Fenster voll anzeigen (vorher prefix(8) ≈ nur ~50 min).
                // nextEvents ist durch den Fetch bereits zeitlich auf 90 min begrenzt;
                // das Limit 40 ist nur ein Sicherheitsnetz gegen Ausreißer.
                ForEach(Array(displayedTrainEvents.prefix(40).enumerated()), id: \.element.id) { index, event in
                    if index > 0 { Divider() }
                    TrainEventRow(event: event, now: now, carETASeconds: carETASeconds)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .cardStyle()
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
        .cardStyle()
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
                apiDot(color: GeopsRealtimeService.shared.connectionDisplayColor,
                       label: "Geops Live")
                apiDot(color: MVGService.shared.connectionDisplayColor,
                       label: "MVV")
                apiDot(color: viewModel.feedback.isCloudConnected ? .green : .red,
                       label: "Cloud")
            }
        }
    }

    private var safetyDisclaimer: some View {
        VStack(spacing: 6) {
            Label("Keine sicherheitsrelevante Anwendung", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.bold())
                .foregroundStyle(.orange)
            Text("Diese App liefert unverbindliche Schätzungen auf Basis von Fahrplan- und GPS-Daten. Sie ersetzt nicht die eigene Aufmerksamkeit und Vorsicht am Bahnübergang. Verlasse dich beim Überqueren ausschließlich auf die Schranken- und Signalanlage vor Ort, nicht auf diese App.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.orange.opacity(0.25), lineWidth: 1)
        )
        .padding(.horizontal)
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
    /// Aktuelle Auto-Fahrzeit zur Schranke (von TravelTimesCard), für den Haken/Ausrufezeichen
    /// unten. nil solange noch keine GPS-Position/Fahrzeit vorliegt — dann kein Icon.
    var carETASeconds: TimeInterval? = nil

    /// true = du schaffst es noch vor Schließung, false = knapp/zu spät, nil = keine Aussage
    /// möglich (keine Fahrzeit bekannt) oder Zug schon durchgefahren.
    private var makesItInTime: Bool? {
        guard let carETASeconds, event.minutesUntil(from: now) > 0 else { return nil }
        // Schranke beginnt laut CrossingEvent.status(at:) ab 1.5 Minuten vor Durchfahrt zu
        // schließen (Status .warning/.closed) — "rechtzeitig" heißt also: Ankunft VOR diesem
        // Zeitpunkt, nicht erst vor der eigentlichen Zugdurchfahrt.
        let secondsUntilClosing = event.minutesUntil(from: now) * 60 - 90
        return carETASeconds < secondsUntilClosing
    }

    @ViewBuilder
    private var makeItIcon: some View {
        if let makesItInTime {
            Image(systemName: makesItInTime ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(makesItInTime ? .green : .orange)
                .accessibilityLabel(makesItInTime
                    ? "Mit dem Auto schaffst du es rechtzeitig"
                    : "Mit dem Auto schaffst du es knapp nicht mehr rechtzeitig")
        }
    }

    var body: some View {
        HStack {
            Circle()
                .fill(event.status(at: now).color)
                .frame(width: 10, height: 10)
            makeItIcon

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(event.train.lineName)
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 6))
                    Text("→ \(event.train.direction)")
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
        } else if minutes < 2 {
            // Sekundengenau statt in ganzen Minuten anzeigen — vorher blieb "in 2 min" bis zu
            // 60s lang unverändert stehen und sprang dann abrupt auf "in 1 min", statt flüssig
            // runterzuzählen. Gerade kurz vor Schrankenschließung soll das smooth ticken.
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
            let sizes    = row.map { $0.sizeThatFits(.unspecified) }
            let rowWidth = sizes.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(0, row.count - 1))
            // Jede Zeile horizontal zentrieren statt links auszurichten — wirkt bei
            // wenigen kurzen Badges deutlich aufgeräumter als ein Linksblock.
            var x = bounds.minX + max(0, (bounds.width - rowWidth) / 2)
            let rowHeight = sizes.map(\.height).max() ?? 0
            for (subview, size) in zip(row, sizes) {
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


