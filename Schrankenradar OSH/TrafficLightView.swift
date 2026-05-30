import SwiftUI

struct TrafficLightView: View {
    let status: CrossingStatus

    var body: some View {
        VStack(spacing: 12) {
            light(color: .red, active: status == .closed)
            light(color: .yellow, active: status == .warning)
            light(color: .green, active: status == .open)
        }
        .padding(20)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(radius: 8)
        .animation(.easeInOut(duration: 0.4), value: status)
    }

    private func light(color: Color, active: Bool) -> some View {
        Circle()
            .fill(active ? color : color.opacity(0.15))
            .frame(width: 80, height: 80)
            .overlay {
                if active {
                    Circle()
                        .fill(color.opacity(0.4))
                        .blur(radius: 12)
                        .scaleEffect(1.3)
                }
            }
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
