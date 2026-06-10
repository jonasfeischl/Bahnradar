import SwiftUI

struct SettingsView: View {
    var viewModel: CrossingViewModel
    @Bindable var locationMonitor: LocationMonitor
    var voiceAnnouncer: VoiceAnnouncer

    @AppStorage("voiceEnabled") private var voiceEnabled: Bool = true
    @State private var radiusInput: String = ""
    @State private var showDeleteConfirmation = false
    @State private var showHelp = false
    @FocusState private var focusedCrossing: Int?


    var body: some View {
        @Bindable var store = viewModel.store
        NavigationStack {
            Form {

                // MARK: Sprachansagen
                Section {
                    Toggle("Sprachansagen aktiv", isOn: $voiceEnabled)

                    Button {
                        testVoice()
                    } label: {
                        Label("Sprache testen", systemImage: "speaker.wave.2.fill")
                    }
                    .disabled(!voiceEnabled)

                } header: {
                    Text("Sprachansagen")
                } footer: {
                    Text("Sprachansagen werden automatisch ausgelöst wenn du fährst und dich in der Nähe der Schranke befindest.")
                }

                // MARK: Bahnübergänge
                Section {
                    ForEach(0..<store.crossings.count, id: \.self) { index in
                        let crossing = store.crossings[index]
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(crossing.name)
                                        .font(.subheadline.bold())
                                    Text(crossing.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if false {
                                    Label("GPS fehlt", systemImage: "location.slash")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                }
                            }
                            HStack(spacing: 16) {
                                Toggle("Sprache", isOn: $store.crossings[index].voiceEnabled)
                                    .onChange(of: crossing.voiceEnabled) { _, _ in store.update(crossing) }
                                    .labelsHidden()
                                Text("Sprache")
                                    .font(.caption)
                                Spacer()
                                Picker("Radius", selection: $store.crossings[index].radiusMeters) {
                                    Text("200m").tag(200.0)
                                    Text("500m").tag(500.0)
                                    Text("1 km").tag(1000.0)
                                    Text("2 km").tag(2000.0)
                                }
                                .pickerStyle(.menu)
                                .onChange(of: crossing.radiusMeters) { _, _ in store.update(crossing) }
                            }


                            // Timing-Offsets
                            offsetSection(index: index, crossing: crossing)
                                .padding(.top, 4)

                            // Ansage-Template
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Ansage-Text")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                TextField("Ansage…", text: $store.crossings[index].announcementTemplate, axis: .vertical)
                                    .font(.caption)
                                    .padding(8)
                                    .background(Color(.tertiarySystemBackground))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .lineLimit(3...5)
                                    .focused($focusedCrossing, equals: index)
                                    .onChange(of: crossing.announcementTemplate) { _, _ in store.update(crossing) }

                                let placeholders: [(String, String)] = [
                                    ("{status}", "Status"),
                                    ("{linie}", "Linie"),
                                    ("{richtung}", "Richtung"),
                                    ("{zeit}", "Zeit")
                                ]
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 6) {
                                        ForEach(placeholders, id: \.0) { ph, label in
                                            PlaceholderButton(label: label) {
                                                store.crossings[index].announcementTemplate += ph
                                                store.update(store.crossings[index])
                                            }
                                        }
                                        Button {
                                            store.crossings[index].announcementTemplate = CrossingLocation.defaultTemplate
                                            store.update(store.crossings[index])
                                        } label: {
                                            Text("↺ Standard")
                                                .font(.caption2)
                                                .padding(.horizontal, 8).padding(.vertical, 4)
                                                .background(Color(.systemGray5))
                                                .foregroundStyle(.secondary)
                                                .clipShape(Capsule())
                                        }.buttonStyle(.plain)
                                    }
                                }
                                Text("Verfügbar: {status} {linie} {richtung} {zeit}")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("Bahnübergänge")
                } footer: {
                    Text("Sprache und Radius können pro Übergang eingestellt werden.")
                }

                // MARK: Lerndaten
                Section {
                    HStack {
                        Text("Feedbacks gegeben")
                        Spacer()
                        Text("\(viewModel.feedback.feedbackCount)")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Cloud Status")
                        Spacer()
                        HStack(spacing: 6) {
                            Circle()
                                .fill(viewModel.feedback.isCloudConnected ? Color.green : Color.red)
                                .frame(width: 8, height: 8)
                            Text(viewModel.feedback.isCloudConnected ? "Verbunden" : "Offline")
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Label("Meine Lerndaten löschen", systemImage: "trash")
                            .foregroundStyle(.red)
                    }
                    .confirmationDialog(
                        "Lerndaten wirklich löschen?",
                        isPresented: $showDeleteConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("Löschen", role: .destructive) {
                            viewModel.feedback.resetLocalLearning()
                        }
                        Button("Abbrechen", role: .cancel) { }
                    } message: {
                        Text("Nur deine eigenen Korrekturen werden gelöscht. Die geteilten Cloud-Daten anderer Nutzer bleiben erhalten.")
                    }

                } header: {
                    Text("Lerndaten")
                }
            }
            .navigationTitle("Einstellungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showHelp = true
                    } label: {
                        Image(systemName: "questionmark.circle")
                    }
                }
            }
            .sheet(isPresented: $showHelp) {
                HelpView()
            }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Fertig") { focusedCrossing = nil }
                }
            }
            .onAppear {
                radiusInput = "\(Int(locationMonitor.radius))"
            }
        }
    }

    // MARK: - Offset-Sektion

    @ViewBuilder
    private func offsetSection(index: Int, crossing: CrossingLocation) -> some View {
        @Bindable var store = viewModel.store

        let community = viewModel.communityOffsets[crossing.id]
        DisclosureGroup {
            VStack(spacing: 10) {

                // → München
                directionOffsetRow(
                    label: "→ München",
                    measured: crossing.measuredOffsetToMunich,
                    localCount: crossing.autoMeasurementsMunich,
                    communityCount: community?.munichCount ?? 0,
                    source: crossing.offsetSource(toMunich: true, communityMunich: community?.munich),
                    fallback: crossing.offsetToMunich,
                    binding: $store.crossings[index].offsetToMunich,
                    onStepperChange: { store.update(store.crossings[index]) }
                )

                // → Freising
                directionOffsetRow(
                    label: "→ Freising",
                    measured: crossing.measuredOffsetToFreising,
                    localCount: crossing.autoMeasurementsFreising,
                    communityCount: community?.freisingCount ?? 0,
                    source: crossing.offsetSource(toMunich: false, communityFreising: community?.freising),
                    fallback: crossing.offsetToFreising,
                    binding: $store.crossings[index].offsetToFreising,
                    onStepperChange: { store.update(store.crossings[index]) }
                )

                // Sync-Status + Reset
                HStack(spacing: 6) {
                    syncStatusBadge(crossing: crossing, community: community)
                    Spacer()
                    if crossing.measuredOffsetToMunich != nil || crossing.measuredOffsetToFreising != nil {
                        Button("Messungen löschen") {
                            var c = crossing
                            c.measuredOffsetToMunich   = nil
                            c.measuredOffsetToFreising = nil
                            c.gpsOffsetMeasurements    = 0
                            c.autoMeasurementsMunich   = 0
                            c.autoMeasurementsFreising = 0
                            store.update(c)
                        }
                        .font(.caption2)
                        .foregroundStyle(.red)
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: offsetIcon(crossing))
                    .foregroundStyle(offsetColor(crossing))
                    .font(.caption)
                Text("Timing")
                    .font(.caption)
                    .foregroundStyle(offsetColor(crossing))
                Text(offsetSummary(crossing))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Offset-Hilfsviews

    @ViewBuilder
    private func directionOffsetRow(
        label: String,
        measured: Double?,
        localCount: Int,
        communityCount: Int,
        source: CrossingLocation.OffsetSource,
        fallback: Double,
        binding: Binding<Double>,
        onStepperChange: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .frame(width: 90, alignment: .leading)

            switch source {
            case .local:
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.blue).font(.caption2)
                Text("\(Int(measured ?? fallback))s")
                    .font(.caption.bold()).foregroundStyle(.blue)
                Text("lokal (\(localCount)×)")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()

            case .community:
                Image(systemName: "person.2.fill").foregroundStyle(.teal).font(.caption2)
                Text("\(Int(measured ?? fallback))s")
                    .font(.caption.bold()).foregroundStyle(.teal)
                Text("community (\(communityCount)×)")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()

            case .estimate:
                Stepper(
                    value: binding,
                    in: -300...300,
                    step: 5
                ) {
                    Text("\(Int(binding.wrappedValue))s")
                        .font(.caption.bold())
                    + Text(" (Schätzung)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .onChange(of: binding.wrappedValue) { _, _ in onStepperChange() }
            }
        }
    }

    @ViewBuilder
    private func syncStatusBadge(crossing: CrossingLocation, community: CommunityGPSOffsets?) -> some View {
        let localTotal = crossing.autoMeasurementsMunich + crossing.autoMeasurementsFreising
        let communityTotal = (community?.munichCount ?? 0) + (community?.freisingCount ?? 0)

        if !viewModel.gpsCloudSynced {
            Label("Synchronisiere…", systemImage: "icloud.and.arrow.down")
                .font(.caption2).foregroundStyle(.secondary)
        } else if localTotal > 0 || communityTotal > 0 {
            HStack(spacing: 4) {
                Image(systemName: "icloud.fill").foregroundStyle(.teal).font(.caption2)
                if localTotal > 0 {
                    Text("\(localTotal) lokal").font(.caption2).foregroundStyle(.blue)
                }
                if communityTotal > 0 {
                    Text("· \(communityTotal) community").font(.caption2).foregroundStyle(.teal)
                }
            }
        } else {
            Label("Noch keine GPS-Daten", systemImage: "location.slash")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func offsetIcon(_ c: CrossingLocation) -> String {
        let community = viewModel.communityOffsets[c.id]
        let src = [c.offsetSource(toMunich: true, communityMunich: community?.munich),
                   c.offsetSource(toMunich: false, communityFreising: community?.freising)]
        if src.allSatisfy({ $0 == .local }) { return "checkmark.seal.fill" }
        if src.contains(.local) || src.contains(.community) { return "checkmark.circle.fill" }
        return "ruler"
    }

    private func offsetColor(_ c: CrossingLocation) -> Color {
        let community = viewModel.communityOffsets[c.id]
        let src = [c.offsetSource(toMunich: true, communityMunich: community?.munich),
                   c.offsetSource(toMunich: false, communityFreising: community?.freising)]
        if src.contains(.local) { return .blue }
        if src.contains(.community) { return .teal }
        return .secondary
    }

    private func offsetSummary(_ c: CrossingLocation) -> String {
        let community = viewModel.communityOffsets[c.id]
        let mOff = c.bestOffset(toMunich: true, communityMunich: community?.munich)
        let fOff = c.bestOffset(toMunich: false, communityFreising: community?.freising)
        let mSrc = c.offsetSource(toMunich: true, communityMunich: community?.munich)
        let fSrc = c.offsetSource(toMunich: false, communityFreising: community?.freising)
        let mMark = mSrc == .estimate ? "" : " ✓"
        let fMark = fSrc == .estimate ? "" : " ✓"
        return "Mchn: \(Int(mOff))s\(mMark) · Fsg: \(Int(fOff))s\(fMark)"
    }

    private func testVoice() {
        let status = viewModel.worstUpcomingStatus
        let next = viewModel.nextEvents.first { $0.minutesUntil > 0 }
        let template = viewModel.selectedCrossing.announcementTemplate
        voiceAnnouncer.announce(status: status, nextEvent: next, template: template.isEmpty ? nil : template)
    }
}

// MARK: - Placeholder Button

struct PlaceholderButton: View {
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text("+ \(label)")
                .font(.caption2)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.15))
                .foregroundStyle(Color.accentColor)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Hilfe

struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                helpSection(
                    icon: "antenna.radiowaves.left.and.right",
                    color: .blue,
                    title: "Radar Tab",
                    text: "Zeigt den aktuellen Status des ausgewählten Bahnübergangs. Die Ampel zeigt ob die Schranke vermutlich offen, schließt bald oder geschlossen ist — basierend auf echten Zugdaten der Deutschen Bahn."
                )

                helpSection(
                    icon: "line.3.horizontal",
                    color: .blue,
                    title: "Bahnübergänge wechseln",
                    text: "Tippe oben links auf die drei Striche um zwischen den Bahnübergängen zu wechseln. Die App wechselt auch automatisch wenn du in den Radius eines Übergangs fährst."
                )

                helpSection(
                    icon: "record.circle",
                    color: .red,
                    title: "Schranken-Modus",
                    text: "Hier kannst du manuell aufzeichnen wann die Schranke zu und wieder auf geht. Die App lernt automatisch aus deinen Beobachtungen und wird dadurch genauer."
                )

                helpSection(
                    icon: "checkmark.circle.fill",
                    color: .green,
                    title: "Stimmt / Stimmt nicht",
                    text: "Mit diesen Buttons gibst du Feedback ob die Vorhersage korrekt war. Das hilft der App zu lernen. Dein Feedback wird mit allen Nutzern in der Cloud geteilt."
                )

                helpSection(
                    icon: "speaker.wave.2.fill",
                    color: .orange,
                    title: "Sprachansagen",
                    text: "Wenn du im Auto sitzt und dich in der Nähe eines Bahnübergangs befindest, sagt die App automatisch den Status an. Sprache und Radius können pro Übergang in den Einstellungen konfiguriert werden."
                )

                helpSection(
                    icon: "location.circle.fill",
                    color: .blue,
                    title: "Erkennungsradius",
                    text: "Jeder Bahnübergang hat seinen eigenen Radius. Bestimmt wie nah du sein musst damit Sprachansagen ausgelöst werden und die App automatisch wechselt. Einstellbar pro Übergang im Einstellungs-Tab."
                )

                helpSection(
                    icon: "brain",
                    color: .purple,
                    title: "Lerndaten",
                    text: "Die App lernt aus deinem Feedback. Die Lerndaten werden in der Cloud gespeichert und mit allen Nutzern geteilt — so wird die App für alle besser. Du kannst nur deine eigenen Daten löschen."
                )

                helpSection(
                    icon: "exclamationmark.triangle.fill",
                    color: .yellow,
                    title: "Hinweis",
                    text: "Güterzüge und Sonderfahrten können nicht erkannt werden da sie nicht im öffentlichen Fahrplan stehen. Alle Angaben sind Schätzungen — niemals auf die App verlassen wenn es um Sicherheit geht."
                )
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Hilfe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }

    private func helpSection(icon: String, color: Color, title: String, text: String) -> some View {
        Section {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(color)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.subheadline.bold())
                    Text(text)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }
}
