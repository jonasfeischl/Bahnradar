import SwiftUI

/// Flaches, statisches Diamant-Icon eines Rangs (`rank.iconName`) für kompakte Stellen —
/// Hero-Badge und Rang-Leiter im Wächter-Tab. Gesperrte Ränge werden nur abgedunkelt
/// (Opacity 0.55, wie im Mockup), nicht entsättigt — die Icons behalten ihre Rangfarbe,
/// nur schwächer sichtbar.
struct RankThumbnail: View {
    let rank: Rank
    let isUnlocked: Bool

    var body: some View {
        Image(rank.iconName)
            .resizable()
            .scaledToFit()
            .opacity(isUnlocked ? 1 : 0.55)
    }
}

/// Abzeichen-Karte für einen Rang in voller Größe, für Feier und Detailansicht — zeigt die
/// animierte GIF-Karte (`rank.imageName`) direkt, nicht das kompakte Icon aus `RankThumbnail`
/// (die große Karte verträgt die Animation gut, ein hochskaliertes kleines Icon würde dagegen
/// unscharf/leer wirken). Kein Schloss/Fortschritt-Overlay mehr auf dem Bild selbst — die
/// eigene Bildkomposition (Diamant, Titel, Sterne) sitzt an unvorhersehbaren Stellen je nach
/// Karte, ein zentriertes Overlay hat sich sichtbar mit Diamant/Titel überlagert. Gesperrt-
/// Hinweise stehen stattdessen als eigene Zeile UNTER der Karte (siehe RankDetailView).
struct RankBadgeCardView: View {
    let rank: Rank
    let isUnlocked: Bool

    /// Seitenverhältnis der Karten-Vorlage (280:380) — feste Pixelgröße vorher ließ auf großen
    /// Bildschirmen viel unbenutzten Hintergrund um eine kleine Karte herum stehen (Nutzer-
    /// Report). Skaliert jetzt auf die verfügbare Breite hoch, Höhe folgt proportional.
    private static let aspectRatio: CGFloat = 280.0 / 380.0

    var body: some View {
        AnimatedGIFView(dataAssetName: rank.imageName)
            .opacity(isUnlocked ? 1 : 0.55)
            .aspectRatio(Self.aspectRatio, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipped()
    }
}

#Preview {
    VStack(spacing: 20) {
        RankBadgeCardView(rank: .diamant, isUnlocked: true)
        RankBadgeCardView(rank: .platin, isUnlocked: false)
    }
    .padding()
    .background(Color.black)
}
