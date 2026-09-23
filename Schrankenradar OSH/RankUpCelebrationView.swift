import SwiftUI

/// Vollbild-Feier beim Rang-Aufstieg — zeigt die neu freigeschaltete Abzeichen-Karte direkt
/// (kein Umbau von FeatureIntroScreen: dessen Farbe ist fest auf Color.brand verdrahtet, und
/// dessen "einmalig pro Tab, nie wieder"-Semantik passt nicht zu einem wiederkehrenden
/// Ereignis, das bis zu 4x im App-Leben auftreten kann).
struct RankUpCelebrationView: View {
    let rank: Rank
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Text("Rang aufgestiegen!")
                .font(.title.bold())
                .foregroundStyle(.white)

            RankBadgeCardView(rank: rank, isUnlocked: true)
                .padding(.horizontal, 24)

            ShareBadgeButton(rank: rank)
                .tint(rank.color)

            Spacer()

            Button(action: onDismiss) {
                Text("Weiter")
                    .font(.title3.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(rank.color, in: RoundedRectangle(cornerRadius: 16))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.05, green: 0.08, blue: 0.15).ignoresSafeArea())
    }
}

#Preview {
    RankUpCelebrationView(rank: .diamant) {}
}
