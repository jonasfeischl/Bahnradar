import SwiftUI

/// Zeigt das gesamte Debug-Log an — gedacht zum direkten Kopieren/Teilen, wenn ein
/// Fehler gemeldet werden soll. Neueste Einträge oben, Fehler/Warnungen farblich markiert.
struct DebugLogView: View {
    @State private var log = DebugLog.shared
    @State private var onlyIssues = false
    @State private var showCopiedToast = false

    private var visibleEntries: [DebugLog.Entry] {
        let all = log.entries.reversed()
        return onlyIssues ? all.filter { $0.level != .info } : Array(all)
    }

    var body: some View {
        List {
            if visibleEntries.isEmpty {
                Text(onlyIssues ? "Keine Fehler/Warnungen bisher." : "Noch keine Log-Einträge.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(visibleEntries) { entry in
                    row(for: entry)
                }
            }
        }
        .listStyle(.plain)
        .font(.system(.footnote, design: .monospaced))
        .navigationTitle("Diagnose-Log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    UIPasteboard.general.string = log.exportText
                    showCopiedToast = true
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                ShareLink(item: log.exportText.isEmpty ? "Kein Log vorhanden." : log.exportText) {
                    Image(systemName: "square.and.arrow.up")
                }
                Menu {
                    Toggle("Nur Fehler/Warnungen", isOn: $onlyIssues)
                    Button(role: .destructive) {
                        log.clear()
                    } label: {
                        Label("Log leeren", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .onAppear { log.markSeen() }
        .overlay(alignment: .bottom) {
            if showCopiedToast {
                Text("In Zwischenablage kopiert")
                    .font(.footnote.bold())
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task {
                        try? await Task.sleep(for: .seconds(1.6))
                        showCopiedToast = false
                    }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showCopiedToast)
    }

    @ViewBuilder
    private func row(for entry: DebugLog.Entry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(entry.date, format: .dateTime.hour().minute().second())
                .foregroundStyle(.secondary)
            // lineLimit: manche Zeilen (z.B. Geops-Stopsequence mit dutzenden Stationsnamen)
            // sind sehr lang — volles CoreText-Layout jeder solchen Zeile beim Scrollen wurde
            // per Instruments als Main-Thread-Hang nachgewiesen. Volltext bleibt über Kopieren/
            // Teilen (log.exportText) weiterhin verfügbar, hier nur die Anzeige begrenzt.
            Text(entry.message)
                .foregroundStyle(color(for: entry.level))
                .textSelection(.enabled)
                .lineLimit(4)
        }
        .listRowBackground(Color.clear)
    }

    private func color(for level: DebugLog.Level) -> Color {
        switch level {
        case .info:  return .primary
        case .warn:  return .orange
        case .error: return .red
        }
    }
}
