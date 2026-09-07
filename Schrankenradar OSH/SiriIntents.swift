import AppIntents
import Foundation

// MARK: - Crossing Enum (für Shortcuts-App UI)

enum CrossingOption: String, AppEnum {
    case oshdachauer       = "osh_dachauer"
    case lerchenauer1       = "feldmoching_lerchenauer1"
    case lerchenauer2       = "feldmoching_lerchenauer2"
    case feldmochinger     = "feldmoching_feldmochinger"

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Bahnübergang"

    static var caseDisplayRepresentations: [CrossingOption: DisplayRepresentation] = [
        .oshdachauer:   DisplayRepresentation(title: "Oberschleißheimer Schranke"),
        .lerchenauer1:   DisplayRepresentation(title: "erste Feldmochinger Schranke"),
        .lerchenauer2:   DisplayRepresentation(title: "zweite Feldmochinger Schranke"),
        .feldmochinger: DisplayRepresentation(title: "Fasanerier Schranke"),
    ]

    var crossingLocation: CrossingLocation? {
        CrossingLocation.all.first { $0.id == rawValue }
    }

    var spokenName: String {
        switch self {
        case .oshdachauer:   return "Dachauer Straße in Oberschleißheim"
        case .lerchenauer1:   return "ersten Feldmochinger Straße"
        case .lerchenauer2:   return "zweiten Feldmochinger Straße"
        case .feldmochinger: return "Fasanerier Straße"
        }
    }
}

// MARK: - Shared Logic
// @MainActor nötig, da UserDefaults.standard in Swift 6 main-actor-isoliert ist.

@MainActor
private func statusText(for crossingId: String) -> String {
    let raw = UserDefaults.standard.string(forKey: "lastStatus_\(crossingId)") ?? "unknown"
    switch raw {
    case "open":    return "wahrscheinlich offen"
    case "warning": return "schließt bald"
    case "closed":  return "wahrscheinlich geschlossen"
    case "opening": return "öffnet gerade"
    default:        return "unbekannt — bitte App öffnen"
    }
}

@MainActor
private func nextTrainMessage(for crossing: CrossingOption) -> String {
    let id = crossing.rawValue
    guard
        let line      = UserDefaults.standard.string(forKey: "nextTrain_line_\(id)"),
        let direction = UserDefaults.standard.string(forKey: "nextTrain_direction_\(id)"),
        let time      = UserDefaults.standard.object(forKey: "nextTrain_time_\(id)") as? Date
    else {
        return "Kein Zug in den nächsten 90 Minuten an der \(crossing.spokenName)."
    }

    let minutes = Int(time.timeIntervalSinceNow / 60)
    let fmt = DateFormatter(); fmt.dateFormat = "HH:mm"
    let timeStr = fmt.string(from: time)

    if minutes <= 0 {
        return "Der \(line) Richtung \(direction) ist gerade an der \(crossing.spokenName)."
    } else if minutes == 1 {
        return "Der nächste \(line) Richtung \(direction) kommt in einer Minute an der \(crossing.spokenName)."
    } else {
        return "Der nächste \(line) Richtung \(direction) kommt in \(minutes) Minuten um \(timeStr) Uhr an der \(crossing.spokenName)."
    }
}

// MARK: - Allgemeiner Intent (für Shortcuts-App mit Parameter-Auswahl)

struct CrossingStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Bahnübergang Status"
    static var description = IntentDescription("Fragt den Status eines Bahnübergangs ab.", categoryName: "Schrankenradar")

    @Parameter(title: "Bahnübergang")
    var crossing: CrossingOption

    static var parameterSummary: some ParameterSummary {
        Summary("Status vom \(\.$crossing) abfragen")
    }

    func perform() async throws -> some ProvidesDialog & ReturnsValue<String> {
        let msg = "Der Bahnübergang \(crossing.spokenName) ist \(await statusText(for: crossing.rawValue))."
        return .result(value: msg, dialog: IntentDialog(stringLiteral: msg))
    }
}

struct NextTrainIntent: AppIntent {
    static var title: LocalizedStringResource = "Nächster Zug"
    static var description = IntentDescription("Sagt wann der nächste Zug den Bahnübergang passiert.", categoryName: "Schrankenradar")

    @Parameter(title: "Bahnübergang")
    var crossing: CrossingOption

    static var parameterSummary: some ParameterSummary {
        Summary("Nächster Zug an der \(\.$crossing)")
    }

    func perform() async throws -> some ProvidesDialog & ReturnsValue<String> {
        let msg = await nextTrainMessage(for: crossing)
        return .result(value: msg, dialog: IntentDialog(stringLiteral: msg))
    }
}

// MARK: - Parameterlose Siri-Intents (sprechen direkt, keine Auswahl)

struct OshStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Status Oberschleißheimer Schranke"
    func perform() async throws -> some ProvidesDialog & ReturnsValue<String> {
        let msg = "Der Bahnübergang \(CrossingOption.oshdachauer.spokenName) ist \(await statusText(for: CrossingOption.oshdachauer.rawValue))."
        return .result(value: msg, dialog: IntentDialog(stringLiteral: msg))
    }
}

struct OshNextTrainIntent: AppIntent {
    static var title: LocalizedStringResource = "Nächster Zug Oberschleißheim"
    func perform() async throws -> some ProvidesDialog & ReturnsValue<String> {
        let msg = await nextTrainMessage(for: .oshdachauer)
        return .result(value: msg, dialog: IntentDialog(stringLiteral: msg))
    }
}

