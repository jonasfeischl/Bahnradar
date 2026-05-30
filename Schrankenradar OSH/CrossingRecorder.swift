import Foundation
import Observation

// MARK: - Zugtyp

enum RecordedTrainType: String, Codable, CaseIterable {
    case sBahn     = "S-Bahn"
    case sonderzug = "Sonderzug"
    case both      = "S-Bahn + Sonderzug"

    var icon: String {
        switch self {
        case .sBahn:     "tram.fill"
        case .sonderzug: "exclamationmark.triangle.fill"
        case .both:      "tram.fill.tunnel"
        }
    }
}

// MARK: - Aufzeichnung

struct CrossingRecord: Identifiable, Codable {
    let id: UUID
    let closedAt: Date
    var openedAt: Date?
    var trainType: RecordedTrainType?

    init(closedAt: Date) {
        self.id       = UUID()
        self.closedAt = closedAt
    }

    var duration: TimeInterval? {
        guard let openedAt else { return nil }
        return openedAt.timeIntervalSince(closedAt)
    }

    var durationText: String {
        guard let d = duration else { return "läuft…" }
        let minutes = Int(d) / 60
        let seconds = Int(d) % 60
        return minutes > 0 ? "\(minutes) min \(seconds) s" : "\(seconds) s"
    }
}

// MARK: - Recorder

private let keyRecords = "crossingRecords"

@Observable
final class CrossingRecorder {

    enum RecorderState {
        case idle
        case closed(since: Date)
        case selectingType(record: CrossingRecord)
    }

    private(set) var recorderState: RecorderState = .idle
    private(set) var records: [CrossingRecord] = []

    /// Laufende Zeit seit Schließen (für Timer-Anzeige)
    var elapsedSeconds: Int {
        if case .closed(let since) = recorderState {
            return Int(Date().timeIntervalSince(since))
        }
        return 0
    }

    init() {
        records = Self.load()
    }

    // MARK: Aktionen

    func markClosed() {
        recorderState = .closed(since: Date())
    }

    func markOpen() {
        guard case .closed(let since) = recorderState else { return }
        let record = CrossingRecord(closedAt: since)
        recorderState = .selectingType(record: record)
    }

    func confirmType(_ type: RecordedTrainType) {
        guard case .selectingType(var record) = recorderState else { return }
        record.openedAt  = Date()
        record.trainType = type
        records.insert(record, at: 0)
        if records.count > 200 { records.removeLast() }
        save()
        recorderState = .idle
    }

    func cancel() {
        recorderState = .idle
    }

    // MARK: Persist

    private func save() {
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: keyRecords)
        }
    }

    private static func load() -> [CrossingRecord] {
        guard let data = UserDefaults.standard.data(forKey: keyRecords),
              let decoded = try? JSONDecoder().decode([CrossingRecord].self, from: data)
        else { return [] }
        return decoded
    }
}
