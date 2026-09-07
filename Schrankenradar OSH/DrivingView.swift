import SwiftUI

struct DrivingView: View {
    let viewModel: CrossingViewModel

    var body: some View {
        let status = viewModel.worstUpcomingStatus
        ZStack {
            status.color.opacity(0.15).ignoresSafeArea()

            VStack(spacing: 32) {
                Text("Schrankenradar")
                    .font(.title3)
                    .foregroundStyle(.secondary)

                TrafficLightView(status: status)

                Text(status.label)
                    .font(.title)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)

                if let next = viewModel.nextEvents.first(where: { $0.minutesUntil > -0.5 }) {
                    nextTrainBadge(event: next)
                }
            }
            .padding()
        }
    }

    private func nextTrainBadge(event: CrossingEvent) -> some View {
        VStack(spacing: 6) {
            Text("Nächster Zug")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Text(event.train.lineName)
                    .font(.title2).bold()
                Text("→ \(event.train.direction)")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Spacer()
                timeLabel(event: event)
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }

    private func timeLabel(event: CrossingEvent) -> some View {
        let minutes = event.minutesUntil
        let text: String
        if minutes < 1 {
            text = "\(Int(minutes * 60))s"
        } else {
            text = "\(Int(minutes)) min"
        }
        return Text(text)
            .font(.title2).bold()
            .foregroundStyle(event.status.color)
    }
}
