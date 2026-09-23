import SwiftUI

/// Rang-Stufen für aktive Melder, basierend auf `RankTracker.lifetimeMeldungen`. Reine
/// Platzhalter-Werte (Schwellen, Icon, Farbe) ohne echte Nutzungsdaten abgestimmt — leicht
/// anpassbar, da an genau dieser einen Stelle gesammelt.
enum Rank: Int, CaseIterable, Comparable, Identifiable {
    case holz = 0, stein, gold, platin, diamant

    var id: Int { rawValue }

    /// Lebenszeit-Meldungen-Schwelle, ab der dieser Rang gilt.
    var threshold: Int {
        switch self {
        case .holz: 0
        case .stein: 25
        case .gold: 75
        case .platin: 150
        case .diamant: 300
        }
    }

    var displayName: String {
        switch self {
        case .holz: "Holz"
        case .stein: "Stein"
        case .gold: "Gold"
        case .platin: "Platin"
        case .diamant: "Diamant"
        }
    }

    var description: String {
        switch self {
        case .holz: "Erste Schritte als Melder"
        case .stein: "Regelmäßiger Beitrag zur Community"
        case .gold: "Verlässliche Stütze der Vorhersage"
        case .platin: "Herausragendes Engagement"
        case .diamant: "Höchste Auszeichnung für besonders engagierte Mitglieder der Community"
        }
    }

    var starCount: Int { rawValue + 1 }

    /// Name des animierten Abzeichen-GIFs als Data-Asset in Assets.xcassets (kein Image-Asset —
    /// SwiftUIs Image würde nur das erste Frame zeigen). Wiedergabe über `AnimatedGIFView` in
    /// `RankBadgeCardView` (Feier/Detail), Rohzugriff für den Teilen-Button über
    /// `NSDataAsset(name: rank.imageName)`.
    var imageName: String { "RankBadge-\(displayName)" }

    /// Name des flachen, statischen Diamant-Icons als normales Image-Asset — für kompakte
    /// Stellen (Hero-Badge, Rang-Leiter im Wächter-Tab), an denen die große animierte Karte
    /// zu unruhig/unpassend skaliert wäre.
    var iconName: String { "RankIcon-\(displayName)" }

    /// Exakt aus den CSS-Variablen des Rang-Mockups übernommen (--holz/--stein/--gold/--platin/
    /// --diamant in rang-mockup.html), nicht mehr nur grob angenähert — sonst passt z.B. die
    /// Sternfarbe (aus rank.color, unabhängig vom gewählten Stern-Bild) nicht zum Rest.
    var color: Color {
        switch self {
        case .holz: Color(red: 0xA0 / 255, green: 0x65 / 255, blue: 0x28 / 255)
        case .stein: Color(red: 0x8C / 255, green: 0x8C / 255, blue: 0x90 / 255)
        case .gold: Color(red: 0xD4 / 255, green: 0xA8 / 255, blue: 0x17 / 255)
        case .platin: Color(red: 0x8E / 255, green: 0xA4 / 255, blue: 0xBE / 255)
        case .diamant: Color(red: 0x4B / 255, green: 0x90 / 255, blue: 0xD4 / 255)
        }
    }

    static func < (lhs: Rank, rhs: Rank) -> Bool { lhs.rawValue < rhs.rawValue }

    static func forCount(_ count: Int) -> Rank {
        allCases.reversed().first { count >= $0.threshold } ?? .holz
    }

    var next: Rank? { Rank(rawValue: rawValue + 1) }
}
