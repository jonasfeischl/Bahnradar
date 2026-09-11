//
//  Schrankenradar_OSHApp.swift
//  Schrankenradar OSH
//
//  Created by Jonas Feischl on 30.05.26.
//

import SwiftUI
import Combine

@main
struct Schrankenradar_OSHApp: App {

    @State private var viewModel        = CrossingViewModel()
    @State private var locationMonitor  = LocationMonitor()
    @State private var voiceAnnouncer   = VoiceAnnouncer()
    @State private var drivingDetector  = DrivingDetector()

    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var showOnboarding = false

    @AppStorage("permissionsDeferred") private var permissionsDeferred = false

    /// Gleicher Key wie SettingsView/HelpView — schaltet den 4. Tab "Vergleich" frei (siehe
    /// dort für die Freischalt-Geste). Reagiert live, ohne App-Neustart.
    @AppStorage("adminUnlocked") private var adminUnlocked = false

    /// Splash mit drehendem Radar-Logo, kurz beim Kaltstart über allem sichtbar. Läuft
    /// über einen eigenen, unabhängigen Timer statt in der Sequenz unten — die kann durch
    /// Onboarding (fullScreenCover) beliebig lange dauern; der Splash liegt in dem Fall
    /// einfach unsichtbar darunter und ist beim Dismiss bereits ausgeblendet.
    @State private var showLaunchScreen = true

    /// Wird erst wahr, sobald Onboarding + Berechtigungs-Sequenz (Bewegung → Standort,
    /// siehe PermissionRequester) komplett durchgelaufen sind. Tabs, die selbst
    /// aktiv GPS anfordern könnten (z.B. ContentView für die Fahrzeiten-Karte) oder einen
    /// eigenen Erklär-Screen zeigen wollen, warten auf dieses Signal statt sofort in ihrem
    /// eigenen onAppear loszulegen — sonst feuert z.B. ContentView.onAppear (Radar ist der
    /// Standard-Tab, erscheint quasi sofort beim Kaltstart) VOR dieser bewusst sequenzierten
    /// Abfrage-Reihenfolge und lässt z.B. den Standort-Popup einzeln/vorzeitig aufploppen statt
    /// geordnet nach Bewegung&Fitness zu kommen (beobachtet: Standort-Popup "kommt nicht mit
    /// den anderen"). @AppStorage statt @State, damit es reaktiv in anderen Views ankommt.
    @AppStorage("appStartupSequenceComplete") private var appStartupSequenceComplete = false

