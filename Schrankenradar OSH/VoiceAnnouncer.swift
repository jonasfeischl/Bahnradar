import AVFoundation

final class VoiceAnnouncer {
    private let synthesizer = AVSpeechSynthesizer()
    private let neuralEngine = NeuralVoiceEngine()
    /// Hält die neuronale Audiowiedergabe am Leben, solange sie läuft — ohne
    /// diese Referenz würde AVAudioPlayer sofort wieder freigegeben.
    private var neuralPlayer: AVAudioPlayer?
    /// Laufende Synthese der zuletzt angeforderten Ansage — wird bei einer neuen
    /// Ansage abgebrochen, damit nie eine überholte Ansage verspätet abgespielt wird.
    private var neuralSynthesisTask: Task<Void, Never>?

    init() {
        configureAudioSession()
    }

    /// Wählt die natürlichste verfügbare deutsche Stimme statt der mitgelieferten
    /// Standard-Stimme (klingt roboterhaft). "Enhanced"/"Premium"-Stimmen sind Apples
    /// hochwertige, on-device generierte Stimmen (ähnliche Technik wie Siri, aber NICHT
    /// Siris eigene Stimme — die gibt Apple für Drittanbieter-Apps grundsätzlich nicht frei).
    /// Enhanced/Premium müssen einmalig in den iOS-Einstellungen heruntergeladen werden
    /// (oben in der Suche nach "Stimmen" suchen — es gibt mehrere gleichnamige Treffer,
    /// der richtige steht unter "Bedienungshilfen → Schaltersteuerung → Gesprochene Inhalte"),
    /// sonst liefert iOS nur die Standardqualität.
    /// Wird bei JEDER Ansage neu abgefragt statt einmal beim App-Start zwischengespeichert —
    /// sonst merkt die App eine während der Laufzeit heruntergeladene bessere Stimme nicht,
    /// solange sie nicht komplett neu gestartet wird.
    private func bestGermanVoice() -> AVSpeechSynthesisVoice? {
        let germanVoices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("de") }
        if let premium  = germanVoices.first(where: { $0.quality == .premium })  { return premium }
        if let enhanced = germanVoices.first(where: { $0.quality == .enhanced }) { return enhanced }
        return AVSpeechSynthesisVoice(language: "de-DE")
    }

    /// Diagnose für die Einstellungen-Ansicht: zeigt welche Stimme aktuell verwendet
    /// würde und welche Qualität sie hat — damit man ohne Xcode sehen kann, ob eine
    /// heruntergeladene Enhanced/Premium-Stimme vom System erkannt wird.
    func currentVoiceDescription() -> String {
        guard let voice = bestGermanVoice() else { return "Keine deutsche Stimme gefunden" }
        return "\(voice.name) (\(Self.qualityLabel(voice.quality)))"
    }

    /// Alle auf dem Gerät registrierten deutschen Stimmen, zur Fehlersuche.
    func allGermanVoicesDescription() -> String {
        let germanVoices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("de") }
        guard !germanVoices.isEmpty else { return "Keine deutschen Stimmen registriert." }
        return germanVoices
            .map { "\($0.name) — \(Self.qualityLabel($0.quality))" }
            .joined(separator: "\n")
    }

    private static func qualityLabel(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .premium:  return "Premium"
        case .enhanced: return "Enhanced"
        default:        return "Standard"
        }
    }

    private func configureAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(
            .playback,
            mode: .spokenAudio,
            options: [.duckOthers, .allowBluetoothHFP, .allowBluetoothA2DP]
        )
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    func announce(status: CrossingStatus, nextEvent: CrossingEvent?, crossingName: String = "") {
        synthesizer.stopSpeaking(at: .word)
        neuralPlayer?.stop()
        // Eine noch laufende, jetzt überholte Synthese abbrechen — sonst könnte kurz
        // danach noch die ALTE Ansage abgespielt werden, nachdem schon eine neuere
        // angefordert wurde.
        neuralSynthesisTask?.cancel()

        let parts = buildText(status: status, nextEvent: nextEvent, crossingName: crossingName)
        speak(parts: parts)
    }

    /// Einmaliger Hinweis, wenn Hintergrund-Tracking (Standort "Immer" erlaubt) beim
    /// Wechsel in den Hintergrund tatsächlich aktiv übernimmt — sonst bemerkt man beim
    /// Fahren ohne Blick aufs Display nicht, ob die App im Hintergrund noch mitläuft.
    func announceBackgroundActive() {
        synthesizer.stopSpeaking(at: .word)
        neuralPlayer?.stop()
        neuralSynthesisTask?.cancel()
        // Kurze Pause vor "aktiv" + lauter gesprochen (Ersatz für echte Betonung) —
        // Werte nach Hörtest mehrerer Varianten festgelegt.
        speak(parts: ["Dein Bahnradar ist jetzt", "aktiv."], pauseBeforeIndices: [1], emphasizeIndices: [1])
    }

    /// Gemeinsamer Syntheseweg: KI-Stimme versuchen, bei jedem Problem (Modell nicht
    /// geladen, Text nicht im vorberechneten Wortschatz, Synthese schlägt fehl) lautlos
    /// auf die iOS-Systemstimme zurückfallen statt die Ansage ausfallen zu lassen.
    private func speak(parts: [String], pauseBeforeIndices: Set<Int> = [], emphasizeIndices: Set<Int> = []) {
        let text = parts.joined(separator: " ")
        DebugLog.shared.add("Sprachansage: versuche neuronale Stimme. Text: \(text)")

        // Inferenz kann kurz dauern, der Aufruf selbst bleibt aber synchron (Aufrufer
        // erwarten kein await) — die eigentliche Arbeit passiert in einem losgelösten
        // Task. neuralEngine ist ein actor, überlappende Aufrufe werden also ohnehin
        // automatisch serialisiert statt sich gegenseitig zu stören.
        neuralSynthesisTask = Task {
            let wavData = await neuralEngine.synthesize(
                parts: parts, pauseBeforeIndices: pauseBeforeIndices, emphasizeIndices: emphasizeIndices
            )
            guard !Task.isCancelled else { return }
            if let wavData {
                DebugLog.shared.add("Sprachansage: neuronale Stimme erfolgreich (\(wavData.count) Bytes WAV).")
                await MainActor.run { self.playNeuralAudio(wavData) }
            } else {
                await MainActor.run { self.speakWithSystemVoice(text) }
            }
        }
    }

    private func speakWithSystemVoice(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = bestGermanVoice()
        utterance.rate = 0.48
        utterance.pitchMultiplier = 1.0
        utterance.postUtteranceDelay = 0.2
        synthesizer.speak(utterance)
    }

    private func playNeuralAudio(_ wavData: Data) {
        neuralPlayer = try? AVAudioPlayer(data: wavData)
        // Ohne prepareToPlay() ist die Audio-Hardware beim ersten play() noch
        // nicht bereit — das schnitt hörbar den Anfang der Ansage ab (z.B.
        // "Zug" komplett verschluckt) und klang wie Stottern.
        neuralPlayer?.prepareToPlay()
        neuralPlayer?.play()
    }

    /// Einheitlicher Aufbau für alle vier Status: "[Name] [Status]. Nächster Zug [Zeit]."
    /// Keine Kurz/Ausführlich-Unterscheidung mehr — immer derselbe, vollständige Satzbau,
    /// Linie/Richtung werden nicht mehr genannt. Der zweite Satz entfällt sauber, wenn kein
    /// Zug in absehbarer Zeit kommt, statt mit leeren Platzhaltern angesagt zu werden.
    private func buildText(status: CrossingStatus, nextEvent: CrossingEvent?, crossingName: String) -> [String] {
        // crossingName (spokenCrossingName) endet immer schon auf "Schranke" (z.B.
        // "Oberschleißheimer Schranke") — die Status-Phrasen duerfen das Wort deshalb
        // nicht nochmal voranstellen, sonst hoert man "... Schranke Schranke ...".
        let name = crossingName.trimmingCharacters(in: .whitespaces)
        let firstSentence: String = {
            switch status {
            case .open:    return "\(name) vermutlich offen."
            case .warning: return "Achtung, \(name) schließt bald."
            case .closed:  return "\(name) wahrscheinlich geschlossen."
            case .opening: return "\(name) öffnet gleich."
            }
        }()

        var parts = [firstSentence.trimmingCharacters(in: .whitespaces)]

        if let event = nextEvent, event.minutesUntil > 0 {
            let minutes = Int(event.minutesUntil)
            let seconds = Int(event.minutesUntil * 60)
            let zeitText: String
            if minutes >= 2         { zeitText = "in \(minutes) Minuten" }
            else if minutes == 1    { zeitText = "in einer Minute" }
            else if seconds == 1    { zeitText = "in einer Sekunde" }
            else                    { zeitText = "in \(seconds) Sekunden" }
            parts.append("Nächster Zug \(zeitText).")
        }

        return parts
    }
}
