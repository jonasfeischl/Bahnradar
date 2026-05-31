import SwiftUI

struct SettingsView: View {
    var viewModel: CrossingViewModel
    @Bindable var locationMonitor: LocationMonitor
    var voiceAnnouncer: VoiceAnnouncer

    @AppStorage("voiceEnabled") private var voiceEnabled: Bool = true
    @State private var radiusInput: String = ""
    @State private var showDeleteConfirmation = false
    @State private var showHelp = false

    var body: some View {
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

                // MARK: Radius
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Aktueller Radius:")
                            Spacer()
                            Text("\(Int(locationMonitor.radius)) m")
                                .foregroundStyle(.secondary)
                        }

                        Slider(
                            value: $locationMonitor.radius,
                            in: 500...10000,
                            step: 500
                        )
                        .tint(.blue)

                        HStack {
                            Text("500 m")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("10 km")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Schnellwahl
                    HStack(spacing: 10) {
                        ForEach([1000, 2000, 5000], id: \.self) { value in
                            Button {
                                locationMonitor.radius = Double(value)
                            } label: {
                                Text(value >= 1000 ? "\(value/1000) km" : "\(value) m")
                                    .font(.caption)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .background(locationMonitor.radius == Double(value)
                                        ? Color.blue.opacity(0.15)
                                        : Color(.secondarySystemBackground))
                                    .foregroundStyle(locationMonitor.radius == Double(value)
                                        ? .blue : .primary)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                } header: {
                    Text("Erkennungsradius")
                } footer: {
                    Text("Wie weit vom Bahnübergang entfernt Sprachansagen ausgelöst werden.")
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
            .onAppear {
                radiusInput = "\(Int(locationMonitor.radius))"
            }
        }
    }

    private func testVoice() {
        let status = viewModel.worstUpcomingStatus
        let next = viewModel.nextEvents.first { $0.minutesUntil > 0 }
        voiceAnnouncer.announce(status: status, nextEvent: next)
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
                    text: "Zeigt den aktuellen Status des Bahnübergangs Dachauer Str. in Oberschleißheim. Die Ampel zeigt ob die Schranke vermutlich offen, schließt bald oder geschlossen ist — basierend auf echten Zugdaten der Deutschen Bahn."
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
                    text: "Wenn du im Auto sitzt und dich in der Nähe der Schranke befindest, sagt die App automatisch den Status der Schranke an. Den Radius kannst du hier einstellen. Mit 'Sprache testen' kannst du prüfen ob die Ansage funktioniert."
                )

                helpSection(
                    icon: "location.circle.fill",
                    color: .blue,
                    title: "Erkennungsradius",
                    text: "Bestimmt wie nah du am Bahnübergang sein musst damit Sprachansagen ausgelöst werden. Kleiner Radius = nur direkt an der Schranke. Großer Radius = auch von weiter weg."
                )

                helpSection(
                    icon: "brain",
                    color: .purple,
                    title: "Lerndaten",
                    text: "Die App lernt aus deinem Feedback und aus dem Schranken-Modus. Die Lerndaten werden in der Cloud gespeichert und mit allen Nutzern geteilt — so wird die App für alle besser. Du kannst nur deine eigenen Daten löschen."
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
