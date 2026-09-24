import SwiftUI
import UserNotifications

// MARK: - Markenfarbe

extension Color {
    /// Hellblau aus dem App-Icon — für Onboarding-Screens und markante Akzente.
    static let brand = Color("BrandBlue")
}

// MARK: - Card Style

/// Einheitlicher Karten-Look (Hintergrund, Ecken, dezenter Schatten) für alle
/// Haupt-Tabs (Radar, Schranke, Einstellungen) — sorgt für ein konsistentes,
/// "fertiges" Erscheinungsbild statt pro View leicht abweichender Werte.
struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
    }
}

extension View {
    func cardStyle() -> some View { modifier(CardStyle()) }
}

// MARK: - Große Aktions-Buttons (Schranken-Modus)

/// Großer, farbiger Vollbreiten-Button für die zentrale Aktion einer Ansicht
/// (z.B. "Schranke ZU/AUF"). Konsistente Typografie/Schatten/Ecken.
struct BigActionButtonStyle: ButtonStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title2.bold())
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
            .background(color, in: RoundedRectangle(cornerRadius: 20))
            .foregroundStyle(.white)
            .shadow(color: color.opacity(0.35), radius: 12, y: 5)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == BigActionButtonStyle {
    static func bigAction(_ color: Color) -> BigActionButtonStyle { BigActionButtonStyle(color: color) }
}

// MARK: - Berechtigungs-Sequenz

/// Fragt Bewegung&Fitness und Standort nacheinander an — jede Abfrage wartet auf die
/// tatsächliche Antwort, bevor die nächste startet (kein festes Zeitfenster-Raten, sonst
/// platzen Dialoge ineinander). Wird sowohl vom Onboarding ("Okay") als auch vom
/// "Berechtigungen anfragen"-Button in den Einstellungen aufgerufen.
enum PermissionRequester {
    static func requestAll(viewModel: CrossingViewModel,
                            locationMonitor: LocationMonitor,
                            drivingDetector: DrivingDetector) async {
        DebugLog.shared.add("Berechtigungs-Sequenz gestartet.")

        drivingDetector.start()
        await DrivingDetector.waitForAuthorizationAnswer()

        try? await Task.sleep(for: .milliseconds(500))
        locationMonitor.start()
        await locationMonitor.waitForAuthorizationAnswer()

        // "Immer"-Upgrade direkt hier anfragen statt erst beim ersten Fahrt-Start — auf
        // Nutzerwunsch alle Berechtigungs-Dialoge gebündelt am Anfang. Kein extra Warten
        // auf die Antwort nötig, da danach nichts mehr in der Sequenz folgt.
        try? await Task.sleep(for: .milliseconds(500))
        locationMonitor.requestAlwaysUpgradeIfNeeded()

        // Nur die Berechtigung early einholen — GPS läuft normalerweise erst während der
        // Fahrt; ohne Fahrt hier wieder stoppen, um nicht unnötig Akku zu verbrauchen.
        if !drivingDetector.isDriving {
            locationMonitor.stop()
        }

        // Auf Nutzerwunsch (vorher: erst beim ersten Fahrt-Start, siehe RouteViewModel) auch
        // Nachrichten/Benachrichtigungen hier bündeln, statt separat und überraschend später.
        try? await Task.sleep(for: .milliseconds(500))
        await requestNotifications()

        DebugLog.shared.add("Berechtigungs-Sequenz abgeschlossen.")
    }

    /// Eigener Baustein statt Teil von requestAll(), weil RouteViewModel.startTrip() das hier
    /// als Sicherheitsnetz erneut aufruft — für Nutzer, die die Sequenz oben per "Später"
    /// übersprungen haben oder die App schon vor dieser Umstellung installiert hatten.
    /// notDetermined-Guard macht Mehrfachaufrufe gefahrlos (iOS zeigt den Dialog nur einmal).
    static func requestNotifications() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }
}
