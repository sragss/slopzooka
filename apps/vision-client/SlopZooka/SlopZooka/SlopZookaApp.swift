//
//  SlopZookaApp.swift
//  SlopZooka
//
//  Created by Sam Ragsdale on 3/22/26.
//

import SwiftUI

@main
struct SlopZookaApp: App {
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        WindowGroup("Launcher", id: "launcher") {
            ContentView()
                .environmentObject(appModel)
        }
        .defaultSize(width: 460, height: 680)
        .windowStyle(.plain)
        .windowResizability(.contentSize)

        WindowGroup("Terminal", id: "terminal", for: String.self) { sessionID in
            TerminalWindowView(sessionID: sessionID.wrappedValue)
                .environmentObject(appModel)
        }
        .defaultSize(width: 1280, height: 832)
        .windowStyle(.plain)
        .windowResizability(.contentSize)
    }
}
