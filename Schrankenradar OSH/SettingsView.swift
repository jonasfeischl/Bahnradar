import SwiftUI

struct SettingsView: View {
    var viewModel: CrossingViewModel
    @Bindable var locationMonitor: LocationMonitor
    var voiceAnnouncer: VoiceAnnouncer
    var drivingDetector: DrivingDetector

    @AppStorage("voiceEnabled") private var voiceEnabled: Bool = true
    @AppStorage("permissionsDeferred") private var permissionsDeferred = false
    @State private var showDeleteConfirmation = false
    @State private var showHelp = false
    @State private var isRequestingPermissions = false

    @AppStorage("hasSeenSettingsIntro") private var hasSeenSettingsIntro = false
    @State private var showSettingsIntro = false

    /// Ob der Admin-Bereich sichtbar ist (Diagnose + zukünftige Admin-Features, User-Ankündigung
    /// 2026-07-22: "mache bald noch mehr Features dazu"). Standardmäßig versteckt. Freigeschaltet
    /// wird er über ein Login (Nutzername+Passwort, `AdminLoginView`), dessen Geheim-Tipp-Ziel
    /// ganz unten in `HelpView` sitzt (der "?"-Hilfe-Screen, ganz bewusst NICHT hier in den
    /// Einstellungen selbst — ein Ort, an dem noch weniger jemand zufällig hin scrollt). Bleibt
    /// einmal erfolgreich eingeloggt auf diesem Gerät dauerhaft freigeschaltet.
    /// WICHTIG: das ist ein rein clientseitiges Gate (Zugangsdaten liegen im kompilierten
    /// Binary) — schützt vor zufälligem Finden durch Laien, nicht vor gezieltem Reverse
    /// Engineering. Für echte Zugriffskontrolle bräuchte es ein Server-seitiges Login, hier
    /// bewusst nicht gebaut, da es kein Backend mit Nutzerkonten gibt.
    @AppStorage("adminUnlocked") private var adminUnlocked = false
    /// Siehe gleichnamige Property in ContentView.swift — reaktives Signal statt einmaligem
    /// @State-Snapshot, damit der Intro-Screen auch dann korrekt erscheint, wenn die App nach
    /// dem Onboarding nur in den Hintergrund/Vordergrund wechselt statt komplett neu zu starten.
    @AppStorage("appStartupSequenceComplete") private var appStartupSequenceComplete = false

    var body: some View {
        @Bindable var store = viewModel.store
        NavigationStack {
            Form {

                // MARK: Berechtigungen
                // Nur sichtbar, wenn beim Onboarding "Später" gewählt wurde — sonst
                // wurden die Berechtigungen bereits dort abgefragt.
                if permissionsDeferred {
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Die App braucht zwei Berechtigungen, um dich automatisch zu warnen: Standort (wechselt zum nächsten Bahnübergang in deiner Nähe — bei der zweiten Standort-Abfrage bitte „Immer erlauben“ wählen, sonst funktionieren Sprachwarnungen nicht bei gesperrtem Bildschirm) und Bewegung & Fitness (erkennt Autofahrten für Sprachansagen).")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Button {
                                isRequestingPermissions = true
                                Task {
                                    await PermissionRequester.requestAll(
                                        viewModel: viewModel, locationMonitor: locationMonitor,
                                        drivingDetector: drivingDetector
                                    )
                                    isRequestingPermissions = false
                                    permissionsDeferred = false
                                }
                            } label: {
                                Label("Berechtigungen anfragen", systemImage: "checkmark.shield.fill")
                            }
                            .disabled(isRequestingPermissions)
                        }
                        .padding(.vertical, 4)
                    }
                }

