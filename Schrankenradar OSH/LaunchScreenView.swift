//
//  LaunchScreenView.swift
//  Schrankenradar OSH
//
//  Created by Jonas Feischl on 24.08.26.
//

import SwiftUI

/// Splash-Screen mit dem "Bahnradar"-Logo und drehendem Radar-Sweep, der beim
/// Kaltstart kurz über der App eingeblendet wird (siehe Schrankenradar_OSHApp).
/// Folgt dem System-Erscheinungsbild (Light/Dark), genau wie der native
/// Launchscreen (siehe LaunchBackground-Colorset) — Dark ist dunkelblau/violett,
/// Light nutzt das Markenblau (siehe Color.brand) mit weißen Akzenten.
struct LaunchScreenView: View {
    @Environment(\.colorScheme) private var colorScheme

    private var isDark: Bool { colorScheme == .dark }

    private let violet = Color(red: 0.58, green: 0.49, blue: 0.94)
    private let navy = Color(red: 0.11, green: 0.11, blue: 0.19)

    private var backgroundColors: [Color] {
        isDark
            ? [Color(red: 0.09, green: 0.10, blue: 0.19), Color(red: 0.04, green: 0.04, blue: 0.08)]
            : [Color(red: 0.38, green: 0.72, blue: 0.96), Color(red: 0.20, green: 0.56, blue: 0.88)]
    }

    /// Farbe von Ringen, Sweep-Beam und Blip-Punkt.
    private var accentColor: Color { isDark ? violet : .white }
    /// Farbe des feststehenden Mittelpunkts.
    private var hubColor: Color { isDark ? .white : navy }
    /// Wortmarke, Trennlinie und Untertitel.
    private var inkColor: Color { .white }

    var body: some View {
        ZStack {
            LinearGradient(colors: backgroundColors, startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            RadialGradient(
                colors: [(isDark ? violet : .white).opacity(isDark ? 0.16 : 0.22), .clear],
                center: isDark ? UnitPoint(x: 0.3, y: 0.46) : UnitPoint(x: 0.28, y: 0.1),
                startRadius: 0,
                endRadius: isDark ? 260 : 240
            )
            .ignoresSafeArea()

            HStack(spacing: 18) {
                RadarGlyph(size: 84, accentColor: accentColor, hubColor: hubColor)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Bahnradar")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(inkColor)

                    Rectangle()
                        .fill(inkColor.opacity(isDark ? 0.5 : 0.6))
                        .frame(width: 190, height: 1)

                    Text("SCHRANKEN IN ECHTZEIT")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .tracking(3)
                        .foregroundStyle(isDark ? violet.opacity(0.85) : inkColor.opacity(0.9))
                }
            }
            .padding(.horizontal, 24)
        }
    }
}

/// Radar-Kreis mit rotierendem Sweep-Beam (Comet-Tail-Gradient, wie bei echten
/// Radar-UIs) — Ringe und Punkte bleiben fest, nur der Beam dreht sich endlos.
private struct RadarGlyph: View {
    let size: CGFloat
    let accentColor: Color
    let hubColor: Color

    @State private var rotate = false

    var body: some View {
        ZStack {
            ForEach([0.34, 0.64, 0.94], id: \.self) { fraction in
                Circle()
                    .stroke(accentColor.opacity(0.32), lineWidth: 1)
                    .frame(width: size * fraction, height: size * fraction)
            }

            Circle()
                .fill(
                    AngularGradient(
                        stops: [
                            .init(color: accentColor.opacity(0), location: 0.0),
                            .init(color: accentColor.opacity(0), location: 0.78),
                            .init(color: accentColor.opacity(0.9), location: 1.0),
                        ],
                        center: .center
                    )
                )
                .frame(width: size * 0.94, height: size * 0.94)
                .rotationEffect(.degrees(rotate ? 360 : 0))

            Circle()
                .fill(accentColor)
                .frame(width: size * 0.1, height: size * 0.1)
                .offset(x: size * 0.19, y: -size * 0.07)

            Circle()
                .fill(hubColor)
                .frame(width: size * 0.095, height: size * 0.095)
        }
        .frame(width: size, height: size)
        .onAppear {
            withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) {
                rotate = true
            }
        }
    }
}

#Preview("Dark") {
    LaunchScreenView()
        .preferredColorScheme(.dark)
}

#Preview("Light") {
    LaunchScreenView()
        .preferredColorScheme(.light)
}
