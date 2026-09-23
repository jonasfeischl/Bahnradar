import Foundation
import MetricKit
import Observation

/// Startet/stoppt bei Bedarf (Admin-Button) das Beobachten von Hang-/Crash-/CPU-Diagnosen,
/// die iOS im Hintergrund sammelt — funktioniert auch unterwegs ganz ohne angeschlossenen
/// Mac, im Gegensatz zu Instruments (braucht eine durchgehende Live-Verbindung). Läuft NICHT
/// automatisch beim App-Start, nur zwischen "Starten" und "Stoppen" im Admin-Bereich.
/// Ergebnisse landen im DebugLog. Setzt voraus, dass in den iOS-Einstellungen unter
/// Datenschutz & Sicherheit → Analyse & Verbesserungen → "Mit App-Entwicklern teilen"
/// aktiviert ist, sonst liefert iOS keine Diagnostic-Payloads (Metric-Payloads kommen
/// unabhängig davon).
@Observable
final class MetricKitMonitor: NSObject, MXMetricManagerSubscriber {
    static let shared = MetricKitMonitor()

    private(set) var isRunning = false

    func toggle() {
        isRunning ? stop() : start()
    }

    private func start() {
        MXMetricManager.shared.add(self)
        isRunning = true
        Task { @MainActor in
            DebugLog.shared.add("[MetricKit] Beobachtung gestartet")
        }
    }

    private func stop() {
        MXMetricManager.shared.remove(self)
        isRunning = false
        Task { @MainActor in
            DebugLog.shared.add("[MetricKit] Beobachtung gestoppt")
        }
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            let zeitraum = Self.formattedRange(payload.timeStampBegin, payload.timeStampEnd)
            Task { @MainActor in
                DebugLog.shared.add("[MetricKit] Metrics-Report \(zeitraum)")
            }
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            // Einzeldiagnosen (Hang/Crash/CPU) tragen selbst keinen Zeitstempel (per SDK-Header
            // geprüft: MXDiagnostic hat keinen) — nur das 24h-Fenster des gesamten Payloads sagt
            // grob, wann es passiert sein könnte. Ohne das würde jeder Eintrag nur die Zustellzeit
            // zeigen (oft Tage später, siehe MetricKit-Backlog-Zustellung bei App-Start).
            let zeitraum = Self.formattedRange(payload.timeStampBegin, payload.timeStampEnd)
            for hang in payload.hangDiagnostics ?? [] {
                let seconds = hang.hangDuration.converted(to: .seconds).value
                Task { @MainActor in
                    DebugLog.shared.add(
                        String(format: "[MetricKit] Hang erkannt (%@): %.0f ms", zeitraum, seconds * 1000),
                        level: .warn
                    )
                    DebugLog.shared.add(Self.stackTraceMessage(hang.callStackTree), level: .warn)
                }
            }
            for crash in payload.crashDiagnostics ?? [] {
                let type = crash.exceptionType?.stringValue ?? "?"
                let reason = crash.terminationReason ?? "?"
                Task { @MainActor in
                    DebugLog.shared.add(
                        "[MetricKit] Crash erkannt (\(zeitraum)): Typ \(type), Grund: \(reason)", level: .error
                    )
                    DebugLog.shared.add(Self.stackTraceMessage(crash.callStackTree), level: .error)
                }
            }
            for cpuException in payload.cpuExceptionDiagnostics ?? [] {
                let seconds = cpuException.totalCPUTime.converted(to: .seconds).value
                Task { @MainActor in
                    DebugLog.shared.add(
                        String(format: "[MetricKit] CPU-Exception (%@): %.1f s Gesamt-CPU-Zeit", zeitraum, seconds),
                        level: .warn
                    )
                    DebugLog.shared.add(Self.stackTraceMessage(cpuException.callStackTree), level: .warn)
                }
            }
        }
    }

    private static func formattedRange(_ begin: Date, _ end: Date) -> String {
        "\(begin.formatted(date: .abbreviated, time: .shortened)) – \(end.formatted(date: .abbreviated, time: .shortened))"
    }

    /// Rohes JSON des Stacktrees als eigene Log-Zeile — enthält Binary-UUID + Offsets statt
    /// Funktionsnamen (Apple liefert aus Privacy-Gründen keine Klartext-Symbole). Mit dem dSYM
    /// des betroffenen Builds (Xcode Organizer → Crashes, oder ein Symbolisierungs-Skript)
    /// lässt sich daraus die genaue Funktion rekonstruieren. Bewusst unverändert/unformatiert,
    /// damit Kopieren/Teilen (DebugLogView) den Text 1:1 weitergibt.
    private static func stackTraceMessage(_ tree: MXCallStackTree) -> String {
        guard let json = String(data: tree.jsonRepresentation(), encoding: .utf8) else {
            return "[MetricKit] Stacktrace nicht lesbar (kein UTF-8)"
        }
        return "[MetricKit] Stacktrace: \(json)"
    }
}
