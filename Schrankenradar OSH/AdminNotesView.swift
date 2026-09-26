import SwiftUI

/// Freier Merkzettel für offene To-Dos ("was die App noch braucht") — nur im Admin-Bereich
/// erreichbar (siehe SettingsView, adminUnlocked-Kommentar), damit unterwegs schnell was
/// notiert werden kann, ohne Xcode oder eine separate Notizen-App zu öffnen.
struct AdminNotesView: View {
    @State private var notes: [AdminNote] = AdminNoteStore.load()
    @State private var newNoteText = ""

    var body: some View {
        List {
            Section {
                HStack(alignment: .top) {
                    TextField("Neue Notiz...", text: $newNoteText, axis: .vertical)
                    Button {
                        addNote()
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                    }
                    .disabled(newNoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            if !notes.isEmpty {
                Section {
                    ForEach(notes) { note in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(note.text)
                            Text(note.createdAt, style: .date)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onDelete(perform: deleteNotes)
                } footer: {
                    Text("Nach links wischen zum Löschen, sobald erledigt.")
                }
            }
        }
        .navigationTitle("Notizen")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func addNote() {
        let trimmed = newNoteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        notes.insert(AdminNote(id: UUID(), text: trimmed, createdAt: Date()), at: 0)
        newNoteText = ""
        AdminNoteStore.save(notes)
    }

    private func deleteNotes(at offsets: IndexSet) {
        notes.remove(atOffsets: offsets)
        AdminNoteStore.save(notes)
    }
}

private struct AdminNote: Identifiable, Codable {
    let id: UUID
    let text: String
    let createdAt: Date
}

/// Gleiches Persistenz-Muster wie TripRecord/FavoriteDestination (JSONEncoder → UserDefaults).
private enum AdminNoteStore {
    private static let key = "adminNotes"

    static func load() -> [AdminNote] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let notes = try? JSONDecoder().decode([AdminNote].self, from: data) else { return [] }
        return notes
    }

    static func save(_ notes: [AdminNote]) {
        guard let data = try? JSONEncoder().encode(notes) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

#Preview {
    NavigationStack { AdminNotesView() }
}
