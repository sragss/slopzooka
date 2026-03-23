//
//  SlopZookaApp.swift
//  SlopZooka
//
//  Created by Sam Ragsdale on 3/22/26.
//

import SwiftUI

@main
struct SlopZookaApp: App {
    var body: some Scene {
        WindowGroup("Launcher", id: "launcher") {
            ContentView()
        }
        .defaultSize(width: 620, height: 820)
        .windowStyle(.plain)
    }
}
