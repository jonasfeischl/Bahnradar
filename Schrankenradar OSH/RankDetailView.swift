import SwiftUI

/// Detailansicht für genau einen Rang — aufgerufen durch Antippen einer Zeile in der
/// Rang-Leiter (WaechterView). Zeigt die große Abzeichen-Karte, bei erreichtem Rang zusätzlich
/// den Teilen-Button.
struct RankDetailView: View {
    let rank: Rank
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer()

                let unlocked = rank.rawValue <= RankTracker.shared.currentRank.rawValue
                RankBadgeCardView(rank: rank, isUnlocked: unlocked)

                if unlocked {
                    ShareBadgeButton(rank: rank)
                        .tint(rank.color)
                } else {
                    Label(
                        "Noch \(rank.threshold - RankTracker.shared.lifetimeMeldungen) Meldungen bis \(rank.displayName)",
                        systemImage: "lock.fill"
                    )
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                }

                Spacer()
            }
            .padding()
            .background(Color(red: 0.05, green: 0.08, blue: 0.15).ignoresSafeArea())
            .navigationTitle(rank.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fertig") { dismiss() }
                        .tint(.white)
                }
            }
        }
    }
}

/// Schreibt das rohe GIF des Rangs (Data-Asset, dieselbe Quelle wie `AnimatedGIFView`) in eine
/// temporäre Datei und teilt deren URL — so wird die tatsächliche Animation geteilt statt nur
/// eines eingefrorenen Frames. `UIImage`/`Data` sind nicht `Transferable`, `URL` dagegen nativ
/// (per SDK-Interface geprüft), daher dieser Umweg. Gleiches Grundprinzip wie das bestehende
/// `ShareLink(item: log.exportText)` in DebugLogView, nur Datei statt Text.
struct ShareBadgeButton: View {
    let rank: Rank
    @State private var fileURL: URL?

    var body: some View {
        Group {
            if let fileURL {
                ShareLink(item: fileURL) {
                    Label("Teilen", systemImage: "square.and.arrow.up")
                }
            } else {
                ProgressView()
                    .task { fileURL = writeToTempFile() }
            }
        }
    }

    private func writeToTempFile() -> URL? {
        guard let data = NSDataAsset(name: rank.imageName)?.data else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Rang-\(rank.displayName).gif")
        try? data.write(to: url)
        return url
    }
}

#Preview {
    RankDetailView(rank: .diamant)
}
