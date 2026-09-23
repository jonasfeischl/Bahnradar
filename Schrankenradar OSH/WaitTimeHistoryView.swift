import SwiftUI

/// Monats-Rückblick der passiv erfassten Wartezeit (WaitTimeTracker) — erreichbar über den
/// Toolbar-Button im Schranken-Modus, bewusst NICHT an die 250m-Anwesenheitsprüfung gekoppelt
/// (anders als die bestehenden Aufzeichnungen/Tages-Muster-Buttons dort), da ein Monats-Rückblick
/// auch von zuhause aus einsehbar sein soll.
struct WaitTimeHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    private let tracker = WaitTimeTracker.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    WaitTimeShareCardView(
                        monthLabel: tracker.currentMonthDisplayName,
                        seconds: tracker.currentMonthSeconds
                    )
                    .frame(maxWidth: 340)
                    .frame(maxWidth: .infinity)

                    ShareWaitTimeCardButton(
                        monthLabel: tracker.currentMonthDisplayName,
                        seconds: tracker.currentMonthSeconds
                    )

                    let earlierMonths = tracker.history.dropFirst()
                    if !earlierMonths.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Frühere Monate")
                                .font(.subheadline.bold())
                                .foregroundStyle(.secondary)
                                .padding(.bottom, 6)
                            ForEach(Array(earlierMonths), id: \.monthKey) { entry in
                                HStack {
                                    Text(WaitTimeTracker.displayName(for: entry.monthKey))
                                    Spacer()
                                    Text(WaitTimeTracker.formatted(entry.seconds))
                                        .bold()
                                }
                                .font(.subheadline)
                                Divider()
                            }
                        }
                        .padding(16)
                        .cardStyle()
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Wartezeit-Rückblick")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
    }
}

/// Die eigentliche "Karte" — Vorschau UND Grundlage für das geteilte Bild (siehe
/// ShareWaitTimeCardButton, rendert exakt diese View via ImageRenderer).
struct WaitTimeShareCardView: View {
    let monthLabel: String
    let seconds: TimeInterval

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: "road.lanes")
                Text("BAHNRADAR")
                    .font(.caption.bold())
                    .tracking(2)
            }
            .foregroundStyle(.white.opacity(0.85))

            Image(systemName: "hourglass")
                .font(.system(size: 40))
                .foregroundStyle(.white)

            Text(WaitTimeTracker.formatted(seconds))
                .font(.system(size: 34, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)

            Text("vor Schranken gewartet — \(monthLabel)")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(colors: [Color.brand, Color.brand.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 24))
    }
}

/// Rendert WaitTimeShareCardView per ImageRenderer zu PNG und teilt es als Datei — exakt dasselbe
/// Muster wie ShareBadgeButton (RankDetailView.swift), nur dass hier eine SwiftUI-View statt
/// eines NSDataAsset-GIFs die Bildquelle ist.
struct ShareWaitTimeCardButton: View {
    let monthLabel: String
    let seconds: TimeInterval
    @Environment(\.displayScale) private var displayScale
    @State private var fileURL: URL?

    var body: some View {
        Group {
            if let fileURL {
                ShareLink(item: fileURL) {
                    Label("Karte teilen", systemImage: "square.and.arrow.up")
                }
            } else {
                ProgressView()
                    .task { fileURL = writeToTempFile() }
            }
        }
    }

    @MainActor
    private func writeToTempFile() -> URL? {
        let renderer = ImageRenderer(content: WaitTimeShareCardView(monthLabel: monthLabel, seconds: seconds).frame(width: 340))
        renderer.scale = displayScale
        guard let data = renderer.uiImage?.pngData() else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Wartezeit-\(monthLabel).png")
        try? data.write(to: url)
        return url
    }
}

#Preview {
    WaitTimeHistoryView()
}
