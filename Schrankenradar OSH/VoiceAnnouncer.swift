import AVFoundation

final class VoiceAnnouncer {
    private let synthesizer = AVSpeechSynthesizer()
    private let voice = AVSpeechSynthesisVoice(language: "de-DE")

    func announce(status: CrossingStatus, nextEvent: CrossingEvent?) {
        synthesizer.stopSpeaking(at: .word)

        let text = buildText(status: status, nextEvent: nextEvent)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = 0.48
        utterance.pitchMultiplier = 1.0
        utterance.postUtteranceDelay = 0.2
        synthesizer.speak(utterance)
    }

    private func buildText(status: CrossingStatus, nextEvent: CrossingEvent?) -> String {
        var parts: [String] = []

        switch status {
        case .open:
            parts.append("Schranke vermutlich offen.")
        case .warning:
            parts.append("Achtung, Schranke schließt bald.")
        case .closed:
            parts.append("Schranke geschlossen.")
        }

        if let event = nextEvent, event.minutesUntil > 0 {
            let minutes = Int(event.minutesUntil)
            let seconds = Int(event.minutesUntil * 60)
            let line = event.train.lineName
            let dir  = event.train.direction

            if minutes >= 2 {
                parts.append("\(line) Richtung \(dir) in \(minutes) Minuten.")
            } else if minutes == 1 {
                parts.append("\(line) Richtung \(dir) in einer Minute.")
            } else {
                parts.append("\(line) Richtung \(dir) in \(seconds) Sekunden.")
            }
        }

        return parts.joined(separator: " ")
    }
}