                // MARK: Sprachansagen
                Section {
                    Toggle("Sprachansagen aktiv", isOn: $voiceEnabled)

                    Button {
                        testVoice()
                    } label: {
                        Label("Sprache testen", systemImage: "speaker.wave.2.fill")
                    }
                    .disabled(!voiceEnabled)

                } header: {
                    Text("Sprachansagen")
                } footer: {
                    Text("Sprachansagen werden automatisch ausgelöst wenn du fährst und dich in der Nähe der Schranke befindest.\n\nGenutzt wird eine natürlichere, direkt in der App eingebaute KI-Stimme — läuft komplett auf dem Gerät, keine Internetverbindung nötig. Bei Problemen hörst du automatisch die normale iOS-Stimme als Rückfalloption, nie Stille.")
                }

                // MARK: Bahnübergänge
                Section {
                    ForEach(0..<store.crossings.count, id: \.self) { index in
                        let crossing = store.crossings[index]
                        NavigationLink {
                            CrossingSettingsDetailView(viewModel: viewModel, index: index)
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(crossing.name)
                                        .font(.subheadline.bold())
                                    Text(crossing.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                HStack(spacing: 6) {
                                    if crossing.voiceEnabled {
                                        Image(systemName: "speaker.wave.2.fill")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(radiusLabel(crossing.radiusMeters))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                } header: {
                    Text("Bahnübergänge")
                } footer: {
                    Text("Tippe auf einen Übergang um Sprache, Radius und Ansage-Text anzupassen.")
                }

                // MARK: Lerndaten
                Section {
                    HStack {
                        Text("Feedbacks gegeben")
                        Spacer()
                        Text("\(viewModel.feedback.feedbackCount)")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Cloud Status")
                        Spacer()
                        HStack(spacing: 6) {
                            Circle()
                                .fill(viewModel.feedback.isCloudConnected ? Color.green : Color.red)
                                .frame(width: 8, height: 8)
                            Text(viewModel.feedback.isCloudConnected ? "Verbunden" : "Offline")
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Label("Meine Lerndaten löschen", systemImage: "trash")
                            .foregroundStyle(.red)
                    }
                    .confirmationDialog(
                        "Lerndaten wirklich löschen?",
                        isPresented: $showDeleteConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("Löschen", role: .destructive) {
                            viewModel.feedback.resetLocalLearning()
                        }
                        Button("Abbrechen", role: .cancel) { }
                    } message: {
                        Text("Nur deine eigenen Korrekturen werden gelöscht. Die geteilten Cloud-Daten anderer Nutzer bleiben erhalten.")
                    }

                } header: {
                    Text("Lerndaten")
                }

                // MARK: Admin (versteckt, siehe adminUnlocked-Kommentar oben) — hier kommen
                // laut Ankündigung künftig weitere Admin-Features dazu, nicht nur Diagnose.
                if adminUnlocked {
                    Section {
                        NavigationLink {
                            DebugLogView()
                        } label: {
                            HStack {
                                Label("Diagnose-Log", systemImage: "list.bullet.rectangle")
                                if DebugLog.shared.unseenIssueCount > 0 {
                                    Spacer()
                                    Text("\(DebugLog.shared.unseenIssueCount)")
                                        .font(.caption2.bold())
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 7).padding(.vertical, 2)
                                        .background(Color.red, in: Capsule())
                                }
                            }
                        }

                        Button {
                            MetricKitMonitor.shared.toggle()
                        } label: {
                            Label(
                                MetricKitMonitor.shared.isRunning ? "MetricKit stoppen" : "MetricKit starten",
                                systemImage: MetricKitMonitor.shared.isRunning ? "stop.circle" : "waveform.path.ecg"
                            )
                            .foregroundStyle(MetricKitMonitor.shared.isRunning ? .red : .accentColor)
                        }
                    } header: {
                        Text("Admin")
                    } footer: {
                        Text("Diagnose-Log protokolliert DB-Fahrplan-Abrufe, Geops-Live-GPS und die Berechnung der Durchfahrtszeit. Bei einem Problem: hier öffnen, „Kopieren“ tippen und den Text weitergeben.\n\nMetricKit beobachtet Hangs/Crashes im Hintergrund, auch unterwegs ohne Mac — nur solange aktiv, wie du es hier eingeschaltet lässt. Landet ebenfalls im Diagnose-Log.")
                    }
                }

            }
            .navigationTitle("Einstellungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showHelp = true
                    } label: {
                        Image(systemName: "questionmark.circle")
                    }
                }
            }
            .sheet(isPresented: $showHelp) {
                HelpView()
            }
            .onAppear {
                if appStartupSequenceComplete, !hasSeenSettingsIntro {
                    showSettingsIntro = true
                }
            }
            .onChange(of: appStartupSequenceComplete) { _, complete in
                if complete, !hasSeenSettingsIntro {
                    showSettingsIntro = true
                }
            }
            .fullScreenCover(isPresented: $showSettingsIntro) {
                FeatureIntroScreen(
                    icon: "gearshape.fill",
                    title: "Einstellungen",
                    message: "Hier kannst du den Bahnübergang wechseln, die Sprachansage anpassen, gelernte Zeiten zurücksetzen und bei Problemen die Diagnose öffnen und weitergeben."
                ) {
                    hasSeenSettingsIntro = true
                    showSettingsIntro = false
                }
            }
        }
    }

