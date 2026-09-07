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
            let begin = payload.timeStampBegin, end = payload.timeStampEnd
            Task { @MainActor in
                DebugLog.shared.add("[MetricKit] Metrics-Report \(begin.formatted(date: .abbreviated, time: .shortened)) – \(end.formatted(date: .abbreviated, time: .shortened))")
            }
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for hang in payload.hangDiagnostics ?? [] {
                let seconds = hang.hangDuration.converted(to: .seconds).value
                Task { @MainActor in
                    DebugLog.shared.add(
                        String(format: "[MetricKit] Hang erkannt: %.0f ms", seconds * 1000),
                        level: .warn
                    )
                }
            }
            for crash in payload.crashDiagnostics ?? [] {
                let type = crash.exceptionType?.stringValue ?? "?"
                let reason = crash.terminationReason ?? "?"
                Task { @MainActor in
                    DebugLog.shared.add("[MetricKit] Crash erkannt: Typ \(type), Grund: \(reason)", level: .error)
                }
            }
            for cpuException in payload.cpuExceptionDiagnostics ?? [] {
                let seconds = cpuException.totalCPUTime.converted(to: .seconds).value
                Task { @MainActor in
                    DebugLog.shared.add(
                        String(format: "[MetricKit] CPU-Exception: %.1f s Gesamt-CPU-Zeit", seconds),
                        level: .warn
                    )
                }
            }
        }
    }
}
