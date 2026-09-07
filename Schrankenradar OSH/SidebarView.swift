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
                    .transition(.opacity)

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

    /// Übergänge nach Ort gruppiert (z.B. "Oberschleißheim", "Feldmoching") in der
    /// Reihenfolge ihres ersten Auftretens — macht die Liste bei mehreren Übergängen
    /// pro Ort übersichtlicher als eine flache Liste.
    private var groupedCrossings: [(location: String, crossings: [CrossingLocation])] {
        var order: [String] = []
        var groups: [String: [CrossingLocation]] = [:]
        for crossing in store.crossings {
            if groups[crossing.subtitle] == nil {
                order.append(crossing.subtitle)
                groups[crossing.subtitle] = []
            }
            groups[crossing.subtitle]?.append(crossing)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(groupedCrossings, id: \.location) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.location.uppercased())
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)

                            VStack(spacing: 6) {
                                ForEach(group.crossings) { crossing in
                                    CrossingRow(crossing: crossing, isSelected: store.selectedId == crossing.id) {
                                        store.select(crossing)
                                        withAnimation(.easeOut(duration: 0.25)) { isOpen = false }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
        }
        .background(Color(.systemBackground))
        .ignoresSafeArea(edges: .vertical)
        .shadow(color: .black.opacity(0.15), radius: 16, x: 8, y: 0)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "tram.fill")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("Bahnübergänge")
                    .font(.title3.bold())
                Text("Wähle deinen Übergang")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
                RoundedRectangle(cornerRadius: 2)
                    .fill(isSelected ? Color.accentColor : .clear)
                    .frame(width: 3)

                Text(crossing.name)
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)

                Spacer()

                if crossing.voiceEnabled {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Image(systemName: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(Color.accentColor)
                    .opacity(isSelected ? 1 : 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 13)
            .background(isSelected ? Color.accentColor.opacity(0.08) : Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}
