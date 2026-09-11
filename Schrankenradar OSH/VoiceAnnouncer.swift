import AVFoundation

final class VoiceAnnouncer: NSObject {
    private let synthesizer = AVSpeechSynthesizer()
    private let neuralEngine = NeuralVoiceEngine()
    /// Hält die neuronale Audiowiedergabe am Leben, solange sie läuft — ohne
    /// diese Referenz würde AVAudioPlayer sofort wieder freigegeben.
    private var neuralPlayer: AVAudioPlayer?
    /// Token für den Interruption-Observer (siehe init) — hält ihn am Leben, analog zu den
    /// Observer-Properties in CrossingViewModel (z.B. calibrationObserver).
    private var audioInterruptionObserver: Any?

    /// True während eine Ansage hörbar läuft (neuronal ODER Systemstimme). Verhindert, dass
    /// mehrere fast gleichzeitig ausgelöste Ansagen (z.B. "Hintergrundmodus aktiv" beim
    /// Verlassen, dann "Live-Status verfügbar", dann eine Status-Ansage — alle im selben
    /// 1s-Tick scharf geschaltet) sich gegenseitig abschneiden, statt der Reihe nach zu spielen.
    private var isSpeaking = false

    private struct QueuedSpeech {
        let parts: [String]
        let pauseBeforeIndices: Set<Int>
        let emphasizeIndices: Set<Int>
        /// true nur für Status-Ansagen: eine neue ersetzt eine noch wartende alte (der Status
        /// hat sich ja schon wieder geändert, die alte wäre beim Abspielen überholt). Die vier
        /// einmaligen Bestätigungen (App aktiv/Hintergrund/Näherung/Live-Status) sind NIE
        /// ersetzbar — die dürfen nie verloren gehen, nur der Reihe nach angehängt werden.
        let replaceable: Bool
    }
    /// FIFO-Warteschlange statt Einzel-Slot — sonst könnte z.B. eine wartende "Live-Status
    /// verfügbar"-Ansage von einer kurz danach ebenfalls wartenden Status-Ansage überschrieben
    /// und dadurch verloren gehen, obwohl beide in derselben Sekunde fällig wurden.
    private var pendingSpeak: [QueuedSpeech] = []

