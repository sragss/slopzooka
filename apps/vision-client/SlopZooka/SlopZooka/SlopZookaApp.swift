//
//  SlopZookaApp.swift
//  SlopZooka
//
//  Created by Sam Ragsdale on 3/22/26.
//

import SwiftUI

@main
struct SlopZookaApp: App {
    @UIApplicationDelegateAdaptor(WindowApplicationDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Launcher", id: "launcher") {
            WindowScene(windows: appDelegate.windows) { ContentView() }
        }
        .defaultSize(width: 460, height: 680)
        .windowStyle(.plain)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.presented)

        WindowGroup("Terminal", id: "terminal", for: String.self) { sessionID in
            WindowScene(windows: appDelegate.windows, id: sessionID.wrappedValue) {
                TerminalWindowView(sessionID: sessionID.wrappedValue)
            }
        }
        .defaultSize(width: 1280, height: 832)
        .windowStyle(.plain)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)

        WindowGroup("Preview", id: "preview", for: String.self) { previewID in
            WindowScene(windows: appDelegate.windows, id: previewID.wrappedValue) {
                BrowserWindowView(previewID: previewID.wrappedValue)
            }
        }
        .defaultSize(width: 1200, height: 820)
        .windowStyle(.plain)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)

        ImmersiveSpace(id: ImmersiveWorkspaceState.sceneID) {
            ImmersiveWorkspaceScene(windows: appDelegate.windows)
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}