struct Lerchenauer1StatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Status erste Feldmochinger Schranke"
    func perform() async throws -> some ProvidesDialog & ReturnsValue<String> {
        let msg = "Der Bahnübergang \(CrossingOption.lerchenauer1.spokenName) ist \(await statusText(for: CrossingOption.lerchenauer1.rawValue))."
        return .result(value: msg, dialog: IntentDialog(stringLiteral: msg))
    }
}

struct Lerchenauer1NextTrainIntent: AppIntent {
    static var title: LocalizedStringResource = "Nächster Zug erste Feldmochinger"
    func perform() async throws -> some ProvidesDialog & ReturnsValue<String> {
        let msg = await nextTrainMessage(for: .lerchenauer1)
        return .result(value: msg, dialog: IntentDialog(stringLiteral: msg))
    }
}

struct Lerchenauer2StatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Status zweite Feldmochinger Schranke"
    func perform() async throws -> some ProvidesDialog & ReturnsValue<String> {
        let msg = "Der Bahnübergang \(CrossingOption.lerchenauer2.spokenName) ist \(await statusText(for: CrossingOption.lerchenauer2.rawValue))."
        return .result(value: msg, dialog: IntentDialog(stringLiteral: msg))
    }
}

struct Lerchenauer2NextTrainIntent: AppIntent {
    static var title: LocalizedStringResource = "Nächster Zug zweite Feldmochinger"
    func perform() async throws -> some ProvidesDialog & ReturnsValue<String> {
        let msg = await nextTrainMessage(for: .lerchenauer2)
        return .result(value: msg, dialog: IntentDialog(stringLiteral: msg))
    }
}

struct FeldmochingerStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Status Fasanerier Schranke"
    func perform() async throws -> some ProvidesDialog & ReturnsValue<String> {
        let msg = "Der Bahnübergang \(CrossingOption.feldmochinger.spokenName) ist \(await statusText(for: CrossingOption.feldmochinger.rawValue))."
        return .result(value: msg, dialog: IntentDialog(stringLiteral: msg))
    }
}

struct FeldmochingerNextTrainIntent: AppIntent {
    static var title: LocalizedStringResource = "Nächster Zug Fasanerie"
    func perform() async throws -> some ProvidesDialog & ReturnsValue<String> {
        let msg = await nextTrainMessage(for: .feldmochinger)
        return .result(value: msg, dialog: IntentDialog(stringLiteral: msg))
    }
}

// MARK: - App Shortcuts (Siri-Phrasen)

struct CrossingAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {

        // Oberschleißheim
        AppShortcut(
            intent: OshStatusIntent(),
            phrases: [
                "Status Oberschleißheimer Schranke in \(.applicationName)",
                "Oberschleißheimer Schranke in \(.applicationName)",
                "Ist die Oberschleißheimer Schranke offen in \(.applicationName)",
                "Ist die Oberschleißheimer Schranke zu in \(.applicationName)",
            ],
            shortTitle: "Schranke OSH",
            systemImageName: "train.side.front.car"
        )

        AppShortcut(
            intent: OshNextTrainIntent(),
            phrases: [
                "Nächster Zug Oberschleißheim in \(.applicationName)",
                "Wann schließt die Oberschleißheimer Schranke in \(.applicationName)",
            ],
            shortTitle: "Zug OSH",
            systemImageName: "tram.fill"
        )

        // Feldmochinger Straße 1
        AppShortcut(
            intent: Lerchenauer1StatusIntent(),
            phrases: [
                "Status erste Feldmochinger Schranke in \(.applicationName)",
                "Erste Feldmochinger Schranke in \(.applicationName)",
                "Ist die erste Feldmochinger Schranke offen in \(.applicationName)",
            ],
            shortTitle: "Schranke Feldmochinger 1",
            systemImageName: "train.side.front.car"
        )

        AppShortcut(
            intent: Lerchenauer1NextTrainIntent(),
            phrases: [
                "Nächster Zug erste Feldmochinger in \(.applicationName)",
                "Wann schließt die erste Feldmochinger Schranke in \(.applicationName)",
            ],
            shortTitle: "Zug Feldmochinger 1",
            systemImageName: "tram.fill"
        )

        // Feldmochinger Straße 2
        AppShortcut(
            intent: Lerchenauer2StatusIntent(),
            phrases: [
                "Status zweite Feldmochinger Schranke in \(.applicationName)",
                "Zweite Feldmochinger Schranke in \(.applicationName)",
                "Ist die zweite Feldmochinger Schranke offen in \(.applicationName)",
            ],
            shortTitle: "Schranke Feldmochinger 2",
            systemImageName: "train.side.front.car"
        )

        AppShortcut(
            intent: Lerchenauer2NextTrainIntent(),
            phrases: [
                "Nächster Zug zweite Feldmochinger in \(.applicationName)",
                "Wann schließt die zweite Feldmochinger Schranke in \(.applicationName)",
            ],
            shortTitle: "Zug Feldmochinger 2",
            systemImageName: "tram.fill"
        )

        // Fasanerie
        AppShortcut(
            intent: FeldmochingerStatusIntent(),
            phrases: [
                "Status Fasanerier Schranke in \(.applicationName)",
                "Fasanerier Schranke in \(.applicationName)",
                "Ist die Fasanerier Schranke offen in \(.applicationName)",
            ],
            shortTitle: "Schranke Fasanerie",
            systemImageName: "train.side.front.car"
        )

        AppShortcut(
            intent: FeldmochingerNextTrainIntent(),
            phrases: [
                "Nächster Zug Fasanerie in \(.applicationName)",
                "Wann schließt die Fasanerier Schranke in \(.applicationName)",
            ],
            shortTitle: "Zug Fasanerie",
            systemImageName: "tram.fill"
        )
    }
}