    override init() {
        super.init()
        configureAudioSession()
        synthesizer.delegate = self
        // iOS reaktiviert die Audiosession nach einer Unterbrechung (Anruf, Siri,
        // Bluetooth-/CarPlay-Wechsel — im Auto-Kontext keine Seltenheit) nicht von selbst.
        // Ohne diesen Observer blieb die nächste Ansage danach lautlos, obwohl der Code sie
        // ganz normal auslöst.
        audioInterruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard
                let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                AVAudioSession.InterruptionType(rawValue: typeValue) == .ended
            else { return }
            self?.configureAudioSession()
        }
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
        let parts = buildText(status: status, nextEvent: nextEvent, crossingName: crossingName)
        speak(parts: parts, replaceable: true)
    }

    /// Bestätigung beim Verlassen der App (echter Hintergrund, nach Gnadenfrist bestätigt) —
    /// IMMER, unabhängig vom Fahrstatus (Nutzerentscheidung), damit klar ist, dass
    /// Hintergrund-Tracking (Standort "Immer" erlaubt) aktiv übernimmt.
    func announceBackgroundActive() {
        speak(parts: ["Die App läuft im Hintergrund."])
    }

    /// Einmalige Bestätigung beim Start einer Fahrt (isDriving false→true, siehe
    /// Schrankenradar_OSHApp.swift) — Gegenstück zu announceBackgroundActive().
    func announceAppActive() {
        speak(parts: ["Dein Bahnradar ist jetzt", "aktiv."], pauseBeforeIndices: [1], emphasizeIndices: [1])
    }

    /// Einmalige Bestätigung beim Eintritt in den Ansage-Radius eines Übergangs (isNearCrossing
    /// false→true, während gefahren wird) — siehe CrossingViewModel.evaluateLifecycleAnnouncements().
    func announceApproachingCrossing() {
        speak(parts: ["Du näherst dich einem überwachten Bahnübergang."])
    }

    /// Einmalige Bestätigung, sobald für den aktuellen Übergang ein Zug mit echten GPS-Live-
    /// Daten vorliegt (CrossingEvent.isLiveData) statt nur Fahrplan-Schätzung.
    func announceLiveStatusAvailable() {
        speak(parts: ["Live-Status verfügbar."])
    }

    /// Wartet eine bereits laufende Ansage ab statt sie abzuschneiden — läuft gerade nichts,
    /// startet sofort. Läuft schon etwas, wird der Request angehängt (siehe pendingSpeak) und
    /// finishedSpeaking() holt die Warteschlange der Reihe nach ab.
    private func speak(
        parts: [String], pauseBeforeIndices: Set<Int> = [], emphasizeIndices: Set<Int> = [], replaceable: Bool = false
    ) {
        guard !isSpeaking else {
            let item = QueuedSpeech(
                parts: parts, pauseBeforeIndices: pauseBeforeIndices, emphasizeIndices: emphasizeIndices,
                replaceable: replaceable
            )
            if replaceable, let index = pendingSpeak.firstIndex(where: { $0.replaceable }) {
                pendingSpeak[index] = item
            } else {
                pendingSpeak.append(item)
            }
            DebugLog.shared.add(
                "Sprachansage: es läuft schon eine andere, in Warteschlange (\(pendingSpeak.count) wartend). " +
                "Text: \(parts.joined(separator: " "))"
            )
            return
        }
        startSpeaking(parts: parts, pauseBeforeIndices: pauseBeforeIndices, emphasizeIndices: emphasizeIndices)
    }

    /// Gemeinsamer Syntheseweg: KI-Stimme versuchen, bei jedem Problem (Modell nicht
    /// geladen, Text nicht im vorberechneten Wortschatz, Synthese schlägt fehl) lautlos
    /// auf die iOS-Systemstimme zurückfallen statt die Ansage ausfallen zu lassen.
    private func startSpeaking(parts: [String], pauseBeforeIndices: Set<Int>, emphasizeIndices: Set<Int>) {
        isSpeaking = true
        let text = parts.joined(separator: " ")
        DebugLog.shared.add("Sprachansage: versuche neuronale Stimme. Text: \(text)")

        // Inferenz kann kurz dauern, der Aufruf selbst bleibt aber synchron (Aufrufer
        // erwarten kein await) — die eigentliche Arbeit passiert in einem losgelösten
        // Task. neuralEngine ist ein actor, überlappende Aufrufe werden also ohnehin
        // automatisch serialisiert statt sich gegenseitig zu stören.
        Task {
            let wavData = await neuralEngine.synthesize(
                parts: parts, pauseBeforeIndices: pauseBeforeIndices, emphasizeIndices: emphasizeIndices
            )
            if let wavData {
                DebugLog.shared.add("Sprachansage: neuronale Stimme erfolgreich (\(wavData.count) Bytes WAV).")
                await MainActor.run { self.playNeuralAudio(wavData) }
            } else {
                await MainActor.run { self.speakWithSystemVoice(text) }
            }
        }
    }

    /// Wird aufgerufen sobald die aktuelle Ansage fertig ist (neuronal oder Systemstimme,
    /// über die Delegates unten) — holt eine zwischenzeitlich zurückgestellte Ansage nach,
    /// falls eine wartet.
    private func finishedSpeaking() {
        isSpeaking = false
        guard !pendingSpeak.isEmpty else { return }
        let next = pendingSpeak.removeFirst()
        startSpeaking(parts: next.parts, pauseBeforeIndices: next.pauseBeforeIndices, emphasizeIndices: next.emphasizeIndices)
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
        neuralPlayer?.delegate = self
        // Ohne prepareToPlay() ist die Audio-Hardware beim ersten play() noch
        // nicht bereit — das schnitt hörbar den Anfang der Ansage ab (z.B.
        // "Zug" komplett verschluckt) und klang wie Stottern.
        neuralPlayer?.prepareToPlay()
        if neuralPlayer?.play() != true {
            // Player konnte nicht erzeugt/gestartet werden — ohne das bliebe isSpeaking
            // hängen und jede künftige Ansage würde nur noch zurückgestellt, nie gesprochen.
            finishedSpeaking()
        }
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

extension VoiceAnnouncer: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.finishedSpeaking() }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in self.finishedSpeaking() }
    }
}

extension VoiceAnnouncer: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finishedSpeaking() }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finishedSpeaking() }
    }
}