    private func radiusLabel(_ meters: Double) -> String {
        meters >= 1000 ? "\(Int(meters / 1000)) km" : "\(Int(meters))m"
    }

    private func testVoice() {
        let status = viewModel.worstUpcomingStatus
        let next = viewModel.nextEvents.first { $0.minutesUntil > 0 }
        voiceAnnouncer.announce(status: status, nextEvent: next,
                                 crossingName: viewModel.selectedCrossing.spokenCrossingName)
    }

}

// MARK: - Admin-Login

/// Nutzername/Passwort-Abfrage für den Admin-Bereich (Diagnose + künftige Admin-Features).
/// Nur über die Geheim-Tipp-Geste in SettingsView erreichbar, siehe adminUnlocked-Kommentar
/// dort — rein clientseitiges Gate, keine echte Zugriffskontrolle (es gibt kein Backend mit
/// Nutzerkonten), soll nur zufälliges Finden durch Laien verhindern.
private struct AdminLoginView: View {
    let onSuccess: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var username = ""
    @State private var password = ""
    @State private var showError = false

    // Feste Zugangsdaten (User-Vorgabe 2026-07-22) — bewusst hier hartkodiert statt in einer
    // Server-Prüfung, da es kein Backend/Nutzerkonten-System gibt.
    private static let validUsername = "Jowdmin"
    private static let validPassword = "qEjkox-cofgup-3jumqa"

