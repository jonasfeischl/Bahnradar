import SwiftUI

// MARK: - Sidebar (öffnet sich von links)

struct SidebarContainerView<Content: View>: View {
    @Binding var isOpen: Bool
    let store: CrossingsStore
    let content: Content

    init(isOpen: Binding<Bool>, store: CrossingsStore, @ViewBuilder content: () -> Content) {
        self._isOpen = isOpen
        self.store = store
        self.content = content()
    }

    var body: some View {
        ZStack(alignment: .leading) {
            content

            if isOpen {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation(.easeOut(duration: 0.25)) { isOpen = false } }

                SidebarPanel(isOpen: $isOpen, store: store)
                    .frame(width: 300)
                    .transition(.move(edge: .leading))
                    .zIndex(1)
            }
        }
        .animation(.easeOut(duration: 0.25), value: isOpen)
    }
}

// MARK: - Sidebar Inhalt

struct SidebarPanel: View {
    @Binding var isOpen: Bool
    var store: CrossingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Header
            HStack {
                Text("Bahnübergänge")
                    .font(.title2.bold())
                Spacer()
                Button {
                    withAnimation(.easeOut(duration: 0.25)) { isOpen = false }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.title2)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 60)
            .padding(.bottom, 16)

            Divider()

            // Bahnübergänge Liste
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(store.crossings) { crossing in
                        CrossingRow(crossing: crossing, isSelected: store.selectedId == crossing.id) {
                            store.select(crossing)
                            withAnimation(.easeOut(duration: 0.25)) { isOpen = false }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }

        }
        .background(Color(.systemBackground))
        .ignoresSafeArea(edges: .vertical)
    }
}

// MARK: - Einzelne Zeile

struct CrossingRow: View {
    let crossing: CrossingLocation
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Status-Indikator
                Circle()
                    .fill(isSelected ? Color.accentColor : Color(.systemGray4))
                    .frame(width: 10, height: 10)

                VStack(alignment: .leading, spacing: 2) {
                    Text(crossing.name)
                        .font(.subheadline.bold())
                        .foregroundStyle(.primary)
                    Text(crossing.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Voice Badge
                if crossing.voiceEnabled {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }

                // TODO-Koordinaten Hinweis
                if false {
                    Image(systemName: "location.slash")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Einstellungen für alle Übergänge

struct CrossingsSettingsView: View {
    @Bindable var store: CrossingsStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach($store.crossings) { $crossing in
                    Section {
                        // Voice Toggle
                        Toggle("Sprachansagen", isOn: $crossing.voiceEnabled)
                            .onChange(of: crossing.voiceEnabled) { _, _ in
                                store.update(crossing)
                            }

                        // Radius
                        HStack {
                            Label("Radius", systemImage: "circle.dashed")
                            Spacer()
                            Picker("", selection: $crossing.radiusMeters) {
                                Text("200m").tag(200.0)
                                Text("500m").tag(500.0)
                                Text("1 km").tag(1000.0)
                                Text("2 km").tag(2000.0)
                            }
                            .pickerStyle(.menu)
                            .onChange(of: crossing.radiusMeters) { _, _ in
                                store.update(crossing)
                            }
                        }

                        // GPS-Koordinaten Status
                        if false {
                            HStack {
                                Image(systemName: "location.slash")
                                    .foregroundStyle(.orange)
                                Text("Koordinaten noch nicht gemessen")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }

                    } header: {
                        HStack {
                            Text(crossing.name)
                            Text("· \(crossing.subtitle)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Einstellungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
    }
}