    /// @AppStorage-Defaults (z.B. "voiceEnabled" = true) gelten nur innerhalb des
    /// @AppStorage-Wrappers selbst — ein roher UserDefaults.standard.bool(forKey:)-Zugriff
    /// (z.B. in CrossingViewModel) sieht ohne dieses register() stattdessen Foundations
    /// eigenen Default (false), solange der Nutzer den Schalter nie manuell betätigt hat.
    /// register(defaults:) gleicht beide Zugriffswege an, ohne je etwas explizit Gesetztes
    /// zu überschreiben.
    init() {
        UserDefaults.standard.register(defaults: ["voiceEnabled": true])
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                TabView {
                    ContentView(viewModel: viewModel, locationMonitor: locationMonitor,
                                voiceAnnouncer: voiceAnnouncer, drivingDetector: drivingDetector)
                        .tabItem {
                            Label("Radar", systemImage: "antenna.radiowaves.left.and.right")
                        }

                    SchrankenModeView(viewModel: viewModel, locationMonitor: locationMonitor)
                        .tabItem {
                            Label("Schranke", systemImage: "record.circle")
                        }

                    SettingsView(viewModel: viewModel, locationMonitor: locationMonitor, voiceAnnouncer: voiceAnnouncer,
                                 drivingDetector: drivingDetector)
                        .tabItem {
                            Label("Einstellungen", systemImage: "gearshape.fill")
                        }

                    // Nur sichtbar nach Admin-Login (siehe adminUnlocked oben) — Rohdaten-
                    // Vergleich der drei APIs, nichts für normale Nutzer.
                    if adminUnlocked {
                        APIComparisonView()
                            .tabItem {
                                Label("Vergleich", systemImage: "chart.bar.doc.horizontal")
                            }
                    }
                }
                // Fahrterkennung + isDriving/isNearCrossing-Sync bewusst hier auf Tab-View-Ebene
                // statt in ContentView — lief vorher nur auf dem Radar-Tab, weil ContentViews
                // .onReceive/.onChange bei Tab-Wechsel pausieren (siehe ContentView.onDisappear
                // "Tab-Wechsel"-Kommentar). Dadurch fror isDriving/isNearCrossing ein, sobald man
                // z.B. während der Fahrt auf dem Schranken-Modus-Tab war — keine Sprachansage mehr,
                // weil evaluateVoiceAnnouncement() (CrossingViewModel) genau diese beiden Werte prüft.
                .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
                    drivingDetector.tick()
                }
                .onChange(of: drivingDetector.isDriving) { _, driving in
                    if driving { locationMonitor.start() } else { locationMonitor.stop() }
                    viewModel.isDriving = driving
                    // Einmalige Bestätigung beim Start jeder Fahrt (Flanke false→true, nicht
                    // bei jedem App-Öffnen) — Gegenstück zu "Hintergrundmodus aktiv" beim
                    // Verlassen der App.
                    let voiceEnabled = UserDefaults.standard.bool(forKey: "voiceEnabled")
                    DebugLog.shared.add("isDriving-Wechsel: \(driving), voiceEnabled: \(voiceEnabled) — announceAppActive \(driving && voiceEnabled ? "wird ausgelöst" : "wird NICHT ausgelöst")")
                    if driving && voiceEnabled {
                        voiceAnnouncer.announceAppActive()
                    }
                }
                .onChange(of: locationMonitor.isNearCrossing) { _, near in
                    viewModel.isNearCrossing = near
                }
                .task {
                    // Ebenfalls tab-unabhängig statt in ContentView.onAppear — GPS-Geschwindigkeit
                    // muss auch außerhalb des Radar-Tabs bei der Fahrterkennung ankommen.
                    locationMonitor.crossings = viewModel.store.crossings
                    locationMonitor.onAutoSwitch = { crossing in
                        guard viewModel.store.selectedId != crossing.id else { return }
                        viewModel.store.select(crossing)
                        Task { await viewModel.fetchData() }
                    }
                    locationMonitor.onSpeedUpdate = { speed in
                        drivingDetector.updateSpeed(metersPerSecond: speed)
                    }
                }
                .task {
                    // Kurz warten bis das Fenster wirklich "key"/bereit ist — ein fullScreenCover
                    // (oder Systemabfragen) direkt beim Kaltstart ausgelöst wird von iOS teils
                    // stillschweigend verworfen (dasselbe Problem wie bei den Berechtigungs-Popups).
                    try? await Task.sleep(for: .milliseconds(400))

                    // Datenladen zentral von hier auslösen statt aus ContentView.onAppear — der
                    // Radar-Tab ist beim Kaltstart oft noch nicht "richtig" erschienen (dasselbe
                    // Zeitfenster-Problem wie oben), wodurch Anzeigen erst nach einem Tab-Wechsel
                    // korrekt aktualisiert wurden.
                    viewModel.setup(voiceAnnouncer: voiceAnnouncer)
                    viewModel.startAutoRefresh()
                    viewModel.startVoiceMonitor()

                    if !hasCompletedOnboarding {
                        // Erster Start: Willkommen + Berechtigungs-Erklärung zeigen.
                        hasCompletedOnboarding = true
                        showOnboarding = true
                        // WICHTIG: warten bis der Nutzer das Onboarding fertig beantwortet hat,
                        // bevor irgendein weiterer Dialog (z.B. der Sprachqualitäts-Hinweis) kommt.
                        // Zwei gleichzeitige Präsentationen (fullScreenCover + alert) lässt iOS
                        // stillschweigend kollidieren — das sah aus wie "Popup kommt und schließt
                        // sofort wieder".
                        while showOnboarding {
                            try? await Task.sleep(for: .milliseconds(300))
                        }
                        // Die Berechtigungs-Sequenz erst HIER (awaited) starten, statt aus einem
                        // separat gestarteten Task heraus — sonst läuft sie noch während unten
                        // schon der Sprachqualitäts-Hinweis erscheint (Präsentations-Kollision).
                        if !permissionsDeferred {
                            await PermissionRequester.requestAll(
                                viewModel: viewModel, locationMonitor: locationMonitor, drivingDetector: drivingDetector
                            )
                        }
                    } else if permissionsDeferred {
                        // Wiederkehrender Start, aber beim letzten Mal "Später" gewählt: Berechtigungen
                        // erneut anfragen. Ist bereits alles entschieden, passiert hier nichts mehr —
                        // sonst würden bei jedem Start unnötig dieselben Abfragen erneut laufen.
                        await PermissionRequester.requestAll(
                            viewModel: viewModel, locationMonitor: locationMonitor, drivingDetector: drivingDetector
                        )
                        permissionsDeferred = false
                    } else {
                        // Normaler Wiedereinstieg (Onboarding erledigt, nichts aufgeschoben) —
                        // PermissionRequester.requestAll() läuft dann NICHT, das startete
                        // drivingDetector.start() bisher aber nur dort bzw. beim Zurückkehren
                        // aus dem Hintergrund. Bei einem echten Kaltstart (App komplett beendet
                        // und neu geöffnet) lief Core Motion dadurch nie an — nur der trägere
                        // GPS-Fallback blieb übrig, bis man die App einmal in den Hintergrund
                        // schickte und zurückholte ("Neustart nötig, damit Fahrterkennung
                        // funktioniert"). start() prüft selbst den Berechtigungsstatus, ist
                        // also gefahrlos wiederholt aufrufbar.
                        drivingDetector.start()
                    }

                    appStartupSequenceComplete = true
                }
                .fullScreenCover(isPresented: $showOnboarding) {
                    OnboardingFlow(isPresented: $showOnboarding)
                }

                if showLaunchScreen {
                    LaunchScreenView()
                        .transition(.opacity)
                }
            }
            .task {
                try? await Task.sleep(for: .seconds(5))
                withAnimation(.easeOut(duration: 0.5)) {
                    showLaunchScreen = false
                }
            }
        }
    }
}
