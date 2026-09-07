import SwiftUI

struct TrafficLightView: View {
    let status: CrossingStatus
    /// Beim allerersten Anzeigen (App-Start, bevor echte Daten geladen sind) soll die
    /// Ampel sofort im richtigen Zustand dastehen statt sichtbar in die Farbe zu
    /// überblenden — nur spätere, echte Statuswechsel während der Nutzung animieren.
    var animated: Bool = true
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 12) {
            light(color: .red,    active: status == .closed,
                  pulsing: status == .closed)
            light(color: .yellow, active: status == .warning || status == .opening,
                  pulsing: false)
            light(color: .green,  active: status == .open,
                  pulsing: false)
        }
        .padding(20)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(radius: 8)
        .animation(animated ? .easeInOut(duration: 0.4) : nil, value: status)
        .onAppear  { startPulse() }
        .onChange(of: status) { _, _ in startPulse() }
    }

    private func startPulse() {
        guard status == .closed else { pulse = false; return }
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
            pulse = true
        }
    }

    private func light(color: Color, active: Bool, pulsing: Bool) -> some View {
        Circle()
            .fill(active ? color : color.opacity(0.15))
            .frame(width: 80, height: 80)
            .overlay {
                if active {
                    Circle()
                        .fill(color.opacity(pulsing ? (pulse ? 0.55 : 0.25) : 0.4))
                        .blur(radius: 12)
                        .scaleEffect(pulsing ? (pulse ? 1.5 : 1.1) : 1.3)
                }
            }
            .scaleEffect(pulsing && active ? (pulse ? 1.05 : 1.0) : 1.0)
    }
}

#Preview {
    HStack(spacing: 20) {
        TrafficLightView(status: .open)
        TrafficLightView(status: .warning)
        TrafficLightView(status: .closed)
    }
    .padding()
}
