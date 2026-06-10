import AVFoundation

final class VoiceAnnouncer {
    private let synthesizer = AVSpeechSynthesizer()
    private let voice = AVSpeechSynthesisVoice(language: "de-DE")

    init() {
        configureAudioSession()
    }

    private func configureAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(
            .playback,
            mode: .spokenAudio,
            options: [.duckOthers, .allowBluetoothHFP, .allowBluetoothA2DP]
        )
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    func announce(status: CrossingStatus, nextEvent: CrossingEvent?, template: String? = nil) {
        synthesizer.stopSpeaking(at: .word)
        let text = buildText(status: status, nextEvent: nextEvent, template: template)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = 0.48
        utterance.pitchMultiplier = 1.0
        utterance.postUtteranceDelay = 0.2
        synthesizer.speak(utterance)
    }

    private func buildText(status: CrossingStatus, nextEvent: CrossingEvent?, template: String?) -> String {
        // Platzhalter-Werte berechnen
        let statusText: String = {
            switch status {
            case .open:    return "Schranke vermutlich offen"
            case .warning: return "Achtung, Schranke schließt bald"
            case .closed:  return "Schranke wahrscheinlich geschlossen"
            case .opening: return "Schranke öffnet gleich"
            }
        }()

        let linie     = nextEvent?.train.lineName ?? ""
        let richtung  = nextEvent?.train.direction ?? ""
        let zeitText: String = {
            guard let event = nextEvent, event.minutesUntil > 0 else { return "" }
            let minutes = Int(event.minutesUntil)
            let seconds = Int(event.minutesUntil * 60)
            if minutes >= 2    { return "in \(minutes) Minuten" }
            if minutes == 1    { return "in einer Minute" }
            return "in \(seconds) Sekunden"
        }()

        // Template auflösen wenn vorhanden
        if let tmpl = template, !tmpl.isEmpty {
            var result = tmpl
            result = result.replacingOccurrences(of: "{status}",   with: statusText)
            result = result.replacingOccurrences(of: "{linie}",    with: linie)
            result = result.replacingOccurrences(of: "{richtung}", with: richtung)
            result = result.replacingOccurrences(of: "{zeit}",     with: zeitText)
            // Doppelte Leerzeichen und Satzzeichen am Ende aufräumen
            result = result.replacingOccurrences(of: "  ", with: " ")
            result = result.trimmingCharacters(in: .whitespaces)
            return result
        }

        // Standard-Ansage
        var parts: [String] = [statusText + "."]
        if !zeitText.isEmpty {
            parts.append("\(linie) Richtung \(richtung) \(zeitText).")
        }
        return parts.joined(separator: " ")
    }
}
