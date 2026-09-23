import SwiftUI
import ImageIO
import UIKit

/// Spielt ein animiertes GIF aus einem Data-Asset (Assets.xcassets, `NSDataAsset`) ab.
/// SwiftUIs `Image` zeigt bei einem GIF nur das erste Frame — deshalb dieser dünne UIKit-
/// Wrapper. Frames werden per ImageIO aus den Rohdaten dekodiert, individuelle Framedauern
/// werden zu einer Gesamtdauer aufsummiert statt einzeln nachgebildet (`UIImage.animatedImage`
/// verteilt sie gleichmäßig) — für die kurzen, meist gleichmäßig getakteten Abzeichen-
/// Animationen hier nicht sichtbar unterscheidbar vom Original.
struct AnimatedGIFView: UIViewRepresentable {
    let dataAssetName: String

    func makeUIView(context: Context) -> UIImageView {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        // Ohne das kann die UIKit-Bridge-View mit ihrer tatsächlichen (oft viel größeren)
        // Pixelgröße über die von sizeThatFits vorgegebenen Grenzen hinaus zeichnen — sichtbar
        // als Überlappung mit SwiftUI-Geschwistern direkt darunter, obwohl die Layout-Größe
        // selbst schon korrekt klein war.
        imageView.clipsToBounds = true

        // Dekodieren ALLER Frames (CGImageSourceCreateImageAtIndex je Frame) lief bisher
        // synchron hier in makeUIView, also auf dem Main Thread während des SwiftUI-Layouts —
        // bei mehreren Dutzend Frames einer aufwendigen Karte spürbar als UI-Hänger beim
        // Öffnen der Detailkarte (Nutzer-Report). Jetzt im Hintergrund dekodiert, Bild danach
        // auf dem Main Thread gesetzt; die View selbst erscheint sofort (leer, bis das Bild da
        // ist) statt die UI zu blockieren.
        let name = dataAssetName
        Task.detached(priority: .userInitiated) {
            guard let data = NSDataAsset(name: name)?.data, let animatedImage = Self.decode(data) else { return }
            await MainActor.run {
                imageView.image = animatedImage
                imageView.startAnimating()
            }
        }
        return imageView
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {}

    /// Ohne diese Methode bestimmt UIImageViews intrinsicContentSize (= volle Pixelgröße des
    /// GIFs, oft weit über 1000pt) die Layout-Größe — jedes von SwiftUI daneben gesetzte
    /// `.frame(width:height:)` wurde dadurch ignoriert, das GIF lief in voller Größe über
    /// Nachbar-Zeilen/-Karten hinweg (auf dem Gerät als überlappende, abgeschnittene Karten
    /// sichtbar). Der Rückgabewert erzwingt stattdessen exakt die von SwiftUI vorgeschlagene
    /// Größe; `contentMode = .scaleAspectFit` skaliert das GIF dann sauber hinein.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIImageView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    // nonisolated: das Projekt setzt standardmäßig MainActor-Isolation für alle Typen
    // (-default-isolation=MainActor). Ohne dieses Schlüsselwort würde der Compiler decode()/
    // frameDuration() implizit dem MainActor zuordnen — der Task.detached-Aufruf oben würde
    // dann für den Aufruf selbst wieder auf den Main Thread zurückspringen und die eigentliche
    // (teure) Dekodierarbeit fände trotz Task.detached weiterhin dort statt. Beide Methoden
    // fassen nur reine ImageIO/Foundation-Werte an, kein UI-Zustand — nonisolated ist sicher.
    nonisolated private static func decode(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return UIImage(data: data) }
        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 1 else { return UIImage(data: data) }

        var frames: [UIImage] = []
        var totalDuration: Double = 0
        for index in 0..<frameCount {
            guard let cgImage = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            frames.append(UIImage(cgImage: cgImage))
            totalDuration += frameDuration(source: source, index: index)
        }
        guard !frames.isEmpty else { return nil }
        return UIImage.animatedImage(with: frames, duration: totalDuration > 0 ? totalDuration : Double(frames.count) * 0.1)
    }

    nonisolated private static func frameDuration(source: CGImageSource, index: Int) -> Double {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let gifProperties = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any] else {
            return 0.1
        }
        let unclamped = gifProperties[kCGImagePropertyGIFUnclampedDelayTime] as? Double
        let clamped = gifProperties[kCGImagePropertyGIFDelayTime] as? Double
        return unclamped ?? clamped ?? 0.1
    }
}
