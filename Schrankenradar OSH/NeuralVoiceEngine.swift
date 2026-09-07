import Foundation
import OnnxRuntimeBindings

/// On-device neuronale Stimme (Thorsten-Voice/VITS, Apache-2.0 + CC0, kommerziell
/// nutzbar — anders als das vorherige Meta-MMS-Modell, das wegen CC-BY-NC-4.0 nicht
/// in einer bezahlten App verwendet werden durfte). Läuft komplett lokal, kein
/// Netzwerk, keine laufenden Kosten.
///
/// Eine weibliche Alternative (Piper-Stimme "kerstin", ebenfalls CC0) wurde
/// getestet und wieder rausgenommen — die einzige verfügbare Qualitätsstufe
/// ("low") artikulierte komplexere Wörter hörbar schlechter als Thorsten.
/// Falls künftig eine bessere freie deutsche Frauenstimme auftaucht, liegt die
/// bisherige kerstin-Arbeit (Modell, Vokabular, Build-Skript) im Desktop-
/// Projektordner unter "kerstin-weiblich (zurückgestellt, low quality)".
///
/// Anders als MMS arbeitet dieses Modell auf Phonem- statt Zeichen-Ebene. Die
/// Text→Phonem-Umwandlung (gruut, MIT-lizenziert) läuft NICHT auf dem Gerät —
/// die App spricht ohnehin nur einen festen, kleinen Wortschatz (Übergangsnamen,
/// Status-Sätze, Zahlwörter), deshalb wurden alle Phonem-Sequenzen einmalig am
/// Rechner vorberechnet (siehe voice_vocab_thorsten.json) und hier nur
/// nachgeschlagen. Kommt ein Text nicht in der Tabelle vor (z.B. ein künftig
/// hinzugefügter Übergang ohne eigenen Eintrag), liefert `synthesize` nil und
/// der Aufrufer fällt automatisch auf die iOS-Systemstimme zurück.
actor NeuralVoiceEngine {
    private let sampleRate: Double = 22_050
    private let session: ORTSession?
    private let vocabulary: [String: [Int64]]

    /// length_scale > 1 = langsamer, < 1 = schneller (VITS-Konvention, invers zu
    /// MMS' speaking_rate). 1.25 auf Nutzerwunsch etwas langsamer als Normaltempo.
    private let lengthScale: Float = 1.25
    /// Halbtöne, um die die fertige Stimme angehoben wird (Nutzerentscheidung nach
    /// Hörtest mehrerer Varianten: 0/+2/+4/+6 -> +2 war die bevorzugte).
    private let pitchShiftSemitones: Double = 2

    nonisolated let isAvailable: Bool

    init() {
        guard
            let modelURL = Bundle.main.url(forResource: "thorsten_vits", withExtension: "onnx"),
            let env = try? ORTEnv(loggingLevel: .warning),
            let session = try? ORTSession(env: env, modelPath: modelURL.path, sessionOptions: nil),
            let vocabURL = Bundle.main.url(forResource: "voice_vocab_thorsten", withExtension: "json"),
            let vocabData = try? Data(contentsOf: vocabURL),
            let rawVocab = try? JSONDecoder().decode([String: [Int]].self, from: vocabData)
        else {
            self.session = nil
            self.vocabulary = [:]
            self.isAvailable = false
            return
        }
        self.session = session
        self.vocabulary = rawVocab.mapValues { $0.map(Int64.init) }
        self.isAvailable = true
    }

    /// Erzeugt eine fertig abspielbare WAV-Datei (22.05kHz, mono) für die gegebenen
    /// Satzteile (z.B. [Name+Status, Zeitangabe]), oder nil bei jedem Fehler bzw.
    /// wenn ein Teil nicht im vorberechneten Wortschatz vorkommt — Aufrufer fällt
    /// dann auf die Systemstimme zurück. Jeder Teil wird einzeln synthetisiert und
    /// die Audiodaten aneinandergehängt statt in einem Modell-Aufruf kombiniert,
    /// damit ein fehlender/unbekannter Teil nicht die ganze Ansage kippt und weil
    /// bei deterministischer Synthese (noise_scale=0) mehrere Aufrufe ohnehin
    /// dieselbe Stimmlage ergeben.
    /// - Parameters:
    ///   - pauseBeforeIndices: Vor diesen Teilen wird eine kurze Stille eingefügt (z.B. für
    ///     eine bewusste Sprechpause zwischen zwei Wörtern statt nahtlosem Übergang).
    ///   - emphasizeIndices: Diese Teile werden etwas lauter abgespielt — Ersatz für eine
    ///     echte Betonung, die das Modell selbst nicht steuerbar unterstützt (keine
    ///     Stress-Markierungen in den Trainingsdaten).
    func synthesize(parts: [String], pauseBeforeIndices: Set<Int> = [], emphasizeIndices: Set<Int> = []) -> Data? {
        guard let session else { return nil }

        var allSamples: [Float] = []
        for (index, part) in parts.enumerated() {
            guard let ids = vocabulary[part] else {
                DebugLog.shared.add("Neuronale Stimme: unbekannter Text im Wortschatz: \"\(part)\"", level: .warn)
                return nil
            }
            guard var samples = runInference(session: session, ids: ids) else { return nil }
            samples = Self.fadeIn(samples, sampleRate: sampleRate)
            if emphasizeIndices.contains(index) {
                samples = Self.boostVolume(samples, factor: 1.6)
            }
            if pauseBeforeIndices.contains(index) {
                allSamples.append(contentsOf: [Float](repeating: 0, count: Int(sampleRate * 0.05)))
            }
            allSamples.append(contentsOf: samples)
        }
        guard !allSamples.isEmpty else { return nil }

        let shifted = Self.pitchShift(allSamples, semitones: pitchShiftSemitones)
        return Self.wavData(samples: shifted, sampleRate: sampleRate)
    }

    private func runInference(session: ORTSession, ids: [Int64]) -> [Float]? {
        do {
            let inputShape: [NSNumber] = [1, NSNumber(value: ids.count)]
            let inputData = NSMutableData(bytes: ids, length: ids.count * MemoryLayout<Int64>.size)
            let inputValue = try ORTValue(tensorData: inputData, elementType: .int64, shape: inputShape)

            let lengths: [Int64] = [Int64(ids.count)]
            let lengthsData = NSMutableData(bytes: lengths, length: MemoryLayout<Int64>.size)
            let lengthsValue = try ORTValue(tensorData: lengthsData, elementType: .int64, shape: [1])

            // [noise_scale, length_scale, noise_scale_dp] — beide noise_scale auf 0
            // fuer deterministische (immer gleich klingende) Ausgabe.
            let scales: [Float] = [0, lengthScale, 0]
            let scalesData = NSMutableData(bytes: scales, length: scales.count * MemoryLayout<Float>.size)
            let scalesValue = try ORTValue(tensorData: scalesData, elementType: .float, shape: [3])

            let outputs = try session.run(
                withInputs: ["input": inputValue, "input_lengths": lengthsValue, "scales": scalesValue],
                outputNames: ["output"],
                runOptions: nil
            )
            guard let outputValue = outputs["output"] else {
                DebugLog.shared.add("Neuronale Stimme: kein output vom Modell.", level: .warn)
                return nil
            }
            let data = try outputValue.tensorData() as Data
            let samples = data.withUnsafeBytes { buffer -> [Float] in
                Array(buffer.bindMemory(to: Float.self))
            }
            guard !samples.isEmpty else {
                DebugLog.shared.add("Neuronale Stimme: leere Samples vom Modell.", level: .warn)
                return nil
            }
            return samples
        } catch {
            DebugLog.shared.add("Neuronale Stimme fehlgeschlagen (\(error)), falle auf iOS-Stimme zurück.", level: .warn)
            return nil
        }
    }

    /// Ersatz für echte Betonung: das Modell selbst kennt keine Stress-Markierungen
    /// (gruut liefert für Thorsten keine ˈ/ˌ-Zeichen, das Modell wurde also nie darauf
    /// trainiert, sie zu beachten) — stattdessen wird der Teil einfach lauter abgespielt.
    /// Clipping-sicher: skaliert nur so weit, wie der lauteste Sample-Wert es zulässt.
    private static func boostVolume(_ samples: [Float], factor: Float) -> [Float] {
        guard let peak = samples.map({ abs($0) }).max(), peak > 0 else { return samples }
        let safeFactor = min(factor, 1.0 / peak)
        return samples.map { $0 * safeFactor }
    }

    /// Der HiFi-GAN-Decoder von VITS startet ohne jeden Vorlaufkontext (Zero-Padding
    /// am linken Rand) und erzeugt dadurch am allerersten Sample oft einen kleinen
    /// Sprung/Knacks. Ein kurzes lineares Fade-in glaettet das, ohne hoerbar etwas
    /// vom eigentlichen Sprachanfang wegzunehmen (25ms ist kuerzer als jeder Laut).
    /// Gilt pro synthetisiertem Teilsatz, da jeder Teil einzeln durch den Decoder
    /// laeuft und denselben Einschwing-Knacks am eigenen Anfang haben kann.
    private static func fadeIn(_ samples: [Float], sampleRate: Double) -> [Float] {
        let fadeSampleCount = min(samples.count, Int(sampleRate * 0.025))
        guard fadeSampleCount > 0 else { return samples }
        var result = samples
        for i in 0..<fadeSampleCount {
            result[i] *= Float(i) / Float(fadeSampleCount)
        }
        return result
    }

    /// Einfache resample-basierte Tonhöhenverschiebung (ratio<1 klingt tiefer und
    /// laenger, ratio>1 hoeher und kuerzer) — lineare Interpolation, dieselbe
    /// Technik wie in den Python-Hörtests, mit der die Halbton-Stufe festgelegt wurde.
    private static func pitchShift(_ samples: [Float], semitones: Double) -> [Float] {
        guard semitones != 0, !samples.isEmpty else { return samples }
        let ratio = pow(2.0, semitones / 12.0)
        let outCount = Int(Double(samples.count) / ratio)
        guard outCount > 0 else { return samples }
        var result = [Float](repeating: 0, count: outCount)
        for i in 0..<outCount {
            let srcPos = Double(i) * ratio
            let idx0 = Int(srcPos)
            let frac = Float(srcPos - Double(idx0))
            if idx0 + 1 < samples.count {
                result[i] = samples[idx0] * (1 - frac) + samples[idx0 + 1] * frac
            } else if idx0 < samples.count {
                result[i] = samples[idx0]
            }
        }
        return result
    }

    /// Verpackt rohe Float-Samples (-1...1) als 16-bit-PCM-WAV-Datei im Speicher,
    /// damit sie direkt über AVAudioPlayer(data:) abspielbar sind.
    private static func wavData(samples: [Float], sampleRate: Double) -> Data {
        let int16Samples = samples.map { sample -> Int16 in
            let clamped = max(-1.0, min(1.0, sample))
            return Int16(clamped * Float(Int16.max))
        }

        var data = Data()
        let byteRate = Int32(sampleRate) * 2
        let dataSize = Int32(int16Samples.count * 2)

        func append(_ string: String) { data.append(string.data(using: .ascii)!) }
        func append(_ value: Int32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append(_ value: Int16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

        append("RIFF")
        append(Int32(36) + dataSize)
        append("WAVE")
        append("fmt ")
        append(Int32(16))
        append(Int16(1))
        append(Int16(1))
        append(Int32(sampleRate))
        append(byteRate)
        append(Int16(2))
        append(Int16(16))
        append("data")
        append(dataSize)
        for sample in int16Samples { append(sample) }

        return data
    }
}
