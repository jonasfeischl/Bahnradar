import SwiftUI

/// Einheitlicher Erklär-Screen, der einmalig beim ersten Öffnen eines Tabs erscheint
/// (Radar, Schranken-Modus, Einstellungen) — gleiches Aussehen für alle drei, nur
/// Icon/Titel/Text unterscheiden sich.
struct FeatureIntroScreen: View {
    let icon: String
    let title: String
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 20) {
                Image(systemName: icon)
                    .font(.system(size: 60))
                    .foregroundStyle(Color.brand)

                Text(title)
                    .font(.largeTitle.bold())
                    .foregroundStyle(Color.brand)
                    .multilineTextAlignment(.center)

                Text(message)
                    .font(.body)
                    .foregroundStyle(Color.brand)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }
            .padding(.horizontal, 32)

            Spacer()

            Button(action: onDismiss) {
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
