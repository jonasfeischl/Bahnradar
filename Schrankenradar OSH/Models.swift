import SwiftUI

// MARK: - Crossing Status

enum CrossingStatus: Equatable {
    case open
    case warning
    case closed
    case opening

    var rawString: String {
        switch self {
        case .open:    "open"
        case .warning: "warning"
        case .closed:  "closed"
        case .opening: "opening"
        }
    }

    var color: Color {
        switch self {
        case .open:    .green
        case .warning: .yellow
        case .closed:  .red
        case .opening: .yellow
        }
    }

    var label: String {
        switch self {
        case .open:    "Vermutlich offen"
        case .warning: "Schließt bald"
        case .closed:  "Wahrscheinlich geschlossen"
        case .opening: "Öffnet gleich"
        }
    }

    var emoji: String {
        switch self {
        case .open:    "🟢"
        case .warning: "🟡"
        case .closed:  "🔴"
        case .opening: "🟡"
        }
    }

    var systemImage: String {
        switch self {
        case .open:    "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .closed:  "xmark.octagon.fill"
        case .opening: "arrow.up.circle.fill"
        }
    }
}

// MARK: - Train

enum TrainDirection {
    case toMunich
    case toFreising

    var label: String {
        switch self {
        case .toMunich: "→ München"
        case .toFreising: "→ Freising/Flughafen"
        }
    }
}

struct TrainDeparture: Identifiable {
    let id: String
    let lineName: String
    let direction: String
    let resolvedDirection: TrainDirection
    let scheduledTime: Date
    let actualTime: Date
    let delayMinutes: Int
    let isArrival: Bool
}

// MARK: - Crossing Event

struct CrossingEvent: Identifiable {
    let id: String
    let train: TrainDeparture
    let estimatedCrossingTime: Date
    /// Wie lange die Schranke nach Zugdurchfahrt geschlossen bleibt (in Minuten)
    let openingDelayMinutes: Double

    func minutesUntil(from date: Date) -> Double {
        estimatedCrossingTime.timeIntervalSince(date) / 60
    }

    func status(at date: Date) -> CrossingStatus {
        let minutes = minutesUntil(from: date)
        if minutes > 3.5                         { return .open }
        if minutes > 2.5                         { return .warning }
        if minutes > -openingDelayMinutes        { return .closed }
        if minutes > -openingDelayMinutes - 0.17 { return .opening }
        return .open
    }

    // Kompatibilität für Code der kein explizites Datum braucht
    var minutesUntil: Double { minutesUntil(from: Date()) }
    var status: CrossingStatus { status(at: Date()) }
}
