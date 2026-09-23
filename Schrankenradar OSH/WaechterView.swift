import SwiftUI

/// Eigener Tab "Wächter" — Rang-Hero-Karte, Wochenstatistik und die komplette Rang-Leiter.
/// Liest ausschließlich `RankTracker.shared`, braucht deshalb keine der von außen
/// durchgereichten Shared-State-Objekte (viewModel/locationMonitor/...), anders als die
/// übrigen Tabs.
struct WaechterView: View {
    @State private var selectedRankForDetail: Rank?

    private var tracker: RankTracker { RankTracker.shared }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    heroCard
                    statsGrid
                    rankLadder
                }
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Wächter")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $selectedRankForDetail) { rank in
                RankDetailView(rank: rank)
            }
        }
    }

    // MARK: - Hero-Karte

    private var heroCard: some View {
        let rank = tracker.currentRank
        return VStack(spacing: 0) {
            HStack(spacing: 16) {
                RankThumbnail(rank: rank, isUnlocked: true)
                    .frame(width: 72, height: 98)

                VStack(alignment: .leading, spacing: 6) {
                    Text("SCHRANKENWÄCHTER")
                        .font(.caption2.bold())
                        .tracking(1)
                        .foregroundStyle(.secondary)
                    Text(rank.displayName.uppercased())
                        .font(.title2.bold())
                        .foregroundStyle(rank.color)
                    HStack(spacing: 3) {
                        ForEach(0..<Rank.allCases.count, id: \.self) { index in
                            starIcon.foregroundStyle(index < rank.starCount ? rank.color : Color(.systemGray4))
                        }
                    }
                }
                Spacer()
            }
            .padding(16)

            if let next = rank.next {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("\(bandXP(rank: rank)) / \(bandXPTotal(rank: rank, next: next)) XP")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("→ \(next.displayName.uppercased())")
                            .font(.caption.bold())
                            .foregroundStyle(next.color)
                    }
                    ProgressView(value: bandProgress(rank: rank, next: next))
                        .tint(rank.color)
                    Text("Noch \(next.threshold - tracker.lifetimeMeldungen) Meldungen bis \(next.displayName)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 16)
    }

    /// Eigene Stern-Grafik (aus dem Mockup) statt SF-Symbol-Stern — als Template geladen, damit
    /// dieselbe Form wie bei den Rang-Icons per `.foregroundStyle` je nach erreicht/gesperrt
    /// eingefärbt werden kann, ohne 5+ vorgefärbte Varianten zu brauchen.
    private var starIcon: some View {
        Image("RankIcon-Star")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: 12, height: 12)
    }

    /// Fortschritt INNERHALB der aktuellen Stufe (nicht absolut ab 0), sonst wirkt der Balken
    /// bei hohen Rängen mit hohem next.threshold winzig/falsch.
    private func bandProgress(rank: Rank, next: Rank) -> Double {
        let span = Double(next.threshold - rank.threshold)
        return Double(tracker.lifetimeMeldungen - rank.threshold) / span
    }

    private func bandXP(rank: Rank) -> Int { (tracker.lifetimeMeldungen - rank.threshold) * 20 }
    private func bandXPTotal(rank: Rank, next: Rank) -> Int { (next.threshold - rank.threshold) * 20 }

    // MARK: - Statistik-Kacheln

    private var statsGrid: some View {
        HStack(spacing: 12) {
            statTile(value: "\(tracker.weeklyMeldungen)", label: "Meldungen\ndiese Woche", color: .blue)
            statTile(value: "\(tracker.streakDays)", label: "Tage\nStreak 🔥", color: .orange)
            statTile(value: "+\(tracker.weeklyXP)", label: "XP diese\nWoche", color: Rank.gold.color)
        }
        .padding(.horizontal, 16)
    }

    private func statTile(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title2.bold())
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Rang-Leiter

    private var rankLadder: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("RANG-SYSTEM")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)

            VStack(spacing: 0) {
                ForEach(Rank.allCases) { rank in
                    Button {
                        selectedRankForDetail = rank
                    } label: {
                        ladderRow(for: rank)
                    }
                    .buttonStyle(.plain)

                    if rank != Rank.allCases.last {
                        Divider().padding(.leading, 66)
                    }
                }
            }
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 13))
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private func ladderRow(for rank: Rank) -> some View {
        let current = tracker.currentRank
        let unlocked = rank.rawValue <= current.rawValue

        HStack(spacing: 14) {
            RankThumbnail(rank: rank, isUnlocked: unlocked)
                .frame(width: 38, height: 52)

            VStack(alignment: .leading, spacing: 2) {
                Text(rank.displayName)
                    .font(.subheadline.bold())
                    .foregroundStyle(unlocked ? rank.color : .secondary)
                if rank == current.next {
                    Text("\(rank.threshold) Meldungen · noch \(rank.threshold - tracker.lifetimeMeldungen)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(rank.threshold) Meldungen")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if rank == current {
                Text("Du")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(rank.color, in: Capsule())
            } else if unlocked {
                Image(systemName: "checkmark")
                    .foregroundStyle(.green)
            } else {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
    }
}

#Preview {
    WaechterView()
}
