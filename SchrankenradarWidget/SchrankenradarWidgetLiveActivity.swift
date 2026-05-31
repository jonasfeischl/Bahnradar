import ActivityKit
import WidgetKit
import SwiftUI

// MARK: - Live Activity Widget

struct CrossingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CrossingActivityAttributes.self) { context in
            // Lock Screen & StandBy
            LockScreenLiveActivityView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded (langes Drücken / seitlich)
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        StatusDot(statusRaw: context.state.statusRaw, size: 14)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(context.state.trainLine)
                                .font(.caption).bold()
                            Text("→ \(context.state.trainDirection)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        if context.state.statusRaw == "closed" || context.state.statusRaw == "opening" {
                            Text("Öffnet in")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(context.state.openingTime, style: .timer)
                                .font(.caption).bold()
                                .foregroundStyle(.green)
                                .monospacedDigit()
                        } else {
                            Text("Rot in")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(context.state.closingTime, style: .timer)
                                .font(.caption).bold()
                                .foregroundStyle(.red)
                                .monospacedDigit()
                        }
                    }
                    .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text("Bahnübergang Dachauer Str.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(context.state.statusLabel)
                            .font(.caption2.bold())
                            .foregroundStyle(statusColor(context.state.statusRaw))
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                StatusDot(statusRaw: context.state.statusRaw, size: 10)
            } compactTrailing: {
                if context.state.statusRaw == "closed" || context.state.statusRaw == "opening" {
                    Text(context.state.openingTime, style: .timer)
                        .font(.caption2).bold()
                        .foregroundStyle(.green)
                        .monospacedDigit()
                        .frame(minWidth: 36)
                } else {
                    Text(context.state.closingTime, style: .timer)
                        .font(.caption2).bold()
                        .foregroundStyle(.red)
                        .monospacedDigit()
                        .frame(minWidth: 36)
                }
            } minimal: {
                StatusDot(statusRaw: context.state.statusRaw, size: 12)
            }
        }
    }

    private func statusColor(_ raw: String) -> Color {
        switch raw {
        case "closed":  return .red
        case "warning": return .yellow
        case "opening": return .yellow
        default:        return .green
        }
    }
}

// MARK: - Lock Screen View

struct LockScreenLiveActivityView: View {
    let context: ActivityViewContext<CrossingActivityAttributes>

    var body: some View {
        HStack(spacing: 16) {
            // Ampel links
            VStack(spacing: 4) {
                circle(.red,    active: context.state.statusRaw == "closed")
                circle(.yellow, active: context.state.statusRaw == "warning" || context.state.statusRaw == "opening")
                circle(.green,  active: context.state.statusRaw == "open")
            }
            .padding(8)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            // Mitte: Info
            VStack(alignment: .leading, spacing: 6) {
                Text("Bahnübergang Dachauer Str.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Text(context.state.statusLabel)
                    .font(.subheadline.bold())
                    .foregroundStyle(statusColor(context.state.statusRaw))

                HStack(spacing: 4) {
                    Text(context.state.trainLine).bold()
                    Text("→ \(context.state.trainDirection)")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }

            Spacer()

            // Rechts: Countdown
            VStack(alignment: .trailing, spacing: 4) {
                if context.state.statusRaw == "closed" || context.state.statusRaw == "opening" {
                    Text("Öffnet in")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(context.state.openingTime, style: .timer)
                        .font(.title3.bold())
                        .foregroundStyle(.green)
                        .monospacedDigit()
                } else {
                    Text("Rot in")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(context.state.closingTime, style: .timer)
                        .font(.title3.bold())
                        .foregroundStyle(.red)
                        .monospacedDigit()
                }
            }
        }
        .padding(14)
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private func circle(_ color: Color, active: Bool) -> some View {
        Circle()
            .fill(active ? color : color.opacity(0.15))
            .frame(width: 18, height: 18)
    }

    private func statusColor(_ raw: String) -> Color {
        switch raw {
        case "closed":  return .red
        case "warning": return .yellow
        case "opening": return .yellow
        default:        return .green
        }
    }
}

// MARK: - Hilfselemente

struct StatusDot: View {
    let statusRaw: String
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
    }

    private var color: Color {
        switch statusRaw {
        case "closed":  return .red
        case "warning": return .yellow
        case "opening": return .yellow
        default:        return .green
        }
    }
}
