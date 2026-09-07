import SwiftUI

// MARK: - Onboarding-Flow (beim allerersten App-Start)

struct OnboardingFlow: View {
    @Binding var isPresented: Bool

    private enum Step { case welcome, permissions }
    @State private var step: Step = .welcome

    @AppStorage("permissionsDeferred") private var permissionsDeferred = false

    var body: some View {
        Group {
            switch step {
            case .welcome:
                OnboardingWelcomeScreen {
                    withAnimation { step = .permissions }
                }
            case .permissions:
                OnboardingPermissionsScreen(
                    onAccept: {
                        // Die eigentliche Berechtigungs-Anfrage übernimmt die App-Ebene (siehe
                        // Schrankenradar_OSHApp.swift), NACHDEM dieses Sheet fertig geschlossen ist —
                        // ein hier separat gestarteter Task würde nicht auf das Schließen warten und
                        // mit dem nachfolgenden Sprachqualitäts-Hinweis kollidieren.
                        permissionsDeferred = false
                        isPresented = false
                    },
                    onLater: {
                        permissionsDeferred = true
                        isPresented = false
                    }
                )
            }
        }
    }
}

// MARK: - Screen 1: Willkommen

private struct OnboardingWelcomeScreen: View {
    let onNext: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 20) {
                Image(systemName: "tram.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(Color.brand)

                Text("Herzlich willkommen bei Bahnradar")
                    .font(.largeTitle.bold())
                    .foregroundStyle(Color.brand)
                    .multilineTextAlignment(.center)

                Text("Bahnradar zeigt dir, wann ein Bahnübergang voraussichtlich offen oder geschlossen ist — auf Basis echter Fahrplan- und Live-GPS-Daten der Züge. So siehst du auf einen Blick, ob dich an der Schranke eine Wartezeit erwartet.")
                    .font(.body)
                    .foregroundStyle(Color.brand)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }
            .padding(.horizontal, 32)

            Spacer()

            Button(action: onNext) {
                Text("Okay")
                    .font(.title3.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(Color.brand, in: RoundedRectangle(cornerRadius: 16))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.ignoresSafeArea())
    }
}

// MARK: - Screen 2: Berechtigungen erklären

private struct OnboardingPermissionsScreen: View {
    let onAccept: () -> Void
    let onLater: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 24) {
                Text("Fast fertig")
                    .font(.largeTitle.bold())
                    .foregroundStyle(Color.brand)

                Text("Damit dich die App automatisch warnen kann, fragt iOS dich gleich nacheinander nach ein paar Berechtigungen. Bitte jede davon erlauben, sonst funktionieren manche Funktionen nicht:")
                    .font(.body)
                    .foregroundStyle(Color.brand)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)

                VStack(alignment: .leading, spacing: 18) {
                    permissionRow(icon: "location.fill",
                                  title: "Standort",
                                  text: "Wechselt automatisch zum nächsten Bahnübergang, sobald du in dessen Nähe kommst. Bei der zweiten Standort-Abfrage bitte „Immer erlauben“ wählen, sonst funktionieren Sprachwarnungen nicht bei gesperrtem Bildschirm.")
                    permissionRow(icon: "figure.walk.motion",
                                  title: "Bewegung & Fitness",
                                  text: "Erkennt automatisch, wenn du fährst, und aktiviert dann die Sprachansagen.")
                }
                .padding(.horizontal, 16)
            }
            .padding(.horizontal, 24)

            Spacer()

            VStack(spacing: 12) {
                Button(action: onAccept) {
                    Text("Okay")
                        .font(.title3.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .background(Color.brand, in: RoundedRectangle(cornerRadius: 16))
                        .foregroundStyle(.white)
                }

                // Bewusst als unauffälliger Text-Button statt gleich gestalteter voller
                // Fläche wie "Okay" — beide sahen vorher identisch aus (gleiche Farbe/Größe),
                // ein Fehltipp auf "Später" übersprang dadurch still alle Berechtigungen
                // (GPS-Auto-Wechsel/Sprachansagen funktionieren dann ohne erkennbaren Grund
                // nicht). Bewusst kein zweiter prominenter Button mehr.
                Button(action: onLater) {
                    Text("Später")
                        .font(.subheadline)
                        .foregroundStyle(Color.brand.opacity(0.6))
                        .padding(.vertical, 10)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.ignoresSafeArea())
    }

    private func permissionRow(icon: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(Color.brand)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Color.brand)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(Color.brand.opacity(0.8))
            }
        }
    }
}
