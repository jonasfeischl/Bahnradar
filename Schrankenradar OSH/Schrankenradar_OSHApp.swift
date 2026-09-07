//
//  Schrankenradar_OSHApp.swift
//  Schrankenradar OSH
//
//  Created by Jonas Feischl on 30.05.26.
//

import SwiftUI

@main
struct Schrankenradar_OSHApp: App {

    @State private var viewModel        = CrossingViewModel()
    @State private var locationMonitor  = LocationMonitor()
    @State private var voiceAnnouncer   = VoiceAnnouncer()
    @State private var drivingDetector  = DrivingDetector()

    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var showOnboarding = false

    @AppStorage("permissionsDeferred") private var permissionsDeferred = false

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
