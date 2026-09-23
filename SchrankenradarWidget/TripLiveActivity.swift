import ActivityKit
import SwiftUI
import WidgetKit

/// Live Activity für eine laufende Fahrt (Fahrt-Tab) — Attribute/ContentState in
/// CrossingActivityAttributes.swift (geteilt mit der Haupt-App, siehe dort). Bewusst schlicht:
/// Übergangsname, Status, grobe Ankunftszeit. Start/Update/Ende steuert RouteViewModel.
struct TripLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TripActivityAttributes.self) { context in
            lockScreenView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.85))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "road.lanes")
                        .foregroundStyle(statusColor(context.state))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.etaText)
                        .font(.caption2)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.crossingName)
                            .font(.caption.bold())
                        Text(context.state.statusLabel)
                            .font(.caption2)
                            .foregroundStyle(statusColor(context.state))
                    }
                }
            } compactLeading: {
                Image(systemName: "road.lanes")
                    .foregroundStyle(statusColor(context.state))
            } compactTrailing: {
                Text(context.state.isBlocked ? "Zu" : "Offen")
                    .font(.caption2.bold())
                    .foregroundStyle(statusColor(context.state))
            } minimal: {
                Image(systemName: "road.lanes")
                    .foregroundStyle(statusColor(context.state))
            }
        }
    }

    private func statusColor(_ state: TripActivityAttributes.ContentState) -> Color {
        state.isBlocked ? .red : .green
    }

    @ViewBuilder
    private func lockScreenView(context: ActivityViewContext<TripActivityAttributes>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "road.lanes")
                .font(.title2)
                .foregroundStyle(statusColor(context.state))
            VStack(alignment: .leading, spacing: 2) {
                Text(context.attributes.crossingName)
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                Text(context.state.statusLabel)
                    .font(.caption)
                    .foregroundStyle(statusColor(context.state))
            }
            Spacer()
            if !context.state.etaText.isEmpty {
                Text(context.state.etaText)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding()
    }
}
