//
//  Schrankenradar_OSHApp.swift
//  Schrankenradar OSH
//
//  Created by Jonas Feischl on 30.05.26.
//

import SwiftUI
import FirebaseCore

@main
struct Schrankenradar_OSHApp: App {

    init() {
        FirebaseApp.configure()
    }

    var body: some Scene {
        WindowGroup {
            TabView {
                ContentView()
                    .tabItem {
                        Label("Radar", systemImage: "antenna.radiowaves.left.and.right")
                    }

                SchrankenModeView()
                    .tabItem {
                        Label("Schranke", systemImage: "record.circle")
                    }
            }
        }
    }
}