    private var canSubmit: Bool { !username.isEmpty && !password.isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Nutzername", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Passwort", text: $password)
                } footer: {
                    if showError {
                        Text("Nutzername oder Passwort falsch.")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button("Anmelden") { submit() }
                        .disabled(!canSubmit)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .navigationTitle("Admin-Login")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Abbrechen") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func submit() {
        guard username == Self.validUsername, password == Self.validPassword else {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            showError = true
            password = ""
            return
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onSuccess()
    }
}

// MARK: - Bahnübergang-Detail

/// Detailansicht für einen einzelnen Bahnübergang — Erkennung (Sprache/Radius),
/// Timing-Kalibrierung und Ansage-Text. Ausgelagert aus der Hauptliste, damit die
/// Einstellungen-Übersicht bei mehreren Übergängen übersichtlich bleibt.
struct CrossingSettingsDetailView: View {
    var viewModel: CrossingViewModel
    let index: Int

    /// Nur eingeloggte Admins dürfen die gelernten Offsets zurücksetzen (User-Wunsch
    /// 2026-07-22) — sonst könnte ein Laie versehentlich echte, mühsam gesammelte
    /// Kalibrierungsdaten löschen. Gleicher Schlüssel wie in SettingsView/HelpView.
    @AppStorage("adminUnlocked") private var adminUnlocked = false

    var body: some View {
        @Bindable var store = viewModel.store
        let crossing = store.crossings[index]

        Form {
            Section("Erkennung") {
                Toggle("Sprachansage", isOn: $store.crossings[index].voiceEnabled)
                    .onChange(of: crossing.voiceEnabled) { _, _ in store.update(crossing) }

                Picker("Radius", selection: $store.crossings[index].radiusMeters) {
                    Text("200 m").tag(200.0)
                    Text("500 m").tag(500.0)
                    Text("1 km").tag(1000.0)
                    Text("2 km").tag(2000.0)
                }
                .onChange(of: crossing.radiusMeters) { _, _ in store.update(crossing) }
            }

            Section {
                offsetSection(index: index, crossing: crossing)
            } header: {
                Text("Timing")
            } footer: {
                Text("Zeitversatz zwischen Fahrplan und tatsächlichem Schließen der Schranke — wird automatisch aus GPS-Messungen gelernt.")
            }

            Section {
                Text("„\(crossing.spokenCrossingName) Wahrscheinlich geschlossen. Nächster Zug in 2 Minuten.“")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 2)
            } header: {
                Text("Ansage-Text")
            } footer: {
                Text("So klingt die Sprachansage — Übergang, Status und der nächste Zug, wenn einer absehbar ist.")
            }
        }
        .navigationTitle(crossing.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Offset-Sektion

    @ViewBuilder
    private func offsetSection(index: Int, crossing: CrossingLocation) -> some View {
        @Bindable var store = viewModel.store

        let community = viewModel.communityOffsets[crossing.id]
        DisclosureGroup {
            VStack(spacing: 26) {

                // → München
                directionOffsetRow(
                    label: "→ München",
                    measured: crossing.measuredOffsetToMunich,
                    localCount: crossing.autoMeasurementsMunich,
                    communityCount: community?.munichCount ?? 0,
                    source: crossing.offsetSource(toMunich: true, communityMunich: community?.munich, communityMunichCount: community?.munichCount ?? 0),
                    fallback: crossing.offsetToMunich,
                    binding: $store.crossings[index].offsetToMunich,
                    onStepperChange: { store.update(store.crossings[index]) }
                )

                // → Freising
                directionOffsetRow(
                    label: "→ Freising",
                    measured: crossing.measuredOffsetToFreising,
                    localCount: crossing.autoMeasurementsFreising,
                    communityCount: community?.freisingCount ?? 0,
                    source: crossing.offsetSource(toMunich: false, communityFreising: community?.freising, communityFreisingCount: community?.freisingCount ?? 0),
                    fallback: crossing.offsetToFreising,
                    binding: $store.crossings[index].offsetToFreising,
                    onStepperChange: { store.update(store.crossings[index]) }
                )

                // Sync-Status
                HStack(spacing: 6) {
                    syncStatusBadge(crossing: crossing, community: community)
                    Spacer()
                }

                // Reset PRO Richtung — ein gemeinsamer Reset für beide würde eine bereits
                // korrekte Richtung mit zurücksetzen, nur weil die andere daneben liegt
                // (genau das Szenario: München korrekt gelernt, Freising nicht).
                // Nur für eingeloggte Admins sichtbar (siehe adminUnlocked-Kommentar oben) —
                // sonst könnte jeder aus Versehen mühsam gesammelte Kalibrierungsdaten löschen.
                if adminUnlocked {
                    HStack(spacing: 16) {
                        if crossing.measuredOffsetToMunich != nil || viewModel.feedback.closingOffsetToMunich != 0 {
                            Button("München zurücksetzen") {
                                var c = crossing
                                c.measuredOffsetToMunich = nil
                                c.autoMeasurementsMunich = 0
                                store.update(c)
                                viewModel.feedback.resetDirectionalLearning(toMunich: true)
                            }
                            .font(.caption2)
                            .foregroundStyle(.red)
                        }
                        if crossing.measuredOffsetToFreising != nil || viewModel.feedback.closingOffsetToFreising != 0 {
                            Button("Freising zurücksetzen") {
                                var c = crossing
                                c.measuredOffsetToFreising = nil
                                c.autoMeasurementsFreising = 0
                                store.update(c)
                                viewModel.feedback.resetDirectionalLearning(toMunich: false)
                            }
                            .font(.caption2)
                            .foregroundStyle(.red)
                        }
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Image(systemName: offsetIcon(crossing))
                        .foregroundStyle(offsetColor(crossing))
                        .font(.caption)
                        .frame(width: 16)
                    Text("Timing")
                        .font(.subheadline)
                        .foregroundStyle(offsetColor(crossing))
                }
                Text(offsetSummary(crossing))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 24)
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - Offset-Hilfsviews

    @ViewBuilder
    private func directionOffsetRow(
        label: String,
        measured: Double?,
        localCount: Int,
        communityCount: Int,
        source: CrossingLocation.OffsetSource,
        fallback: Double,
        binding: Binding<Double>,
        onStepperChange: @escaping () -> Void
    ) -> some View {
        switch source {
        case .local:
            HStack(spacing: 8) {
                Text(label)
                    .font(.caption)
                    .frame(width: 80, alignment: .leading)
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.blue).font(.caption2)
                Text("\(Int(measured ?? fallback))s")
                    .font(.caption.bold()).foregroundStyle(.blue)
                Text("lokal (\(localCount)×)")
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

        case .community:
            HStack(spacing: 8) {
                Text(label)
                    .font(.caption)
                    .frame(width: 80, alignment: .leading)
                Image(systemName: "person.2.fill").foregroundStyle(.teal).font(.caption2)
                Text("\(Int(measured ?? fallback))s")
                    .font(.caption.bold()).foregroundStyle(.teal)
                Text("community (\(communityCount)×)")
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

        case .estimate:
            // Stepper bekommt die ganze Zeile — Label + Wert kompakt im Stepper-Label,
            // damit die +/- Buttons rechts nicht mit Text überlappen.
            Stepper(value: binding, in: -300...300, step: 5) {
                HStack(spacing: 6) {
                    Text(label)
                        .font(.caption)
                    Spacer(minLength: 4)
                    Text("\(Int(binding.wrappedValue))s")
                        .font(.caption.bold())
                        .monospacedDigit()
                    Text("Schätzung")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: binding.wrappedValue) { _, _ in onStepperChange() }
        }
    }

    @ViewBuilder
    private func syncStatusBadge(crossing: CrossingLocation, community: CommunityGPSOffsets?) -> some View {
        let localTotal = crossing.autoMeasurementsMunich + crossing.autoMeasurementsFreising
        let communityTotal = (community?.munichCount ?? 0) + (community?.freisingCount ?? 0)

        if !viewModel.gpsCloudSynced {
            Label("Synchronisiere…", systemImage: "icloud.and.arrow.down")
                .font(.caption2).foregroundStyle(.secondary)
        } else if localTotal > 0 || communityTotal > 0 {
            HStack(spacing: 4) {
                Image(systemName: "icloud.fill").foregroundStyle(.teal).font(.caption2)
                if localTotal > 0 {
                    Text("\(localTotal) lokal").font(.caption2).foregroundStyle(.blue)
                }
                if communityTotal > 0 {
                    Text("· \(communityTotal) community").font(.caption2).foregroundStyle(.teal)
                }
            }
        } else {
            Label("Noch keine GPS-Daten", systemImage: "location.slash")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func offsetIcon(_ c: CrossingLocation) -> String {
        let community = viewModel.communityOffsets[c.id]
        let src = [c.offsetSource(toMunich: true, communityMunich: community?.munich, communityMunichCount: community?.munichCount ?? 0),
                   c.offsetSource(toMunich: false, communityFreising: community?.freising, communityFreisingCount: community?.freisingCount ?? 0)]
        if src.allSatisfy({ $0 == .local }) { return "checkmark.seal.fill" }
        if src.contains(.local) || src.contains(.community) { return "checkmark.circle.fill" }
        return "ruler"
    }

    private func offsetColor(_ c: CrossingLocation) -> Color {
        let community = viewModel.communityOffsets[c.id]
        let src = [c.offsetSource(toMunich: true, communityMunich: community?.munich, communityMunichCount: community?.munichCount ?? 0),
                   c.offsetSource(toMunich: false, communityFreising: community?.freising, communityFreisingCount: community?.freisingCount ?? 0)]
        if src.contains(.local) { return .blue }
        if src.contains(.community) { return .teal }
        return .secondary
    }

    private func offsetSummary(_ c: CrossingLocation) -> String {
        let community = viewModel.communityOffsets[c.id]
        let mOff = c.bestOffset(toMunich: true, communityMunich: community?.munich, communityMunichCount: community?.munichCount ?? 0)
        let fOff = c.bestOffset(toMunich: false, communityFreising: community?.freising, communityFreisingCount: community?.freisingCount ?? 0)
        let mSrc = c.offsetSource(toMunich: true, communityMunich: community?.munich, communityMunichCount: community?.munichCount ?? 0)
        let fSrc = c.offsetSource(toMunich: false, communityFreising: community?.freising, communityFreisingCount: community?.freisingCount ?? 0)
        let mMark = mSrc == .estimate ? "" : " ✓"
        let fMark = fSrc == .estimate ? "" : " ✓"
        return "Mchn: \(Int(mOff))s\(mMark) · Fsg: \(Int(fOff))s\(fMark)"
    }
}

// MARK: - Hilfe

struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    // Geheim-Tipp-Ziel fürs Admin-Login (siehe adminUnlocked-Kommentar in SettingsView) —
    // dieselbe @AppStorage-Schlüssel wie dort, wird also geräteweit geteilt.
    @AppStorage("adminUnlocked") private var adminUnlocked = false
    @State private var showAdminLogin = false

    var body: some View {
        NavigationStack {
            List {
                helpSection(
                    icon: "antenna.radiowaves.left.and.right",
                    color: .blue,
                    title: "Radar Tab",
                    text: "Zeigt den aktuellen Status des ausgewählten Bahnübergangs. Die Ampel zeigt ob die Schranke vermutlich offen, schließt bald oder geschlossen ist — basierend auf echten Zugdaten der Deutschen Bahn."
                )

                helpSection(
                    icon: "line.3.horizontal",
                    color: .blue,
                    title: "Bahnübergänge wechseln",
                    text: "Tippe oben links auf die drei Striche um zwischen den Bahnübergängen zu wechseln. Die App wechselt auch automatisch wenn du in den Radius eines Übergangs fährst."
                )

                helpSection(
                    icon: "record.circle",
                    color: .red,
                    title: "Schranken-Modus",
                    text: "Hier kannst du manuell aufzeichnen wann die Schranke zu und wieder auf geht. Die App lernt automatisch aus deinen Beobachtungen und wird dadurch genauer. Funktioniert nur direkt an der Schranke (250m Umkreis) — so bleiben die geteilten Messdaten echt."
                )

                helpSection(
                    icon: "checkmark.circle.fill",
                    color: .green,
                    title: "Stimmt / Stimmt nicht",
                    text: "Mit diesen Buttons gibst du Feedback ob die Vorhersage korrekt war. Das hilft der App zu lernen. Dein Feedback wird mit allen Nutzern in der Cloud geteilt."
                )

                helpSection(
                    icon: "speaker.wave.2.fill",
                    color: .orange,
                    title: "Sprachansagen",
                    text: "Wenn du im Auto sitzt und dich in der Nähe eines Bahnübergangs befindest, sagt die App automatisch den Status an. Sprache und Radius können pro Übergang in den Einstellungen konfiguriert werden."
                )

                helpSection(
                    icon: "location.circle.fill",
                    color: .blue,
                    title: "Erkennungsradius",
                    text: "Jeder Bahnübergang hat seinen eigenen Radius. Bestimmt wie nah du sein musst damit Sprachansagen ausgelöst werden und die App automatisch wechselt. Einstellbar pro Übergang im Einstellungs-Tab."
                )

                helpSection(
                    icon: "brain",
                    color: .purple,
                    title: "Lerndaten",
                    text: "Die App lernt aus deinem Feedback. Die Lerndaten werden in der Cloud gespeichert und mit allen Nutzern geteilt — so wird die App für alle besser. Du kannst nur deine eigenen Daten löschen."
                )

                helpSection(
                    icon: "dot.radiowaves.left.and.right",
                    color: .green,
                    title: "Geops Live (GPS)",
                    text: "Die App empfängt die Live-GPS-Position der Züge in Echtzeit. Daraus wird der Schließzeitpunkt direkt aus der tatsächlichen Zugposition berechnet — viel genauer als aus dem Fahrplan allein. Der grüne Punkt unten zeigt, dass die Live-Verbindung steht."
                )

                helpSection(
                    icon: "scope",
                    color: .blue,
                    title: "Genauigkeit & Kalibrierung",
                    text: "Bei jeder Zugdurchfahrt misst die App per GPS den genauen Zeitversatz und kalibriert sich automatisch. Nach einigen Fahrten wird die Vorhersage präzise. Den aktuellen Stand siehst du am Genauigkeits-Abzeichen im Radar-Tab."
                )

                helpSection(
                    icon: "tram.fill.tunnel",
                    color: .orange,
                    title: "Andere Züge & Güterzüge",
                    text: "Nähert sich ein Zug der keine S-Bahn ist (z.B. Regionalbahn) und kreuzt den Übergang, erkennt die App ihn über GPS und zeigt ihn mit echtem Namen und Richtung an. Hinweis: Reine Güterzüge ohne öffentlichen Fahrplan können nicht immer erfasst werden."
                )

                helpSection(
                    icon: "apps.iphone",
                    color: .indigo,
                    title: "Homescreen-Widget",
                    text: "Das Homescreen-Widget übernimmt die genauen Live-Daten der App, solange diese kürzlich geöffnet war. Ohne aktuelle App-Daten greift es auf einen eigenen Fahrplan-Abruf zurück (etwas ungenauer)."
                )

                helpSection(
                    icon: "battery.75",
                    color: .green,
                    title: "Akkuverbrauch",
                    text: "Während einer Fahrt hält die App eine Live-Verbindung offen und nutzt GPS — das verbraucht etwas mehr Akku als andere Apps. Ohne aktive Fahrt (z.B. beim reinen Nachschauen im Radar-Tab) ist der Verbrauch gering."
                )

                helpSection(
                    icon: "exclamationmark.triangle.fill",
                    color: .yellow,
                    title: "Hinweis",
                    text: "Güterzüge und Sonderfahrten können nicht erkannt werden da sie nicht im öffentlichen Fahrplan stehen. Alle Angaben sind Schätzungen — niemals auf die App verlassen wenn es um Sicherheit geht."
                )

                // Unauffälliger App-Name ganz am Ende als Geheim-Tipp-Ziel — ein Tipp öffnet
                // das Admin-Login, oder loggt (falls schon eingeloggt) über denselben Tipp
                // wieder aus. Bewusst kein sichtbarer Hinweis auf diese Funktion.
                Section {
                    Text("Schrankenradar OSH")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if adminUnlocked {
                                adminUnlocked = false
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            } else {
                                showAdminLogin = true
                            }
                        }
                }
                .listRowBackground(Color.clear)
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Hilfe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fertig") { dismiss() }
                }
            }
            .sheet(isPresented: $showAdminLogin) {
                AdminLoginView {
                    adminUnlocked = true
                    showAdminLogin = false
                }
            }
        }
        .presentationDetents([.large])
    }

    private func helpSection(icon: String, color: Color, title: String, text: String) -> some View {
        Section {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(color)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.subheadline.bold())
                    Text(text)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }
}
