//
//  Schrankenradar_OSHApp.swift
//  Schrankenradar OSH
//
//  Created by Jonas Feischl on 30.05.26.
//

import SwiftUI
import UserNotifications

@main
struct Schrankenradar_OSHApp: App {

    @State private var viewModel        = CrossingViewModel()
    @State private var locationMonitor  = LocationMonitor()
    @State private var voiceAnnouncer   = VoiceAnnouncer()

    var body: some Scene {
        WindowGroup {
            TabView {
                ContentView(viewModel: viewModel, locationMonitor: locationMonitor, voiceAnnouncer: voiceAnnouncer)
                    .tabItem {
                        Label("Radar", systemImage: "antenna.radiowaves.left.and.right")
                    }

                SchrankenModeView(viewModel: viewModel)
                    .tabItem {
                        Label("Schranke", systemImage: "record.circle")
                    }

                SettingsView(viewModel: viewModel, locationMonitor: locationMonitor, voiceAnnouncer: voiceAnnouncer)
                    .tabItem {
                        Label("Einstellungen", systemImage: "gearshape.fill")
                    }
            }
            .task {
                UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
                UNUserNotificationCenter.current().removeAllDeliveredNotifications()
            }
        }
    }
}
