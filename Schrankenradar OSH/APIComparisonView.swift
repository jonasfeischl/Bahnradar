import SwiftUI

/// Admin-Tab "Vergleich" (siehe APIComparisonViewModel) — zeigt DB/Geops/MVG als eigene,
/// wischbare Seiten nebeneinander, plus eine "Kombiniert"-Seite aus den oben ausgewählten
/// Quellen. Nur zum Vergleichen der Rohdaten gedacht, keine Verbindung zur Produktions-Anzeige
/// (Radar-Tab).
struct APIComparisonView: View {
    private enum Page: Int, CaseIterable {
        case db, geops, mvg, dbMvg, combined

        var title: String {
            switch self {
            case .db:       "DB"
            case .geops:    "Geops"
            case .mvg:      "MVG"
            case .dbMvg:    "DB+MVG"
            case .combined: "Kombiniert"
            }
        }
    }

    @State private var viewModel = APIComparisonViewModel()
    @State private var selectedPage: Page = .db
    /// Reine Anzeige-Einstellung (kein Einfluss auf welche Züge geladen/gezeigt werden), daher
    /// bewusst lokaler View-State statt im ViewModel — siehe ComparisonRow.crossingTime(_:
    /// applyOffset:).
    @State private var showOffset = false

    var body: some View {
        @Bindable var viewModel = viewModel
        NavigationStack {
            VStack(spacing: 0) {
                header(viewModel: viewModel)
                Divider()
                TabView(selection: $selectedPage) {
                    pageContent(rows: viewModel.dbRows,
                                emptyText: "Keine DB-Daten.",
                                errorText: viewModel.dbError)
                        .tag(Page.db)
                    pageContent(rows: viewModel.geopsRows,
                                emptyText: "Keine Geops-Daten für diesen Übergang.",
                                errorText: nil)
                        .tag(Page.geops)
                    pageContent(rows: viewModel.mvgRows,
                                emptyText: "Keine MVG-Daten.",
                                errorText: viewModel.mvgError)
                        .tag(Page.mvg)
                    pageContent(rows: viewModel.dbMvgRows,
                                emptyText: "Keine Daten.",
                                errorText: viewModel.dbError)
                        .tag(Page.dbMvg)
                    pageContent(rows: viewModel.combinedRows,
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
        .onAppear {
            viewModel.startAutoRefresh()
            // Nur EIN .page-TabView im ganzen Projekt (grep-geprüft) — globale Appearance-Werte
            // hier zu setzen betrifft daher keine andere Stelle der App.
            UIPageControl.appearance().currentPageIndicatorTintColor = .black
            UIPageControl.appearance().pageIndicatorTintColor = .systemGray3
        }
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
            }

            HStack(spacing: 8) {
                offsetToggle
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

    /// Schaltet zwischen Bahnhofs-Rohzeiten (aus) und geschätzter Schranken-Durchfahrtszeit
    /// (an, Bahnhofs-Zeit + CrossingLocation.bestOffset) um — siehe ComparisonRow.offsetSeconds.
    private var offsetToggle: some View {
        Button {
            showOffset.toggle()
        } label: {
            Label("Schranken-Zeit", systemImage: showOffset ? "arrow.right.circle.fill" : "arrow.right.circle")
                .font(.caption.bold())
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(showOffset ? Color.accentColor : Color.secondary.opacity(0.15), in: Capsule())
                .foregroundStyle(showOffset ? Color.white : Color.secondary)
        }
        .buttonStyle(.plain)
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
    //
    // Kartenstil + Zeilenaufbau bewusst identisch zu ContentView.upcomingTrainsList/
    // TrainEventRow (Radar-Tab) gehalten — Statuspunkt links, Linien-Badge, Richtung,
    // Soll-Zeit/Verspätung, rechts die Zeit + Countdown-Label. Der Statuspunkt hier ist nur
    // eine GROBE Näherung an CrossingEvent.status(at:) (feste 3.0/2.0-Minuten-Schwellen, ohne
    // openingDelayMinutes) — Rohdaten einer einzelnen Quelle haben keine gelernte
    // Öffnungsverzögerung, anders als im Radar-Tab. Kein eigenes Quellen-Badge mehr auf der
    // Kombiniert-Seite: eine dortige Zeile kann bereits mehrere Quellen zusammengeführt zeigen
    // (siehe APIComparisonViewModel.combinedRows), ein "DB"-Badge wäre da irreführend — die
    // note-Zeile zeigt stattdessen z.B. "Geops ✓" wenn Geops den Zug live bestätigt hat.

    @ViewBuilder
    private func pageContent(rows: [ComparisonRow], emptyText: String, errorText: String?) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let errorText {
                    Text(errorText)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }
                if rows.isEmpty {
                    Text(emptyText)
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                } else {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider() }
                        rowView(row)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .cardStyle()
            .padding(.horizontal)
            .padding(.top, 8)
        }
    }

    private func rowView(_ row: ComparisonRow) -> some View {
        // showOffset an: Bahnhofs-Zeiten + CrossingLocation.bestOffset → geschätzte Schranken-
        // Durchfahrtszeit (siehe offsetToggle/ComparisonRow.crossingTime). Fällt auf die
        // Bahnhofs-Zeit zurück, wenn für diese Zeile kein Offset bekannt ist (z.B. MVG ohne
        // Richtung) — dann bewusst KEIN Hinweis-Icon, "Soll"/Uhrzeit bleiben einfach unverändert.
        let displayScheduled = row.crossingTime(row.scheduledTime, applyOffset: showOffset)
        let displayActual = row.crossingTime(row.actualTime, applyOffset: showOffset)

        return HStack {
            Circle()
                .fill(statusColor(for: displayActual))
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.lineName)
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 6))
                    if let direction = row.direction {
                        Text("→ \(direction)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 4) {
                    Text("Soll \(displayScheduled, style: .time)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if row.delayMinutes > 0 {
                        Text("+\(row.delayMinutes) min")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                if let note = row.note, !note.isEmpty {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(displayActual, style: .time)
                    .font(.subheadline)
                    .fontWeight(.medium)
                timeUntilLabel(for: displayActual)
            }
        }
        .padding(.vertical, 4)
    }

    /// Grobe Näherung an CrossingEvent.status(at:)/CrossingStatus.color (Models.swift) — dieselben
    /// 3.0/2.0-Minuten-Schwellen wie dort, aber ohne openingDelayMinutes (Rohdaten einer einzelnen
    /// Quelle kennen die gelernte Öffnungsverzögerung nicht).
    private func statusColor(for time: Date) -> Color {
        let minutes = time.timeIntervalSinceNow / 60
        let status: CrossingStatus
        if minutes > 3.0        { status = .open }
        else if minutes > 2.0   { status = .warning }
        else if minutes > -1.5  { status = .closed }
        else                    { status = .open }
        return status.color
    }

    @ViewBuilder
    private func timeUntilLabel(for time: Date) -> some View {
        let minutes = time.timeIntervalSinceNow / 60
        let seconds = Int(minutes * 60)

        if minutes < -0.5 {
            Text("passiert")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if minutes < 2 {
            Text("\(max(0, seconds))s")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.red)
        } else {
            Text("in \(Int(minutes)) min")
                .font(.caption)
                .foregroundStyle(minutes < 3 ? .orange : .secondary)
        }
    }
}
