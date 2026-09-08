import SwiftUI

/// Admin-Tab "Vergleich" (siehe APIComparisonViewModel) — zeigt DB/Geops/MVG als eigene,
/// wischbare Seiten nebeneinander, plus eine "Kombiniert"-Seite aus den oben ausgewählten
/// Quellen. Nur zum Vergleichen der Rohdaten gedacht, keine Verbindung zur Produktions-Anzeige
/// (Radar-Tab).
struct APIComparisonView: View {
    private enum Page: Int, CaseIterable {
        case db, geops, mvg, combined

        var title: String {
            switch self {
            case .db:       "DB"
            case .geops:    "Geops"
            case .mvg:      "MVG"
            case .combined: "Kombiniert"
            }
        }
    }

    @State private var viewModel = APIComparisonViewModel()
    @State private var selectedPage: Page = .db

    var body: some View {
        @Bindable var viewModel = viewModel
        NavigationStack {
            VStack(spacing: 0) {
                header(viewModel: viewModel)
                Divider()
                TabView(selection: $selectedPage) {
                    listView(rows: viewModel.dbRows,
                             emptyText: "Keine DB-Daten.",
                             errorText: viewModel.dbError)
                        .tag(Page.db)
                    listView(rows: viewModel.geopsRows,
                             emptyText: "Keine Geops-Daten für diesen Übergang.",
                             errorText: nil)
                        .tag(Page.geops)
                    listView(rows: viewModel.mvgRows,
                             emptyText: "Keine MVG-Daten.",
                             errorText: viewModel.mvgError)
                        .tag(Page.mvg)
                    listView(rows: viewModel.combinedRows,
                             emptyText: "Keine Quelle ausgewählt oder keine Daten.",
                             errorText: nil)
                        .tag(Page.combined)
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
            }
            .navigationTitle("API-Vergleich · \(selectedPage.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if viewModel.isLoading {
                        ProgressView()
                    } else {
                        Button {
                            Task { await viewModel.refresh() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
            }
        }
        .onAppear { viewModel.startAutoRefresh() }
        .onDisappear { viewModel.stopAutoRefresh() }
    }

    // MARK: - Kopfbereich

    private func header(viewModel: APIComparisonViewModel) -> some View {
        @Bindable var viewModel = viewModel
        return VStack(alignment: .leading, spacing: 10) {
            Picker("Übergang", selection: $viewModel.selectedCrossing) {
                ForEach(CrossingLocation.all) { crossing in
                    Text(crossing.name).tag(crossing)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()

            HStack(spacing: 8) {
                Text("Kombiniert aus:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(APISource.allCases) { source in
                    sourceChip(source, viewModel: viewModel)
                }
                Spacer()
                if let lastRefreshAt = viewModel.lastRefreshAt {
                    Text(lastRefreshAt, format: .dateTime.hour().minute().second())
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func sourceChip(_ source: APISource, viewModel: APIComparisonViewModel) -> some View {
        let isOn = viewModel.enabledSources.contains(source)
        return Button {
            if isOn { viewModel.enabledSources.remove(source) }
            else    { viewModel.enabledSources.insert(source) }
        } label: {
            Text(source.rawValue)
                .font(.caption.bold())
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(isOn ? Color.accentColor : Color.secondary.opacity(0.15), in: Capsule())
                .foregroundStyle(isOn ? Color.white : Color.secondary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Listen

    @ViewBuilder
    private func listView(rows: [ComparisonRow], emptyText: String, errorText: String?) -> some View {
        List {
            if let errorText {
                Text(errorText)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            if rows.isEmpty {
                Text(emptyText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rows) { row in
                    rowView(row)
                }
            }
        }
        .listStyle(.plain)
    }

    private func rowView(_ row: ComparisonRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(row.source.rawValue)
                    .font(.caption2.bold())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
                    .foregroundStyle(.secondary)
                Text(row.lineName)
                    .font(.subheadline.bold())
                if let direction = row.direction {
                    Text(direction)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(row.actualTime, format: .dateTime.hour().minute().second())
                    .font(.subheadline.monospacedDigit())
            }
            HStack(spacing: 8) {
                Text("Soll \(row.scheduledTime.formatted(date: .omitted, time: .shortened))")
                if row.delayMinutes > 0 {
                    Text("+\(row.delayMinutes) min")
                        .foregroundStyle(.orange)
                }
                if let note = row.note, !note.isEmpty {
                    Text(note)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
